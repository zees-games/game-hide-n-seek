extends "hs_module_base.gd"
## The commands, the chat wiring, the map vote and the tunable cvars of [HsModule] (a middle layer, split off for size); never loaded on its own.


## The maps the SERVER names for this game, fetched and added to the catalogue. Returns how
## many documents they held.
##
## [b]The server's list, not this game's.[/b] A map pack used to be a `server_dependencies`
## entry in `game.yml`, which travels in this game's own pack — so a new map meant a release
## of the game, and a server owner could not choose which maps to run. The owner names them
## now in their deployment's map config (dot-server-deploy's `cfg/content.yml`, which fills
## [member DotGameDescriptor.maps]); [DotGameContent] fetches each pack and hands back its
## `maps/` directory. A server that still names one under `server_dependencies` keeps working,
## because DotGameContent reads those too.
##
## [b]Still server-only.[/b] The server sends the map it is playing in MAP, so a client never
## needs a map file and none of these is in a client's content sync. With nothing named, this
## game plays its built-in map.
##
## [b]Called after EVERY catalogue load[/b], not only the first: `load_from` forgets everything
## read before, and a reload that did not come back here dropped every delivered map — which
## is what mg-wipeout and mg-deathrun did until the three were moved onto DotGameContent.
func _add_delivered_maps(world: HsGame) -> int:
	if server == null or world.catalogue == null:
		return 0

	var read := 0

	for root in await DotGameContent.map_dirs(server, "maps"):
		read += world.catalogue.add_directory(root)

	return read


## An operator's catch: `hs_catch <userid>`, as if a seeker had touched them. For a stuck
## round, and for testing a map's ending without six friends.
func _cmd_catch(ctx: DotCmdContext) -> void:
	var world := game as HsGame

	if world == null or ctx.argc() < 1 or not ctx.arg(0).is_valid_int():
		ctx.reply("Which player? hs_catch <userid>")
		return

	var id := HsNetBridge.player_key(ctx.arg(0).to_int())

	if world.catch(id, &"", HsGame.CAUGHT_TAG):
		ctx.reply("Caught %s." % id)
	else:
		ctx.reply("%s is not a hider who can be caught now." % id)


## A number as an operator would type it: `34`, not `34.000000`.
##
## [b]Not `%g`, which GDScript's format strings do not have.[/b] It is accepted by the parser
## and fails at RUNTIME with "unsupported format character" — inside `_game_load`, which is
## the one place in the module sequence that unwinds everything above it. The symptom in
## game-buses-from-hell was a server whose netcode came up, logged that it was ready, and
## then reported that the game would not load.
static func _number(value: float) -> String:
	return "%d" % int(round(value)) if is_equal_approx(value, round(value)) else "%.3f" % value


## One cvar, its default taken from the configuration rather than written twice.
func _tunable(
	cvar_name: String, current: float, description: String, apply: Callable
) -> void:
	var cvar := add_cvar(cvar_name, _number(current), description)

	if cvar == null:
		return

	# The handler must not capture `cvar`: it would be a reference cycle the engine never frees.
	cvar.changed.connect(func(_old: String, new_value: String) -> void:
		apply.call(new_value.to_float())
		log_info("a tunable changed", {"cvar": cvar_name, "now": new_value})
	)


## Joins the bridge's chat seam to the services layer's router.
##
## [b]Here rather than in either of them, because this is the only object that holds
## both.[/b] The bridge knows what arrived on the wire and nothing about what a line means;
## the services layer knows the rules and nothing about the wire. That separation is why a
## client cannot send a line with somebody else's name on it: what crosses is a channel id
## and a string, and everything else is decided on this side.
func _wire_chat() -> void:
	if bridge == null or services == null:
		return

	bridge.connect("say_requested", _on_say_requested)
	services.connect("command_entered", _on_chat_command)


## The players' vote for the next map, over dot-vote: `!vote`, `!rtv`, `!nominate`.
##
## [b]Opened [member HsVote.open_after_sec] into the last round on a map and applied when that
## round ends[/b]; see [code]game/hs_vote.gd[/code]. A server owner turns it off or reshapes it
## in `user://cfg/hideseek_vote.json` or `game.yml`'s `metadata: map_vote:`, keyed as dot-vote's
## [DotVoteRules]. A vote that cannot be built is a WARN and the rotation alone, never a server
## that will not start.
func _build_vote(world: HsGame) -> void:
	if world.catalogue == null:
		return

	vote = HsVote.new()
	vote.name = "MapVote"
	_wire_vote_hooks(world)
	add_child(vote)
	var ready := vote.setup()

	if not ready.ok:
		DotLog.result(CHANNEL, "the map vote; the rotation alone chooses", ready)
		vote.queue_free()
		vote = null
		return

	var commanded := vote.install_commands(self)
	DotLog.result(CHANNEL, "the map vote's commands", commanded)
	_wire_vote_menu_and_events(world)


## The callables the map vote asks the game and the server through.
func _wire_vote_hooks(world: HsGame) -> void:
	vote.commands_spec_fn = world.rotation_commands
	vote.in_rotation_fn = func(id: StringName) -> bool: return world.catalogue.in_rotation(id)
	vote.rotation_order_fn = func() -> Array: return world.catalogue.rotation_order
	vote.maps_fn = func() -> Array:
		var out: Array = []

		for id in world.catalogue.playable(world.config.map_ids):
			# A pack map is dot-vote's to list, with its pack's name.
			if world.catalogue.is_content(id):
				continue

			# maps.yml: a map outside the active rotation is not balloted or nominated.
			if not world.catalogue.in_rotation(id):
				continue

			out.append([id, str((world.catalogue.maps.get(id, {}) as Dictionary).get("name", id))])

		return out
	vote.apply_fn = func(id: StringName) -> DotResult:
		world.next_map_id = id
		return DotResult.success(id)
	vote.due_fn = func() -> bool:
		return world.rounds_left_on_map() <= 1
	vote.voters_fn = func() -> Array:
		var out: Array = []

		for id: Variant in world.players:
			var player: HsPlayer = world.players[id]

			if player == null or player.is_bot:
				continue

			var userid := HsNetBridge.session_of(StringName(str(id)))

			if userid > 0:
				out.append(StringName(str(userid)))

		return out
	vote.announce_fn = func(line: String) -> void:
		var chat: Object = services.get("chat") if services != null else null

		if chat != null:
			var _said: Variant = chat.call("announce", line, HsServices.CH_ALL)
		elif server != null:
			server.broadcast_message(line)
	vote.is_admin_fn = func(voter: StringName) -> bool:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null
		return session != null and session.has_permission(DotAdminFlags.CHANGEMAP)
	vote.ballot_fn = func(state: Dictionary) -> void:
		if server == null:
			return

		for session in server.playing_sessions():
			var data := state.duplicate()
			data["you"] = str(session.userid)
			server.send_notice(session, DotNotice.make(
				&"", "", float(state.get("seconds", -1.0)), MAP_BALLOT_TOPIC, data
			))
	vote.people_fn = func(voter: StringName) -> Dictionary:
		var session := server.session_by_userid(String(voter).to_int()) if server != null else null

		if session == null:
			return {}

		var avatar: Variant = session.identity.get("avatar_url") if session.identity != null else ""
		return {"name": session.display_name, "avatar": avatar if avatar is String else ""}

	# Whether a round is live, for `time_up: finish_round`: warmup and the gap between rounds
	# have nothing to play out, so a limit that runs out there changes at once. No match is
	# "cannot tell", which holds as before.
	vote.round_in_progress_fn = func() -> bool:
		return world.match_node == null or world.match_node.is_live()


## The map menu and the events that tell the vote where the round is.
func _wire_vote_menu_and_events(world: HsGame) -> void:
	# The map menu (M), dot-vote's: a player holding the owner's `sv_map_menu_flag` changes the
	# map now, not after its rounds, and sees the same rows a solo player does. Read by name,
	# because a server on a dot-vote older than the menu has no `map_menu` and runs without it.
	var menu_half: Variant = vote.commands.get(&"map_menu") if vote.commands != null else null
	if menu_half is Object:
		(menu_half as Object).set(&"change_fn", world.change_map_now)
		(menu_half as Object).set(&"rows_fn", func(_rows: Array) -> Array: return world.map_rows())

	_tunable("hs_vote_after", vote.open_after_sec,
		"Seconds into the last round on a map before the vote for the next one opens",
		func(value: float) -> void:
			if vote != null:
				vote.open_after_sec = maxf(value, 0.0))

	world.world_rebuilt.connect(func() -> void:
		if vote != null and world.map != null:
			vote.note_map(world.map.id())
	)
	world.round_began.connect(func(_number: int, _map: StringName) -> void:
		if vote != null:
			vote.note_round_start()
	)
	world.match_node.round_ended.connect(func(_number: int, _winner: int, _outcome: int) -> void:
		if vote != null:
			vote.note_round_end()
	)

	if server != null:
		server.client_disconnected.connect(func(session: DotClientSession, _reason: String) -> void:
			if vote != null:
				vote.forget_voter(StringName(str(session.userid)))
		)


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said: DotResult = services.call("say", peer_id, channel_id, text)

	if said.ok:
		return

	# Back to the one person who asked. A refusal broadcast would be a rate limit announced
	# to the server.
	bridge.call("notice", peer_id, said.error.message)


## A `!command` typed into chat. Run through the console as the person who typed it.
##
## [b]As THEM, not as the server.[/b] `run_command_as_uid` builds a context with that
## player's own flags, so `!kick` from somebody without the flag is refused by the same file
## that refuses it at the console — rather than by this function having an opinion.
func _on_chat_command(peer_id: int, command: String, args: PackedStringArray) -> void:
	if server == null:
		return

	var session := server.session_of(peer_id)

	if session == null:
		return

	for reply in server.run_command_as_uid(
		session.uid(), command, args, DotCmdContext.Source.CHAT
	):
		bridge.call("notice", peer_id, reply)


func _cmd_wish(ctx: DotCmdContext, side: int) -> void:
	var world := game as HsGame
	if world == null or ctx.session == null:
		ctx.reply("Only a player can choose a side.")
		return
	if not world.config.allow_side_choice:
		ctx.reply("Sides are drawn on this server.")
		return
	world.wish_side(HsNetBridge.player_key(ctx.session.userid), side)
	ctx.reply(
		"You will be picked to seek first." if side == HsGame.SEEKERS
		else ("You will only seek first if nobody else can." if side == HsGame.HIDERS else "Either side.")
	)


func _cmd_say(ctx: DotCmdContext) -> void:
	var text := ctx.rest()

	if text.strip_edges() == "":
		ctx.reply("Say what?")
		return

	if services == null or services.get("chat") == null:
		ctx.reply("This server has no chat.")
		return

	var announced: Variant = services.get("chat").call("announce", text, HsServices.CH_ALL)

	if announced is DotResult and not (announced as DotResult).ok:
		ctx.reply_error(announced)
		return

	ctx.reply("Said: %s" % text)


func _cmd_status(ctx: DotCmdContext) -> void:
	var world := game as HsGame

	if world == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.describe_lines())


func _cmd_net(ctx: DotCmdContext) -> void:
	if bridge == null:
		ctx.reply("No bridge; this server is not replicating anything.")
		return

	ctx.reply_lines(bridge.call("describe_lines"))

	if services != null:
		ctx.reply_lines(services.call("describe_lines"))


func _cmd_maps(ctx: DotCmdContext) -> void:
	var world := game as HsGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.catalogue.describe_lines())
	ctx.reply("playing: %s" % str(world.map_doc.get("id", "-")))


func _cmd_map(ctx: DotCmdContext) -> void:
	var world := game as HsGame
	var id := StringName(ctx.arg(0)) if ctx.argc() > 0 else &""

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	if id == &"" or not world.catalogue.playable(world.config.map_ids).has(id):
		ctx.reply("Which map? %s" % ", ".join(world.catalogue.playable(world.config.map_ids)))
		return

	world.next_map_id = id
	ctx.reply("%s is next, from the end of this round." % String(id))


func _cmd_taunts(ctx: DotCmdContext) -> void:
	var world := game as HsGame

	if world == null or world.taunts == null:
		ctx.reply("No world.")
		return

	for id in world.taunt_ids():
		var entry := world.taunts.entry(id)
		ctx.reply("  %-18s %-20s %.1f s" % [String(id), str(entry.get("title", "")), float(entry.get("seconds", 0.0))])

	ctx.reply(str(world.taunts.describe()))


func _cmd_reload(ctx: DotCmdContext) -> void:
	var world := game as HsGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	var loaded := world.catalogue.load_from(world.config.map_directory)
	loaded += await _add_delivered_maps(world)
	world.apply_rotation()

	if vote != null:
		vote.refresh_maps()

	ctx.reply("%d documents read; %d refused. The next map draws from them." % [
		loaded, world.catalogue.refused.size()])

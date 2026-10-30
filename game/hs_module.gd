extends "hs_module_cmds.gd"

## This game, as a module a dedicated server loads: [DotGameModule] holds the netcode, bridge, roster and teardown; this holds the cvars, console commands, map vote and minimum-players rule.
##
## No `class_name`: [method DotModuleHost.load_module] takes a path, and a module inside a dot-cloud pack cannot have one (a mounted pack's globals are not registered in the host).

# No `const CHANNEL`: [DotGameModule] declares one and a subclass may not redeclare it, which is right, since a second channel would split this module's records.

## Where the services keep punishments (empty: [DotGameServices]'s default store). Static because
## dot-server constructs the module from a path, so there is no instance to set a field on; a test
## points it at a directory of its own.
static var punishments_file: String = ""


func _map_config_keys() -> Dictionary:
	return HsMapConfig.KEYS


func _map_config_game() -> String:
	return HsMapConfig.GAME_ID


func _module_name() -> String:
	return "hideseek"


func _game_service() -> StringName:
	return HsGame.SERVICE


func _game_missing_hint() -> String:
	return (
		"create an HsGame, add it to the tree and let its _ready() register it under "
		+ "'%s' — a module cannot build the world, because the world outlives it"
		% String(HsGame.SERVICE)
	)


## The netcode's numbers, which are the game's and not the addon's.
## Tick rate comes from the world so `sv_tickrate` reaches it; a number written here would run at a rate the operator did not choose.
func _net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = (game as HsGame).tick_rate
	config.snapshot_rate = HsGame.NET_SNAPSHOT_RATE
	config.world_extent = HsGame.NET_WORLD_EXTENT
	config.enable_prediction = true
	# [b]Off: nothing here is shot.[/b] A catch is measured between two bodies on the server's
	# own present, and rewinding them would be catching somebody where they were.
	config.enable_lag_compensation = false
	# Everybody playing, and nothing else: the furniture is the map document, not entities, so
	# a snapshot is a full server's players and room to spare.
	config.max_entities_per_snapshot = 64
	return config


func _make_bridge() -> Node:
	return HsNetBridge.new()


## Chat, voice and moderation, over [DotGameServices].
## The bridge is handed over as the link; [DotGameModule] assigns `voice_relay_fn`, checks `check_admission` before seating anybody, and makes the roster follow this layer.
func _make_services() -> Node:
	var services := HsServices.new()
	services.bridge = bridge
	services.punishments_file = punishments_file
	return services


## Profiles, avatars and admission: dot-platform's [DotPlatformIdentity] over this game's one-slot schema.
## Authentication is the host's `dot_auth_server`, the same for every game; this layer is a scoped profile, a name and a face. With authentication off everybody is a guest.
func _make_identity() -> Node:
	var identity_layer := DotPlatformIdentity.new()
	identity_layer.avatar_schema = HsAvatars.schema()
	identity_layer.stock_avatar_fn = HsAvatars.stock_avatar
	identity_layer.avatar_translate_fn = HsAvatars.from_site
	return identity_layer


func _game_load() -> DotResult:
	var world := game as HsGame

	if world == null:
		return DotResult.fail(DotError.CODE_STATE, "The registered game is not an HsGame.")

	# Nobody is caught or drawn to seek behind a loading cover: the roster is DotGameModule's,
	# so ask it by userid (a bot's key has none, and the roster holds nobody it did not seat).
	world.loading_fn = func(key: StringName) -> bool:
		return is_loading(HsNetBridge.session_of(key))

	add_command("hs_status", _cmd_status, "Show the round, the map and who is caught")
	add_command("hs_net", _cmd_net, "Show what the netcode is doing")
	# maps.yml, before the commands: its `commands: names:` block renames hs_maps / hs_map (roles
	# of those names) as it does dot-vote's, and the ballot reads the marks it sets.
	var _rotation := world.load_rotation()
	add_command(world.command_name("hs_maps", "hs_maps"), _cmd_maps, "List the maps, and any refused file")
	add_command("hs_reload", _cmd_reload, "Read the map directory again (from the next map)")
	add_command("hs_taunts", _cmd_taunts, "List the taunts")
	add_command(world.command_name("hs_map", "hs_map"), _cmd_map,
		"Play a map next: hs_map <id> (at the end of this round)", "")
	add_command("hs_catch", _cmd_catch, "Catch a hider now: hs_catch <userid>", "")
	# A player's wish for the next draw, from chat as !seek / !hide / !any.
	add_command("seek", _cmd_wish.bind(HsGame.SEEKERS), "Ask to seek in the next draw", "")
	add_command("hide", _cmd_wish.bind(HsGame.HIDERS), "Ask to hide in the next draw", "")
	add_command("any", _cmd_wish.bind(0), "Either side in the next draw", "")
	add_command("hs_say", _cmd_say, "Say something to everybody, as the server")

	_wire_chat()
	_wire_identity()
	_wire_map(world)
	_wire_progress(world)
	_add_tunables(world)
	_build_vote(world)

	_bind_rule_cvars(world)
	_bind_config(world)

	# REPLICATED: each client draws (or not) the map's world pack under the server's choice.
	var _worlds := add_cvar(
		"hs_use_worlds", "1",
		"Drawn worlds: 1 lets a client draw a map's converted world pack where it has one, 0 keeps the plain box look everywhere.",
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)

	_bots = add_cvar(
		"hs_bots", "1",
		"Automatic stand-ins: 1 keeps as many as bot_quota and bot_quota_mode say, 0 none at all."
	)

	# [DotBotQuota] is dot-server's, so `bot_quota` and `bot_quota_mode` mean the same on every server.
	# The default is this game's `minimum_players` in fill mode; `hs_bots` stays the switch it was.
	_quota = DotBotQuota.install(self, world.config.minimum_players)

	# Started here, not in the world's `_ready`: `start()` builds the map, and before the bridge exists nothing hears `world_rebuilt`, so no client is told of the map (invisible floors).
	var _delivered: int = await _add_delivered_maps(world)
	# A rotation file's wildcards match what is installed, so match again with the delivered maps.
	world.apply_rotation()

	# The vote was built above, before these arrived; read without them, its list held only
	# the practice map and never opened a ballot. hs_reload refreshes it the same way.
	if vote != null:
		vote.refresh_maps()

	world.start()

	log_info("the map is up", world.describe())
	return DotResult.success(null)


## The cvars of the rule sets this game runs under, each bound where it is declared.
func _bind_rule_cvars(world: HsGame) -> void:
	# sv_falldamage and its tunables: dot-combat's, on by default in this game. Server-side
	# only, so no REPLICATED: the damage is the server's and arrives as health.
	var _fall := world.fall_rules.bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY)

	# dot-player-controller's mp_forceview and mp_solidplayers, REPLICATED: the client places its own
	# camera and predicts its own player from them.
	var _views := world.view_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	var _bodies := world.body_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	# hs_ambient*: REPLICATED, because each client plays its own ambience under the server's intent; the directory cvar stays local.
	var _ambient := world.ambient_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED,
		DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY
	)
	# Dead bodies: dot-player-char's sv_ragdoll* set. The server only picks each death's reaction
	# from them; REPLICATED, because the clients draw the bodies (see the client's netcode).
	var _ragdolls := world.ragdoll_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)
	# The map's toys: dot-props' sv_toys* set. REPLICATED, because a client hides the toys the
	# server took away and draws the rest.
	var _toys := world.toy_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	)

	# mp_forcecamera, mp_freeroam, mp_freeroam_speed: dot-spectate's rules, so spectators
	# free-roam unless an operator says otherwise. REPLICATED, because each client flies its
	# own spectator camera under them (HsClient.toggle_roam).
	for made: Object in world.spectate_rules.bind_cvars(
		add_cvar, DotConVar.FLAG_ARCHIVE | DotConVar.FLAG_NOTIFY | DotConVar.FLAG_REPLICATED
	):
		if str(made.get(&"name")) == DotSpectatorRules.CVAR_FORCE_CAMERA:
			_force_camera_cvar = made


## Who somebody is reaches the world: a face as they are seated, and the real name and face
## once dot-platform has them. All three events end in [method HsNetBridge.refresh_player].
func _wire_identity() -> void:
	var link := bridge as HsNetBridge

	if link == null:
		return

	link.avatar_fn = _avatar_for
	hook_post("player_admitted", _on_profile)
	hook_post("player_avatar_changed", _on_profile)
	hook_post("player_renamed", _on_profile)


## What a session looks like: what dot-platform resolved for them, or the stock person.
## Through the platform module's `player_for`, never the hub by a key made here: the hub keys players by their scoped profile key, which only admission knows, so `u<session>` finds nobody. Duck-typed, since a server without dot-platform is a configuration.
func _avatar_for(session_id: int) -> DotAvatar:
	var session := server.session_by_userid(session_id) if server != null else null
	var platform: Object = server.modules.get_module("platform") \
		if server != null and server.modules != null else null

	if session != null and platform != null and platform.has_method("player_for"):
		var player: Variant = platform.call("player_for", session)

		if player is Object and (player as Object).get("avatar") is DotAvatar:
			return (player as Object).get("avatar") as DotAvatar

	if identity != null and identity.has_method("avatar_for"):
		return identity.call("avatar_for", String(HsNetBridge.player_key(session_id)))

	return null


func _on_profile(event: DotEvent) -> void:
	var session_id := event.get_int("userid")
	var session := server.session_by_userid(session_id) if server != null else null
	var link := bridge as HsNetBridge

	if session == null or link == null:
		return

	link.refresh_player(session_id, session.display_name, _avatar_for(session_id))


## The numbers an operator will want to change, as cvars.
## Live, each writing through to the configuration the world reads. `hs_players_per_seeker` changes the NEXT round's draw, not the current seekers.
func _add_tunables(world: HsGame) -> void:
	var config := world.config

	# [b]How the stand-ins see, hear, turn and know a map is dot-bot's[/b]: `bot_difficulty`
	# (easy, medium, hard, nightmare; medium by default) and every `bot_*` setting it bundles,
	# the names every game in the family uses. On the game as metadata, never the registry.
	var _bot_cvars := DotBotSettings.of(world).bind_cvars(add_cvar, DotConVar.FLAG_NOTIFY, add_command)


## Every [HsConfig] field as an `hs_<field>` cvar, a cfg/ yml key and a workbench set. The cvars shipped server configs and map files already use under other names stay, as aliases of the field.
func _bind_config(world: HsGame) -> void:
	var binder := world.config_binder
	if binder == null:
		return
	binder.bind_cvars(add_cvar, DotConVar.FLAG_ARCHIVE, console.has_name)
	binder.bind_commands(add_command)
	for alias: String in ALIASES:
		_alias(world, alias, ALIASES[alias])
	binder.field_changed.connect(_on_config_field)
	_start_workbench(world)


## An older cvar name for a config field: it reports the field and writes through the field's own cvar.
func _alias(world: HsGame, alias: String, key: String) -> void:
	var binder := world.config_binder
	var target := binder.cvar_for(key)
	var cvar := add_cvar(alias, _field_text(world.config.get(key)), "Same as hs_%s" % key)
	if cvar == null or target == null:
		return
	cvar.changed.connect(func(_old: String, new_value: String) -> void:
		var value: Variant = world.config.get(key)
		var text := new_value
		if value is bool:
			text = "1" if new_value.to_float() >= 0.5 else "0"
		elif value is int:
			text = str(roundi(new_value.to_float()))
		var _set: Variant = target.set_value(text))


static func _field_text(value: Variant) -> String:
	if value is bool:
		return "1" if value else "0"
	return str(value)


## A field changed from a cvar, the workbench or a file: the alias follows, and whatever the world cached is told.
func _on_config_field(key: String, _value: Variant, _source: String) -> void:
	var world := game as HsGame
	if world == null:
		return
	var config := world.config
	for alias: String in ALIASES:
		if ALIASES[alias] == key and console != null:
			var _set: Variant = console.set_cvar(alias, _field_text(config.get(key)))
	match key:
		"auto_taunt_seconds":
			if world.taunts != null:
				world.taunts.auto_after = config.auto_taunt_seconds
		"auto_taunt_radius":
			if world.taunts != null:
				world.taunts.auto_radius = config.auto_taunt_radius
		"taunt_points":
			if world.taunts != null:
				world.taunts.points_voluntary = config.taunt_points
		"forced_taunt_points":
			if world.taunts != null:
				world.taunts.points_forced = config.forced_taunt_points
		"auto_bunny_hop":
			for id: StringName in world.players:
				(world.players[id] as HsPlayer).retune()
		"spectate_camera":
			# Through the cvar, so what `mp_forcecamera` reports is what is in force.
			if _force_camera_cvar != null:
				var _set: Variant = _force_camera_cvar.set_value(str(config.spectate_camera))
			elif world.spectate != null:
				world.spectate.set_force_camera(config.spectate_camera)
		"minimum_players":
			if _quota != null and _quota.quota_cvar != null:
				var _set: Variant = _quota.quota_cvar.set_value(str(config.minimum_players))
		"map_rotation_file":
			config.map_rotation_file = config.map_rotation_file.strip_edges()
			var _read := world.load_rotation()
			if vote != null:
				vote.refresh_maps()


## dot-workbench over the config and the block rules: the F9 panel off a dedicated server, the HTTP page only with `workbench.enabled` in cfg/server.yml. Edits are admitted for dot-auth tickets of the listed admins.
func _start_workbench(world: HsGame) -> void:
	workbench = DotGameWorkbench.new()
	workbench.name = "Workbench"
	workbench.dedicated = DisplayServer.get_name() == "headless"
	workbench.listen_host_fn = func() -> bool: return DisplayServer.get_name() != "headless"
	var admin_permit := Callable()
	if server != null and server.admins != null:
		admin_permit = server.admins.uid_has_permission
	workbench.permit_fn = func(actor: Variant, flag: String) -> bool:
		return admin_permit.is_valid() and actor is String and bool(admin_permit.call(actor, flag))
	for set: DotProfileSet in world.config_binder.profile_sets():
		workbench.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	var ambient_set := DotGameWorkbench.cvar_set(console, HsAmbience.cvar_types(), AMBIENT_KIND)
	if ambient_set != null:
		workbench.add_set(ambient_set, "Ambience (hs_ambient*)")
	add_child(workbench)
	var started := workbench.start(world.ensure_runtime())
	if not started.ok:
		DotLog.result(CHANNEL, "the workbench", started)
		return
	# Off until the owner sets sv_workbench_remote 1; then flagged admins edit from a client.
	if net != null:
		var _served := workbench.serve_remote(net)
	if workbench.api != null:
		var rt := workbench.api.runtime as DotProfileRuntime
		if rt != null:
			world.config_binder.attach(rt)
			if ambient_set != null:
				DotGameWorkbench.bind_cvar_set(ambient_set, rt, console)
	add_command("workbench", func(ctx: DotCmdContext) -> void: ctx.reply_lines(_workbench_lines()),
		"Show the admin workbench's state", DotAdminFlags.CVAR)


## The workbench's runtime, so the `noblock` kind is listed beside the game settings.
func _noblock_runtime() -> Object:
	return workbench.api.runtime if workbench != null and workbench.api != null else null


## Hiders pass hiders and seekers pass seekers under `mp_teamblock 0`; the world's sides, not a numeric userid.
func _noblock_side(id: Variant) -> Variant:
	return (game as HsGame).team_of_side(id)


func _workbench_lines() -> PackedStringArray:
	if workbench == null:
		return PackedStringArray(["workbench    off"])
	if workbench.running_http:
		return PackedStringArray(["workbench    http " + JSON.stringify(workbench.http.call("describe"))])
	return PackedStringArray(["workbench    off (workbench.enabled in cfg/server.yml)"])


## Nothing to undo: the commands are removed by [DotModule], and the netcode, bridge and roster are [DotGameModule]'s. The world predates the module and survives `module reload`, so it is not freed here.
func _game_unload() -> void:
	if workbench != null:
		workbench.queue_free()
		workbench = null
	if game != null and "block_rules" in game:
		game.set(&"block_rules", null)
	if game != null and "loading_fn" in game:
		game.set(&"loading_fn", Callable())

	_bot_ids.clear()

	if vote != null:
		vote.queue_free()
		vote = null


## The server slept or woke. The vote's director follows it on its own (DotGameModule finds
## it); the map ballot's timer is this game's, so it starts again here on waking.
func _game_hibernation(hibernating: bool) -> void:
	if not hibernating and vote != null:
		vote.note_woke()


## Keeps enough people in the round for there to be one.
## A seeker and a hider, or nothing happens: a side with nobody satisfies "round over" on the first tick, so one person alone would loop start/end rounds, each decided correctly and never erroring.
## A stand-in is removed the moment a person takes their place.
func _game_tick(_tick: int, delta: float) -> void:
	if vote != null:
		vote.advance(delta)

	_since_roster_check += delta

	if _since_roster_check < ROSTER_INTERVAL:
		return

	_since_roster_check = 0.0
	_keep_the_round_full()
	_note_pings()


## Each session's ping onto its player, for the Tab board. dot-server already keeps it.
func _note_pings() -> void:
	var world := game as HsGame
	if world == null or server == null:
		return
	for session in server.playing_sessions():
		var who: HsPlayer = world.players.get(HsNetBridge.player_key(session.userid))
		if who != null:
			who.ping_ms = session.ping_ms


func _keep_the_round_full() -> void:
	var world := game as HsGame

	if world == null or bridge == null or _quota == null:
		return

	# People only: a stand-in or a bot added by hand through the bridge is never in `_bot_ids`, so it stays outside the count. A leaver is gone from `players` once the bridge removes them.
	var humans := 0

	for id: StringName in world.players:
		if not (world.players[id] as HsPlayer).is_bot:
			humans += 1

	# Forget any that have gone for some other reason — a round reset, an admin — so the
	# count below is of stand-ins that actually exist.
	for index in range(_bot_ids.size() - 1, -1, -1):
		if not world.players.has(_bot_ids[index]):
			_bot_ids.remove_at(index)

	# `hs_bots 0` takes the stand-ins out as well as not adding more: a switch that left the
	# ones already in until a map change would be an operator with no way to empty a server.
	var wanted := 0

	if _bots == null or _bots.get_bool():
		var slots: int = server.config.max_players if server != null and server.config != null else -1
		wanted = _quota.wanted(humans, slots)

	for _i in range(maxi(wanted - _bot_ids.size(), 0)):
		var bot: HsPlayer = bridge.call("add_bot", _bot_name(world))

		if bot == null:
			break

		_bot_ids.append(bot.player_id)

	# Newest first, so the stand-in a person replaces is the one that arrived last and the
	# ones that have been playing longest keep playing.
	while _bot_ids.size() > wanted:
		var leaving: StringName = _bot_ids.pop_back()
		bridge.call("remove_player", HsNetBridge.session_of(leaving))


## A stand-in's name: the game's list through dot-bot's [DotBotNames], never one already in
## [param world], so solo and a server name them alike and a scoreboard never has two Wrens.
static func _bot_name(world: HsGame) -> String:
	var taken: Array = []
	for id: StringName in world.players:
		taken.append((world.players[id] as HsPlayer).display_name)
	return DotBotNames.pick(taken, world.players.size(), HsGame.BOT_NAMES)


## The map is what a server listing prints, reported on every rebuild: the server forgets it
## whenever a game unloads, and a browser showing last round's map is a browser lying.
func _wire_map(world: HsGame) -> void:
	if world.map != null and not world.map.doc.is_empty():
		report_map(String(world.map.id()))

	world.world_rebuilt.connect(func() -> void:
		report_map(String(world.map.id()))
	)


## An achievement is told to the one person who earned it.
## As a notice, which a client already draws in its chat box, not a new event kind; a stand-in never earns one ([HsProgress] does not count them).
func _wire_progress(world: HsGame) -> void:
	if bridge == null:
		return

	# Filed under dot-game's stable per-server key (guests too), so it outlives the connection
	# and a restart; see [HsProgress].
	if world.progress != null:
		world.progress.durable_key_fn = func(id: StringName) -> String:
			var session := server.session_by_userid(HsNetBridge.session_of(id)) \
				if server != null else null
			return String(stats_feed.key_for(session)) if session != null and stats_feed != null else ""

	world.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		var peer_id: int = bridge.call("peer_for_player", HsNetBridge.session_of(id))

		if peer_id > 0:
			bridge.call("notice", peer_id, "Achievement: %s (+%d)" % [title, points])
	)


## This game's columns on the Tab board: the points, and which side.
func _game_board_fields(session: Object) -> Dictionary:
	var world := game as HsGame
	var who: HsPlayer = world.players.get(HsNetBridge.player_key(int(session.get(&"userid")))) if world != null and session != null else null

	if who == null:
		return {}

	return {"points": who.points, "team": world.team_of(who.player_id)}


func describe() -> Dictionary:
	var out := super.describe()
	var world := game as HsGame

	if world != null:
		out.merge({"round": world.round_number, "world": world.describe()}, true)

	return out

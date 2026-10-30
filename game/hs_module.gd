extends "hs_module_cmds.gd"

## This game, as a module a dedicated server loads.
##
## [b]A hundred and forty lines, against the five hand-written modules' 837 to 1,816.[/b]
## [DotGameModule] holds the netcode and its four load-bearing constants, the bridge, the
## message seal, the identity layer, the roster, the authoritative tick and a teardown in
## the reverse order. Two of those five hand-written copies had the same line wrong and
## nobody could ever join those servers. What is left here is what is actually this game's:
## the cvars an operator turns between rounds, the console commands, the map vote, and the rule
## that keeps enough people in a round for one to happen.
##
## [b]No `class_name`, and that is a requirement rather than a style.[/b]
## [method DotModuleHost.load_module] takes a PATH and constructs the module itself — it
## must, because that is the shape that lets an operator name one in a config file — and a
## module delivered inside a dot-cloud pack cannot have a `class_name` at all: a mounted
## pack's globals are not registered in the host.
##
## [codeblock]
## server.modules.load_module("res://game/hs_module.gd")
## [/codeblock]

# [b]No `const CHANNEL` here, and its absence is the point.[/b] [DotGameModule] already
# declares one and GDScript refuses to let a subclass redeclare it — which is the right
# refusal: a module logs through [method DotModule.log_info], which stamps the module's own
# name, so a second channel would split one module's records across two places an operator
# has to know to turn up separately.

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
##
## Tick rate from the world, so `sv_tickrate` reaches it: the server sets the engine's
## physics rate from that cvar at boot, the world is built after the server and reads it,
## and this reads the world. A number written here instead would be a netcode running at a
## rate the operator did not choose, silently.
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
##
## [b]The bridge is handed over as the link, and that is the whole of the wiring.[/b] A chat
## line goes out through `send_chat` and a voice frame through `send_voice`, both on this
## game's own wire. [DotGameModule] does the rest: it assigns the bridge's `voice_relay_fn`,
## checks `check_admission` before seating anybody, and tells the roster to follow this layer
## so a leaver is forgotten by the rate limiter and the voice router together.
func _make_services() -> Node:
	var services := HsServices.new()
	services.bridge = bridge
	services.punishments_file = punishments_file
	return services


## Profiles, avatars and admission: dot-platform's [DotPlatformIdentity] over this game's
## one-slot schema. [DotGameModule] builds it before the services and loads dot-platform's
## own module beside it.
##
## [b]Authentication is not here and was never this game's.[/b] Whether a player is proven
## to be somebody is the host's `dot_auth_server`, the same for every game it runs; what
## this layer does is everything after — a scoped profile, the name on it, and a face.
## With authentication off everybody is a guest with a profile of their own, which is what
## a LAN server is.
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

	# [b]How many is dot-server's [DotBotQuota], so `bot_quota` and `bot_quota_mode` mean the
	# same thing on every server in the family.[/b] The default is this game's own minimum
	# (`minimum_players`, from the config file) in fill mode, which is the rule it ran before
	# the policy was shared: stand-ins top the round up to that many players, a person who
	# joins takes a stand-in's place, and the stand-in comes back when they leave. `hs_bots`
	# stays the switch it always was, so a server config that sets it means what it meant.
	_quota = DotBotQuota.install(self, world.config.minimum_players)

	# [b]Started here and not in the world's own `_ready`.[/b] `start()` builds the map and puts
	# everybody on it, and a world that did that before the bridge existed would have built a
	# map with nothing listening to `world_rebuilt` — one the server knows about and no client
	# is ever told about. Invisible floors: a player stands on nothing and the server says they
	# are fine.
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

	# dot-player-controller's mp_forceview (first or third person: the player's choice, or one
	# held) and mp_solidplayers (players and stand-ins block each other, 1 by default).
	# REPLICATED: the client places its own camera under the first and predicts its own
	# player under the second.
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
##
## [b]Through the platform module's `player_for`, and never the hub by a key made here.[/b]
## The hub keys a player by their scoped profile key, which only admission knows; a lookup
## by `u<session>` finds nobody, every time, and falls through to stock — which reads as
## "this player has no avatar" rather than as a wrong key. Duck-typed, because a server
## without dot-platform is a configuration.
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


## The numbers an operator is actually going to want to change, as cvars.
##
## [b]Live, and each one writes through to the configuration the world already reads.[/b] A
## server owner finds their server's balance by moving one of them between rounds with people
## watching; a JSON file and a restart is a balance nobody tunes.
##
## [b]What is NOT here is anything the round has already decided.[/b] `hs_players_per_seeker`
## changes how many are drawn for the NEXT round; it does not make anybody a seeker now.
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


## [b]Nothing to undo.[/b] The commands are the module's own and [DotModule] removes them;
## the netcode, the bridge and the roster are [DotGameModule]'s and it tears them down in
## the reverse order it built them. The world is NOT this module's to free: it was in the
## tree before the module loaded, and a server can unload and reload a game module without
## the map going away, which is what `module reload` is for.
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
##
## [b]A seeker and a hider, or nothing happens at all.[/b] A round ends the moment a side has
## nobody alive, and a side with nobody AT ALL satisfies that on the first tick — so a server
## with one person on it would start a round, end it and start another for as long as nobody
## else joined. Every one of those rounds is decided correctly, which is why nothing errors.
##
## A stand-in is removed the moment a person takes their place. They are here to make the
## game exist, not to take the fun half from the people who came to play it.
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

	# People only. A stand-in is not one, and neither is a bot somebody put in by hand through
	# the bridge (a test, an admin): those are never in `_bot_ids` either, so they are left
	# alone and outside the count. A leaver is gone from `players` the moment the bridge
	# removes them, so nobody half-disconnected is counted.
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
##
## [b]As a notice, which a client already draws in its chat box[/b], rather than a new event
## kind: an unlock is text for one player, which is exactly what a notice is — and a stand-in
## never earns one, because [HsProgress] does not count them.
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

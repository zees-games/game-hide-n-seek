extends Node

const HsConfig := preload("../game/hs_config.gd")
const HsGame := preload("../game/hs_game.gd")
const HsPlayer := preload("../game/hs_player.gd")
const HsNetLink := preload("../game/net/hs_net_link.gd")

## The game as a deployed server runs it: a real [DotServer], booted from a config file, with
## the module loaded BY PATH the way an operator names it — so the netcode, the services, the
## cvars and the stand-ins are the ones a deployment gets, not a copy assembled for a test.
##
## [b]What neither of the other suites can reach.[/b] `headless_run` drives a world by hand and
## `headless_net` joins two halves with no server; this is the only place [HsModule] loads,
## [DotGameModule]'s order runs, a cvar is typed at a console and a round is played by
## nothing but the stand-ins the module seats itself.

const SECTIONS := 13
const CHECKS := 98

const SERVER_DIR := "user://hs_dedicated"
const PORT := 28931
const QUERY_PORT := 28932
const TICK_RATE := 60

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

var server: DotServer = null
var game: HsGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("hideseek as a dedicated server")
	print("")

	var probe: Array = []
	if not _is_exit_probe():
		probe = await _run_exit_probe()

	DotPaths.remove_tree(SERVER_DIR)
	DirAccess.make_dir_recursive_absolute(SERVER_DIR)

	await _boot()

	if server != null and server.state == DotServer.State.RUNNING:
		await _test_the_module_loads()
		_test_the_commands()
		await _test_a_round_runs()
		await _test_a_reload_keeps_delivered_maps()
		await _test_the_map_vote()
		_test_map_rotation_file()
		_test_finish_round_waits_for_a_live_round()
		await _test_loading_cover()
		await _test_a_module_reload()
		await _test_it_unloads_cleanly()

	_test_no_message_preloads_itself()

	if not probe.is_empty():
		_test_exits_clean(probe)

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	# The copy of this suite that the exit probe runs does not run the probe itself.
	var sections := SECTIONS - (1 if _is_exit_probe() else 0)
	var checks := CHECKS - (EXIT_PROBE_CHECKS if _is_exit_probe() else 0)

	if _sections_entered != _sections_finished or _sections_entered != sections:
		print("ERROR: %d of %d sections finished, %d declared." % [_sections_finished, _sections_entered, sections])
		code = 1

	if _passed + _failed != checks:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, checks])
		code = 1

	await _shut_down()
	DotPaths.remove_tree(SERVER_DIR)
	get_tree().quit(code)


## Takes the server down before quitting: a booted [DotServer]'s listener holds the main loop,
## and a run that only called `quit()` prints its results and hangs. See mg-smash-copter.
func _shut_down() -> void:
	if server == null:
		return

	if server.modules != null:
		server.modules.unload_all()

	server.shutdown("the dedicated test is finished")

	for _i in range(10):
		await get_tree().process_frame

	if is_instance_valid(game):
		remove_child(game)
		game.free()
		game = null

	if is_instance_valid(server):
		remove_child(server)
		server.free()
		server = null

	await get_tree().process_frame


func _boot() -> void:
	_section("booting")

	# `startup_config`, because `sv_tickrate` is startup-only and dot-server execs this file
	# before the listener for exactly that reason.
	var cfg_path := "%s/server.cfg" % SERVER_DIR
	var cfg := FileAccess.open(cfg_path, FileAccess.WRITE)
	cfg.store_line("// written by examples/dedicated.gd")
	cfg.store_line("sv_tickrate %d" % TICK_RATE)
	cfg.close()

	var config := DotServerConfig.new()
	config.startup_config = cfg_path
	config.autoexec_config = ""
	config.hostname = "hideseek test"
	config.max_players = 24
	config.hibernate_when_empty = false
	config.rcon_password = ""
	config.port = PORT
	config.query_port = QUERY_PORT
	config.admins_path = "%s/admins.json" % SERVER_DIR
	config.bans_path = "%s/bans.json" % SERVER_DIR
	config.audit_log_path = "%s/audit.jsonl" % SERVER_DIR
	# Off, or this run never ends: a thread blocked in a read of stdin is one Godot will not
	# exit without.
	config.stdin_console_enabled = false

	server = DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)

	for _i in range(120):
		await get_tree().process_frame

		if server.state == DotServer.State.RUNNING:
			break

	_check(server.state == DotServer.State.RUNNING, "the server boots", DotServer.State.keys()[server.state])
	_check(Engine.physics_ticks_per_second == TICK_RATE, "and sv_tickrate reached the engine",
		"%d" % Engine.physics_ticks_per_second)
	_finished()


func _test_the_module_loads() -> void:
	_section("the module")

	# The world is built after the server (whose tick rate it reads) and before the module
	# (which refuses to load without a world to run; it cannot build one).
	var config := HsConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.hide_seconds = 3.0
	config.round_seconds = 30.0
	config.minimum_players = 3
	config.map_ids = PackedStringArray(["hs_practice"])

	game = HsGame.new()
	game.name = "World"
	game.config = config
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)
	await get_tree().process_frame

	_check(DotRegistry.get_node_service(HsGame.SERVICE) == game, "the world publishes itself where a module looks")
	_check(not game.map_doc.is_empty(), "and already has a map")

	(load("res://game/hs_module.gd") as GDScript).set("punishments_file", "%s/punishments.json" % SERVER_DIR)
	var loaded: DotResult = await server.modules.load_module("res://game/hs_module.gd")
	_check(loaded.ok, "the module loads into the server", loaded.error.message if not loaded.ok else "")

	var module := _module()
	_check(module != null and module.get("net") != null and module.get("bridge") != null,
		"with its netcode and the game's bridge")

	var net: DotNetManager = module.get("net") if module != null else null
	_check(net != null and net.config.tick_rate == TICK_RATE, "the netcode runs at the configured rate")
	_check(net != null and absf(net.config.world_extent - HsGame.NET_WORLD_EXTENT) < 0.01,
		"against the world extent both ends decode with")
	_finished()


func _test_the_commands() -> void:
	_section("the console")
	_check(_said(_run_command("hs_status"), "hideseek"), "hs_status says what the round is doing")
	_check(_said(_run_command("hs_maps"), "hs_practice"), "hs_maps lists the maps")
	_check(_said(_run_command("hs_taunts"), "You lose"), "hs_taunts lists the taunts")
	_check(_said(_run_command("hs_net"), "bridge"), "hs_net says what the netcode is doing")

	# A cvar's default is the value the world was built with, and setting one writes through.
	_check(_said(_run_command("hs_round_seconds"), "30"), "hs_round_seconds reports the world's own value")
	var _set := _run_command("hs_round_seconds 45")
	_check(is_equal_approx(game.config.round_seconds, 45.0), "and setting it writes through to the world",
		"%.1f" % game.config.round_seconds)
	var _back := _run_command("hs_max_seekers 0")
	_check(game.config.max_seekers == 1, "a round with no seeker is not one: it is taken as one",
		"%d" % game.config.max_seekers)
	_finished()


## A whole round, played by the stand-ins the module seats on its own.
func _test_a_round_runs() -> void:
	_section("a round, played by the stand-ins")
	var rounds: Array = []
	var drawn: Array = []
	game.round_over.connect(func(n: int, winner: int, why: String) -> void: rounds.append([n, winner, why]))
	game.round_began.connect(func(_n: int, _map: StringName) -> void: drawn.append(game.players_on(HsGame.SEEKERS).size()))

	# The server ticks itself, in real time. The module tops the server up every two seconds. A
	# round is three seconds of hiding and at most forty-five of seeking here: the stand-in
	# seekers catch everybody or the clock gives it to the hiders.
	#
	# [b]Bounded in the server's ticks, not the wall clock's seconds.[/b] The claim is that the
	# simulation decides a round, and a wall-clock bound turns a busy machine into a failure: at
	# 75 s it held 45 s of round with room to spare until the doors made the stand-ins take most
	# of the seek, and then a build running alongside made it fail one run in three. The wall
	# clock is only the cap for a server that stopped ticking at all.
	var started := Time.get_ticks_msec()
	var sim_limit := game.current_tick() + int((game.config.hide_seconds + game.config.round_seconds + 20.0) * game.tick_rate)
	var hard := started + 300000

	while rounds.is_empty() and game.current_tick() < sim_limit and Time.get_ticks_msec() < hard:
		await get_tree().physics_frame

	var bots := 0

	for id: StringName in game.players:
		if (game.players[id] as HsPlayer).is_bot:
			bots += 1

	_check(bots == game.config.minimum_players, "the module seated stand-ins up to the minimum", "%d" % bots)
	_check(not drawn.is_empty() and drawn[0] == 1, "and drew one of them to seek", str(drawn))
	print("(the round took %.1f s of real time)" % ((Time.get_ticks_msec() - started) / 1000.0))
	_check(not rounds.is_empty(), "and a round was decided", str(rounds))
	_check(not rounds.is_empty() and str(rounds[0][2]) != "", "with a sentence saying why", str(rounds))
	# [b]A person takes a stand-in's place, and leaving gives it back[/b]: DotBotQuota's fill
	# mode, the family's default. Driven by calling the roster check rather than waiting for
	# its interval, with a person added through the bridge the way a test's player is (peer
	# zero, not a stand-in), so the count is exact and nothing else moves under it.
	var quota_module := _module()
	var quota_bridge: Object = quota_module.get("bridge") if quota_module != null else null
	_check(server.console.find_cvar("bot_quota") != null and server.console.find_cvar("bot_quota_mode") != null,
		"the shared bot_quota cvars are registered")
	# How the stand-ins see, hear and know a map is dot-bot's: the family's names, medium by default.
	var bot_settings := DotBotSettings.of(game)
	_check(server.console.get_string("bot_difficulty", "") == "medium" and bot_settings.difficulty() == "medium",
		"bot_difficulty is the module's and medium is the default")
	var _hard := _run_command("bot_difficulty hard")
	_check(bot_settings.difficulty() == "hard" and is_equal_approx(server.console.get_float("bot_sight"), DotBotProfile.preset_value("hard", "sight")),
		"bot_difficulty hard writes every bot_* setting", server.console.get_string("bot_sight"))
	var _medium := _run_command("bot_difficulty medium")
	var _alias := _run_command("hs_min_players 3")
	_check(server.console.find_cvar("bot_quota") != null and server.console.find_cvar("bot_quota").get_int() == 3,
		"and the old hs_min_players sets bot_quota",
		server.console.find_cvar("bot_quota").get_string() if server.console.find_cvar("bot_quota") != null else "missing")

	if quota_module != null and quota_bridge != null:
		quota_module.call("_keep_the_round_full")
		var bots_before: int = (quota_module.get("_bot_ids") as Array).size()
		var joined: DotResult = quota_bridge.call("add_player", 0, 9001, "Person")
		quota_module.call("_keep_the_round_full")
		var bots_with: int = (quota_module.get("_bot_ids") as Array).size()
		_check(joined.ok and bots_before == 3 and bots_with == bots_before - 1,
			"a person joining takes a stand-in's place", "%d -> %d" % [bots_before, bots_with])
		quota_bridge.call("remove_player", 9001)
		quota_module.call("_keep_the_round_full")
		var bots_after: int = (quota_module.get("_bot_ids") as Array).size()
		_check(bots_after == bots_before, "and a stand-in comes back when they leave",
			"%d -> %d" % [bots_with, bots_after])
	else:
		_check(false, "a person joining takes a stand-in's place", "no module")
		_check(false, "and a stand-in comes back when they leave", "no module")

	var _restored := _run_command("hs_min_players 3")

	_check(_said(_run_command("hs_status"), "round"), "and hs_status still answers")
	_finished()


## The players' vote decides the next map: a ballot over the server's maps, one vote cast,
## and the round's end puts the winner on the next round. Driven by hand rather than by
## the clock, because stand-ins are not voters and a server of stand-ins never opens one.
func _test_the_map_vote() -> void:
	_section("the map vote")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	_check(vote != null, "the module built a map vote")

	if vote == null:
		_finished()
		return

	_check(server.console.find_command("vote") != null if server.console.has_method("find_command") else true,
		"and registered dot-vote's vote command")

	# Hibernation: DotGameModule hands the director the server, the ballot's timer waits with
	# it, and waking starts both again from the top.
	var sleeper: DotVoteDirector = vote.get("director")
	_check(server.hibernation_changed.is_connected(sleeper.set_hibernating),
		"the vote follows the server's hibernation without a line of this game's")
	vote.set("_opened_this_map", true)
	server.console.execute("sv_hibernate_when_empty 1")
	_check(server.is_hibernating() and sleeper.hibernating, "an empty server sleeps, and the vote with it",
		server.state_name())
	var on_map: float = vote.get("_on_map_sec")
	vote.call("advance", 600.0)
	_check(is_equal_approx(vote.get("_on_map_sec"), on_map), "ten minutes asleep do not count towards the ballot")
	server.console.execute("sv_hibernate_when_empty 0")
	_check(not sleeper.hibernating, "waking wakes the vote")
	_check(is_zero_approx(vote.get("_on_map_sec")) and not vote.get("_opened_this_map"),
		"and the map ballot is owed again from the top")

	# Every map in the directory, not only this suite's practice house.
	game.config.map_ids = PackedStringArray()
	vote.call("refresh_maps")
	var ids: Array = []

	for choice: DotVoteChoice in (vote.get("source") as DotVoteListSource).entries:
		ids.append(String(choice.id))

	_check(ids.has("hs_apartments") and ids.has("hs_manor"), "it offers the delivered maps", str(ids))

	# The map menu's server half (M): the owner's flag changes the map now, anybody else
	# gets a nomination and a rock-the-vote. Contexts as dot-server makes them for a chat line.
	var menu_half: Object = vote.get("commands").get("map_menu")
	_check(menu_half != null and server.console.find_command("mapmenu") != null
		and server.console.find_cvar("sv_map_menu_flag").get_string() == "generic"
		and (menu_half.get("change_fn") as Callable).is_valid(),
		"the map menu is there, staff-only by default, changing the map now")
	var staff := DotCmdContext.new()
	staff.source = DotCmdContext.Source.CHAT
	staff.permissions = PackedStringArray(["generic"])
	var player := DotCmdContext.new()
	player.source = DotCmdContext.Source.CHAT
	var menu_offer: Dictionary = menu_half.call("offer", player)
	_check((menu_offer["maps"] as Array).size() > 1 and not bool(menu_offer["allowed"]) and bool(menu_offer["vote"]),
		"a player is offered every map, as a vote")
	var target: StringName = &""
	for row: Dictionary in menu_offer["maps"]:
		if not bool(row["current"]):
			target = StringName(str(row["id"]))
			break
	var menu_changed: Dictionary = await menu_half.call("choose", staff, target)
	_check(bool(menu_changed["ok"]) and StringName(str(game.map_doc.get("id", ""))) == target, "staff choosing one changes the map on the spot",
		"%s: %s" % [target, menu_changed.get("text", "")])

	vote.set("voters_fn", func() -> Array: return [&"7"])
	var director: DotVoteDirector = vote.get("director")
	var opened := director.open_vote(DotVoteClock.REASON_MANUAL)
	_check(opened.ok and director.is_voting(), "a ballot opens", opened.error.message if not opened.ok else "")

	# A map the ballot actually offers: it draws a handful from the server's maps, and with more
	# maps than places a fixed id is on it some runs and not others.
	var offered := director.ballot.option_ids() if director.ballot != null else []
	var maps_offered := offered.filter(func(id: StringName) -> bool: return String(id).begins_with("hs_"))
	var choice: StringName = &"hs_manor" if offered.has(&"hs_manor") or maps_offered.is_empty() else StringName(maps_offered[0])
	var cast := director.cast_one(&"7", choice)
	# Everybody has voted; the director closes on its next advance, which is the server's tick.
	director.advance(0.05)
	_check(cast.ok and director.pending_id() == choice, "one vote decides it, waiting for the round's end",
		"%s %s of %s" % [cast.ok, director.pending_id(), offered])

	# No frame between these: the stand-ins' rounds are still running, and one that started in
	# between would lay the voted map itself and leave this check reading the rotation's.
	vote.call("note_round_end")
	_check(game.next_map_id == choice, "the round's end hands it to the world", str(game.next_map_id))

	game.call("_lay_out_map")
	_check(StringName(str(game.map_doc.get("id", ""))) == choice and game.next_map_id == &"",
		"and the next map laid is the one voted for, once", "%s / %s" % [game.map_doc.get("id", ""), game.next_map_id])

	# Rock the vote, typed at the console as a player's !rtv reaches it. Under MANUAL the
	# director opens nothing itself, a passed rtv included: it answered "Rocked. 1 of 1." and
	# no ballot came. Past dot-vote's cooldown between two ballots, on the director alone so
	# the map's own ballot timer does not open one first.
	var laid := StringName(str(game.map_doc.get("id", "")))
	_check(director.current_id() == laid and not director.is_voting(),
		"the new map starts the vote over", "%s / %s" % [director.current_id(), laid])
	vote.set("voters_fn", func() -> Array: return [&"console"])
	director.rules.rtv_delay_sec = 0.0
	director.rules.min_players_to_vote = 1
	director.rules.rtv_min_players = 1
	director.rules.allow_single_voter_auto = true
	director.advance(director.rules.vote_cooldown_sec + 0.1)
	var opened_count := [0]
	var counter := func(_options: Array, _seconds: float) -> void: opened_count[0] += 1
	director.vote_opened.connect(counter)
	var rocked := _run_command("rtv")
	vote.call("advance", 0.05)
	_check(director.is_voting(), "and a passing rock-the-vote opens a ballot", str(rocked))
	# The director opens it under MANUAL; this game used to open it from clock.expired too.
	_check(opened_count[0] == 1, "and opens exactly one rtv ballot, not a second from the game", str(opened_count[0]))
	director.vote_opened.disconnect(counter)
	_finished()


## maps.yml on the live module: a map outside the active rotation stays installed and loadable
## by `hs_map`, but is never drawn, balloted or nominated; a rotation switch takes effect; the
## game's own commands and dot-vote's are renamed from the file's `commands:`; no file changes
## nothing.
func _test_map_rotation_file() -> void:
	_section("maps.yml")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	_check(game != null and game.catalogue != null and vote != null and vote.get("director") != null,
		"the game has maps and a vote")

	if game == null or game.catalogue == null or vote == null or vote.get("director") == null:
		return

	var director: DotVoteDirector = vote.get("director")
	var catalogue := game.catalogue
	game.config.map_ids = PackedStringArray()
	var built := DotMapRotationFile.from_trees([{"defaults": {
		"rotation": "main",
		"rotations": {
			"main": {"mode": "cycle", "maps": ["hs_apartments", "hs_manor"]},
			"alt": {"maps": ["hs_manor"]},
		},
		"commands": {"names": {"rtv": "rockthevote", "hs_map": "setnextis", "hs_maps": "maplist"}},
	}}], "game-hide-n-seek")
	_check(built.ok, "a maps.yml with two rotations and renamed commands parses",
		"" if built.ok else built.error.message)
	if not built.ok:
		return

	var kept_file: DotMapRotationFile = game.rotation_file
	var all_ids: Array[StringName] = catalogue.playable(PackedStringArray())
	_check(all_ids.size() > 2 and catalogue.in_rotation_fn.is_valid() == (kept_file != null and kept_file.has_rotations()),
		"the catalogue holds more maps than the rotation will", str(all_ids.size()))
	game.rotation_file = built.value
	game.apply_rotation()
	vote.call("refresh_maps")

	_check(game.in_rotation(&"hs_apartments") and game.in_rotation(&"hs_manor"), "the listed maps are in rotation")
	_check(not game.in_rotation(&"hs_camp") and catalogue.playable(PackedStringArray()).has(&"hs_camp"),
		"an unlisted map is out of rotation and still installed")
	_check(not game.shuffles_maps(), "a cycle rotation does not shuffle the draw")

	var drawn: Array = []
	var previous: StringName = &""
	for _i in 6:
		var doc := catalogue.next_map(PackedStringArray(), game.shuffles_maps(), game.random.stream(&"map"), previous)
		previous = StringName(str(doc["id"]))
		drawn.append(String(previous))
	_check(drawn == ["hs_apartments", "hs_manor", "hs_apartments", "hs_manor", "hs_apartments", "hs_manor"],
		"six draws cycle the written order and never leave it", str(drawn))

	var ids := (vote.get("source") as DotVoteListSource).choices().map(func(c: DotVoteChoice) -> StringName: return c.id)
	_check(ids.has(&"hs_manor") and ids.has(&"hs_apartments") and not ids.has(&"hs_camp"),
		"a map outside the rotation is not on the ballot, one inside is", str(ids))
	var nominated := director.nominate(&"u77", &"hs_camp")
	_check(not nominated.ok, "nominate refuses a map outside the rotation")
	_check(not director.nominated_ids().has(&"hs_camp"), "and nothing was recorded")

	var queued := _run_command("hs_map hs_camp")
	_check(_said(queued, "hs_camp is next") and game.next_map_id == &"hs_camp",
		"an operator can still queue it with hs_map", str(queued))
	game.next_map_id = &""

	_check(server.console.find_command("hs_map") != null and server.console.find_command("hs_maps") != null,
		"with no file at load the game's own commands keep their names")
	_check(game.command_name("hs_map", "hs_map") == "setnextis" and game.command_name("hs_maps", "hs_maps") == "maplist"
		and game.command_name("hs_reload", "hs_reload") == "hs_reload",
		"the game's own command names come from maps.yml's commands, others keep theirs")
	var rows := game.map_rows().filter(func(r: Dictionary) -> bool: return r["id"] == "hs_camp")
	_check(rows.size() == 1 and str(rows[0]["detail"]).contains("not in rotation"),
		"the map menu marks a map that is not in rotation")
	_check(_said(PackedStringArray(catalogue.describe_lines()), "not in rotation"),
		"and so does the hs_maps list")

	var rtv := DotVoteCommands.new()
	rtv.director = director
	rtv.spec_fn = game.rotation_commands
	var bound := rtv.bind(server.console)
	_check(bound.ok and rtv.command_name("rtv") == "rockthevote" and server.console.find_command("rockthevote") != null,
		"a renamed rtv command is registered from maps.yml's commands")
	var vote_commands: DotVoteCommands = vote.get("commands")
	_check(vote_commands != null and vote_commands.spec_fn.is_valid(), "and the game's vote hands its commands the file")

	var switched := game.rotation_file.switch(game._rot, "alt")
	game.apply_rotation()
	vote.call("refresh_maps")
	_check(switched.ok and game.in_rotation(&"hs_manor") and not game.in_rotation(&"hs_apartments"),
		"switching to the alt rotation takes effect")
	ids = (vote.get("source") as DotVoteListSource).choices().map(func(c: DotVoteChoice) -> StringName: return c.id)
	_check(not ids.has(&"hs_apartments") and ids.has(&"hs_manor"), "and the ballot follows it")
	_check(not game.rotation_file.switch(game._rot, "nope").ok, "an unknown rotation is refused")

	# No file again: everything back in, as before maps.yml.
	game.rotation_file = null
	game.apply_rotation()
	vote.call("refresh_maps")
	var all_in := true
	for id in catalogue.playable(PackedStringArray()):
		all_in = all_in and game.in_rotation(id)
	_check(all_in and game.shuffles_maps() == game.config.shuffle_maps, "with no file every map is in rotation and the draw is as configured")
	_check(game.rotation_commands().is_empty() and game.command_name("hs_map", "hs_map") == "hs_map",
		"and no command is renamed")

	game.rotation_file = kept_file
	game.apply_rotation()
	vote.call("refresh_maps")
	_finished()


## [b]`time_up: finish_round` waits for a round being played, never for warmup.[/b] The game
## hands dot-vote its match's answer (`round_in_progress_fn`); without it a limit that ran out
## in warmup held the change for `finish_round_max_sec` over a round that had not started.
## Run on a director of its own carrying the game's own hook, so the real vote's clock is
## untouched; the match's state is set by hand and put back.
func _test_finish_round_waits_for_a_live_round() -> void:
	_section("finish_round waits for a live round, not warmup")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	var director: DotVoteDirector = vote.get("director") if vote != null else null
	var hook: Variant = director.get("round_in_progress_fn") if director != null else null
	_check(hook is Callable and (hook as Callable).is_valid(), "the game tells its vote whether a round is live")

	if not (hook is Callable and (hook as Callable).is_valid()) or game == null or game.match_node == null:
		_finished()
		return

	var match_node: DotMatch = game.match_node
	var was := match_node.state
	match_node.state = DotMatch.State.WARMUP
	var warm_applied := []
	var warm := _finish_round_probe(hook, warm_applied)
	_check(warm_applied == [&"b"] and not warm.is_finishing_round(),
		"in warmup a time limit with finish_round changes at once", str(warm_applied))

	match_node.state = DotMatch.State.LIVE
	var live_applied := []
	var live := _finish_round_probe(hook, live_applied)
	_check(live_applied.is_empty() and live.is_finishing_round(),
		"during a live round it waits for the round", str(live_applied))

	match_node.state = DotMatch.State.INTERMISSION
	live.advance(0.1)
	_check(live_applied == [&"b"], "and the round ending is the change", str(live_applied))

	match_node.state = was
	warm.queue_free()
	live.queue_free()
	_finished()


## A director under `time_up: finish_round` carrying [param hook], its clock run out with a
## winner already decided: what dot-vote's own suite builds, with the game's answer in it.
func _finish_round_probe(hook: Callable, applied: Array) -> DotVoteDirector:
	var source := DotVoteListSource.new()
	var _a := source.add(DotVoteChoice.of(&"a", "A"))
	var _b := source.add(DotVoteChoice.of(&"b", "B"))
	source.apply_fn = func(id: StringName) -> DotResult:
		applied.append(id)
		return DotResult.success(id)

	var rules := DotVoteRules.new()
	rules.apply_delay_sec = 0.0
	rules.duration_sec = 100.0
	rules.vote_lead_sec = 40.0
	rules.vote_duration_sec = 5.0
	rules.include_extend = false
	rules.apply = DotVoteRules.Apply.END_OF_TIME
	rules.cooldown = 0
	rules.time_up = DotVoteRules.TimeUp.FINISH_ROUND
	# For ever: only the hook may release it.
	rules.finish_round_max_sec = 0.0

	var probe := DotVoteDirector.new()
	probe.rules = rules
	probe.source = source
	probe.register_service = false
	probe.self_advance = false
	probe.round_based = true
	probe.player_count_fn = func() -> int: return 4
	probe.set(&"round_in_progress_fn", hook)
	add_child(probe)
	probe.begin(&"a")
	source.current = &"a"

	for i in range(61):
		probe.advance(1.0)

	probe.cast_one(&"p1", &"b")

	# The ballot closes, then the limit (100 s) runs out with the winner decided.
	for i in range(46):
		probe.advance(1.0)

	return probe


## A reload keeps the maps the server names. `hs_reload` reads the map directory again with
## `load_from`, which forgets everything read before, and in two of the three games built this
## way it stopped there: every delivered map was gone until a restart, with nothing logged.
## A pack "mounted" on the disk and a descriptor naming it stand in for dot-cloud and the
## deployment's map config (dot-server-deploy's cfg/content.yml), which a suite has neither of.
func _test_a_reload_keeps_delivered_maps() -> void:
	_section("a reload keeps the maps the server names")
	var key := "dot-test/hs-delivered@1.0.0"
	var mount := DotGameContent.mount_of(key)
	var dir := mount.path_join("maps")
	var id := &"hs_delivered_check"
	DirAccess.make_dir_recursive_absolute(dir)
	var doc: Dictionary = game.catalogue.practice()
	doc["id"] = String(id)
	var file := FileAccess.open(dir.path_join("delivered_check.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(doc))
	file.close()

	# The manager's running descriptor, named the way a deployment names it. Restored below:
	# `_current` is the manager's own, and nothing else in this suite should see the pack.
	var manager: Object = server.games
	var was: Variant = manager.get("_current")
	var named := DotGameDescriptor.new()
	named.maps = PackedStringArray([key])
	manager.set("_current", named)

	var _first := _run_command("hs_reload")
	for _i in range(3):
		await get_tree().process_frame
	_check(game.catalogue.maps.has(id), "a map the server names is in the catalogue after hs_reload",
		str(game.catalogue.maps.keys()))
	_check(game.catalogue.maps.has(&"hs_practice"),
		"beside the built-in one")

	# The ballot sees them from boot, not only after a reload: _game_load builds the vote
	# before the delivered maps arrive, and a list read then held only the practice map,
	# which never opens a ballot. A module unloaded and loaded with the pack named is a boot
	# (not module_reload, which reloads the script under the world's live instances). Every
	# map for the length of this check, not only this suite's practice one, and the catalogue
	# as a boot finds it: the world outlives the module and still holds the map from the
	# hs_reload above, which a vote built at load would read without the fix.
	var only := game.config.map_ids
	game.config.map_ids = PackedStringArray()
	var _builtin := game.catalogue.load_from(game.config.map_directory)
	var reloaded := _run_command("module_unload hideseek")
	reloaded.append_array(_run_command("module_load res://game/hs_module.gd"))
	for _i in range(60):
		await get_tree().process_frame

		if _module() != null and _module().get("vote") != null:
			break
	var booted_vote: Node = _module().get("vote") if _module() != null else null
	var booted_ids: Array = []

	if booted_vote != null:
		for choice: DotVoteChoice in (booted_vote.get("source") as DotVoteListSource).entries:
			booted_ids.append(String(choice.id))

	_check(booted_ids.has(String(id)), "and on the ballot of a module that boots with it named, unrefreshed",
		"%s %s" % [reloaded, booted_ids])
	game.config.map_ids = only

	manager.set("_current", was)
	var _second := _run_command("hs_reload")
	for _i in range(3):
		await get_tree().process_frame
	_check(not game.catalogue.maps.has(id), "and it came from the server's list: unnamed, a reload drops it")

	DirAccess.remove_absolute(dir.path_join("delivered_check.json"))
	var path := dir
	while path != "res://dot_cloud":
		DirAccess.remove_absolute(path)
		path = path.get_base_dir()
	DirAccess.remove_absolute("res://dot_cloud")
	_finished()


## [b]A hider behind its loading cover is not caught, and is once the cover lifts.[/b] A real
## [DotClientLink] joins over the server's ENet socket and says nothing, as a client still loading
## its level does. The round is put in its seek by hand with a stand-in seeker on top of it (a
## joiner during the seek would seek itself): the touch must not catch it, the sight meter must
## not fill, and it must not be drawn to seek. An operator's `hs_catch` still lands. The client
## then sends `game.cover` on the real wire and the same touch catches it.
func _test_loading_cover() -> void:
	_section("a client behind its loading cover is not caught")

	var module := _module()
	var roster: DotGameRoster = module.get("roster") if module != null else null

	var known: Dictionary = {}
	for each in server.playing_sessions():
		known[each.userid] = true

	var side := Node.new()
	side.name = "CoverClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	# Under a node named like this suite's own, so the RPC path the server sends resolves in the
	# client's separate multiplayer tree too.
	var mirror := Node.new()
	mirror.name = name
	side.add_child(mirror)
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Cover"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	mirror.add_child(link)
	# A real client has its game's link under `Server`; without it every event the server sends
	# to this stand-in has no node to land on and the engine logs three errors per message.
	# DotClientLink drops its children as the connection phase changes, so it is re-added then.
	var attach := func(_a: Variant = null, _b: Variant = null) -> void:
		if link.get_node_or_null(NodePath(String(HsNetLink.NODE_NAME))) == null:
			link.add_child(HsNetLink.attached_to(link, null, false))
	attach.call()
	link.phase_changed.connect(attach)
	link.connect_to_server("127.0.0.1:%d" % PORT)

	var seat: Array = [null]
	for _i in 1800:
		await get_tree().physics_frame
		for each in server.playing_sessions():
			if not known.has(each.userid) and game.players.has(StringName("u%d" % each.userid)):
				seat[0] = each
		if seat[0] != null:
			break

	_check(seat[0] != null and roster != null, "a real client joins over the socket", str(link.last_error))

	var seeker: HsPlayer = null
	for id: StringName in game.players:
		if (game.players[id] as HsPlayer).is_bot:
			seeker = game.players[id]
			break

	if seat[0] == null or roster == null or seeker == null:
		for what in ["held as loading", "the touch", "the sight meter", "the seeker draw", "an operator's catch",
				"the cover report", "the touch after", "bots and strangers", "leaving"]:
			_check(false, "%s (no runner joined)" % what)
		link.disconnect_from_server("done")
		side.queue_free()
		_finished()
		return

	var userid: int = seat[0].userid
	var key := StringName("u%d" % userid)
	var hider: HsPlayer = game.players[key]
	_check(roster.is_loading(userid), "the server holds the seat as loading from its spawn", str(roster.describe()))

	# The whole of the setup and the attempt is one run with no await, so nothing ticks between.
	var was_phase: int = game.phase
	game.phase = HsGame.Phase.SEEK
	game._set_side(key, HsGame.HIDERS)
	game._set_side(seeker.player_id, HsGame.SEEKERS)
	hider.caught = false
	hider.sight_meter = 0.0
	seeker.held_until = -1.0
	seeker.place_at(hider.controller.state.position, 0.0)
	var was_mode: int = game.config.catch_mode
	game.config.catch_mode = HsConfig.Catch.TOUCH
	game._advance_catching(0.05)
	_check(not hider.caught, "a seeker's touch does not catch it", "caught=%s" % hider.caught)

	game.config.catch_mode = HsConfig.Catch.SIGHT
	game._advance_catching(0.05)
	_check(not hider.caught and hider.sight_meter == 0.0, "and the sight meter does not fill", "%s" % hider.sight_meter)
	game.config.catch_mode = was_mode

	# The draw leaves a covered seat on the hiders' side while somebody else can seek.
	var drawn_covered := 0
	for _i in 12:
		game._round_seed = _i
		game.seeker_history.clear()
		game._draw_sides()
		if game.team_of(key) == HsGame.SEEKERS:
			drawn_covered += 1
	_check(drawn_covered == 0, "a covered seat is not drawn to seek", "%d of 12 draws" % drawn_covered)

	game.phase = HsGame.Phase.SEEK
	game._set_side(key, HsGame.HIDERS)
	game._set_side(seeker.player_id, HsGame.SEEKERS)
	hider.caught = false
	_check(game.catch(key, &"", HsGame.CAUGHT_TAG), "an operator's catch still lands")
	game.phase = was_phase

	DotGameClient.report_cover(link, false)
	var lifted := false
	for _i in 900:
		await get_tree().physics_frame
		if not roster.is_loading(userid):
			lifted = true
			break
	_check(lifted, "its cover report crosses the wire and ends the loading state")

	game.phase = HsGame.Phase.SEEK
	game._set_side(key, HsGame.HIDERS)
	game._set_side(seeker.player_id, HsGame.SEEKERS)
	hider.caught = false
	seeker.held_until = -1.0
	seeker.place_at(hider.controller.state.position, 0.0)
	game.config.catch_mode = HsConfig.Catch.TOUCH
	game._advance_catching(0.05)
	_check(hider.caught, "and the same touch now catches it", "caught=%s" % hider.caught)
	game.config.catch_mode = was_mode
	game.phase = was_phase

	_check(not bool(game.loading_fn.call(&"bot7")) and not bool(game.loading_fn.call(&"u99999")),
		"a bot, or a seat the roster does not hold, is never loading")

	link.disconnect_from_server("done")
	var gone := false
	for _i in 900:
		await get_tree().physics_frame
		if not game.players.has(key):
			gone = true
			break
	_check(gone and not roster.is_loading(userid), "it leaves and the roster forgets it")
	side.queue_free()
	_finished()


## A module reload must leave ONE link under the server, still named for the client's route.
## Two used to be left, the live one renamed `@Node@n`, and every RPC to a real client was lost
## without an error. The proof is a real client over the socket: signing on is server events.
func _test_a_module_reload() -> void:
	_section("a module reload leaves one live link")

	for _i in range(2):
		_check(server.modules.unload_module("hideseek").ok, "the module unloads")
		var back: DotResult = await server.modules.load_module("res://game/hs_module.gd")
		_check(back.ok, "and loads again", back.error.message if not back.ok else "")
	for _i in range(5):
		await get_tree().process_frame

	var links := 0
	for child in server.get_children():
		if child.get_script() == HsNetLink:
			links += 1
	_check(links == 1 and server.has_node(NodePath(String(HsNetLink.NODE_NAME))),
		"exactly one link, under the name the client routes to", "%d" % links)

	var side := Node.new()
	side.name = "ReloadClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Reloaded"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	var mirror := Node.new()
	mirror.name = name
	side.add_child(mirror)
	mirror.add_child(link)
	# The client's sink: it shares the server link's name so the RPC path resolves, and
	# attached_to no longer adds it.
	var attach := func(_a: Variant = null, _b: Variant = null) -> void:
		if link.get_node_or_null(NodePath(String(HsNetLink.NODE_NAME))) == null:
			link.add_child(HsNetLink.attached_to(link, null, false))
	attach.call()
	link.phase_changed.connect(attach)
	var spawned := [false]
	link.spawned.connect(func() -> void: spawned[0] = true)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var joined := await _until(func() -> bool:
		return spawned[0] or link.phase == DotClientLink.Phase.FAILED, 30.0)
	_check(joined and spawned[0], "a real client still hears the server's events after two reloads")
	link.disconnect_from_server("done")
	for _i in range(10):
		await get_tree().process_frame
	side.queue_free()
	_finished()


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


func _test_it_unloads_cleanly() -> void:
	_section("unloading")
	server.modules.unload_all()
	await get_tree().process_frame
	_check(_module() == null, "the module unloads")
	_check(server.console.find_command("hs_status") == null if server.console.has_method("find_command") else true,
		"and takes its commands with it")
	_check(is_instance_valid(game), "and leaves the world, which outlives it")
	_finished()


## No message script preloads itself: in mg-buses-from-hell that one line leaked the whole
## script graph at exit (8ed866c), and the leak is printed after `quit()`, where no assertion
## reaches. So the cause is checked, on the source.
func _test_no_message_preloads_itself() -> void:
	_section("exiting clean")
	var offenders := PackedStringArray()
	var dir := DirAccess.open("res://game/net")

	for file in dir.get_files():
		if not file.ends_with(".gd"):
			continue

		var source := FileAccess.get_file_as_string("res://game/net/" + file)

		if source.contains("extends DotNetMessage") and source.contains("preload(\"%s\")" % file):
			offenders.append(file)

	_check(offenders.is_empty(), "no message preloads itself", ", ".join(offenders))
	_finished()


func _module() -> DotModule:
	return server.modules.get_module("hideseek") if server != null and server.modules != null else null


func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, context)
	return PackedStringArray(captured)


func _said(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.findn(text) >= 0:
			return true

	return false


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return

	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)


# --- Exiting clean ----------------------------------------------------------------

## The flag this suite hands the copy of itself it runs. See [method _run_exit_probe].
const EXIT_PROBE_FLAG := "--exit-probe"

## What the exit probe adds to a run — one section, these checks — and the copy does not.
const EXIT_PROBE_CHECKS := 4


## How long the copy may run before it is killed and this probe fails. A copy that is still
## running this long after it started is hung, and the likeliest reason is the one that says
## nothing at all: a scene whose script failed to parse never reaches `quit()` and prints
## nothing. `-- --exit-probe-seconds N` lowers it, which is how the deadline itself is armed —
## any N shorter than the suite takes is a copy that is still running when it expires.
const EXIT_PROBE_SECONDS := 300


func _is_exit_probe() -> bool:
	return EXIT_PROBE_FLAG in OS.get_cmdline_user_args()


func _exit_probe_seconds() -> int:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--exit-probe-seconds")
	if at >= 0 and at + 1 < args.size() and args[at + 1].is_valid_int():
		return maxi(1, args[at + 1].to_int())
	return EXIT_PROBE_SECONDS


## Runs this same suite in a fresh process: `[exit code, its stdout, its stderr, whether it
## had to be killed, the seconds it was allowed]`.
##
## [b]A leak is reported after `quit()`, by the engine, where nothing in the process that
## leaked can read it.[/b] "N ObjectDB instances were leaked at exit" is printed once the
## scene tree is gone, so the only process that can check a run's exit is another one. On
## Godot 4.7.2 a script that names itself, loaded after its base, cuts the engine's exit
## teardown short and every script loaded before it is reported leaked — hundreds of lines
## a passing run printed for weeks, which is why this is a check now and not a warning.
##
## [b]First, before this run opens a port[/b], so the two never contend for a socket — and
## so this run is always the second one against the same `user://`, which is the other
## thing no single run can see.
##
## [b]Not `OS.execute`.[/b] That blocks until the copy exits, so a copy that hangs held this
## run for ever; and when the outer `timeout` then killed this run, the copy was left behind
## holding the suite's directory and port. So the copy is started, polled against a deadline
## and killed at it. Two deadlines, because Godot dies on SIGTERM without running a line of
## script — nothing in this process can clean up after it is killed:
##
## - coreutils `timeout` wraps the copy where it exists. It is an exec wrapper, not a shell,
##   and it outlives this process, so a copy orphaned by the outer `timeout` still dies on
##   time. Its exit status 124 is how its expiry is recognised.
## - this loop's own deadline, a little later, for a platform without it.
##
## `execute_with_pipe` rather than `create_process`, because the latter captures nothing and
## the whole point is reading what the copy printed. Non-blocking, and drained on every pass
## rather than once at the end: a pipe holds 64 KiB, and a copy that fills it blocks on its
## next print — a hang this probe would then report as the suite's own. The copy's stdin is
## the other end of a pipe this process holds open, which is why every suite turns the
## server's stdin console off: a reader blocked on it never lets the copy exit.
func _run_exit_probe() -> Array:
	var seconds := _exit_probe_seconds()
	print("(running this suite once more in a fresh process, to read what it leaves at exit — %d s allowed)" % seconds)
	var scene := scene_file_path if scene_file_path != "" else "res://examples/dedicated.tscn"
	var exe := OS.get_executable_path()
	var args := PackedStringArray([
		"--headless", "--path", ProjectSettings.globalize_path("res://"),
		scene, "--", EXIT_PROBE_FLAG,
	])
	var wrapped := false
	for wrapper: String in ["/usr/bin/timeout", "/bin/timeout"]:
		if FileAccess.file_exists(wrapper):
			var outer := PackedStringArray(["--kill-after=10", str(seconds), exe])
			outer.append_array(args)
			exe = wrapper
			args = outer
			wrapped = true
			break

	var proc := OS.execute_with_pipe(exe, args, false)
	if proc.is_empty():
		return [-1, "", "could not start %s" % exe, false, seconds]
	var pid: int = proc["pid"]
	var pipes: Array[FileAccess] = [proc["stdio"], proc["stderr"]]
	var bytes: Array[PackedByteArray] = [PackedByteArray(), PackedByteArray()]
	var deadline := Time.get_ticks_msec() + (seconds + 30) * 1000
	var hung := false
	while OS.is_process_running(pid):
		_drain_exit_probe(pipes, bytes)
		if Time.get_ticks_msec() > deadline:
			OS.kill(pid)
			hung = true
			break
		await get_tree().create_timer(0.1).timeout
	# Once more after it exits: what it wrote between the last pass and its exit is still in
	# the pipe, and the leak report is always the last thing it writes.
	_drain_exit_probe(pipes, bytes)

	# OS.kill has already reaped it, and asking for the exit code of a reaped pid is an error.
	var code := -1 if hung else OS.get_process_exit_code(pid)
	if wrapped and code == 124:
		hung = true
	return [code, bytes[0].get_string_from_utf8(), bytes[1].get_string_from_utf8(), hung, seconds]


func _drain_exit_probe(pipes: Array[FileAccess], bytes: Array[PackedByteArray]) -> void:
	for i in pipes.size():
		while true:
			var chunk := pipes[i].get_buffer(65536)
			if chunk.is_empty():
				break
			bytes[i].append_array(chunk)


func _test_exits_clean(probe: Array) -> void:
	_section("exiting clean, as a second process saw it")

	var code: int = probe[0]
	var stdout: String = probe[1]
	var stderr: String = probe[2]
	var hung: bool = probe[3]
	var seconds: int = probe[4]
	# Every leak line is the engine's, and the engine writes them to stderr; both are
	# searched so that stays a fact about the engine rather than an assumption here. Shown
	# apart, because a pipe each is two streams whose interleaving is lost, and where a hung
	# copy had got to is the end of its stdout.
	var text := stdout + "\n" + stderr
	var tail := "its last lines:\n%s\nand the last on stderr:\n%s" % [
		_last_lines(stdout, 15), _last_lines(stderr, 10)
	]

	# A copy that was killed never reached its exit, so neither of the last two was seen, and
	# passing them on an absence of lines would be passing them blind.
	var passes_detail := ""
	if hung:
		passes_detail = ("still running after %d s, so it was killed — a scene that failed to "
			+ "parse, or a thread still blocked when it quit; %s") % [seconds, tail]
	elif code != 0:
		passes_detail = "exit %d; %s" % [code, tail]
	_check(not hung and code == 0, "this suite, run again in a fresh process, passes",
		passes_detail)
	_check(not hung and not text.contains("leaked at exit"), "and leaves no object alive at exit",
		"it was killed before it reached its exit" if hung else _line_with(text, "leaked at exit"))
	_check(not hung and not text.contains("still in use at exit"), "and no resource",
		"it was killed before it reached its exit" if hung else _line_with(text, "still in use at exit"))
	# The engine's RPC routing errors: a message sent to a path the other end does not have.
	# They leave the suite passing (the message is just lost), so only the log shows them.
	var rpc_errors := 0
	for line in text.split("\n"):
		if line.contains("Node not found:") or line.contains("Failed to get path from RPC") \
				or line.contains("Invalid packet received") or line.contains("Parameter \"node\" is null"):
			rpc_errors += 1
	_check(not hung and rpc_errors == 0, "and logs no RPC routing error",
		"it was killed before it reached its exit" if hung
		else "%d lines, first: %s" % [rpc_errors, _line_with(text, "Node not found:")])
	_finished()


func _line_with(text: String, needle: String) -> String:
	for line in text.split("\n"):
		if line.contains(needle):
			return line.strip_edges()
	return ""


func _last_lines(text: String, count: int) -> String:
	var lines := text.strip_edges().split("\n")
	return "\n".join(lines.slice(maxi(0, lines.size() - count)))

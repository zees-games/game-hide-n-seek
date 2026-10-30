extends "dedicated_client.gd"

## The game as a deployed server runs it: a real [DotServer], booted from a config file, with
## the module loaded BY PATH the way an operator names it, so the netcode, the services, the
## cvars and the stand-ins are a deployment's own. The only suite where [HsModule] loads.

const SECTIONS := 15
const CHECKS := 114

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
		_test_config_and_noblock()
		_test_finish_round_waits_for_a_live_round()
		await _test_loading_cover()
		await _test_ambient_cvars_reach_the_client()
		await _test_a_module_reload()
		await _test_it_unloads_cleanly()

	_test_no_message_preloads_itself()

	if not probe.is_empty():
		_test_exits_clean(probe)

	var sections := SECTIONS - (1 if _is_exit_probe() else 0)
	var checks := CHECKS - (EXIT_PROBE_CHECKS if _is_exit_probe() else 0)

	await _shut_down()
	DotPaths.remove_tree(SERVER_DIR)
	_report_sections(_sections_entered, _sections_finished, sections, checks)


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
	var binder := HsConfig.make_binder(config)
	_check(binder.load_layers().ok, "the config layers load")
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.hide_seconds = 3.0
	config.round_seconds = 30.0
	config.minimum_players = 3
	config.map_ids = PackedStringArray(["hs_practice"])

	game = HsGame.new()
	game.name = "World"
	game.config = config
	game.config_binder = binder
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)
	await get_tree().process_frame

	_check(DotRegistry.get_node_service(HsGame.SERVICE) == game, "the world publishes itself where a module looks")
	_check(not game.map_doc.is_empty(), "and already has a map")

	(load("res://game/hs_module.gd") as GDScript).set("punishments_file", "%s/punishments.json" % SERVER_DIR)
	var loaded: DotResult = await server.modules.load_module("res://game/hs_module.gd")
	_check(loaded.ok, "the module loads into the server", loaded.error.message if not loaded.ok else "")

	var module := _module()
	_check(game != null and game.progress != null and game.progress.durable_key_fn.is_valid(),
		"progress is filed under dot-game's stable stats key")
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

	# Bounded in the server's ticks, not the wall clock: a wall-clock bound turned a busy
	# machine into a failure. The wall clock is only the cap for a server that stopped ticking.
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
	_stand_in_quota()
	_check(_said(_run_command("hs_status"), "round"), "and hs_status still answers")
	_finished()


## A person takes a stand-in's place, and leaving gives it back (DotBotQuota's fill mode).
## Driven by the roster check, with a person added through the bridge, so the count is exact.
func _stand_in_quota() -> void:
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

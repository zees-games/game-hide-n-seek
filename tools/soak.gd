extends Node

const HsConfig := preload("../game/hs_config.gd")
const HsGame := preload("../game/hs_game.gd")

## Bot soak on the real game: N stand-ins play rounds back to back on one map for M simulated
## minutes through dot-bot's DotBotSoak, fed by dot-spawn's DotSpawnWatch.
##
## [codeblock]
## ./game.sh soak [map] [minutes]
## godot --headless --path . res://tools/soak.tscn -- --map hs_manor --bots 7 --minutes 5
## [/codeblock]
##
## --probe prints a PROBE line per bot per second (the log has them all; the game.sh filter hides them).
## Takes the harness's own flags too (--soak-max-stuck-sec and the rest of DotBotSoakConfig).
## Writes .godot/test-logs/soak-<map>.json, prints the SOAK line, exits 1 when the run fails.
## A hider settled in its spot, a seeker through the hide and anyone between rounds have no goal.
## There is no navigation mesh query here, so off-nav and unreachable are off.

const DEFAULT_MAP := &"hs_manor"
const DEFAULT_MINUTES := 2.0
const DEFAULT_BOTS := 7
const TICK_RATE := 32

var _game: HsGame
var _ticks := 0
var _probe := false


func _ready() -> void:
	_probe = OS.get_cmdline_user_args().has("--probe")
	DotLog.set_level(DotLog.Level.ERROR)
	Engine.physics_ticks_per_second = 1920
	Engine.max_physics_steps_per_frame = 64
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--" + name)
	if at >= 0 and at + 1 < args.size():
		return args[at + 1]
	return fallback


func _run() -> void:
	var map_id := _arg("map", String(DEFAULT_MAP))
	var cfg := DotBotSoakConfig.new()
	cfg.minutes = DEFAULT_MINUTES
	cfg.bots = DEFAULT_BOTS
	# A stand-in may take 20 s to get out of a pit up a stair with a 0.43 m last riser, past a
	# landing as deep as the body is wide, or round a fenced garden corner it is chased into; a
	# minute is a deadlock. --soak-max-stuck-sec overrides.
	cfg.max_stuck_sec = 20.0
	cfg.apply_cli()
	cfg.minutes = float(_arg("minutes", str(cfg.minutes)))
	cfg.bots = int(_arg("bots", str(cfg.bots)))
	# Kills are not a soak signal here: a catch is the game working.
	cfg.require_kills_after_sec = -1.0

	var config := HsConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	config.map_ids = PackedStringArray([map_id])
	config.seed_value = cfg.seed_value
	_game = HsGame.new()
	_game.config = config
	_game.tick_rate = TICK_RATE
	_game.authoritative = true
	_game.register_service = false
	add_child(_game)
	_game.set_physics_process(false)
	await get_tree().physics_frame
	for i in range(cfg.bots):
		var bot := _game.add_player(StringName("u%d" % (900 + i)), "Bot%d" % i)
		bot.is_bot = true
	_game.start()
	if _game.map == null:
		_fail("the game built no map for %s" % map_id)
		return

	var watch := DotSpawnWatch.new()
	watch.rules.enabled = true
	watch.rules.kill_y = -400.0

	var soak := DotBotSoak.new(cfg)
	soak.watch = watch
	soak.movers_fn = _movers
	soak.object_count_fn = func() -> int: return int(Performance.get_monitor(Performance.OBJECT_COUNT))
	soak.step_fn = _step

	var delta := 1.0 / float(TICK_RATE)
	while not soak.is_done():
		soak.advance(delta)
		# Doors and bodies are where the physics server says only after a physics frame.
		await get_tree().physics_frame

	var report := soak.finish()
	report["map"] = map_id
	report["catches"] = _game.players.values().filter(func(p) -> bool: return p.caught).size()
	print(DotBotSoak.summary(report))
	print(DotBotSoak.report_line(report))
	var path := ProjectSettings.globalize_path("res://.godot/test-logs/soak-%s.json" % map_id)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if soak.write_report(report, path) != OK:
		push_error("could not write %s" % path)
	_game.queue_free()
	for _i in range(3):
		await get_tree().process_frame
	get_tree().quit(0 if report["ok"] else 1)


func _step(delta: float) -> void:
	_game.simulate(delta)
	_ticks += 1
	if _probe and _ticks % TICK_RATE == 0:
		_print_probe()


## Once a second, one PROBE line per bot (--probe): where it is and what its walk holds.
func _print_probe() -> void:
	for id: StringName in _game.players:
		var player = _game.players[id]
		if not player.is_bot or player.controller == null:
			continue
		var st: Dictionary = _game.bots._state.get(id, {})
		var path: PackedVector3Array = st.get("path", PackedVector3Array())
		print("PROBE t=%d %s side=%d phase=%d mode=%s pos=%s goal=%s path=%d corner=%d stuck_count=%d vel=%s" % [
			_ticks / TICK_RATE, id, _game.team_of(id), _game.phase, st.get("mode", &""),
			player.controller.state.position.snapped(Vector3.ONE * 0.1), (st.get("goal", Vector3.INF) as Vector3).snapped(Vector3.ONE * 0.1),
			path.size(), int(st.get("corner", 0)), int(st.get("stuck_count", 0)), player.controller.state.velocity.snapped(Vector3.ONE * 0.1)])


func _movers() -> Array:
	var out: Array = []
	for id: StringName in _game.players:
		var player = _game.players[id]
		if not player.is_bot or player.controller == null:
			continue
		var state: Dictionary = _game.bots._state.get(id, {})
		# Nobody is driven before the hide; seekers stand through it, blindfolded; a hider settled stands.
		var phase: int = _game.phase
		var side: int = _game.team_of(id)
		var standing: bool = phase == 0 or (side != 1 and phase != 2) or state.get("mode", &"") == &"hidden"
		out.append({"id": id, "position": player.controller.state.position, "kind": &"bot", "has_goal": not standing})
	return out


func _fail(why: String) -> void:
	printerr("SOAK setup failed: ", why)
	get_tree().quit(2)

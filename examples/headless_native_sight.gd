extends DotGameCheckSuite

const HsConfig := preload("../game/hs_config.gd")
const HsGame := preload("../game/hs_game.gd")
const HsPlayer := preload("../game/hs_player.gd")
const HsBots := preload("../game/hs_bots.gd")

## The stand-ins' bodies in sight in dot-sim (`HsBots.sight_mode`, native by default) answer exactly as the script does:
## `_sees`, `_nearest_seen_seeker` and `_visible_prey` over every pair of bodies a live round has, on real maps with their
## walls, props and toys, every few ticks, and every ask the bots make themselves under `sight_verify`. Then what one ask
## costs either way, and the whole server tick with the mode flipped every few ticks in the same round. With no library
## the native half is skipped; [code]GS_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead. Hit registration and lag
## compensation are not touched.

const SECTIONS := 4
const CHECKS := 10
const MAPS := ["hs_manor", "hs_school"]
const BOTS := 16
const RATE := 60
## Every pair of bodies is asked both ways every this many ticks.
const SWEEP_EVERY := 15

var _entered := 0
var _finished := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("Hide and Seek native bodies in sight")
	print("")
	_entered += 1
	print("the library has the bodies in sight")
	_check(HsBots.sight_mode == "native", "HsBots.sight_mode is native without the game turning it on")
	var loaded := DotSim.has(&"body_sight") and DotSim.has(&"sight")
	if not loaded:
		print("  dot-sim's body_sight module is not loaded: the native half is skipped")
		_check((OS.get_environment("GS_SIM_REQUIRE_NATIVE") if OS.has_environment("GS_SIM_REQUIRE_NATIVE") else OS.get_environment("DOT_SIM_REQUIRE_NATIVE")) != "1", "the library is loaded (GS_SIM_REQUIRE_NATIVE=1)")
		_finished += 1
		_report_sections(_entered, _finished, SECTIONS - 3, 2)
		return
	_check(true, "the library has DotSimBodySight")
	_finished += 1

	_entered += 1
	print("live rounds on %s with sight_verify: every pair swept, every bot ask checked" % ", ".join(MAPS))
	HsBots.sight_verify = true
	HsBots.sight_checked = 0
	HsBots.sight_mismatches = 0
	var sweep := {"pairs": 0, "differ": 0, "seen": 0, "nearest": 0, "found": 0}
	var timing := {"native": 0, "script": 0, "asks": 0}
	for map_id: String in MAPS:
		var game := await _new_game(map_id)
		var limit := int((game.config.hide_seconds + 60.0) * RATE)
		for tick in range(limit):
			game.simulate(1.0 / RATE)
			if tick % SWEEP_EVERY == 0 and game.phase != HsGame.Phase.IDLE:
				_sweep(game, sweep, timing)
			await get_tree().physics_frame
		_drop(game)
	HsBots.sight_verify = false
	print("  %d pairs and %d nearest asks swept, %d seen, %d found; %d live asks checked" % [sweep["pairs"], sweep["nearest"], sweep["seen"], sweep["found"], HsBots.sight_checked])
	_check(sweep["pairs"] > 1000 and sweep["seen"] > 0 and sweep["seen"] < sweep["pairs"], "the sweeps asked many pairs, some seen and some not")
	_check(sweep["found"] > 0, "a nearest ask found a body")
	_check(sweep["differ"] == 0, "every swept ask gave the script's answer", "%d differed" % sweep["differ"])
	_check(HsBots.sight_checked > 1000, "the bots asked natively", "%d asks" % HsBots.sight_checked)
	_check(HsBots.sight_mismatches == 0, "no live ask differed", "%d differed" % HsBots.sight_mismatches)
	var asks := maxi(int(timing["asks"]), 1)
	print("  bench %d nearest asks: script %.2f us, native %.2f us per ask" % [asks, float(timing["script"]) / asks, float(timing["native"]) / asks])
	_finished += 1

	_entered += 1
	print("the whole server tick with the mode flipped every 50 ticks in one round")
	var ab := await _whole_tick(MAPS[0], int(OS.get_environment("HS_SIGHT_AB_TICKS")) if OS.has_environment("HS_SIGHT_AB_TICKS") else 3000)
	print("  %s: native %.4f ms, script %.4f ms per tick (%d and %d seek ticks)" % [MAPS[0], ab["native_ms"], ab["script_ms"], ab["native_n"], ab["script_n"]])
	_check(ab["native_n"] > 0 and ab["script_n"] > 0, "both modes ran seek ticks")
	_finished += 1

	_entered += 1
	print("sight_mode script keeps the script, the round still plays")
	HsBots.sight_mode = "script"
	var game := await _new_game(MAPS[0])
	for tick in range(int((game.config.hide_seconds + 5.0) * RATE)):
		game.simulate(1.0 / RATE)
		await get_tree().physics_frame
	_check(not game.bots._sight_ready, "no native table is written in script mode")
	_check(game.phase == HsGame.Phase.SEEK, "the round reached the seek")
	_drop(game)
	HsBots.sight_mode = "native"
	_finished += 1

	_report_sections(_entered, _finished, SECTIONS, CHECKS)


func _new_game(map_id: String) -> HsGame:
	var config := HsConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	config.hide_seconds = 10.0
	config.map_ids = PackedStringArray([map_id])
	config.seed_value = 20261117
	var game := HsGame.new()
	game.config = config
	game.tick_rate = RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	var _set := DotBotSettings.of(game).set_difficulty("medium")
	await get_tree().physics_frame
	for i in range(BOTS):
		var bot := game.add_player(StringName("u%d" % (900 + i)), "Bot%d" % i)
		bot.is_bot = true
	game.start()
	return game


func _drop(game: HsGame) -> void:
	remove_child(game)
	game.free()


## Every ordered pair of bodies through `_sees` and every body's nearest both ways, native against the script, on
## the table the last tick's drive wrote (the bodies have moved since: written again here, as drive does).
func _sweep(game: HsGame, sweep: Dictionary, timing: Dictionary) -> void:
	var bots: HsBots = game.bots
	HsBots.sight_verify = false
	bots._sight_bind(game.players)
	if not bots._sight_ready:
		HsBots.sight_verify = true
		return
	var players: Array = game.players.values()
	for a: HsPlayer in players:
		for b: HsPlayer in players:
			if a == b:
				continue
			sweep["pairs"] += 1
			var native := bots._sight_sees(a, b)
			var script := bots._sees(a, b)
			if native != script:
				sweep["differ"] += 1
				push_error("sweep: %s sees %s native %s script %s" % [a.player_id, b.player_id, native, script])
			if script:
				sweep["seen"] += 1
		var at := a.controller.state.position
		var sight := bots.settings().profile.sight
		for prey in [false, true]:
			sweep["nearest"] += 1
			timing["asks"] += 1
			var t0 := Time.get_ticks_usec()
			var native: Variant = bots._sight_nearest(a, at, 1 if prey else 2, INF if prey else sight, prey)
			var t1 := Time.get_ticks_usec()
			var script: HsPlayer = bots._visible_prey_script(a, at) if prey else bots._nearest_seen_seeker_script(a, at, sight)
			var t2 := Time.get_ticks_usec()
			timing["native"] += t1 - t0
			timing["script"] += t2 - t1
			if script != null:
				sweep["found"] += 1
			if native is bool or native != script:
				sweep["differ"] += 1
				push_error("sweep: nearest (prey %s) for %s native %s script %s" % [prey, a.player_id, native, script])
	HsBots.sight_verify = true


## The whole tick, native and script in alternating blocks of the same seek.
func _whole_tick(map_id: String, ticks: int) -> Dictionary:
	var game := await _new_game(map_id)
	var guard := 0
	while game.phase != HsGame.Phase.SEEK and guard < 120 * RATE:
		game.simulate(1.0 / RATE)
		guard += 1
		await get_tree().physics_frame
	var total := {"native": 0, "script": 0}
	var count := {"native": 0, "script": 0}
	for t in range(ticks):
		var mode := "native" if (t / 50) % 2 == 0 else "script"
		HsBots.sight_mode = mode
		var t0 := Time.get_ticks_usec()
		game.simulate(1.0 / RATE)
		var dt := Time.get_ticks_usec() - t0
		if game.phase == HsGame.Phase.SEEK:
			total[mode] += dt
			count[mode] += 1
		await get_tree().physics_frame
	HsBots.sight_mode = "native"
	_drop(game)
	return {"native_ms": total["native"] / 1000.0 / maxi(count["native"], 1), "script_ms": total["script"] / 1000.0 / maxi(count["script"], 1),
		"native_n": count["native"], "script_n": count["script"]}

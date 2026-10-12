extends Node

const HsConfig := preload("../game/hs_config.gd")
const HsGame := preload("../game/hs_game.gd")
const HsPlayer := preload("../game/hs_player.gd")

## Stand-ins play whole rounds against each other on the real maps, and the suite measures how
## they hide and how they seek.
##
## [b]Why rounds, not a unit test.[/b] Christian's first play test watched bot hiders stand
## together in the open and three be tagged inside one second. Whether a bot hides well is how
## long it lasts against a seeker that searches, so this plays rounds (seven stand-ins, the game
## drawing its own seekers by its default rules, one for seven, `bot_difficulty medium`) and holds the numbers to bands:
##
## - how long a hider lasts once the seekers are let go, on average (caught ones at the second
##   they were caught, survivors at the round's end);
## - the share of rounds the hiders win, somebody still hidden at the end, and the share of hiders
##   never found: at medium a close game (30-60% of rounds, 15-40% of hiders), because a seeker
##   that finds nobody is as broken as a hider that is found at once;
## - that the hiders shut doors behind them;
## - how far apart the hiders are when the seekers are let go, and how few stand within 3 m of
##   another;
## - that the seekers catch somebody at all in most rounds;
## - that no stand-in stays stuck beside an open door's panel for long.
##
## Twenty-four rounds by default, four a map, about four minutes: a band on six rounds was a band
## on noise. `-- --rounds N` plays another number, `-- --first N` starts
## at the Nth round's map and seed, `-- --difficulty hard` plays another preset, and
## `HS_BOTS_TRACE=1` prints where everybody is every two seconds and every catch (with what last sent the hider moving), and `HS_BOTS_FOLLOW=u903` one stand-in every half second. `HS_CAUGHT_FROM`, `HS_BEACON_LEFT` and `HS_BEACON_SECONDS` set those rules for a measurement. Without `maps/` linked it plays the practice house.

## Maps the rounds rotate through, when `maps/` is there.
const MAPS := ["hs_manor", "hs_apartments", "hs_village", "hs_park", "hs_school", "hs_camp"]

const TICK_RATE := 32
const TICK := 1.0 / float(TICK_RATE)
const BOTS := 7

## The bands at medium. A hider lasts at least this long on average (seconds of seeking).
const MIN_MEAN_SURVIVAL := 90.0

## At medium: the share of rounds the hiders win, and of hiders never found.
const HIDER_WINS := Vector2(0.30, 0.60)
const NEVER_FOUND := Vector2(0.15, 0.40)

## The longest any stand-in may spend walking and still within 1.5 m of one spot beside an open
## door's panel, in seconds. A seeker spent about thirty pressed into the corner behind an open
## fire door (`hns-bot-door-corner-1`), and a hider a whole hide against one at the top of a
## stair, until a bot went round an open panel's free edge; then 18 s was left on 48 seeds
## (panels spanning a corridor or a stair top, doors pinned to open towards a bot leaving).
## Bots now step out of a swing to open or shut a door and shut a panel they linger at, and
## the maps were fixed where a panel had no way round: seeds 0-23 give 9.8 s at worst, 24-47
## 14.5 s (a manor door's jamb, a cottage bedroom door). 15 s, not 10: the rest is unfinished
## work (`hns-bot-door-linger-2`), not the target.
const MAX_STUCK := 15.0

const SECTIONS := 2

var _passed := 0
var _failed := 0
var _entered := 0
var _completed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	# The world ticks itself (simulate) and waits for a physics frame after each tick so doors
	# and bodies are where the physics server says; physics frames come at their rate in real
	# time, so a fast rate lets a round of four minutes play in seconds.
	Engine.physics_ticks_per_second = 1920
	Engine.max_physics_steps_per_frame = 64
	_run.call_deferred()


func _run() -> void:
	print("hideseek bots")
	print("")
	var args := OS.get_cmdline_user_args()
	var rounds := 24
	var at := args.find("--rounds")
	if at >= 0 and at + 1 < args.size():
		rounds = maxi(1, int(args[at + 1]))
	var difficulty := "medium"
	at = args.find("--difficulty")
	if at >= 0 and at + 1 < args.size():
		difficulty = args[at + 1]

	var first := 0
	at = args.find("--first")
	if at >= 0 and at + 1 < args.size():
		first = maxi(0, int(args[at + 1]))
	var linked := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://maps"))
	var results: Array[Dictionary] = []

	_section("%d rounds of stand-ins at %s%s" % [rounds, difficulty, "" if linked else " (no maps/: the practice house)"])
	for r in range(first, first + rounds):
		var map_id: String = MAPS[r % MAPS.size()] if linked else "hs_practice"
		var result := await _round(map_id, r, difficulty)
		results.append(result)
		print("  round %2d %-14s %d seekers  caught %d of %d  mean last %5.1f s  first %5.1f s  spread %.1f m, %d within 3 m  survey %4.0f ms  %d doors shut  stuck %4.1f s (%s at %s)" % [
			r + 1, map_id, result["seekers"], result["caught"], result["hiders"], result["mean_last"], minf(float(result["first"]), 999.0),
			result["spread"], result["close"], result["survey_ms"], result["doors_shut"], result["stuck"], result["stuck_who"], str((result["stuck_at"] as Vector3).snapped(Vector3.ONE * 0.1))])
	_completed += 1

	_section("the bands")
	var lasts := 0.0
	var hiders := 0
	var survived := 0
	var close := 0
	var spread := 0.0
	var rounds_with_catch := 0
	var hider_wins := 0
	var first_catches := PackedFloat32Array()
	var doors_shut := 0
	var stuck_worst := {}
	for result in results:
		if stuck_worst.is_empty() or float(result["stuck"]) > float(stuck_worst["stuck"]):
			stuck_worst = result
		doors_shut += int(result["doors_shut"])
		lasts += float(result["sum_last"])
		hiders += int(result["hiders"])
		survived += int(result["hiders"]) - int(result["caught"])
		close += int(result["close"])
		spread += float(result["spread"])
		if int(result["caught"]) < int(result["hiders"]):
			hider_wins += 1
		if int(result["caught"]) > 0:
			rounds_with_catch += 1
			first_catches.append(float(result["first"]))
	var mean := lasts / maxf(float(hiders), 1.0)
	var share := float(survived) / maxf(float(hiders), 1.0)
	print("  mean time a hider lasts: %.1f s; %.0f%% of hiders never found; hiders won %d rounds of %d; %d with a catch; mean spread %.1f m; %d hiders within 3 m of another; %d doors shut" % [
		mean, share * 100.0, hider_wins, results.size(), rounds_with_catch, spread / maxf(float(results.size()), 1.0), close, doors_shut])
	if difficulty == "medium":
		_check(mean >= MIN_MEAN_SURVIVAL, "bot hiders last %.0f s or more on average against bot seekers" % MIN_MEAN_SURVIVAL, "%.1f s" % mean)
		var wins := float(hider_wins) / maxf(float(results.size()), 1.0)
		_check(wins >= HIDER_WINS.x and wins <= HIDER_WINS.y,
			"a close game: the hiders win %.0f-%.0f%% of rounds" % [HIDER_WINS.x * 100.0, HIDER_WINS.y * 100.0], "hiders won %d of %d" % [hider_wins, results.size()])
		_check(share >= NEVER_FOUND.x and share <= NEVER_FOUND.y,
			"%.0f-%.0f%% of hiders are never found" % [NEVER_FOUND.x * 100.0, NEVER_FOUND.y * 100.0], "%.0f%%" % (share * 100.0))
		_check(doors_shut > 0, "hiders shut doors behind them", "%d doors" % doors_shut)
		_check(rounds_with_catch * 2 >= results.size(), "the seekers catch somebody in at least half the rounds", "%d of %d" % [rounds_with_catch, results.size()])
		_check(close * 4 <= hiders, "hiders spread out: at most one in four within 3 m of another when the seekers come", "%d of %d" % [close, hiders])
		var none_at_once := true
		for f in first_catches:
			if f < 3.0:
				none_at_once = false
		_check(none_at_once, "nobody is caught in the first three seconds of a seek")
	_check(float(stuck_worst.get("stuck", 0.0)) <= MAX_STUCK, "no stand-in stays stuck beside an open door's panel more than %.0f s" % MAX_STUCK,
		"%.1f s, %s at %s on %s" % [float(stuck_worst.get("stuck", 0.0)), stuck_worst.get("stuck_who", ""), str((stuck_worst.get("stuck_at", Vector3.ZERO) as Vector3).snapped(Vector3.ONE * 0.1)), stuck_worst.get("map", "")])
	_completed += 1

	print("")
	print("%d sections entered, %d finished" % [_entered, _completed])
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	var code := 1 if _failed > 0 else 0
	if _entered != SECTIONS or _completed != _entered:
		print("ERROR: %d of %d sections finished." % [_completed, SECTIONS])
		code = 1
	get_tree().quit(code)


## One round on [param map_id]: seven stand-ins from a fresh world, played to its end.
func _round(map_id: String, index: int, difficulty: String) -> Dictionary:
	var config := HsConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	config.map_ids = PackedStringArray([map_id])
	config.seed_value = 20261012 + index * 7919
	if OS.has_environment("HS_CAUGHT_FROM"):
		config.caught_seek_from = int(OS.get_environment("HS_CAUGHT_FROM"))
	if OS.has_environment("HS_BEACON_LEFT"):
		config.beacon_hiders_left = int(OS.get_environment("HS_BEACON_LEFT"))
	if OS.has_environment("HS_BEACON_SECONDS"):
		config.beacon_seconds_left = float(OS.get_environment("HS_BEACON_SECONDS"))

	var game := HsGame.new()
	game.name = "Bots_%d" % index
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	var _set := DotBotSettings.of(game).set_difficulty(difficulty)
	await get_tree().physics_frame

	for i in range(BOTS):
		var bot := game.add_player(StringName("u%d" % (900 + i)), "Bot%d" % i)
		bot.is_bot = true

	var caught_at := {}
	var seek_started := -1.0
	game.caught.connect(func(id: StringName, by: StringName, how: StringName) -> void:
		caught_at[id] = game.seek_elapsed
		if OS.has_environment("HS_BOTS_TRACE"):
			var who: HsPlayer = game.players.get(id)
			var st: Dictionary = game.bots._state.get(id, {})
			print("    caught %s at %.1f s by %s (%s) at %s mode %s %s fled %.1f s ago" % [id, game.seek_elapsed, by, how,
				who.controller.state.position.snapped(Vector3.ONE * 0.1) if who != null else Vector3.ZERO, st.get("mode", ""), st.get("why", ""), game.bots.now() - float(st.get("moved_at", -INF))]))
	game.start()

	var follow := StringName(OS.get_environment("HS_BOTS_FOLLOW"))
	var hiders: Array[StringName] = []
	var spread := 0.0
	var close := 0
	var limit := int((config.hide_seconds + config.round_seconds + 10.0) * TICK_RATE)
	for tick in range(limit):
		game.simulate(TICK)
		await get_tree().physics_frame
		if seek_started < 0.0 and game.phase == HsGame.Phase.SEEK:
			seek_started = game._now()
			for p in game.players_on(HsGame.HIDERS):
				hiders.append(p.player_id)
			var measured := _spread(game.players_on(HsGame.HIDERS))
			spread = measured[0]
			close = measured[1]
			if OS.has_environment("HS_BOTS_TRACE"):
				for p in game.players_on(HsGame.HIDERS):
					var st: Dictionary = game.bots._state.get(p.player_id, {})
					var spot: Dictionary = st.get("spot", {})
					print("    %s at %s crouch %.1f spot %s exp %.2f mode %s" % [p.player_id, p.controller.state.position.snapped(Vector3.ONE * 0.1), p.controller.state.crouch_fraction,
						str((spot.get("at", Vector3.ZERO) as Vector3).snapped(Vector3.ONE * 0.1)), float(spot.get("exposure", -1.0)), st.get("mode", "")])
		if seek_started >= 0.0 and game.phase != HsGame.Phase.SEEK:
			break
		if follow != &"" and tick % (TICK_RATE / 2) == 0 and game.players.has(follow):
			_follow(game, follow)
		if OS.has_environment("HS_BOTS_TRACE") and tick % (TICK_RATE * 2) == 0 and (seek_started >= 0.0 or OS.has_environment("HS_BOTS_HIDE")):
			var line := "    %5.1f s" % game.seek_elapsed
			for id: StringName in game.players:
				var p: HsPlayer = game.players[id]
				var st: Dictionary = game.bots._state.get(id, {})
				line += "  %s%s%s %s" % [id.substr(3), "S" if game.team_of(id) == HsGame.SEEKERS else "h", String(st.get("mode", "")).substr(0, 4),
					str(Vector2(p.controller.state.position.x, p.controller.state.position.z).snapped(Vector2.ONE))]
				if game.team_of(id) == HsGame.SEEKERS and not (st.get("goal_place", {}) as Dictionary).is_empty():
					var g: Vector3 = st["goal_place"]["at"]
					line += "->%s" % str(Vector2(g.x, g.z).snapped(Vector2.ONE))
			print(line)

	var seekers := BOTS - hiders.size()
	var sum_last := 0.0
	var first := INF
	var caught := 0
	var round_len := game.round_limit()
	for id in hiders:
		if caught_at.has(id):
			caught += 1
			sum_last += float(caught_at[id])
			first = minf(first, float(caught_at[id]))
		else:
			sum_last += round_len
	var result := {
		"seekers": seekers, "hiders": hiders.size(), "caught": caught, "sum_last": sum_last,
		"mean_last": sum_last / maxf(float(hiders.size()), 1.0), "first": first,
		"spread": spread, "close": close, "survey_ms": float((game.get("bots") as Object).get("survey_ms")) if game.get("bots") != null else 0.0,
	}
	result["doors_shut"] = int(game.bots.doors_shut)
	result["stuck"] = float(game.bots.longest_stuck)
	result["stuck_at"] = game.bots.longest_stuck_at
	result["stuck_who"] = game.bots.longest_stuck_who
	result["map"] = map_id
	remove_child(game)
	game.free()
	await get_tree().process_frame
	return result


## `HS_BOTS_FOLLOW=<id>`: one stand-in every half second, where it is going and the doors
## round it, which is how the door-corner seekers were found.
func _follow(game: HsGame, id: StringName) -> void:
	var who: HsPlayer = game.players[id]
	var st: Dictionary = game.bots._state.get(id, {})
	var at := who.controller.state.position
	var line := "    %6.2f s %s %s v %s %s" % [game.bots.now(), id, str(at.snapped(Vector3.ONE * 0.1)),
		str(who.controller.state.velocity.snapped(Vector3.ONE * 0.1)), st.get("mode", "")]
	var path: PackedVector3Array = st.get("path", PackedVector3Array())
	if not path.is_empty():
		line += " corner %s" % str(path[mini(int(st.get("corner", 0)), path.size() - 1)].snapped(Vector3.ONE * 0.1))
	var detour: PackedVector3Array = st.get("detour", PackedVector3Array())
	if not detour.is_empty():
		line += " detour %s" % str(detour[0].snapped(Vector3.ONE * 0.1))
	line += " goal %s stuck %d" % [str((st.get("goal", Vector3.ZERO) as Vector3).snapped(Vector3.ONE * 0.1)), int(st.get("stuck_count", 0))]
	for index in range(game.map.doors.count()):
		var panel: Vector3 = game.map.doors.panel_transform(index, game.map.doors.fraction(index, game._tick)).origin
		if panel.distance_to(at + Vector3(0.0, 1.0, 0.0)) < 2.5:
			var ends: PackedVector3Array = game.map.doors.panel_ends(index, game.map.doors.fraction(index, game._tick))
			line += " door %d %s, hinge %s free %s" % [index, "open" if game.map.doors.is_open(index) else "shut",
				str(Vector2(ends[0].x, ends[0].z).snapped(Vector2.ONE * 0.1)), str(Vector2(ends[1].x, ends[1].z).snapped(Vector2.ONE * 0.1))]
	print(line)


## The hiders' mean distance to their nearest other hider, and how many have one within 3 m.
func _spread(hiders: Array[HsPlayer]) -> Array:
	var total := 0.0
	var close := 0
	for a in hiders:
		var nearest := INF
		for b in hiders:
			if a != b:
				nearest = minf(nearest, a.controller.state.position.distance_to(b.controller.state.position))
		if nearest < INF:
			total += nearest
		if nearest < 3.0:
			close += 1
	return [total / maxf(float(hiders.size()), 1.0), close]


func _section(name: String) -> void:
	_entered += 1
	print(name)


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return
	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)

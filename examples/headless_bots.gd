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
## `HS_BOTS_PROBE=1` prints where each survivor ends and whether the seekers can walk to it; `HS_BOTS_MAPS=a,b` plays other maps, `HS_BOTS_TRACE=1` prints where everybody is every two seconds and every catch (with what last sent the hider moving), and `HS_BOTS_FOLLOW=u903` one stand-in every half second (every tick with `HS_BOTS_EVERY=1`). `HS_CAUGHT_FROM`, `HS_BEACON_LEFT` and `HS_BEACON_SECONDS` set those rules for a measurement. Without `maps/` linked it plays the practice house.

## Maps the rounds rotate through, when `maps/` is there.
const DEFAULT_MAPS := ["hs_manor", "hs_apartments", "hs_village", "hs_park", "hs_school", "hs_camp", "hs_restaurant"]

## `HS_BOTS_MAPS=hs_frontyard,hs_hotel` plays those maps instead: the bands for a map added to the
## pack (an imported one) without lengthening the default run or moving the six maps' statistics.
var MAPS: Array = Array(OS.get_environment("HS_BOTS_MAPS").split(",", false)) if OS.has_environment("HS_BOTS_MAPS") else DEFAULT_MAPS

var TICK_RATE := int(OS.get_environment("HS_BOTS_TICK")) if OS.has_environment("HS_BOTS_TICK") else 32
var TICK := 1.0 / float(TICK_RATE)
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
## Bots now step out of a swing to open or shut a door, shut a panel they linger at and go
## somewhere else after 8 s, count a door only on their own storey, pass a corner only once the
## way on is open, and the maps lost their panels with no way round (small rooms' doors slide).
const MAX_STUCK := 9.0

## What the review found wrong (2026-10-15) and how it is held. Hiders: this share ends the hide at
## least [constant MOVED_FAR] metres from where they spawned and out of every seeker's sight.
## Seeker: the first seeker's walk comes within [constant COVER_RADIUS] metres of at least
## [constant MIN_COVERED] of the map's surveyed places inside [constant COVER_SECONDS] seconds,
## and somebody is caught inside [constant FIND_WITHIN] seconds in [constant FIND_SHARE] of rounds.
## The same measures on the review's stand-ins ([member HsBots.legacy]: hiders stand, the seeker
## walks a line) must fail, or they measure nothing.
const MOVED_FAR := 8.0
const MIN_MOVED := 0.80
const MIN_UNSEEN := 0.80
const COVER_RADIUS := 6.0
const COVER_SECONDS := 120.0
const MIN_COVERED := 0.15
const FIND_WITHIN := 120.0
const FIND_SHARE := 0.70

## Rounds the legacy stand-ins play to arm the checks above.
const ARMED_ROUNDS := 2

const SECTIONS := 3

## The annotator's hiding spots against the random survey they replaced. Each hider's place when
## the seek begins is scored `(1 - exposure) * 2 + enclosure * 1.5` (the share of the map's
## watchers that see a crouched head there, and how tucked in it is, both measured by the same
## [method HsBots.quality] for every place), and the mean must beat what the old survey's best
## picks scored on the same map by [constant MIN_QUALITY_GAIN]. The hiders that stood where they
## spawned (they spawn in a hide room: they would pass) and hiders at random places on the floor must fail it. And every map has a round with a catch: a map on which the seekers never
## find anybody is unwinnable.
const MIN_QUALITY_GAIN := 0.15

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
		var moved := 0
		var unseen := 0
		var covered := 0.0
		var found := 0
		for result in results:
			moved += int(result["moved"])
			unseen += int(result["unseen"])
			covered += float(result["covered"])
			if float(result["first"]) <= FIND_WITHIN:
				found += 1
		var count := float(maxi(results.size(), 1))
		print("  hiders end the hide %d of %d at least %.0f m from their spawn, %d of %d out of every seeker's sight; the first seeker covers %.0f%% of the surveyed places in %.0f s; somebody caught inside %.0f s in %d of %d rounds" % [
			moved, hiders, MOVED_FAR, unseen, hiders, covered / count * 100.0, COVER_SECONDS, FIND_WITHIN, found, results.size()])
		_check(float(moved) >= MIN_MOVED * float(hiders), "hiders walk off: %.0f%% end the hide at least %.0f m from where they spawned" % [MIN_MOVED * 100.0, MOVED_FAR], "%d of %d" % [moved, hiders])
		_check(float(unseen) >= MIN_UNSEEN * float(hiders), "hiders hide: %.0f%% are out of every seeker's sight when the seek begins" % [MIN_UNSEEN * 100.0], "%d of %d" % [unseen, hiders])
		_check(covered / count >= MIN_COVERED, "the seeker sweeps the map: %.0f%% of its surveyed places within %.0f m in %.0f s" % [MIN_COVERED * 100.0, COVER_RADIUS, COVER_SECONDS], "%.0f%%" % (covered / count * 100.0))
		_check(float(found) >= FIND_SHARE * count, "the seeker finds a hider within %.0f s in %.0f%% of rounds" % [FIND_WITHIN, FIND_SHARE * 100.0], "%d of %d" % [found, results.size()])
	if difficulty == "medium":
		var q_new := 0.0
		var q_old := 0.0
		var by_map := {}
		for result in results:
			q_new += float(result["q_new"])
			q_old += float(result["q_old"])
			by_map[result["map"]] = int(by_map.get(result["map"], 0)) + (1 if int(result["caught"]) > 0 else 0)
			if result["round"] < MAPS.size():
				print("  %-14s %d links used, %d chokepoints, annotated in %.0f ms" % [result["map"], result["links"], result["chokes"], result["annotate_ms"]])
		q_new /= float(maxi(results.size(), 1))
		q_old /= float(maxi(results.size(), 1))
		print("  a hider's place scores %.2f against %.2f for the old survey's best picks" % [q_new, q_old])
		_check(q_new >= q_old + MIN_QUALITY_GAIN, "hiders' places beat the old survey's by %.2f" % MIN_QUALITY_GAIN, "%.2f against %.2f" % [q_new, q_old])
		var unwinnable := PackedStringArray()
		for m in by_map:
			if int(by_map[m]) == 0:
				unwinnable.append(m)
		_check(unwinnable.is_empty(), "no map is unwinnable: the seekers catch somebody on every map played", ", ".join(unwinnable))
	_check(float(stuck_worst.get("stuck", 0.0)) <= MAX_STUCK, "no stand-in stays stuck beside an open door's panel more than %.1f s" % MAX_STUCK,
		"%.1f s, %s at %s on %s" % [float(stuck_worst.get("stuck", 0.0)), stuck_worst.get("stuck_who", ""), str((stuck_worst.get("stuck_at", Vector3.ZERO) as Vector3).snapped(Vector3.ONE * 0.1)), stuck_worst.get("map", "")])
	_completed += 1

	_section("the checks, armed against the stand-ins that stood and walked a line")
	var old: Array[Dictionary] = []
	for r in range(first, first + ARMED_ROUNDS):
		var result := await _round(MAPS[r % MAPS.size()] if linked else "hs_practice", r, difficulty, true)
		old.append(result)
		print("  legacy round %2d %-14s moved far %d of %d, unseen %d, covered %.0f%%, first catch %5.1f s" % [
			r + 1, result["map"], result["moved"], result["hiders"], result["unseen"], float(result["covered"]) * 100.0, minf(float(result["first"]), 999.0)])
	var old_moved := 0
	var old_unseen := 0
	var old_hiders := 0
	var old_covered := 0.0
	var old_found := 0
	var old_q_new := 0.0
	var old_q_old := 0.0
	for result in old:
		old_q_new += float(result["q_rand"])
		old_q_old += float(result["q_old"])
		old_moved += int(result["moved"])
		old_unseen += int(result["unseen"])
		old_hiders += int(result["hiders"])
		old_covered += float(result["covered"])
		if float(result["first"]) <= FIND_WITHIN:
			old_found += 1
	_check(float(old_moved) < MIN_MOVED * float(old_hiders), "armed: hiders that stand where they spawn fail the moved-far check", "%d of %d moved" % [old_moved, old_hiders])
	_check(old_covered / float(old.size()) < MIN_COVERED, "armed: a seeker walking a straight line fails the coverage check", "%.0f%%" % (old_covered / float(old.size()) * 100.0))
	_check(float(old_found) < FIND_SHARE * float(old.size()), "armed: a seeker walking a straight line fails the find-a-hider check", "%d of %d rounds" % [old_found, old.size()])
	_check(old_q_new / float(old.size()) < old_q_old / float(old.size()) + MIN_QUALITY_GAIN, "armed: hiders at random places on the floor fail the hiding-quality check",
		"%.2f against %.2f" % [old_q_new / float(old.size()), old_q_old / float(old.size())])
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
func _round(map_id: String, index: int, difficulty: String, legacy: bool = false) -> Dictionary:
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

	game.bots.legacy = legacy
	var caught_at := {}
	var hide_spawn := {}
	var seekers_at_start: Array[StringName] = []
	var visited := PackedVector3Array()
	var moved := 0
	var unseen := 0
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
	var quality_new := 0.0
	var quality_old := 0.0
	var quality_rand := 0.0
	var limit := int((config.hide_seconds + config.round_seconds + 10.0) * TICK_RATE)
	for tick in range(limit):
		game.simulate(TICK)
		await get_tree().physics_frame
		if hide_spawn.is_empty() and game.phase == HsGame.Phase.HIDE:
			for id: StringName in game.players:
				hide_spawn[id] = (game.players[id] as HsPlayer).controller.state.position
		if seek_started >= 0.0 and game.seek_elapsed <= COVER_SECONDS and tick % 8 == 0:
			for id in seekers_at_start:
				visited.append((game.players[id] as HsPlayer).controller.state.position)
		if seek_started < 0.0 and game.phase == HsGame.Phase.SEEK:
			seek_started = game._now()
			for p in game.players_on(HsGame.HIDERS):
				hiders.append(p.player_id)
			for p in game.players_on(HsGame.SEEKERS):
				seekers_at_start.append(p.player_id)
			for p in game.players_on(HsGame.HIDERS):
				if p.controller.state.position.distance_to(hide_spawn.get(p.player_id, p.controller.state.position)) >= MOVED_FAR:
					moved += 1
				var seen := false
				for q in game.players_on(HsGame.SEEKERS):
					if game._clear_between(q.eye_position(), p.eye_position(), true):
						seen = true
				if not seen:
					unseen += 1
			var picks: PackedVector3Array = game.bots.legacy_picks(hiders.size())
			for p in game.players_on(HsGame.HIDERS):
				quality_new += _score(game.bots.quality(p.controller.state.position)) / float(maxi(hiders.size(), 1))
			for at in picks:
				quality_old += _score(game.bots.quality(at)) / float(maxi(picks.size(), 1))
			var scatter := DotRandomStream.new(5, &"hs_bots_random")
			for _i in range(hiders.size()):
				quality_rand += _score(game.bots.quality(game.bots.nav.random_point(scatter))) / float(maxi(hiders.size(), 1))
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
		if follow != &"" and (tick % (TICK_RATE / 2) == 0 or OS.has_environment("HS_BOTS_EVERY")) and game.players.has(follow):
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
			if OS.has_environment("HS_BOTS_PROBE"):
				var pl: HsPlayer = game.players[id]
				var sp: Vector3 = pl.controller.state.position
				var sk: Vector3 = (game.map.call("spawn", "seekers", 0) as Array)[0]
				print("    SURVIVOR %s at %s path from seeker spawn %.1f" % [id, sp, game.bots.nav.path_length(game.bots.nav.closest(sk), sp)])
	var result := {
		"seekers": seekers, "hiders": hiders.size(), "caught": caught, "sum_last": sum_last,
		"mean_last": sum_last / maxf(float(hiders.size()), 1.0), "first": first,
		"moved": moved, "unseen": unseen, "covered": _covered(game.bots.spots + game.bots.sweep, visited),
		"q_new": quality_new, "q_old": quality_old, "q_rand": quality_rand,
		"links": game.bots.links_used, "chokes": game.bots.annotations.chokepoints.size() if game.bots.annotations != null else 0, "annotate_ms": game.bots.annotate_ms,
		"spread": spread, "close": close, "survey_ms": float((game.get("bots") as Object).get("survey_ms")) if game.get("bots") != null else 0.0,
	}
	result["doors_shut"] = int(game.bots.doors_shut)
	result["stuck"] = float(game.bots.longest_stuck)
	result["stuck_at"] = game.bots.longest_stuck_at
	result["stuck_who"] = game.bots.longest_stuck_who
	result["map"] = map_id
	result["round"] = index
	remove_child(game)
	game.free()
	await get_tree().process_frame
	return result


## The share of the surveyed places a walk came within [constant COVER_RADIUS] metres of (on the
## same storey): how much of the map a seeker has been round, whatever it was thinking.
func _covered(spots: Array[Dictionary], walk: PackedVector3Array) -> float:
	if spots.is_empty():
		return 0.0
	var seen := 0
	for spot in spots:
		var at: Vector3 = spot["at"]
		for p in walk:
			if Vector2(p.x - at.x, p.z - at.z).length() <= COVER_RADIUS and absf(p.y - at.y) < 2.5:
				seen += 1
				break
	return float(seen) / float(spots.size())


## `HS_BOTS_FOLLOW=<id>`: one stand-in every half second, where it is going and the doors
## round it, which is how the door-corner seekers were found.
func _follow(game: HsGame, id: StringName) -> void:
	var who: HsPlayer = game.players[id]
	var st: Dictionary = game.bots._state.get(id, {})
	var at := who.controller.state.position
	var line := "    %6.2f s %s %s v %s %s" % [game.bots.now(), id, str(at.snapped(Vector3.ONE * 0.1)),
		str(who.controller.state.velocity.snapped(Vector3.ONE * 0.1)), st.get("mode", "")]
	line += " crouch %.1f" % who.controller.state.crouch_fraction
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


func _score(q: Array) -> float:
	return (1.0 - float(q[0])) * 2.0 + float(q[1]) * 1.5


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

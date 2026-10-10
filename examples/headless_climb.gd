extends Node

const HsConfig := preload("../game/hs_config.gd")
const HsGame := preload("../game/hs_game.gd")
const HsPlayer := preload("../game/hs_player.gd")

## The maps' ways UP and ways IN, walked by a body rather than read from a document.
##
## [b]Why this exists apart from `headless_maps`.[/b] A flight of stairs is a dozen slabs the
## builder lines up with a storey, and a crawl space is a lid at a height; both are right on
## paper and wrong by a few centimetres in a way only the motor notices. A stairwell whose
## landing is a step too high is a floor nobody reaches and every check of the document passes.
## So here somebody stands at the foot of each one that matters, holds forward for a few
## seconds, and the suite asks how high they got; and somebody tries a play tube standing (and
## is refused) and then crouched (and gets through).
##
## Every coordinate is hide-n-seek-maps' `tools/build_maps.py`; a map moved there is a climb
## that fails here, which is the point. Without `maps/` linked in (CI clones this repository
## alone) there is nothing to climb, and it says so.

## map, where to stand, which way to face (the game's yaw: 0 looks along -Z), seconds of
## running, how high their feet must end up, and what it is.
const CLIMBS := [
	["hs_apartments", Vector3(7.0, 0.05, -1.4), 0.0, 2.5, 1.6, "the stairwell's first flight, to the half landing"],
	["hs_apartments", Vector3(-18.0, 0.05, 4.4), 0.0, 3.5, 3.3, "the fire escape, from the alley to the first floor"],
	["hs_warehouse", Vector3(12.8, 0.05, -1.2), 0.0, 3.0, 3.5, "the stairs to the mezzanine"],
	["hs_warehouse", Vector3(-9.4, 0.05, 20.7), 90.0, 1.4, 2.5, "the steps onto a container's roof"],
	["hs_manor", Vector3(0.0, 0.05, 3.0), 0.0, 3.5, 3.7, "the grand stair, to the landing"],
	["hs_village", Vector3(20.6, 0.05, 6.1), -90.0, 3.0, 2.9, "the barn's stairs, to the hayloft"],
	["hs_park", Vector3(0.1, 0.05, 1.2), 0.0, 3.0, 2.3, "the tall tower's steps"],
]

## A play tube in the park, running east from x -6 to 4: where to stand at its west mouth.
const TUBE_MAP := "hs_park"
const TUBE_MOUTH := Vector3(-6.8, 0.05, -2.5)
const TUBE_YAW := -90.0

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()
var _expected_checks := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("hideseek climbs")
	print("")

	var linked := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://maps"))

	if not linked:
		print("(no map directory: nothing to climb)")
	else:
		var by_map := {}
		for climb: Array in CLIMBS:
			if not by_map.has(climb[0]):
				by_map[climb[0]] = []
			(by_map[climb[0]] as Array).append(climb)

		for map_id: String in by_map:
			await _test_climbs(map_id, by_map[map_id])

		await _test_the_tube()

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished:
		print("ERROR: %d of %d sections finished." % [_sections_finished, _sections_entered])
		code = 1

	if _passed + _failed != _expected_checks:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, _expected_checks])
		code = 1

	get_tree().quit(code)


func _test_climbs(map_id: String, climbs: Array) -> void:
	_section(map_id)
	_expected_checks += climbs.size()
	var game := await _world(map_id)
	var body := game.add_player(&"u1", "Climber")
	await _physics_frame()

	for climb: Array in climbs:
		body.place_at(climb[1], float(climb[2]))
		var top := -INF
		for _i in range(int(float(climb[3]) * TICK_RATE)):
			_drive(body, float(climb[2]), false)
			await _step(game)
			top = maxf(top, body.controller.state.position.y)
		var at := body.controller.state.position
		_check(at.y >= float(climb[4]) - 0.05, str(climb[5]),
			"feet at %.2f, wanted %.2f; highest %.2f, ended at %s" % [at.y, float(climb[4]), top, at.snapped(Vector3.ONE * 0.1)])

	await _dispose(game)
	_finished()


func _test_the_tube() -> void:
	_section("a play tube: refused standing, crawled through crouched")
	_expected_checks += 2
	var game := await _world(TUBE_MAP)
	var body := game.add_player(&"u1", "Crawler")
	await _physics_frame()

	body.place_at(TUBE_MOUTH, TUBE_YAW)
	for _i in range(TICK_RATE * 2):
		_drive(body, TUBE_YAW, false)
		await _step(game)
	_check(body.controller.state.position.x < -5.6, "somebody standing does not fit",
		"x %.2f" % body.controller.state.position.x)

	body.place_at(TUBE_MOUTH, TUBE_YAW)
	for _i in range(TICK_RATE * 5):
		_drive(body, TUBE_YAW, true)
		await _step(game)
	_check(body.controller.state.position.x > 0.0, "somebody crouched gets through",
		"x %.2f" % body.controller.state.position.x)

	await _dispose(game)
	_finished()


# --- Helpers --------------------------------------------------------------------

func _world(map_id: String) -> HsGame:
	var config := HsConfig.new()
	config.warmup_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	config.map_ids = PackedStringArray([map_id])

	var game := HsGame.new()
	game.name = "World_%s" % map_id
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	await _physics_frame()
	await _physics_frame()
	return game


func _drive(body: HsPlayer, yaw: float, crouched: bool) -> void:
	var command := DotFpsCommand.new()
	command.yaw = yaw
	command.move = Vector2(0.0, 1.0)
	command.set_button(DotFpsCommand.BUTTON_CROUCH, crouched)
	body.controller.apply_command(command)


func _step(game: HsGame) -> void:
	game.simulate(TICK)
	await _physics_frame()


func _physics_frame() -> void:
	await get_tree().physics_frame


func _dispose(game: HsGame) -> void:
	remove_child(game)
	game.free()
	await get_tree().process_frame


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

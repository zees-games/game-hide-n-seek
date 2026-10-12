extends Node

const HsConfig := preload("../game/hs_config.gd")
const HsGame := preload("../game/hs_game.gd")
const HsPlayer := preload("../game/hs_player.gd")
const HsMapDoc := preload("../game/hs_map_doc.gd")

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
	["hs_school", Vector3(-11.0, 0.05, -1.2), 0.0, 3.0, 1.7, "the west stairwell, to its landing"],
	["hs_school", Vector3(-9.0, 1.85, -7.6), 180.0, 3.0, 3.5, "and from the landing on up to the top corridor"],
	["hs_school", Vector3(16.0, 0.05, 3.2), 180.0, 4.0, 3.5, "the gym's stair, to the balcony"],
	["hs_school", Vector3(24.0, 0.05, 5.4), 180.0, 3.0, 2.5, "the bleachers, to the top row"],
	["hs_school", Vector3(-6.0, 0.05, -23.2), 0.0, 2.0, 1.15, "the steps up to the portable classroom"],
	["hs_mall", Vector3(-19.8, 0.05, -1.2), -90.0, 4.0, 3.9, "the atrium's west stair, up to the bridge"],
	["hs_mall", Vector3(25.2, 0.05, 13.6), -90.0, 4.0, 3.9, "the service stair, from the south corridor"],
	["hs_mall", Vector3(-26.6, 4.05, -3.45), 90.0, 3.0, 5.9, "the cinema's tiers, up the aisle to the back row"],
	["hs_ship", Vector3(-27.0, -3.15, -1.5), 0.0, 3.0, -1.7, "the after stairwell, up from the engine room"],
	["hs_ship", Vector3(-25.0, -1.55, -4.8), 180.0, 3.0, -0.1, "and on round the turn to the cabin deck"],
	["hs_ship", Vector3(1.0, 2.05, 15.6), 0.0, 3.5, 3.1, "the gangway, from the quay onto the deck"],
	["hs_ship", Vector3(-39.6, 3.25, 7.5), -90.0, 3.5, 6.3, "the aft stair, up to the sun deck"],
	["hs_ship", Vector3(14.0, 6.45, 4.5), -90.0, 3.5, 9.3, "the stair to the bridge's roof"],
	["hs_castle", Vector3(-34.2, 0.05, -29.1), 0.0, 2.0, 1.4, "the north-west tower's stair, from its door"],
	["hs_castle", Vector3(29.0, 0.05, 7.6), 0.0, 4.5, 5.9, "the stair up the inside of the east wall to the walk"],
	["hs_castle", Vector3(-10.4, 0.05, -18.6), 0.0, 2.5, 1.9, "the keep's stair, to its first landing"],
	["hs_castle", Vector3(4.4, -3.45, -18.6), 180.0, 4.0, -0.1, "up from the dungeon into the great hall"],
	["hs_castle", Vector3(-10.7, -3.45, 1.0), 180.0, 4.0, -0.1, "the tunnel's stair, up into the tack room"],
	["hs_castle", Vector3(-40.2, -1.55, 0.0), 90.0, 2.0, -0.1, "the steps out of the moat"],
	["hs_camp", Vector3(-34.0, 0.05, -24.4), 0.0, 1.5, 1.1, "a cabin's steps, up to its door"],
	["hs_camp", Vector3(-39.0, 0.05, 24.6), 0.0, 2.0, 1.4, "the lookout tower's first flight"],
	["hs_camp", Vector3(-37.0, 10.55, 20.6), 180.0, 2.5, 11.9, "and its fourth, up through the lookout's floor"],
	["hs_camp", Vector3(5.0, 0.05, -10.4), 0.0, 3.5, 3.9, "the treehouse stair"],
	["hs_camp", Vector3(18.6, 0.05, -39.2), 90.0, 4.0, 3.9, "the stair up to the far platform"],
	["hs_camp", Vector3(22.2, -1.15, 1.0), 90.0, 2.0, -0.1, "the steps out of the lake"],
	["hs_museum", Vector3(-7.0, 0.05, 18.6), 0.0, 4.0, 4.9, "the west grand stair, up to the gallery"],
	["hs_museum", Vector3(7.0, 0.05, 18.6), 0.0, 4.0, 4.9, "and the east one"],
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

	if OS.has_environment("HS_CLIMB_SEARCH"):
		await _search(StringName(OS.get_environment("HS_CLIMB_SEARCH")))
		get_tree().quit(0)
		return

	# Needs no map directory: a garden built here out of the catalogue's own props.
	await _test_props()

	# `-- --props` runs the garden alone, for tuning a prop's pieces without the maps' minute.
	var linked := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://maps")) \
		and not "--props" in OS.get_cmdline_user_args()

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
		await _test_door_corners()

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


## Trees and furniture collide as their shapes (dot-props' DotPropPieces, `props/pieces.json`),
## not as one box: Christian's first play test circled the trees wanting their branches and met
## the canopy's box at arm's length. Each prop stands alone in a garden built here.
const GARDEN := [
	# prop id, where it stands
	[&"nature_tree_default", Vector3(0.0, 0.0, 0.0)],
	[&"furniture_table", Vector3(0.0, 0.0, 20.0)],
	[&"nature_climbtree_oak", Vector3(-25.0, 0.0, 0.0)],
	[&"nature_climbtree_fork", Vector3(-25.0, 0.0, -25.0)],
]

## The climbing trees (`tools/climb_trees.py`), where a run at one jumps onto a limb: the prop's
## position, the game's yaw it runs along, how near its middle it jumps, whether it tucks its
## legs (crouch-jumps), how high the feet must end, and what that is. Found by `_search`
## (`HS_CLIMB_SEARCH=nature_climbtree_oak`, `HS_CLIMB_NOTUCK=1` for plain jumps).
const TREE_CLIMBS := [
	[Vector3(-25.0, 0.0, 0.0), 0.0, 2.2, false, 1.15, "a plain jump lands on the climbing oak's first limb, 1.2 m up"],
	[Vector3(-25.0, 0.0, 0.0), 120.0, 1.6, true, 1.8, "a crouch-jump lands on its second limb, 1.75 m up"],
	[Vector3(-25.0, 0.0, -25.0), 20.0, 2.8, true, 1.55, "a crouch-jump lands in the forked tree's crotch, 1.6 m up"],
]


func _test_props() -> void:
	_section("trees and furniture collide as their shapes, not as one box")
	_expected_checks += 6 + TREE_CLIMBS.size()
	var game := await _world("hs_practice")
	var props: Array = []
	for item: Array in GARDEN:
		props.append({"id": String(item[0]), "at": [item[1].x, item[1].y, item[1].z]})
	var doc := {
		"format": 1, "kind": "hideseek_map", "id": "hs_garden", "name": "Garden",
		"boxes": [{"at": [0.0, -0.1, 0.0], "size": [80.0, 0.2, 80.0], "mat": "grass"}],
		"props": props,
		"spawns": {"hiders": [{"at": [0.0, 0.05, 30.0]}], "seekers": [{"at": [5.0, 0.05, 30.0]}]},
	}
	var valid := HsMapDoc.validate(doc)
	var built: DotResult = game.build_map(valid.value) if valid.ok else valid
	_check(built.ok and not game.props_catalogue.pieces_of(&"nature_tree_default").is_empty(),
		"the garden builds, and a tree has pieces to collide as", str(built.error.message if not built.ok else ""))
	var body := game.add_player(&"u1", "Climber")
	await _physics_frame()

	# Walking at the trunk under the canopy: a box the canopy's width stopped a person 1.7 m out.
	body.place_at(Vector3(0.0, 0.05, 4.0), 0.0)
	# The motor slides a walker round the trunk and on, so the nearest it came is the answer.
	var gap := INF
	for _i in range(TICK_RATE * 2):
		_drive(body, 0.0, false)
		await _step(game)
		gap = minf(gap, Vector2(body.controller.state.position.x, body.controller.state.position.z).length())
	_check(gap < 1.2, "a person walks in under a tree's leaves, up to its trunk (its box stopped them 1.9 m out)",
		"%.2f m from the trunk's middle" % gap)

	# The commonest tree on the maps has stubby branches either side of its trunk, 1.1 m and
	# 1.5 m up. Run at one, jump (tucking the legs up), and stand on it. Found by `_search`.
	var low := await _jump_onto(game, body, Vector3(0.0, 0.05, 5.0), 0.0, Vector3.ZERO, 2.2)
	_check(low.y > 0.9 and body.controller.state.mode == DotFpsState.Mode.GROUND,
		"a jump lands on a tree's low branch, and the player stands on it", "feet at %.2f" % low.y)
	var high := await _jump_onto(game, body, Vector3(4.92, 0.05, 0.87), 80.0, Vector3.ZERO, 3.4)
	_check(high.y > 1.4 and body.controller.state.mode == DotFpsState.Mode.GROUND,
		"a crouch-jump lands on its branch 1.5 m up", "feet at %.2f" % high.y)
	var stood := high.y
	for _i in range(TICK_RATE * 2):
		body.controller.apply_command(DotFpsCommand.new())
		await _step(game)
	_check(body.controller.state.position.y > stood - 0.1 and stood > 1.4,
		"and stays up there standing still for two seconds", "feet at %.2f" % body.controller.state.position.y)

	# Trees made to be climbed: limbs with flat tops at a jump's and a crouch-jump's height, and
	# nothing over them, so a person stands up there and stays.
	for climb: Array in TREE_CLIMBS:
		var centre: Vector3 = climb[0]
		var yaw: float = climb[1]
		var back := -Vector3(-sin(deg_to_rad(yaw)), 0.0, -cos(deg_to_rad(yaw))) * 5.0
		var feet := await _jump_onto(game, body, centre + Vector3(back.x, 0.05, back.z), yaw, centre, climb[2], climb[3])
		var landed := feet.y
		for _i in range(TICK_RATE * 2):
			body.controller.apply_command(DotFpsCommand.new())
			await _step(game)
		_check(landed > float(climb[4]) and body.controller.state.position.y > landed - 0.1
			and body.controller.state.mode == DotFpsState.Mode.GROUND and body.controller.state.crouch_fraction < 0.05,
			"%s, and stands up there two seconds" % climb[5], "feet at %.2f, then %.2f, crouch %.2f" % [landed, body.controller.state.position.y, body.controller.state.crouch_fraction])

	# A table is a top and four legs: a seeker's eye sees through under it, and a box would not.
	var space: PhysicsDirectSpaceState3D = game.get_world_3d().direct_space_state
	var under := PhysicsRayQueryParameters3D.create(Vector3(0.0, 0.35, 23.0), Vector3(0.0, 0.35, 17.0))
	var over := PhysicsRayQueryParameters3D.create(Vector3(0.0, 0.7, 23.0), Vector3(0.0, 0.7, 17.0))
	_check(space.intersect_ray(under).is_empty() and not space.intersect_ray(over).is_empty(),
		"a table is a top on legs: a line under it is clear, a line through its top is not")

	await _dispose(game)
	_finished()


## `HS_CLIMB_SEARCH=<prop id>`: runs at the prop from every 20 degrees, jumping at four
## distances, and prints every approach that ends with the feet up on it. How the approaches
## in [method _test_props] were found; run it after re-measuring a prop's pieces.
func _search(prop: StringName) -> void:
	var game := await _world("hs_practice")
	var doc := {
		"format": 1, "kind": "hideseek_map", "id": "hs_garden", "name": "Garden",
		"boxes": [{"at": [0.0, -0.1, 0.0], "size": [80.0, 0.2, 80.0], "mat": "grass"}],
		"props": [{"id": String(prop), "at": [0.0, 0.0, 0.0]}],
		"spawns": {"hiders": [{"at": [0.0, 0.05, 30.0]}], "seekers": [{"at": [5.0, 0.05, 30.0]}]},
	}
	var _b: DotResult = game.build_map(HsMapDoc.validate(doc).value)
	var body := game.add_player(&"u1", "Climber")
	await _physics_frame()
	for a in range(0, 360, 20):
		for d in [1.6, 2.2, 2.8, 3.4]:
			var yaw := float(a)
			var back := -Vector3(-sin(deg_to_rad(yaw)), 0.0, -cos(deg_to_rad(yaw))) * 5.0
			var end := await _jump_onto(game, body, Vector3(back.x, 0.05, back.z), yaw, Vector3.ZERO, d, not OS.has_environment("HS_CLIMB_NOTUCK"))
			if end.y > 0.5:
				print("yaw %d jump %.1f -> feet %s mode %d" % [a, d, end.snapped(Vector3.ONE * 0.01), body.controller.state.mode])
	print("searched")


## Somebody hops into the corner between a wall and every swinging door of [constant DOOR_MAP]
## left open, and comes down (`[hns-door-wedge-1]`).
##
## A seeker bot that walked into the 80 degree corner behind the school's open fire door and
## hopped to get unstuck hung 0.6 m up for the rest of the round, falling ever faster and never
## moving: the rest query beside the wall named the wall for a push that the panel stopped, so
## the slide never met the panel and found no way down. dot-player-controller's
## `surf_physics_selftest` holds the motor's way out; this holds every real door of a map against it.
## Each body stands a little off the corner, walks into it for a second (so it ends up touching
## both faces, as the bot did), then jumps still pushing, and must be standing on the floor
## again within a second and a half.
const DOOR_MAP := "hs_school"


func _test_door_corners() -> void:
	_section("%s: a hop into the corner behind every open door comes down" % DOOR_MAP)
	_expected_checks += 2
	var game := await _world(DOOR_MAP)
	var body := game.add_player(&"u1", "Hopper")
	await _physics_frame()
	var doors := game.map.doors
	var hung: Array[String] = []
	var tried := 0

	for index in range(doors.count()):
		var spec: Dictionary = doors.doors[index]["spec"]
		if str(spec["motion"]) != "swing":
			continue
		doors.apply(index, true, false, -1)
		doors.pose_at(0)
		var size := HsMapDoc.v3(spec["size"])
		var side := 1.0 if str(spec["hinge"]) == "right" else -1.0
		var shut := doors.panel_transform(index, 0.0, 0)
		var open := doors.panel_transform(index, 1.0)
		var floor_y := float((spec["at"] as Array)[1]) - size.y * 0.5
		var hinge := shut * Vector3(side * size.x * 0.5, -size.y * 0.5, 0.0)
		var wall := (shut.basis.x * side).normalized()
		var panel := (open.basis.x * -side).normalized()
		var into := (wall + panel).normalized()
		var start := Vector3(hinge.x, floor_y + 0.05, hinge.z) + into * 1.0
		var facing := -into
		var yaw := rad_to_deg(atan2(-facing.x, -facing.z))
		body.place_at(start, yaw)
		await _step(game)
		var hop := -1
		var landed := false
		for i in range(int(TICK_RATE * 2.5)):
			var command := DotFpsCommand.new()
			command.yaw = yaw
			command.move = Vector2(0.0, 1.0)
			if i == TICK_RATE:
				command.set_button(DotFpsCommand.BUTTON_JUMP, true)
				hop = i
			body.controller.apply_command(command)
			await _step(game)
			if hop >= 0 and i - hop > 4 and body.controller.state.mode == DotFpsState.Mode.GROUND:
				landed = true
				break
		tried += 1
		if not landed:
			hung.append("%s %d at %s" % [str(spec.get("name", "door")), index, body.controller.state.position.snapped(Vector3.ONE * 0.01)])
		doors.apply(index, bool(spec["open"]), false, -1)
		doors.pose_at(0)

	_check(tried >= 10, "every swinging door is tried", "%d" % tried)
	_check(hung.is_empty(), "and the hop into every one comes down to the floor", "; ".join(hung.slice(0, 6)))
	await _dispose(game)
	_finished()


## Runs at [param yaw] from [param start], jumps once within [param jump_at] metres of
## [param centre] (flat), holds crouch in the air, keeps going a moment, and returns where the
## feet ended.
func _jump_onto(game: HsGame, body: HsPlayer, start: Vector3, yaw: float, centre: Vector3, jump_at: float, tuck: bool = true) -> Vector3:
	body.place_at(start, yaw)
	await _step(game)
	var jumped := -1
	for i in range(TICK_RATE * 3):
		var at := body.controller.state.position
		var command := DotFpsCommand.new()
		command.yaw = yaw
		command.move = Vector2(0.0, 1.0) if jumped < 0 or i - jumped < TICK_RATE / 2 else Vector2.ZERO
		if jumped < 0 and Vector2(centre.x - at.x, centre.z - at.z).length() <= jump_at:
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)
			jumped = i
		command.set_button(DotFpsCommand.BUTTON_CROUCH, tuck and jumped >= 0 and i - jumped > 4 and i - jumped < TICK_RATE / 2)
		body.controller.apply_command(command)
		await _step(game)
	return body.controller.state.position


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

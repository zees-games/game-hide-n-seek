extends Node

const HsConfig := preload("../game/hs_config.gd")
const HsGame := preload("../game/hs_game.gd")
const HsMapDoc := preload("../game/hs_map_doc.gd")

## Every map the game can be sent, built the way a server builds it and looked over for the
## mistakes a map document makes without any error: a spawn inside a wall or over nothing, a
## prop the catalogue does not have (built as nothing), a prop sunk into a wall or floating
## over the floor, too little to hide behind, a door that opens into a wall or a wardrobe,
## and a doorway something stands in, and a document too big to send.
##
## [b]Why this exists apart from `headless_run`.[/b] The maps are generated in
## hide-n-seek-maps by `tools/build_maps.py`, a few hundred boxes and props each, and none of
## those mistakes stops a round: a prop floating a hand's width over a table is a prop every
## seeker looks at first, and a spawn inside a locker is a player stuck for the round. The
## renders find the ugly ones; this finds the rest, on every map, every time.
##
## Sections and checks are both counted; mg-smash-copter's notes say why the second matters.
## Adding a map adds a section and CHECKS_PER_MAP checks.

const MAPS := ["hs_practice", "hs_apartments", "hs_warehouse", "hs_manor", "hs_village", "hs_park", "hs_school", "hs_mall", "hs_ship", "hs_castle", "hs_camp", "hs_museum", "hs_restaurant", "hs_apartment", "hs_frontyard"]
const CHECKS_PER_MAP := 14

## A drawn, non-solid box thicker than this is not floor paint, water or a decal.
const PAINT_THICKNESS := 0.3

## The maps actually checked: all of MAPS, or only the practice house where `maps/` is not
## linked in (CI, which clones this repository alone). As mg-deathrun's headless_courses
## does: the delivered maps are checked wherever they are present, which is every machine
## that has run dot-bootstrap. Sections and checks are counted against this list.
var _maps: Array = []

## A person's capsule, for "is this spawn clear".
const RADIUS := 0.4
const HEIGHT := 1.8

## Fewest spawns of each kind a map may have: one per player up to these, laps after.
const MIN_HIDER_SPAWNS := 6
const MIN_SEEKER_SPAWNS := 3

## Fewest props a map must have that a crouching person fits behind: at least this tall and
## this wide. A map with fewer is a map where the only hiding place is a corner.
const MIN_COVER := 12
const COVER_HEIGHT := 0.8
const COVER_WIDTH := 0.6

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("hideseek maps")
	print("")

	await _test_the_catalogue()

	for id: String in _maps:
		await _test_map(StringName(id))

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	var sections := 1 + _maps.size()
	var checks := 1 + CHECKS_PER_MAP * _maps.size()

	if _sections_entered != _sections_finished or _sections_entered != sections:
		print("ERROR: %d of %d sections finished, %d expected." % [_sections_finished, _sections_entered, sections])
		code = 1

	if _passed + _failed != checks or _maps.is_empty():
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, checks])
		code = 1

	get_tree().quit(code)


func _test_the_catalogue() -> void:
	_section("the catalogue")
	var game := await _world(&"")
	var ids: Array = []

	for id: StringName in game.catalogue.maps:
		ids.append(String(id))

	ids.sort()
	var linked := DirAccess.dir_exists_absolute(ProjectSettings.globalize_path("res://maps"))
	_maps = MAPS.duplicate() if linked else ["hs_practice"]

	if not linked:
		print("(no map directory: the built-in practice house only)")

	var missing: Array = []

	for id: String in _maps:
		if not ids.has(id):
			missing.append(id)

	_check(missing.is_empty() and game.catalogue.refused.is_empty(),
		"every map is in it, and no file was refused", "have %s, missing %s, refused %s" % [ids, missing, game.catalogue.refused])
	await _dispose(game)
	_finished()


func _test_map(id: StringName) -> void:
	_section(String(id))
	var game := await _world(id)
	var doc := game.map_doc
	_check(str(doc.get("id", "")) == String(id), "it is the map that was built", str(doc.get("id", "")))

	var bytes := HsMapDoc.encode(doc).size()
	_check(bytes > 0 and bytes < HsMapDoc.WIRE_LIMIT, "it fits on the wire", "%d of %d bytes" % [bytes, HsMapDoc.WIRE_LIMIT])

	var missing: PackedStringArray = game.map.get("_missing")
	_check(missing.is_empty() and game.map.props.size() == (doc["props"] as Array).size(),
		"every prop in it is one the catalogue has", ", ".join(missing))

	await _audit_colliderless(id, doc)

	var cover := 0

	for prop: Dictionary in game.map.props:
		var size: Vector3 = prop["size"]
		if size.y >= COVER_HEIGHT and maxf(size.x, size.z) >= COVER_WIDTH:
			cover += 1

	_check(cover >= MIN_COVER, "it has enough to hide behind", "%d props a crouching person fits behind" % cover)

	var spawns: Dictionary = doc.get("spawns", {})
	var hiders_n := (spawns.get("hiders", []) as Array).size()
	var seekers_n := (spawns.get("seekers", []) as Array).size()
	_check(hiders_n >= MIN_HIDER_SPAWNS and seekers_n >= MIN_SEEKER_SPAWNS, "it has enough spawns",
		"%d hiders, %d seekers" % [hiders_n, seekers_n])

	var bad_spawns: Array = []

	for side: String in ["hiders", "seekers"]:
		for seat in range((spawns.get(side, []) as Array).size()):
			var at: Vector3 = game.map.spawn(side, seat)[0]
			var why := _spawn_fault(game, at)
			if why != "":
				bad_spawns.append("%s %d at %s: %s" % [side, seat, at, why])

	_check(bad_spawns.is_empty(), "every spawn stands on a floor with room for a person", "; ".join(bad_spawns))

	var buried: Array = []
	var floating: Array = []

	for index in range(game.map.props.size()):
		var prop: Dictionary = game.map.props[index]
		var frame: Transform3D = prop["transform"]
		var size: Vector3 = prop["size"]
		var centre := frame * Vector3(0.0, size.y * 0.5, 0.0)

		if _inside_world(game, centre):
			buried.append("%s at %s" % [prop["id"], frame.origin])

		# Hung from a ceiling, or floating on water (which is not solid), by design.
		var hangs := String(prop["id"]).contains("ceiling") or String(prop["id"]).contains("lily")

		if not hangs and not _rests_on_something(game, frame, size):
			floating.append("%s at %s" % [prop["id"], frame.origin])

	_check(buried.is_empty(), "no prop is sunk into a wall or a floor", "; ".join(buried.slice(0, 6)))
	_check(floating.is_empty(), "every prop stands on something", "%d: %s" % [floating.size(), "; ".join(floating.slice(0, 6))])

	var doors := game.map.doors
	var swung_into: Array = []
	var blocked: Array = []

	for index in range(doors.count()):
		var spec: Dictionary = doors.doors[index]["spec"]
		var ways := [0, 1] if str(spec["motion"]) == "swing" and bool(spec["away"]) else [0]

		if str(spec["motion"]) == "swing":
			for flip: int in ways:
				for f in [0.5, 1.0]:
					var hit := _door_hits(game, index, f, flip)
					if hit != "":
						swung_into.append("%s at %s%s, %d%% open: %s" % [doors.name_of(index), HsMapDoc.v3(spec["at"]),
							" the other way" if flip == 1 else "", int(f * 100.0), hit])

		var through := _doorway_fault(game, index)
		if through != "":
			blocked.append("%s at %s: %s" % [doors.name_of(index), HsMapDoc.v3(spec["at"]), through])

		doors.apply(index, bool(spec["open"]), false, -1)
		doors.pose_at(0)

	# The toys (dot-props'): all built, none standing in a wall, a prop or another toy, and two
	# seconds of physics later every loose one still where the map put it, not through a floor
	# or flung off by an overlap the solver pushed apart.
	var box := game.map.toys
	var placed := (doc.get("toys", []) as Array).size()
	var stuck: Array = []
	var own: Array[RID] = []
	for toy in box.toys:
		for part: CollisionObject3D in [toy.fixed, toy.body]:
			if part != null:
				own.append(part.get_rid())
	for toy in box.toys:
		var hit := _toy_hits(game, toy, own)
		if hit != "":
			stuck.append("%s %d at %s: %s" % [toy.def["id"], toy.index, toy.global_position.snapped(Vector3.ONE * 0.1), hit])
	_check(box.count() == placed and box.missing.is_empty() and stuck.is_empty(),
		"every toy is one dot-props has, and stands clear", "%d of %d built%s; %s" % [box.count(), placed,
			" (missing %s)" % ", ".join(box.missing) if not box.missing.is_empty() else "", "; ".join(stuck.slice(0, 6))])
	for _i in range(120):
		await get_tree().physics_frame
	var strayed: Array = []
	for toy in box.toys:
		if toy.body != null and toy.body.global_position.distance_to(toy.rest.origin) > 0.6:
			strayed.append("%s %d: %s to %s" % [toy.def["id"], toy.index, toy.rest.origin.snapped(Vector3.ONE * 0.1), toy.body.global_position.snapped(Vector3.ONE * 0.1)])
	_check(strayed.is_empty(), "two seconds on, every toy is still where the map put it", "; ".join(strayed.slice(0, 6)))

	_check(swung_into.is_empty(), "every door swings into free space", "%d doors; %s" % [doors.count(), "; ".join(swung_into.slice(0, 6))])
	_check(blocked.is_empty(), "every doorway is clear to walk through once its door is open", "; ".join(blocked.slice(0, 6)))
	await _dispose(game)
	_finished()


## What a toy's own shapes, lifted five centimetres off the floor it stands on, are inside of
## the map's walls and furniture, or "". Every toy's colliders are left out: a see-saw's plank
## lies on its own base.
func _toy_hits(game: HsGame, toy: DotPropToy, own: Array[RID]) -> String:
	var space := game.get_world_3d().direct_space_state
	for part: CollisionObject3D in [toy.fixed, toy.body]:
		if part == null:
			continue
		for child in part.get_children():
			var shape := child as CollisionShape3D
			if shape == null or shape.shape == null:
				continue
			var query := PhysicsShapeQueryParameters3D.new()
			query.shape = shape.shape
			query.transform = shape.global_transform.translated(Vector3(0, 0.05, 0))
			query.collision_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")
			query.exclude = own
			var hits := space.intersect_shape(query, 1)
			if not hits.is_empty():
				var other: Object = hits[0].get("collider")
				return str(other.name) if other is Node else "something"
	return ""


## What door [param index]'s panel, [param f] of the way open and swung the map's way or (with
## [param flip]) the other, is inside, or "". Its outer four fifths at a sliver's thickness: the
## edge at the hinge sits in the jamb by design.
func _door_hits(game: HsGame, index: int, f: float, flip: int) -> String:
	var doors := game.map.doors
	var spec: Dictionary = doors.doors[index]["spec"]
	var size := HsMapDoc.v3(spec["size"])
	var side := 1.0 if str(spec["hinge"]) == "right" else -1.0
	var frame := doors.panel_transform(index, f, flip)
	var box := BoxShape3D.new()
	box.size = Vector3(size.x * 0.8, size.y - 0.1, 0.02)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = box
	query.collision_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")
	query.transform = frame * Transform3D(Basis.IDENTITY, Vector3(-side * size.x * 0.1, 0.0, 0.0))
	query.exclude = [(doors.doors[index]["body"] as CollisionObject3D).get_rid()]
	var what: Array = []

	for hit: Dictionary in game.get_world_3d().direct_space_state.intersect_shape(query, 4):
		var prop := game.map.prop_from_hit(hit["collider"], int(hit["shape"]))
		var collider: Object = hit["collider"]
		what.append(String(game.map.prop_id(prop)) if prop >= 0 \
			else "another door" if collider is Node and (collider as Node).get_parent() == doors else "a wall")

	return ", ".join(what)


## Whether somebody can walk through door [param index]'s doorway with it open: a ray straight
## through the middle of the hole, at a knee's height and a head's, finds nothing.
func _doorway_fault(game: HsGame, index: int) -> String:
	var doors := game.map.doors
	var spec: Dictionary = doors.doors[index]["spec"]
	doors.apply(index, true, false, -1)
	doors.pose_at(0)
	var shut := doors.panel_transform(index, 0.0, 0)
	var size := HsMapDoc.v3(spec["size"])
	var space := game.get_world_3d().direct_space_state
	var mask := game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")

	for height in [0.5, minf(1.6, size.y - 0.3)]:
		var middle := shut * Vector3(0.0, -size.y * 0.5 + height, 0.0)
		var across := shut.basis * Vector3(0.0, 0.0, 0.5)
		var ray := PhysicsRayQueryParameters3D.create(middle - across, middle + across, mask)
		var hit := space.intersect_ray(ray)

		if not hit.is_empty():
			var prop := game.map.prop_from_hit(hit["collider"], int(hit["shape"]))
			return "at %.1f m, %s" % [height, String(game.map.prop_id(prop)) if prop >= 0 else "something solid"]

	return ""


## Why a person could not stand at [param at], or "" when they can.
func _spawn_fault(game: HsGame, at: Vector3) -> String:
	var space := game.get_world_3d().direct_space_state
	var mask := game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")

	var down := PhysicsRayQueryParameters3D.create(at + Vector3(0.0, 0.5, 0.0), at + Vector3(0.0, -0.6, 0.0), mask)
	if space.intersect_ray(down).is_empty():
		return "nothing under it"

	var capsule := CapsuleShape3D.new()
	capsule.radius = RADIUS
	capsule.height = HEIGHT
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = capsule
	query.collision_mask = mask
	query.transform = Transform3D(Basis.IDENTITY, at + Vector3(0.0, HEIGHT * 0.5 + 0.08, 0.0))

	var hits := space.intersect_shape(query, 4)

	if not hits.is_empty():
		var what: Array = []
		for hit: Dictionary in hits:
			var index := game.map.prop_from_hit(hit["collider"], int(hit["shape"]))
			what.append(String(game.map.prop_id(index)) if index >= 0 else "a wall")
		return "in the way: %s" % ", ".join(what)

	return ""


func _inside_world(game: HsGame, point: Vector3) -> bool:
	var query := PhysicsPointQueryParameters3D.new()
	query.position = point
	query.collision_mask = game.physics.layer_mask(&"world")
	return not game.get_world_3d().direct_space_state.intersect_point(query, 1).is_empty()


## A ray down from just inside the prop's base finds a floor, a table or another prop within
## a few centimetres. A tilted prop is tested from its lowest corner's height.
func _rests_on_something(game: HsGame, frame: Transform3D, size: Vector3) -> bool:
	var space := game.get_world_3d().direct_space_state
	var mask := game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")
	var base := frame.origin

	for x in [-0.3, 0.0, 0.3]:
		for z in [-0.3, 0.0, 0.3]:
			var from := frame * Vector3(size.x * x, 0.04, size.z * z)
			var query := PhysicsRayQueryParameters3D.create(from, Vector3(from.x, base.y - 0.12, from.z), mask)
			query.hit_from_inside = false
			if not space.intersect_ray(query).is_empty():
				return true

	return false


func _world(id: StringName, drawn := false) -> HsGame:
	var config := HsConfig.new()
	config.warmup_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	config.map_ids = PackedStringArray([String(id)]) if id != &"" else PackedStringArray()

	var game := HsGame.new()
	game.name = "World_%s" % String(id)
	game.config = config
	game.tick_rate = 60
	game.authoritative = true
	game.draw_world = drawn
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	return game


## dot-core's [DotCollisionAudit] over the map as a client draws it: visible geometry with no
## shape near it, which a player walks through. Fails on any finding. The audit is the lenient
## one (a shape anywhere under the map that the mesh touches covers it), because the map keeps
## its drawing in `Drawn` and its shapes in `Solid`. The exact half is in the document: a
## visible box that is not solid is drawn and walked through by definition, and the map opts
## those batches out, so this also holds that to paint: a non-solid box thicker than
## PAINT_THICKNESS must sit inside a solid one (embers in a hearth), never be a wall or a crate.
func _audit_colliderless(id: StringName, doc: Dictionary) -> void:
	var drawn := await _world(id, true)
	var res := DotCollisionAudit.audit(drawn.map, true)
	var found := 0
	var ghosts := 0
	var thick: Array[String] = []
	var solids: Array[AABB] = []

	for box: Dictionary in doc["boxes"]:
		if bool(box.get("solid", true)):
			solids.append(AABB(HsMapDoc.v3(box["at"]) - HsMapDoc.v3(box["size"]) * 0.5, HsMapDoc.v3(box["size"])))

	for box: Dictionary in doc["boxes"]:
		if bool(box.get("visible", true)) and not bool(box.get("solid", true)):
			ghosts += 1
			var size := HsMapDoc.v3(box["size"])
			var area := AABB(HsMapDoc.v3(box["at"]) - size * 0.5, size)
			var inside := false

			for solid in solids:
				inside = inside or solid.grow(0.01).encloses(area)

			if size.y > PAINT_THICKNESS and not inside:
				thick.append("%s at %s" % [box["mat"], box["at"]])

	if res.ok:
		var report: DotCollisionAudit = res.value
		found = report.count()
		print("  collision audit: %d meshes with no shape near them of %d, %d visible boxes not solid" % [found, report.examined, ghosts])

		for line in report.describe_lines().slice(1, 12):
			print("  %s" % line)

	_check(res.ok and found == 0 and (res.value as DotCollisionAudit).examined > 0, "nothing drawn is walked through", "" if res.ok else res.error.message)
	_check(thick.is_empty(), "every box that is drawn and not solid is paint", ", ".join(thick))
	await _dispose(drawn)


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

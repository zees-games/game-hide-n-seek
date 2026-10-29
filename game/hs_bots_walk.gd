extends "hs_bots_survey.gd"
## The doors, the corners and the walking helpers of [HsBots] (a middle layer, split off for size); never loaded on its own.


## `[door, points]`: two points round the free edge of the open door panel between [param at] and [param corner] (one this side, one past it),
## or `[-1, empty]` when no panel is in the way (the next stretch of the walk crosses it) or no floor round its edge.
func _door_detour(at: Vector3, corner: Vector3, seeker: bool = false) -> Array:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	var none := [-1, PackedVector3Array()]
	if doors == null or int(doors.call("count")) == 0:
		return none
	var to := Vector2(corner.x - at.x, corner.z - at.z)
	if to.length() < 0.05:
		return none
	var a := Vector2(at.x, at.z)
	var heading := to.normalized()
	var b := a + heading * minf(to.length(), DETOUR_LOOK)
	var clear := HsPlayer.BODY_RADIUS + 0.08
	var tick := int(game.get("_tick"))
	var specs: Array = doors.get("doors")
	for index in range(specs.size()):
		var spec: Dictionary = (specs[index] as Dictionary)["spec"]
		if str(spec["motion"]) != "swing":
			continue
		var c: Array = spec["at"]
		if not _door_on_level(spec, at) or Vector2(float(c[0]) - at.x, float(c[2]) - at.z).length() > 3.5:
			continue
		var f: float = doors.call("fraction", index, tick)
		# Shut or nearly: a doorway, the use key's business.
		if f < 0.1:
			continue
		var ends: PackedVector3Array = doors.call("panel_ends", index, f)
		var h := Vector2(ends[0].x, ends[0].z)
		var e := Vector2(ends[1].x, ends[1].z)
		var length := h.distance_to(e)
		if length < 0.1:
			continue
		var along := (e - h) / length
		var normal := Vector2(-along.y, along.x)
		var side_a := normal.dot(a - h)
		var side_b := normal.dot(b - h)
		# The panel is in the way only when the walk crosses it: the corner on its far side and the
		# crossing on the panel itself, not at its hinge end (that is the doorway, and a body
		# rubbing the frame slides past). Walking alongside it on the corner's own side is not.
		var blocked := false
		if signf(side_a) != signf(normal.dot(Vector2(corner.x, corner.z) - h)) and signf(side_a) != signf(side_b) \
				and absf(side_a - side_b) > 0.001:
			var cross := a + (b - a) * (side_a / (side_a - side_b))
			var on := along.dot(cross - h)
			blocked = on > 0.1 and on < length + clear
		if not blocked:
			continue
		var near := signf(side_a) if side_a != 0.0 else 1.0
		var k := HsPlayer.BODY_RADIUS + 0.35
		var first := e + along * k + normal * near * 0.3
		# Past the tip by more than a body's radius: at 0.15 the line to this point passed 0.3 m from
		# it for a seeker coming back out of the pocket behind the panel, and clipped it (hs_village's
		# door 13, nine seconds against its free edge).
		var second := e + along * (HsPlayer.BODY_RADIUS + 0.12) - normal * near * k
		var out := PackedVector3Array([Vector3(first.x, at.y, first.y), Vector3(second.x, at.y, second.y)])
		# Room past the free edge for a body: a gap narrower than a body (the edge near a wall)
		# is no way round, and a bot tried it for a minute in a flat's corridor.
		var waist := Vector3(0.0, 0.6, 0.0)
		var edge := Vector3(e.x, at.y, e.y) + waist
		if not _los(edge, edge + Vector3(along.x, 0.0, along.y) * (k + HsPlayer.BODY_RADIUS)):
			return [index, PackedVector3Array()]
		# A seeker only: the gap between the free edge and a wall or fence on the detour's side must take a body, or the first waypoint
		# wedges it. A fleeing hider keeps the old behaviour: a door-only result left it wedged against the panel.
		if seeker:
			var pinch := edge + Vector3(-along.y, 0.0, along.x) * near * -1.0 * (HsPlayer.BODY_RADIUS * 2.0 + 0.05)
			if not _los(edge, pinch):
				return [index, PackedVector3Array()]
		if nav.is_ready():
			for i in range(out.size()):
				var floor_at := nav.closest(out[i])
				if Vector2(floor_at.x - out[i].x, floor_at.z - out[i].z).length() > 0.45 or absf(floor_at.y - at.y) > HsPlayer.BODY_STEP + 0.1:
					# No way round (the free edge is against a wall): the door, but no points.
					return [index, PackedVector3Array()]
				out[i] = floor_at
		return [index, out]
	return none


func _door_fraction(index: int) -> float:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	return float(doors.call("fraction", index, int(game.get("_tick")))) if doors != null else 0.0


func _next_corner(state: Dictionary, at: Vector3) -> Vector3:
	var path: PackedVector3Array = state["path"]
	var corner: int = state["corner"]
	# Passed when near it flat and on its level: on a switchback stair the next flight's corner is over the bot's head. A sharp turn
	# (a doorway entered from along its wall) is passed only close to, or a bot cut the corner into the jamb.
	while corner < path.size() - 1 and Vector2(path[corner].x - at.x, path[corner].z - at.z).length() < _pass_within(path, corner) \
			and absf(path[corner].y - at.y) < 0.9:
		# Not until the way to the next one is open to a body: passed early, a bot turning round
		# the end of a gallery's rail walked into the rail's end post and stood there thirteen
		# seconds (`headless_bots` round 7, the manor's landing).
		if Vector2(path[corner].x - at.x, path[corner].z - at.z).length() > CORNER_CLOSE and not _body_clear(at, path[corner + 1]):
			break
		corner += 1
	state["corner"] = corner
	return path[mini(corner, path.size() - 1)] if not path.is_empty() else at


## Whether a body walking straight from [param at] to [param to] on one level meets no wall or furniture at a rail's bar height (three lines).
## Not the doors: an open panel is `_door_detour`'s, and counted here a corner beside one was never passed.
func _body_clear(at: Vector3, to: Vector3) -> bool:
	if absf(to.y - at.y) > HsPlayer.BODY_STEP:
		return true
	var flat := Vector3(to.x - at.x, 0.0, to.z - at.z)
	if flat.length() < 0.05:
		return true
	var world := (game as Node3D).get_world_3d()
	if world == null:
		return true
	var space := world.direct_space_state
	var physics: DotPhysicsLayout = game.get("physics")
	var mask := physics.layer_mask(&"world") | physics.layer_mask(&"prop") if physics != null else 1
	var side := flat.normalized().cross(Vector3.UP) * HsPlayer.BODY_RADIUS
	for height in [0.47, 0.97]:
		var up := Vector3(0.0, height, 0.0)
		for off in [Vector3.ZERO, side, -side]:
			var query := PhysicsRayQueryParameters3D.create(at + up + off, Vector3(to.x, at.y, to.z) + up + off, mask, _door_rids())
			if not space.intersect_ray(query).is_empty():
				return false
	return true


## How near a bot must come to corner [param i] of [param path] to count it passed: half a
## metre where the path runs on nearly straight, less where it turns sharply.
static func _pass_within(path: PackedVector3Array, i: int) -> float:
	if i <= 0 or i >= path.size() - 1:
		return 0.5
	var into := Vector2(path[i].x - path[i - 1].x, path[i].z - path[i - 1].z)
	var out := Vector2(path[i + 1].x - path[i].x, path[i + 1].z - path[i].z)
	if into.length() < 0.01 or out.length() < 0.01:
		return 0.5
	return 0.5 if absf(into.angle_to(out)) < deg_to_rad(45.0) else 0.3


## Moves along [param world_dir] (flat) whatever way the view is turned.
static func _walk(command: DotFpsCommand, world_dir: Vector3) -> void:
	var flat := Vector3(world_dir.x, 0.0, world_dir.z)
	if flat.length() < 0.01:
		command.move = Vector2.ZERO
		return
	flat = flat.normalized()
	var yaw := deg_to_rad(command.yaw)
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	command.move = Vector2(flat.dot(right), flat.dot(forward)).limit_length(1.0)


## Steps round anybody within a metre: people pass through people here, and a bot that walks
## through somebody walks through their camera.
func _step_round_people(player: HsPlayer, command: DotFpsCommand, players: Dictionary) -> void:
	if command.move.length() < 0.1:
		return
	var at := player.controller.state.position
	var yaw := deg_to_rad(command.yaw)
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var push := Vector3.ZERO
	for id: StringName in players:
		var other: HsPlayer = players[id]
		if other == player or not other.is_alive() or other.watching:
			continue
		var off := at - other.controller.state.position
		off.y = 0.0
		var d := off.length()
		if d < 1.1 and d > 0.001 and absf(at.y - other.controller.state.position.y) < 1.5:
			push += off / d * (1.1 - d)
	if push == Vector3.ZERO:
		return
	var world := forward * command.move.y + right * command.move.x
	# Aside, never back: two bots meeting in a doorway pushed each other back out of it, each
	# pressing in again, and a seeker stood in a park cabin's doorway for sixteen seconds
	# (`headless_bots` round 28). People pass through people, so going on through is allowed.
	var heading := world.normalized()
	var against := push.dot(heading)
	if against < 0.0:
		push -= heading * against
	world += push * 2.0
	command.move = Vector2(world.dot(right), world.dot(forward)).limit_length(1.0)


## Opens a shut door it is walking into, and leaves open ones alone. Released between presses,
## so the game sees an edge.
func _wants_door(player: HsPlayer, command: DotFpsCommand) -> bool:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	if doors == null or int(doors.call("count")) == 0 or command.move.length() < 0.1 or player.wants_use:
		return false
	var yaw := deg_to_rad(command.yaw)
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var going := (forward * command.move.y + right * command.move.x).normalized()
	var index: int = doors.call("door_for", player.eye_position(), going, 1.6)
	return index >= 0 and not bool(doors.call("is_open", index)) and not bool(doors.call("moving", index, int(game.get("_tick"))))


## Which way to step aside when caught on something ahead: towards a wall within a body's width when there is one on one side only,
## else by chance. A stair along a wall is climbed against the wall; the path runs down the middle of the mesh.
func _sidestep_side(at: Vector3, ahead: Vector3, stream: DotRandomStream) -> float:
	if ahead.length() > 0.01:
		var waist := at + Vector3(0.0, 0.6, 0.0)
		var heading := ahead.normalized()
		var left := not _los(waist, waist + heading.rotated(Vector3.UP, deg_to_rad(110.0)) * 0.9)
		var right := not _los(waist, waist + heading.rotated(Vector3.UP, deg_to_rad(-110.0)) * 0.9)
		if left != right:
			return 1.0 if left else -1.0
	return 1.0 if stream.next_unit() < 0.5 else -1.0


## Stuck within a metre of an open doorway the walk goes through: two points, square to its middle on this side and past it on the far side.
## The path is baked at exactly a body's radius from the frame, so a bot a little off caught the jamb. Only once stuck:
## steering every path through every doorway's middle sent bots round in circles. True when it set one.
func _through_doorway(state: Dictionary, at: Vector3, t: float) -> bool:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	if doors == null or not nav.is_ready():
		return false
	var corner := _next_corner(state, at)
	var tick := int(game.get("_tick"))
	var specs: Array = doors.get("doors")
	for index in range(specs.size()):
		var spec: Dictionary = (specs[index] as Dictionary)["spec"]
		if not _door_on_level(spec, at) or float(doors.call("fraction", index, tick)) < 0.9:
			continue
		var frame: Transform3D = doors.call("panel_transform", index, 0.0)
		var middle := Vector3(frame.origin.x, at.y, frame.origin.z)
		if Vector2(middle.x - at.x, middle.z - at.z).length() > 1.2:
			continue
		var normal := frame.basis.z
		normal.y = 0.0
		if normal.length() < 0.01:
			continue
		normal = normal.normalized()
		var here := normal.dot(at - middle)
		if signf(here) == signf(normal.dot(corner - middle)):
			continue
		var near := signf(here) if here != 0.0 else 1.0
		var out := PackedVector3Array([middle + normal * near * 0.6, middle - normal * near * 0.8])
		for i in range(out.size()):
			var floor_at := nav.closest(out[i])
			if Vector2(floor_at.x - out[i].x, floor_at.z - out[i].z).length() > 0.45 or absf(floor_at.y - at.y) > HsPlayer.BODY_STEP + 0.3:
				return false
			out[i] = floor_at
		state["detour"] = out
		state["detour_until"] = t + 3.0
		state["detour_door"] = -1
		state["sidestep_until"] = -INF
		return true
	return false


## How fast a seeker searches: [constant SEARCH_PACE], or the map's own `seeker_pace` (0 to 1)
## where its furniture and floors hide more than a slow search clears in a round (the converted
## flats and restaurants: a pace of 0.28 found two of four hiders in 240 s).
func _search_pace() -> float:
	var doc: Dictionary = game.get("map_doc") if game != null else {}
	var asked := float(doc.get("seeker_pace", 0.0))
	return clampf(asked, 0.1, 1.0) if asked > 0.0 else SEARCH_PACE


## A door this bot tried to shut and could not, for [constant SHUT_FAILED_FOR]: not tried again from here. Forgotten at every give-up,
## it was planned again at once and the bot stepped back to shut it every three seconds.
func _note_shut_failed(state: Dictionary, index: int) -> void:
	state["shut_failed"] = index
	state["shut_failed_at"] = now()


func _shut_failed(state: Dictionary, index: int) -> bool:
	return int(state.get("shut_failed", -1)) == index and now() - float(state.get("shut_failed_at", -INF)) < SHUT_FAILED_FOR


## Measures, apart from what [method _unstick] does about it, how long a walking bot has been
## within [constant STUCK_LEFT] of one spot without getting there: the suite's number.
## Whether an open (or opening) door's panel is within [param reach] of [param at], flat.
func _open_door_near(at: Vector3, reach: float) -> bool:
	return _open_door_index_near(at, reach) >= 0


## The nearest open (or opening) door whose panel is within [param reach] of [param at], flat;
## -1 for none.
func _open_door_index_near(at: Vector3, reach: float) -> int:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	if doors == null:
		return -1
	var best := -1
	var nearest := reach
	var tick := int(game.get("_tick"))
	for index in range(int(doors.call("count"))):
		var f: float = doors.call("fraction", index, tick)
		if f < 0.1:
			continue
		if not _door_on_level((doors.get("doors") as Array)[index]["spec"], at):
			continue
		var ends: PackedVector3Array = doors.call("panel_ends", index, f)
		var p := Geometry2D.get_closest_point_to_segment(Vector2(at.x, at.z), Vector2(ends[0].x, ends[0].z), Vector2(ends[1].x, ends[1].z))
		var d := p.distance_to(Vector2(at.x, at.z))
		if d < nearest:
			nearest = d
			best = index
	return best


## Whether a door's panel is on the storey of somebody standing at [param at]: its foot within a step of their feet and its head above
## a crouched body's. A flat 2 m / 2.5 m window counted a cabin's door for a hider in the crawl space under its floor.
static func _door_on_level(spec: Dictionary, at: Vector3) -> bool:
	var c: Array = spec["at"]
	var half := float((spec["size"] as Array)[1]) * 0.5
	return float(c[1]) - half - at.y < HsPlayer.BODY_STEP + 0.1 and float(c[1]) + half - at.y > HsPlayer.BODY_CROUCH


## Flee goals within [constant AVOID_RADIUS] of a place the bot lingered at (past
## [constant LINGER_POCKET]) are left out for [constant AVOID_FOR] seconds, so a chased hider that
## keeps picking the same doorway's far side picks somewhere else (`headless_bots`, hs_manor).
func _without_avoided(state: Dictionary, spots: Array, t: float) -> Array:
	var avoid: Array = state.get("avoid", [])
	var anchor: Vector3 = state.get("linger_at", Vector3.INF)
	if anchor != Vector3.INF and t - float(state.get("linger_since", t)) >= LINGER_POCKET:
		avoid.append([anchor, t])
	var kept: Array = []
	for entry in avoid:
		if t - float(entry[1]) < AVOID_FOR:
			kept.append(entry)
	if kept.size() > 8:
		kept = kept.slice(kept.size() - 8)
	state["avoid"] = kept
	if kept.is_empty():
		return spots
	var out: Array = []
	for spot in spots:
		var there: Vector3 = spot["at"]
		var bad := false
		for entry in kept:
			var v: Vector3 = entry[0]
			if Vector2(there.x - v.x, there.z - v.z).length() < AVOID_RADIUS:
				bad = true
				break
		if not bad:
			out.append(spot)
	# Everything avoided: better the old choice than none.
	return out if not out.is_empty() else spots


func _note_lingering(state: Dictionary, at: Vector3, t: float) -> void:
	var anchor: Vector3 = state.get("linger_at", Vector3.INF)
	if anchor == Vector3.INF or Vector2(at.x - anchor.x, at.z - anchor.z).length() > STUCK_LEFT:
		state["linger_at"] = at
		state["linger_since"] = t
		return
	var held := t - float(state["linger_since"])
	if held > longest_stuck and _open_door_near(anchor, 2.0):
		longest_stuck = held
		longest_stuck_at = anchor
		longest_stuck_who = state.get("who", &"")

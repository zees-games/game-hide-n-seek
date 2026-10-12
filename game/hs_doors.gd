extends Node3D

const HsMapDoc := preload("hs_map_doc.gd")
const HsMaterials := preload("hs_materials.gd")

## A map's doors: panels a player opens and shuts with the use key.
##
## [b]A door's pose is a pure function of the tick and of the last time it was used.[/b] The
## same rule mg-deathrun's traps keep: the state of a door is `(open, since)`, the side it is
## going to and the tick it set off on, and where the panel is on any tick follows from those
## two numbers and the document. So the only thing that is ever sent is a use — `DOOR`, a door,
## which way, and the tick — and a client that hears it late still poses the past correctly,
## because the tick is part of the message. Nothing about a door is replicated per tick.
##
## [b]A static body moved through the physics server, not a kinematic one and not an
## animation.[/b] mg-wipeout found that a kinematic body applies a new transform a physics step
## late, and a body that is a step late is a door a player is predicted walking through on one
## end and stopped by on the other. A static body written through `PhysicsServer3D` is where it
## was put on the very next query.
##
## [b]On the world layer[/b], with the walls, so a shut door stops a body, a seeker's view and a
## touch alike: the sight rule and the touch rule ask "is there a wall between", and a shut door
## is one. A door left open is not.
##
## [b]A door never shuts on anybody.[/b] A use is refused while any body stands anywhere the
## panel passes through on its way, because a static panel posed inside a capsule leaves the
## controller to push its way out, and a hider pinned in a door frame by a seeker slamming it
## would be the door deciding a catch.

const CHANNEL := "hs.doors"

## How far, from the eye, a door can be reached.
const REACH := 2.3

## How many poses along its path a door's sweep is tested at.
const SWEEP_SAMPLES := 7

## Handles, on both faces of a door that is not secret.
const HANDLE_SIZE := Vector3(0.12, 0.04, 0.05)
const HANDLE_TINT := Color(0.18, 0.18, 0.2)

var physics: DotPhysicsLayout = null
var draw_world: bool = false
var tick_rate: int = 64

## One per door, in document order: `{spec, body, open, since, ticks, flip}`. `open` is the side
## it is going to or is at; `since` is the tick it set off, or -1 for "at rest where it
## started"; `flip` is whether a swinging door went the other way from the document's angle.
##
## [b]A swinging door opens away from whoever opens it[/b], unless the map says `away: false`.
## One that always swung the same way would be a door nobody standing on that side could open,
## because they would be standing in its way.
var doors: Array[Dictionary] = []


func build(doc: Dictionary) -> void:
	clear()

	for raw: Dictionary in doc.get("doors", []):
		var size := HsMapDoc.v3(raw["size"])
		var body := StaticBody3D.new()
		body.name = "Door%d" % doors.size()
		var shape := CollisionShape3D.new()
		var cube := BoxShape3D.new()
		cube.size = size
		shape.shape = cube
		body.add_child(shape)
		add_child(body)

		if physics != null:
			var _applied := physics.apply_to(body, &"world")

		if draw_world:
			_draw(body, raw, size)

		doors.append({
			"spec": raw, "body": body, "open": bool(raw["open"]), "since": -1, "flip": false,
			"ticks": maxi(1, roundi(float(raw["seconds"]) * float(tick_rate))),
		})

	pose_at(0)


func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

	doors.clear()


func count() -> int:
	return doors.size()


func _draw(body: StaticBody3D, spec: Dictionary, size: Vector3) -> void:
	var panel := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	panel.mesh = mesh
	panel.material_override = HsMaterials.material(str(spec["mat"]), HsMapDoc.colour(spec["tint"]))
	body.add_child(panel)

	if bool(spec["secret"]) or str(spec["motion"]) == "lift":
		return

	# A handle near the free edge, on both faces: what says "this opens" from across a room.
	var free_edge := -1.0 if str(spec["hinge"]) == "right" else 1.0
	var metal := StandardMaterial3D.new()
	metal.albedo_color = HANDLE_TINT
	metal.metallic = 0.6
	metal.roughness = 0.4

	for face in [-1.0, 1.0]:
		var handle := MeshInstance3D.new()
		var knob := BoxMesh.new()
		knob.size = HANDLE_SIZE
		handle.mesh = knob
		handle.material_override = metal
		handle.position = Vector3(
			free_edge * (size.x * 0.5 - 0.14), -size.y * 0.5 + minf(1.0, size.y * 0.45),
			face * (size.z * 0.5 + HANDLE_SIZE.z * 0.5)
		)
		body.add_child(handle)


# --- State ------------------------------------------------------------------

## Every door back to how the map has it. The top of every round.
func reset() -> void:
	for door in doors:
		door["open"] = bool((door["spec"] as Dictionary)["open"])
		door["since"] = -1
		door["flip"] = false


func set_tick_rate(rate: int) -> void:
	tick_rate = maxi(rate, 1)

	for door in doors:
		door["ticks"] = maxi(1, roundi(float((door["spec"] as Dictionary)["seconds"]) * float(tick_rate)))


func is_open(index: int) -> bool:
	return bool(doors[index]["open"])


## How far open door [param index] is on [param tick]: 0 shut, 1 open.
func fraction(index: int, tick: int) -> float:
	var door := doors[index]
	var since := int(door["since"])

	if since < 0:
		return 1.0 if bool(door["open"]) else 0.0

	var progress := clampf(float(tick - since) / float(door["ticks"]), 0.0, 1.0)
	return progress if bool(door["open"]) else 1.0 - progress


## Whether door [param index] is still on its way somewhere on [param tick].
func moving(index: int, tick: int) -> bool:
	var since := int(doors[index]["since"])
	return since >= 0 and tick >= since and tick - since < int(doors[index]["ticks"])


## Sets a door off, towards the other side, on [param tick], opening away from [param user]
## (somebody's eyes). What a use does on the server.
func toggle(index: int, tick: int, user: Vector3) -> bool:
	var open := not is_open(index)
	apply(index, open, flips_for(index, user) if open else is_flipped(index), tick)
	return open


## Sets a door off towards [param open] on [param tick], swinging the document's way or, with
## [param flip], the other. What a client does when it is told.
func apply(index: int, open: bool, flip: bool, tick: int) -> void:
	if index < 0 or index >= doors.size():
		return

	doors[index]["open"] = open
	doors[index]["flip"] = flip
	doors[index]["since"] = tick


func is_flipped(index: int) -> bool:
	return bool(doors[index]["flip"])


## Whether door [param index], opened by somebody at [param user], swings the other way from
## its document: the free edge goes away from them.
func flips_for(index: int, user: Vector3) -> bool:
	var spec: Dictionary = doors[index]["spec"]

	if str(spec["motion"]) != "swing" or not bool(spec["away"]):
		return false

	var shut := Transform3D(Basis(Vector3.UP, deg_to_rad(float(spec["yaw"]))), HsMapDoc.v3(spec["at"]))
	var their_side := signf((shut.affine_inverse() * user).z)
	var side := 1.0 if str(spec["hinge"]) == "right" else -1.0

	# The free edge's local z, opened by `angle`, is side * width * sin(angle): it goes to the
	# side the angle's sign times the hinge's says. Away is the other side from the user.
	var goes := signf(side * float(spec["angle"]))
	return their_side != 0.0 and goes == their_side


# --- Poses ------------------------------------------------------------------

## Where door [param index]'s panel is at [param f] of the way open, as a world transform.
## [param flip] -1 means "as the door is now".
func panel_transform(index: int, f: float, flip: int = -1) -> Transform3D:
	var spec: Dictionary = doors[index]["spec"]
	var size := HsMapDoc.v3(spec["size"])
	var frame := Transform3D(Basis(Vector3.UP, deg_to_rad(float(spec["yaw"]))), HsMapDoc.v3(spec["at"]))
	var side := 1.0 if str(spec["hinge"]) == "right" else -1.0

	match str(spec["motion"]):
		"slide":
			var along := float(spec["travel"]) if float(spec["travel"]) > 0.0 else size.x
			return frame * Transform3D(Basis.IDENTITY, Vector3(side * along * f, 0.0, 0.0))
		"lift":
			var up := float(spec["travel"]) if float(spec["travel"]) > 0.0 else size.y - 0.08
			return frame * Transform3D(Basis.IDENTITY, Vector3(0.0, up * f, 0.0))
		_:
			var hinge := Vector3(side * size.x * 0.5, 0.0, 0.0)
			var flipped := is_flipped(index) if flip < 0 else flip == 1
			var angle := float(spec["angle"]) * (-1.0 if flipped else 1.0)
			var turn := Basis(Vector3.UP, deg_to_rad(angle * f))
			return frame * Transform3D(Basis.IDENTITY, hinge) * Transform3D(turn, Vector3.ZERO) \
				* Transform3D(Basis.IDENTITY, -hinge)


## Door [param index]'s panel at [param f] of the way open as two world points at its middle
## height, `[hinge edge, free edge]`. A bot steps round the free edge of an open panel that
## stands across its way (`HsBots._door_detour`); the hinge edge is against the wall.
func panel_ends(index: int, f: float) -> PackedVector3Array:
	var spec: Dictionary = doors[index]["spec"]
	var half := HsMapDoc.v3(spec["size"]).x * 0.5
	var side := 1.0 if str(spec["hinge"]) == "right" else -1.0
	var frame := panel_transform(index, f)
	return PackedVector3Array([frame * Vector3(side * half, 0.0, 0.0), frame * Vector3(-side * half, 0.0, 0.0)])


## Poses every door for [param tick]. Cheap enough to call every tick: a door at rest is
## written once and skipped after.
func pose_at(tick: int) -> void:
	for index in range(doors.size()):
		var f := fraction(index, tick)
		var door := doors[index]

		if door.has("posed") and is_equal_approx(float(door["posed"]), f):
			continue

		door["posed"] = f
		_place(door["body"], panel_transform(index, f))


static func _place(body: Node3D, at: Transform3D) -> void:
	body.transform = at

	if body is CollisionObject3D and body.is_inside_tree():
		PhysicsServer3D.body_set_state(
			(body as CollisionObject3D).get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM,
			body.global_transform
		)


# --- Asking -----------------------------------------------------------------

## Which door somebody at [param eyes] looking along [param aim] would use: the nearest whose
## panel, where it was last posed, is within reach and in front of them. -1 for none.
##
## [b]Where it was posed, not where the tick says[/b], because a client never ticks the world:
## it poses the doors for its own input tick, and the HUD asking with any other tick would be
## a prompt for a door somewhere it is not.
func door_for(eyes: Vector3, aim: Vector3, reach: float = REACH) -> int:
	var best := -1
	var closest := reach

	for index in range(doors.size()):
		var frame := (doors[index]["body"] as Node3D).transform
		var size := HsMapDoc.v3((doors[index]["spec"] as Dictionary)["size"])
		var local := frame.affine_inverse() * eyes
		var nearest := frame * Vector3(
			clampf(local.x, -size.x * 0.5, size.x * 0.5),
			clampf(local.y, -size.y * 0.5, size.y * 0.5),
			clampf(local.z, -size.z * 0.5, size.z * 0.5)
		)
		var to := nearest - eyes
		var distance := to.length()

		if distance >= closest:
			continue

		# In front: within about sixty degrees of where they look, or close enough to touch.
		if distance > 0.6 and aim.normalized().dot(to / distance) < 0.5:
			continue

		closest = distance
		best = index

	return best


## Whether a standing body whose feet are at [param feet] is anywhere door [param index]'s
## panel passes through between [param from] and [param to] of the way open.
## [param flip] as in [method panel_transform].
func sweeps(index: int, feet: Vector3, radius: float, height: float, from: float, to: float,
		flip: int = -1) -> bool:
	var size := HsMapDoc.v3((doors[index]["spec"] as Dictionary)["size"])

	for step in range(SWEEP_SAMPLES):
		var f := lerpf(from, to, float(step) / float(SWEEP_SAMPLES - 1))
		var frame := panel_transform(index, f, flip)
		var bottom := frame.affine_inverse() * feet
		var top := frame.affine_inverse() * (feet + Vector3(0.0, height, 0.0))

		# The capsule's axis, in the panel's frame, against the panel grown by the radius.
		var low := minf(bottom.y, top.y)
		var high := maxf(bottom.y, top.y)

		if high < -size.y * 0.5 or low > size.y * 0.5:
			continue

		if absf(bottom.x) < size.x * 0.5 + radius and absf(bottom.z) < size.z * 0.5 + radius:
			return true

	return false


func name_of(index: int) -> String:
	var name := str((doors[index]["spec"] as Dictionary)["name"])
	return name if name != "" else "door %d" % index


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray()

	for index in range(doors.size()):
		var door := doors[index]
		lines.append("%-3d %-24s %-5s %s%s" % [
			index, name_of(index), str((door["spec"] as Dictionary)["motion"]),
			"open" if bool(door["open"]) else "shut",
			"" if int(door["since"]) < 0 else "  (since tick %d)" % int(door["since"]),
		])

	return lines

extends Node3D

const HsMapDoc := preload("hs_map_doc.gd")
const HsMaterials := preload("hs_materials.gd")
const HsProps := preload("hs_props.gd")

## A map document, built: the building, the furniture, the lights and the sky.
##
## [b]The same document on every machine, and a server builds only what collides.[/b] Boxes
## become one static body of box shapes on the world layer; props become one static body of
## box shapes on the prop layer, each shape knowing which prop it is. A client also draws them.
## A server draws nothing, so a dedicated server holds a few thousand shapes and no meshes.
##
## [b]Boxes are drawn batched, by material and by twelve-metre chunk.[/b] A school is a
## thousand boxes, and a mesh per box is a thousand draw calls, which a browser does not give
## you. One mesh per material is the other extreme and is wrong for a reason only the renderer
## knows: the compatibility renderer the shell uses lights each mesh with at most eight omni
## lights, so one floor mesh for the whole school would be lit by eight of its forty lamps and
## every other room would be dark. A chunk is about a room, which is about a lamp.
##
## [b]Props are drawn as [MultiMeshInstance3D]s, one per model mesh.[/b] Two hundred chairs are
## one draw call per chair mesh, not two hundred. They never move: they are the room.
##
## [b]A prop's collision is its catalogue box, turned the way the map turns it.[/b] What a
## seeker's sight stops on and what a player walks into or hides behind are the same box, so
## the two can never disagree about where the sofa is.

const CHANNEL := "hs.map"

## Metres of world one batched mesh covers. See the class notes.
const CHUNK := 12.0

## A shot's impact closer than this to a prop's box counts as hitting it: a bullet stops on the
## surface, and a point exactly on a face is outside a strict test half the time.
const HIT_MARGIN := 0.06

signal built()

var physics: DotPhysicsLayout = null

## The catalogue every prop's size and model come from.
var catalogue: HsProps = null

## Whether this machine draws anything: a client does, a server does not.
var draw_world: bool = false

## The normalised document this was built from.
var doc: Dictionary = {}

## Every prop in the map: `{id, transform, size, shape}`. The transform's origin is the middle
## of the prop's footprint on the floor.
var props: Array[Dictionary] = []

var _solid: StaticBody3D = null
var _furniture: StaticBody3D = null
var _drawn: Node3D = null
var _environment: WorldEnvironment = null
var _sun: DirectionalLight3D = null
var _bounds: AABB = AABB()
var _missing: PackedStringArray = PackedStringArray()


func id() -> StringName:
	return StringName(str(doc.get("id", "")))


## Builds [param p_doc], which [HsMapDoc.validate] has already normalised.
func build(p_doc: Dictionary) -> DotResult:
	clear()
	doc = p_doc

	_solid = StaticBody3D.new()
	_solid.name = "Solid"
	add_child(_solid)
	_put_on(_solid, &"world")

	_furniture = StaticBody3D.new()
	_furniture.name = "Furniture"
	add_child(_furniture)
	_put_on(_furniture, &"prop")

	if draw_world:
		_drawn = Node3D.new()
		_drawn.name = "Drawn"
		add_child(_drawn)

	_build_boxes()
	_build_props()

	if draw_world:
		_build_lights()
		_build_environment()

	if not _missing.is_empty():
		DotLog.warn(CHANNEL, "a map names props this server's catalogue does not have; they are left out", {
			"map": String(id()), "missing": ", ".join(_missing),
		})

	DotLog.debug(CHANNEL, "built a map", {
		"id": String(id()), "boxes": (doc["boxes"] as Array).size(), "props": props.size(),
	})
	built.emit()
	return DotResult.success(null)


func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

	props.clear()
	_missing.clear()
	_bounds = AABB()
	_solid = null
	_furniture = null
	_drawn = null
	_environment = null
	_sun = null


func _put_on(body: CollisionObject3D, layer: StringName) -> void:
	if physics == null:
		return

	var applied := physics.apply_to(body, layer)

	if not applied.ok:
		DotLog.warn(CHANNEL, "a map body could not be put on its layer", {"layer": String(layer)})


# --- Building --------------------------------------------------------------

func _build_boxes() -> void:
	var batches := {}
	var any := false

	for box: Dictionary in doc["boxes"]:
		var size := HsMapDoc.v3(box["size"])
		var at := HsMapDoc.v3(box["at"])
		var frame := Transform3D(Basis(Vector3.UP, deg_to_rad(float(box.get("yaw", 0.0)))), at)

		var corner := AABB(at - size * 0.5, size)
		_bounds = corner if not any else _bounds.merge(corner)
		any = true

		if bool(box.get("solid", true)):
			var shape := CollisionShape3D.new()
			var cube := BoxShape3D.new()
			cube.size = size
			shape.shape = cube
			shape.transform = frame
			_solid.add_child(shape)

		if not draw_world or not bool(box.get("visible", true)):
			continue

		var tint := HsMapDoc.colour(box.get("tint", [1, 1, 1]))
		var cell := Vector2i(floori(at.x / CHUNK), floori(at.z / CHUNK))
		var key := "%s|%s|%d|%d" % [str(box["mat"]), tint.to_html(), cell.x, cell.y]

		if not batches.has(key):
			var tool := SurfaceTool.new()
			tool.begin(Mesh.PRIMITIVE_TRIANGLES)
			batches[key] = {"tool": tool, "mat": str(box["mat"]), "tint": tint}

		_add_box((batches[key] as Dictionary)["tool"], frame, size)

	for key: String in batches:
		var batch: Dictionary = batches[key]
		var tool: SurfaceTool = batch["tool"]
		var mesh := MeshInstance3D.new()
		mesh.name = "Boxes"
		mesh.mesh = tool.commit()
		mesh.material_override = HsMaterials.material(batch["mat"], batch["tint"])
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF \
			if HsMaterials.is_transparent(batch["mat"]) else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		_drawn.add_child(mesh)


## Six faces of a box, outward normals, into [param tool]. No UVs: every surface material is
## mapped in world space.
static func _add_box(tool: SurfaceTool, frame: Transform3D, size: Vector3) -> void:
	var h := size * 0.5
	var faces := [
		[Vector3.RIGHT, Vector3(h.x, -h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, -h.y, h.z)],
		[Vector3.LEFT, Vector3(-h.x, -h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, h.y, -h.z), Vector3(-h.x, -h.y, -h.z)],
		[Vector3.UP, Vector3(-h.x, h.y, -h.z), Vector3(-h.x, h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(h.x, h.y, -h.z)],
		[Vector3.DOWN, Vector3(-h.x, -h.y, h.z), Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z), Vector3(h.x, -h.y, h.z)],
		[Vector3.BACK, Vector3(h.x, -h.y, h.z), Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z), Vector3(-h.x, -h.y, h.z)],
		[Vector3.FORWARD, Vector3(-h.x, -h.y, -h.z), Vector3(-h.x, h.y, -h.z), Vector3(h.x, h.y, -h.z), Vector3(h.x, -h.y, -h.z)],
	]

	for face: Array in faces:
		var normal: Vector3 = frame.basis * (face[0] as Vector3)
		var a: Vector3 = frame * (face[1] as Vector3)
		var b: Vector3 = frame * (face[2] as Vector3)
		var c: Vector3 = frame * (face[3] as Vector3)
		var d: Vector3 = frame * (face[4] as Vector3)

		# Godot's front face winds so that (b - a) x (c - a) points AGAINST the normal (measured
		# against BoxMesh's own arrays). The corners above go round the other way, so each
		# triangle is emitted reversed; the other order is a map drawn inside out, every wall
		# invisible from the room it bounds.
		for v: Vector3 in [a, c, b, a, d, c]:
			tool.set_normal(normal)
			tool.add_vertex(v)


func _build_props() -> void:
	var by_id := {}

	for raw: Dictionary in doc["props"]:
		var prop_id := StringName(str(raw["id"]))

		if catalogue == null or not catalogue.has(prop_id):
			if not _missing.has(String(prop_id)):
				_missing.append(String(prop_id))
			continue

		var size := catalogue.size_of(prop_id)
		var basis := Basis.from_euler(Vector3(
			deg_to_rad(float(raw.get("pitch", 0.0))),
			deg_to_rad(float(raw.get("yaw", 0.0))),
			deg_to_rad(float(raw.get("roll", 0.0)))
		), EULER_ORDER_YXZ)
		var frame := Transform3D(basis, HsMapDoc.v3(raw["at"]))

		var shape := CollisionShape3D.new()
		var cube := BoxShape3D.new()
		cube.size = size
		shape.shape = cube
		shape.transform = frame * Transform3D(Basis.IDENTITY, Vector3(0.0, size.y * 0.5, 0.0))
		shape.set_meta(&"hs_prop", props.size())
		_furniture.add_child(shape)

		props.append({"id": prop_id, "transform": frame, "size": size, "shape": shape})

		if draw_world:
			if not by_id.has(prop_id):
				by_id[prop_id] = []
			(by_id[prop_id] as Array).append(frame)

	if not draw_world:
		return

	for prop_id: StringName in by_id:
		var frames: Array = by_id[prop_id]
		var parts := catalogue.parts(prop_id)

		if parts.is_empty():
			for frame: Transform3D in frames:
				var stand_in := catalogue.instance(prop_id)
				stand_in.transform = frame
				_drawn.add_child(stand_in)
			continue

		for part: Array in parts:
			var multi := MultiMesh.new()
			multi.transform_format = MultiMesh.TRANSFORM_3D
			multi.mesh = part[0]
			multi.instance_count = frames.size()

			for i in range(frames.size()):
				multi.set_instance_transform(i, (frames[i] as Transform3D) * (part[1] as Transform3D))

			var drawn := MultiMeshInstance3D.new()
			drawn.name = "Props_%s" % String(prop_id)
			drawn.multimesh = multi
			_drawn.add_child(drawn)


func _build_lights() -> void:
	for light: Dictionary in doc["lights"]:
		var omni := OmniLight3D.new()
		omni.position = HsMapDoc.v3(light["at"])
		omni.omni_range = float(light["range"])
		omni.light_energy = float(light["energy"])
		omni.light_color = HsMapDoc.colour(light["colour"])
		omni.omni_attenuation = 1.2
		omni.shadow_enabled = false
		_drawn.add_child(omni)


func _build_environment() -> void:
	var env_doc: Dictionary = doc["environment"]
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = HsMapDoc.colour(env_doc["sky_top"])
	sky_material.sky_horizon_color = HsMapDoc.colour(env_doc["sky_horizon"])
	sky_material.ground_horizon_color = HsMapDoc.colour(env_doc["sky_horizon"]).darkened(0.2)
	sky_material.ground_bottom_color = HsMapDoc.colour(env_doc["ground"])

	var sky := Sky.new()
	sky.sky_material = sky_material

	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = HsMapDoc.colour(env_doc["ambient"])
	environment.ambient_light_energy = float(env_doc["ambient_energy"])
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC

	if float(env_doc["fog"]) > 0.0:
		environment.fog_enabled = true
		environment.fog_density = float(env_doc["fog"])
		environment.fog_light_color = HsMapDoc.colour(env_doc["sky_horizon"])

	_environment = WorldEnvironment.new()
	_environment.name = "Environment"
	_environment.environment = environment
	add_child(_environment)

	_sun = DirectionalLight3D.new()
	_sun.name = "Sun"
	_sun.rotation_degrees = Vector3(float(env_doc["sun_pitch"]), float(env_doc["sun_yaw"]), 0.0)
	_sun.light_energy = float(env_doc["sun_energy"])
	_sun.light_color = HsMapDoc.colour(env_doc["sun_colour"])
	_sun.shadow_enabled = float(env_doc["sun_energy"]) > 0.05
	_sun.directional_shadow_max_distance = 60.0
	add_child(_sun)


# --- Asking ----------------------------------------------------------------

## Where seat [param seat] of [param of] on [param side] (`"hiders"` or `"seekers"`) starts:
## `[position, yaw]`. More people than spawns stand in rings round them, a metre and a bit
## apart, so nobody starts inside anybody else.
func spawn(side: String, seat: int) -> Array:
	var list: Array = (doc.get("spawns", {}) as Dictionary).get(side, [])

	if list.is_empty():
		return [Vector3(0.0, 1.0, 0.0), 0.0]

	var base: Dictionary = list[seat % list.size()]
	var lap := seat / list.size()
	var at := HsMapDoc.v3(base["at"])

	if lap > 0:
		var angle := float(lap) * 2.39996
		at += Vector3(cos(angle), 0.0, sin(angle)) * (1.1 * ceilf(float(lap) / 6.0))

	return [at, float(base.get("yaw", 0.0))]


func kill_height() -> float:
	return float(doc.get("kill_y", -30.0))


func bounds() -> AABB:
	return _bounds


## Which prop a physics query hit, from the collider and the shape index it reported; -1 for
## anything that is not a prop.
func prop_from_hit(collider: Object, shape_index: int) -> int:
	if collider == null or collider != _furniture:
		return -1

	var owner_id := _furniture.shape_find_owner(shape_index)
	var node := _furniture.shape_owner_get_owner(owner_id) as Node

	if node == null or not node.has_meta(&"hs_prop"):
		return -1

	return int(node.get_meta(&"hs_prop"))


## Which prop [param point] is on, within [constant HIT_MARGIN]. -1 for none.
func prop_containing(point: Vector3) -> int:
	for index in range(props.size()):
		var prop: Dictionary = props[index]
		var size: Vector3 = prop["size"]
		var local: Vector3 = (prop["transform"] as Transform3D).affine_inverse() * point
		var half := size * 0.5 + Vector3.ONE * HIT_MARGIN

		if absf(local.x) <= half.x and local.y >= -HIT_MARGIN and local.y <= size.y + HIT_MARGIN \
				and absf(local.z) <= half.z:
			return index

	return -1


func prop_id(index: int) -> StringName:
	return (props[index] as Dictionary)["id"] if index >= 0 and index < props.size() else &""


## A camera for watching the whole map from above, for somebody with nobody left to watch.
func overview() -> Transform3D:
	var centre := _bounds.get_center()
	var reach := maxf(_bounds.size.length() * 0.45, 12.0)
	var eye := centre + Vector3(reach * 0.5, reach * 0.55, reach * 0.5)
	return Transform3D(Basis.IDENTITY, eye).looking_at(centre, Vector3.UP)


func describe_lines() -> PackedStringArray:
	return PackedStringArray([
		"map        %s (%s)" % [str(doc.get("name", "")), String(id())],
		"boxes      %d" % (doc.get("boxes", []) as Array).size(),
		"props      %d" % props.size(),
		"lights     %d" % (doc.get("lights", []) as Array).size(),
	])

extends Node3D

const HsMapDoc := preload("hs_map_doc.gd")
const HsMaterials := preload("hs_materials.gd")
const HsProps := preload("hs_props.gd")
const HsDoors := preload("hs_doors.gd")
const HsPaths := preload("hs_paths.gd")

## A map document, built: the building, the furniture, the lights and the sky. The same document on every machine; a server builds only what collides (one static body of box shapes for the world, one for props), a client also draws them.
## Boxes are drawn batched by material and by twelve-metre chunk: a mesh per box is a draw call per box, and one mesh per material would be lit by at most eight of the Compatibility renderer's omni lights, leaving other rooms dark. Props are one MultiMesh per model mesh.
## A prop's collision is its catalogue pieces or its box (dot-props' [DotPropPieces]), so sight and walking share the same shapes and a player can crawl under a table.

const CHANNEL := "hs.map"

## dot-lighting's contact shade, loaded by path (API 4): see [method _add_contact_shade].
const CONTACT_SHADE_SCRIPT := "res://addons/dot_lighting/runtime/dot_contact_shade.gd"

## Where a document's converted world pack is: hide-n-seek-maps/world, linked; rebased.
const WORLD_ROOT := "res://world"

## The surface kinds a drawn world's generic faces use, when the game vendors them (dot-map's tools/sync-surfaces.sh); else the addon's.
const SURFACES_ROOT := "res://assets/surfaces"
## Meta on every drawn box batch; by name they were "@Boxes@N" after the first, which a prefix test missed.
const BOX_BATCH := &"hs_box_batch"

## Where a map's baked light is shipped (made by `tools/bake_lightmaps.sh`; dot-map's DotMapBoxBake), and the version of what this game bakes.
const BAKE_PATH := "res://lightmaps/%s.res"
const BAKE_VERSION := 1

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

## Every prop in the map: `{id, transform, size, shapes}`. The transform's origin is the middle
## of the prop's footprint on the floor.
var props: Array[Dictionary] = []

## The doors, which move: their own node, because everything else here never does.
var doors: HsDoors = null

## The tick rate a door's seconds are counted in. Set by the game before it builds.
var tick_rate: int = 64

## The map's toys (dot-props' [DotPropToyBox]): balls, swings, see-saws, switches. Simulated
## where [member authoritative], posed from snapshots elsewhere; under the game's `sv_toys*`
## [member toy_rules]. Set by the game before it builds.
var toys: DotPropToyBox = null
var authoritative: bool = true
var toy_rules: DotPropToyRules = null
var gravity: float = 20.0

## Whether a client draws a document's `world` pack in place of its boxes ([method load_world]).
var use_worlds: bool = true

## The drawn world pack, or null while the boxes are what is seen.
var drawn_world: DotMapDrawnWorld = null

## The drawn world's credit line (its author, and the art whose licence asks for a name); empty without one.
var world_credits: String = ""

## The converted map's displacement ground (the document's `terrain`), or null.
var terrain: DotMapTerrain = null
var _solid: StaticBody3D = null
var _furniture: StaticBody3D = null
var _drawn: Node3D = null
## The boxes the contact shade is built from, gathered by the box and furniture builders.
var _shade_boxes: Array = []
var _environment: WorldEnvironment = null
var _sun: DirectionalLight3D = null
var _bounds: AABB = AABB()
var _missing: PackedStringArray = PackedStringArray()

## Whether a map's baked light is laid over it when the game ships one (the bake tool turns it off to build what it bakes).
static var use_bakes: bool = true

## The LightmapGI laid over this map, or null: its lamps then light it live.
var baked: LightmapGI = null


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
	_build_terrain()
	_build_props()
	_add_contact_shade(_shade_boxes)
	_shade_boxes = []

	doors = HsDoors.new()
	doors.name = "Doors"
	doors.physics = physics
	doors.draw_world = draw_world
	doors.tick_rate = tick_rate
	add_child(doors)
	doors.build(doc)

	_build_toys()

	if draw_world:
		_build_lights()
		_build_environment()
		_attach_bake()

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
	terrain = null
	_solid = null
	_furniture = null
	doors = null
	toys = null
	_drawn = null
	_environment = null
	_sun = null
	baked = null
	drawn_world = null
	world_credits = ""


## Draws the document's converted `world` pack (dot-map's [DotMapDrawnWorld]) in place of the box meshes, on a client. The boxes,
## props, doors and toys still collide and the bots' mesh is baked from them; the pack is only what is seen. A pack that is not
## here, will not read or was made at another scale leaves the boxes drawn. Succeeds with true when the world is drawn.
func load_world() -> DotResult:
	var spec: Dictionary = doc.get("world", {})
	if not draw_world or not use_worlds or spec.is_empty() or _drawn == null:
		return DotResult.success(false)
	var wanted := id()
	var prefix := HsPaths.rebase(WORLD_ROOT).path_join(str(spec["pack"])).path_join(String(wanted))
	if not FileAccess.file_exists(prefix + ".json"):
		return DotResult.success(false)
	var read: DotResult = await DotMapDrawnWorld.read(prefix, DotRegistry.get_service(&"dot_cloud_client"))
	if id() != wanted or _drawn == null:
		return DotResult.success(false)
	if not read.ok:
		DotLog.warn(CHANNEL, "a map's world would not read; its boxes are drawn", {"map": String(wanted), "at": prefix, "why": read.error.message})
		return read
	var world: DotMapBspMesh = read.value
	var mpu := float((world.manifest.get("units", {}) as Dictionary).get("metres_per_unit", 0.0))
	if absf(mpu - float(spec["metres_per_unit"])) > 1e-5:
		DotLog.warn(CHANNEL, "a map's world was made at another scale; its boxes are drawn", {"map": String(wanted), "pack": mpu, "doc": spec["metres_per_unit"]})
		return DotResult.fail(DotError.CODE_INVALID, "world pack scale differs", prefix)
	attach_world(world, HsMapDoc.v3(spec["offset"]))
	return DotResult.success(true)


## Lays [param world] over the map at [param offset] (the importer's shift, undone): the box meshes and their contact shade
## out, the document's lamps freed when the bake holds them. Props, doors and toys stay drawn: they are this game's, not the pack's.
func attach_world(world: DotMapBspMesh, offset: Vector3) -> void:
	for child in _drawn.get_children():
		if child.has_meta(BOX_BATCH) or String(child.name) == "ContactShade":
			_drawn.remove_child(child)
			child.queue_free()
	var lamps := _drawn.get_children().filter(func(n: Node) -> bool: return n is OmniLight3D)
	var surfaces := HsPaths.rebase(SURFACES_ROOT)
	drawn_world = DotMapDrawnWorld.attach(_drawn, world, {
		"transform": Transform3D(Basis.IDENTITY, offset),
		"surfaces_root": surfaces if DirAccess.dir_exists_absolute(surfaces) else DotMapSurfaces.DEFAULT_ROOT,
		"environment": _environment.environment if _environment != null else null,
		"lamps": lamps,
		"cloud": DotRegistry.get_service(&"dot_cloud_client"),
	})
	world_credits = drawn_world.credits
	DotLog.info(CHANNEL, "the map is drawn from its world pack", {"map": String(id()), "lit": drawn_world.lit != null, "credits": world_credits})


## The toys, on their own layers: a loose one on `toy` (people walk through and push it), one somebody stands on and every frame on `prop`, and footprints on `footprint`, which nothing collides with and a bot's walkable mesh is baked round.
func _build_toys() -> void:
	toys = DotPropToyBox.new()
	toys.name = "Toys"
	toys.authoritative = authoritative
	toys.draw = draw_world
	if toy_rules != null:
		toys.rules = toy_rules
	toys.gravity = gravity
	toys.kill_y = kill_height()
	if physics != null:
		toys.loose_layer = physics.layer_mask(&"toy")
		toys.loose_mask = physics.collision_mask(&"toy")
		toys.solid_layer = physics.layer_mask(&"prop")
		toys.solid_mask = physics.collision_mask(&"prop")
		toys.footprint_layer = physics.layer_mask(&"footprint")
		toys.aim_mask = physics.layer_mask(&"world") | physics.layer_mask(&"prop") | physics.layer_mask(&"toy")
	add_child(toys)
	var built := toys.build(doc.get("toys", []))
	if not built.ok:
		DotLog.warn(CHANNEL, "a map's toys would not build", {"map": String(id()), "why": built.error.message})


func _put_on(body: CollisionObject3D, layer: StringName) -> void:
	if physics == null:
		return

	var applied := physics.apply_to(body, layer)

	if not applied.ok:
		DotLog.warn(CHANNEL, "a map body could not be put on its layer", {"layer": String(layer)})



## The displacement ground: one triangle shape in the world body, and a mesh when drawing.
func _build_terrain() -> void:
	if not doc.has("terrain"):
		return
	var res := DotMapTerrain.from_dict(doc["terrain"])
	if not res.ok:
		DotLog.warn(CHANNEL, "a map's terrain would not read; it has no ground there", {"map": String(id()), "error": str(res)})
		return
	terrain = res.value
	var shape := CollisionShape3D.new()
	shape.name = "Terrain"
	shape.shape = terrain.build_shape()
	shape.set_meta(&"surface", terrain.mat)
	_solid.add_child(shape)
	var box := terrain.bounds()
	_bounds = box if _bounds == AABB() else _bounds.merge(box)
	if not draw_world:
		return
	var mesh := MeshInstance3D.new()
	mesh.name = "Boxes_terrain"
	mesh.set_meta(BOX_BATCH, true)
	mesh.mesh = terrain.build_mesh()
	mesh.material_override = HsMaterials.material_in(terrain.mat if terrain.mat != "" else "grass", HsMapDoc.colour((doc["terrain"] as Dictionary).get("tint", [1, 1, 1])), str(doc.get("look", "pastel")))
	_drawn.add_child(mesh)


func _build_boxes() -> void:
	var look := str(doc.get("look", "pastel"))
	var batches := {}
	var any := false
	var bakeable := draw_world and DotMapBoxBake.can_bake()

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
			# What a footstep on it sounds like (dot-audio's DotAudioFootsteps reads the hit
			# shape's meta; "stone", "hedge", "fabric" and the rest fold onto its surfaces).
			shape.set_meta(&"surface", str(box.get("mat", "")))
			_solid.add_child(shape)

		if not draw_world or not bool(box.get("visible", true)):
			continue

		var tint := HsMapDoc.colour(box.get("tint", [1, 1, 1]))
		var cell := Vector2i(floori(at.x / CHUNK), floori(at.z / CHUNK))
		var solid := bool(box.get("solid", true))
		# Solid and painted boxes are never batched together: a batch of floor paint or water is
		# opted out of the collision audit as a whole, and must not hide a solid box's mesh.
		var key := "%s|%s|%d|%d|%s" % [str(box["mat"]), tint.to_html(), cell.x, cell.y, solid]

		if not batches.has(key):
			var tool := SurfaceTool.new()
			tool.begin(Mesh.PRIMITIVE_TRIANGLES)
			var lit := bakeable and solid and not HsMaterials.is_transparent(str(box["mat"]))
			batches[key] = {"tool": tool, "mat": str(box["mat"]), "tint": tint, "solid": solid, "sheet": DotMapBoxBake.new_sheet() if lit else null}

		var sheet: RefCounted = (batches[key] as Dictionary)["sheet"]
		if sheet != null:
			DotMapBoxBake.add_faces(sheet, frame, size)
		else:
			_add_box((batches[key] as Dictionary)["tool"], frame, size)
		if not HsMaterials.is_transparent(str(box["mat"])):
			_shade_boxes.append({"transform": frame, "size": size})

	var index := 0
	for key: String in batches:
		var batch: Dictionary = batches[key]
		var tool: SurfaceTool = batch["tool"]
		var mesh := MeshInstance3D.new()
		# The same name on every build of a document: a bake finds its meshes by path.
		mesh.name = "Boxes_%d" % index
		index += 1
		mesh.set_meta(BOX_BATCH, true)
		if not bool(batch["solid"]):
			# Floor paint, water, a light fitting, embers in a hearth: drawn on purpose and
			# walked over or through (dot-core DotCollisionAudit).
			mesh.set_meta(&"dot_no_collision", true)
		if batch["sheet"] != null:
			mesh.mesh = DotMapBoxBake.commit(tool, batch["sheet"])
			mesh.set_meta(DotMapBoxBake.META_BAKEABLE, true)
		else:
			mesh.mesh = tool.commit()
		mesh.material_override = HsMaterials.material_in(batch["mat"], batch["tint"], look)
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

		# Godot's front face winds against the normal, the corners above go round the other way, so each triangle is emitted reversed or the map is drawn inside out.
		for v: Vector3 in [a, c, b, a, d, c]:
			tool.set_normal(normal)
			tool.add_vertex(v)


## Whether map furniture [param prop_id] casts a contact shade: only a furniture-kit block that collides as its box and stands upright, so its box is its shape. A piece-built prop is open underneath and its box would shade lit floor.
## Nothing here breaks or moves, so the shade, one mesh built at load, never outlives what cast it. See docs/design.md#colour-and-light.
func _shades_floor(prop_id: StringName, raw: Dictionary) -> bool:
	if catalogue == null or not catalogue.pieces_of(prop_id).is_empty():
		return false
	if str(catalogue.entry(prop_id).get("kit", "")) != "furniture":
		return false
	return is_zero_approx(float(raw.get("pitch", 0.0))) and is_zero_approx(float(raw.get("roll", 0.0)))


## dot-lighting's contact shade (API 4) where a box meets the floor, a wall or another box; the Compatibility renderer has no ambient occlusion. Glass, water, doors and secret panels neither cast nor take one.
## By path, behind the level, so a client shell older than the helper still runs the map without it.
func _add_contact_shade(boxes: Array) -> void:
	if boxes.is_empty() or _drawn == null or DotAddonApi.build_level("dot_lighting") < 4 \
			or not ResourceLoader.exists(CONTACT_SHADE_SCRIPT):
		return
	var shade: Variant = (load(CONTACT_SHADE_SCRIPT) as GDScript).call(&"node", boxes)
	if shade is MeshInstance3D and (shade as MeshInstance3D).mesh != null:
		(shade as Node).name = "ContactShade"
		_drawn.add_child(shade)
	elif shade is Node:
		(shade as Node).free()


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

		var shapes: Array = []

		for part: Array in catalogue.shapes_of(prop_id):
			var shape := CollisionShape3D.new()
			shape.shape = part[0]
			shape.transform = frame * (part[1] as Transform3D)
			shape.set_meta(&"hs_prop", props.size())
			_furniture.add_child(shape)
			shapes.append(shape)

		props.append({"id": prop_id, "transform": frame, "size": size, "shapes": shapes})

		if draw_world and _shades_floor(prop_id, raw):
			# Its box casts and takes none: bands on a cabinet's own sides would float off its model.
			_shade_boxes.append({"transform": frame.translated_local(Vector3(0.0, size.y * 0.5, 0.0)),
				"size": size, "casts": true, "shaded": false})

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


## What this map's bake must have been made from: the boxes, lamps and environment, and the versions of everything that lays them out.
func light_fingerprint() -> String:
	return DotMapBoxBake.fingerprint({
		"hs": BAKE_VERSION, "boxes": doc.get("boxes", []), "lights": doc.get("lights", []), "environment": doc.get("environment", {}),
		"look": doc.get("look", ""),
	})


## The map's baked light laid over it, if the game ships one made from this document. A map drawn from a world pack has none.
func _attach_bake() -> void:
	if not use_bakes or not doc.get("world", {}).is_empty():
		return
	var lamps := _drawn.get_children().filter(func(n: Node) -> bool: return n is OmniLight3D)
	var res := DotMapBoxBake.attach(self, HsPaths.rebase(BAKE_PATH % String(id())), light_fingerprint(), lamps)
	if res.ok:
		baked = res.value


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


## The sky and the sun: a dot-lighting document made from the map's `environment` ([method light_document]), giving every map the family's light while keeping its own sun angle, colour and sky.
func _build_environment() -> void:
	var env_doc: Dictionary = doc["environment"]
	var lighting := Node3D.new()
	lighting.name = "Lighting"
	add_child(lighting)
	_sun = DotLightRig.apply(lighting, DotLightDocument.from_dictionary(light_document(env_doc)),
		light_profile(float(env_doc["ambient_energy"])))

	if _sun != null:
		# The map's own angle, in Godot's degrees as the map document has always written it,
		# rather than through dot-lighting's source convention.
		_sun.rotation_degrees = Vector3(float(env_doc["sun_pitch"]), float(env_doc["sun_yaw"]), 0.0)
		# The rig aimed its fill opposite the sun it was given; turned with the sun here, or it
		# lights the faces the sun already does.
		var fill := lighting.get_node_or_null("Fill") as DirectionalLight3D
		if fill != null:
			var aimed := DotLightRig.fill(DotLightDocument.from_dictionary(light_document(env_doc)), _sun.rotation,
				light_profile(float(env_doc["ambient_energy"])))
			fill.rotation = aimed.rotation
			aimed.free()
		_sun.shadow_blur = 1.5
		_sun.directional_shadow_max_distance = 60.0

	for node in lighting.get_children():
		if node is WorldEnvironment:
			_environment = node as WorldEnvironment
			var sky := (node as WorldEnvironment).environment.sky
			if sky != null and sky.sky_material is ProceduralSkyMaterial:
				# The map's blue at the zenith (the rig draws it in the ambient colour, a grey
				# chosen for the shade) and again under the horizon, where an overview would
				# see a dark void round the map.
				var material := sky.sky_material as ProceduralSkyMaterial
				material.sky_top_color = HsMapDoc.colour(env_doc["sky_top"])
				material.ground_bottom_color = material.sky_top_color


## The dot-lighting document a map's `environment` describes.
## Brightness is 380 times the square of `sun_energy`. The ambient is a near-neutral pale grey at the map's strength ([method light_profile]), because a cool fill turned every room lavender. The fog is the map's horizon from 120 m out, hazing the distance and never a room.
static func light_document(env_doc: Dictionary) -> Dictionary:
	var sun := HsMapDoc.colour(env_doc["sun_colour"])
	var horizon := HsMapDoc.colour(env_doc["sky_horizon"])
	var energy := float(env_doc["sun_energy"])
	return {
		"sun": {
			"colour": [sun.r, sun.g, sun.b],
			"brightness": 380.0 * energy * energy,
			"spread_degrees": 1.0,
			"ambient_colour": [0.86, 0.86, 0.90],
		},
		"fog": {
			"enabled": true,
			"colour": [horizon.r, horizon.g, horizon.b],
			"start": 6300.0,
			"end": 40000.0,
			"max_density": 0.25,
		},
	}


## What this machine draws of a map's light: dot-lighting's `painted()`, with the map's fill.
## Shadows stay on in the browser, unlike `web()`: a hider's shadow is part of what a seeker reads, and the boxes are batched. `painted()` is matched to the Compatibility renderer (which clips a sunlit pastel to white) and adds a shadowless fill from the side the sun is not on, so a room's walls are different shades, which is where a hider hides.
## Ambient is `ambient_energy` times 4 of `painted()`'s and the fill times 2.8, keeping rooms as light as before while the ground outside loses its glare.
static func light_profile(ambient_energy: float = 0.5) -> DotLightProfile:
	var p := DotLightProfile.painted()
	p.sun_shadows = true
	p.sky_below_horizon = true
	p.ambient_energy *= ambient_energy * 4.0
	p.fill_energy *= ambient_energy * 2.8
	# Less contrast than painted()'s 1.12: the grade pivots at mid grey, and Kenney's dark
	# trunks, pines and furniture in shade went to black at 1.12.
	p.contrast = 1.04
	# Glow only from what is brighter than white (the lamps), not from every pale wall: at
	# dot-lighting's 0.85 a room of near-white pastels glowed into one milky veil.
	p.glow_threshold = 1.0
	return p



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
		var pieces := catalogue.pieces_of(prop["id"]) if catalogue != null else []

		if not pieces.is_empty():
			if DotPropPieces.contains(pieces, local, HIT_MARGIN):
				return index
			continue

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
		"doors      %d" % (doc.get("doors", []) as Array).size(),
		"props      %d" % props.size(),
		"lights     %d" % (doc.get("lights", []) as Array).size(),
	])

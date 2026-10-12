extends RefCounted

const HsPaths := preload("hs_paths.gd")

## The props a map is furnished with: the catalogue that `tools/measure_props.gd` measured out
## of the vendored models.
##
## [b]A size per prop, read from a file, on every machine.[/b] A prop's collision box is its
## size, and two ends building it from two different measurements would be a predicting client
## walking round a sofa the server has somewhere else. The server cannot measure anything — a
## headless process has the meshes but no reason to load them — so the size is measured once,
## offline, into `props/catalogue.json`, and everybody reads the number.
##
## [b]Drawn as parts, not as scenes.[/b] A map holds hundreds of props and nearly every one
## is one of a few dozen models, so a client asks [method parts] for a model's meshes and
## their transforms and the map draws each one with a [MultiMeshInstance3D]: a few dozen draw
## calls for a whole manor rather than one per chair. [method instance] builds one prop as a
## scene, for a tool that wants to look at a single model.

const CHANNEL := "hs.props"

const CATALOGUE := "res://props/catalogue.json"

## The part-shaped collision `tools/measure_props.gd` cuts out of the models with dot-props'
## [DotPropPieces]: a tree as a trunk, branches and a canopy, a table as a top and legs. A prop
## not in it collides as its box.
const PIECES := "res://props/pieces.json"

## id -> `{id, title, kit, model, scale, size: Vector3, offset: Vector3, disguise, pieces}`. The
## `disguise` flag is the catalogue's (shared with mg-prop-hunt) and nothing here reads it.
var props: Dictionary = {}

## id -> the prop's collision shapes, built once from its pieces and shared by every copy of it.
var _shapes: Dictionary = {}

## The ids, sorted, for a menu and for a stable order.
var order: Array[StringName] = []

## model path -> PackedScene, or null when the model would not load. Shared by every
## catalogue in the process, because a model is the same file whoever asks.
static var _scenes: Dictionary = {}

## model path -> Array of `[Mesh, Transform3D]`, the model's meshes in its own frame.
static var _parts: Dictionary = {}

## kit -> material name -> Color: the colours a kit is drawn in instead of its own. See
## `props/kits.json`: Kenney's Nature Kit is teal and coral by design, which reads as a
## cartoon beside realistic rooms.
var recolour: Dictionary = {}

## Mesh -> the copy drawn in this catalogue's colours. Shared, because a mesh is a mesh.
static var _recoloured: Dictionary = {}


## Reads the catalogue. Returns how many props it holds; 0 is a server with nothing to hide
## as, which is said once and loudly.
func load_file(path: String = CATALOGUE, pieces_path: String = PIECES) -> int:
	var text := FileAccess.get_file_as_string(HsPaths.rebase(path))
	var parsed: Variant = JSON.parse_string(text) if text != "" else null

	if not (parsed is Dictionary):
		DotLog.error(CHANNEL, "the prop catalogue would not read", {"path": path})
		return 0

	props.clear()
	order.clear()
	recolour.clear()
	_shapes.clear()

	# Optional: without it every prop is its box, as before the file existed.
	var pieces_text := FileAccess.get_file_as_string(HsPaths.rebase(pieces_path)) if pieces_path != "" else ""
	var pieces_doc: Variant = JSON.parse_string(pieces_text) if pieces_text != "" else null
	var all_pieces: Dictionary = (pieces_doc as Dictionary).get("pieces", {}) if pieces_doc is Dictionary else {}

	var colours: Variant = (parsed as Dictionary).get("recolour", {})

	if colours is Dictionary:
		for kit: String in colours:
			var table := {}
			for material: String in (colours[kit] as Dictionary):
				var rgb: Array = colours[kit][material]
				table[material] = Color(float(rgb[0]), float(rgb[1]), float(rgb[2]))
			recolour[kit] = table

	for raw: Variant in (parsed as Dictionary).get("props", []):
		if not (raw is Dictionary):
			continue

		var entry := raw as Dictionary
		var id := StringName(str(entry.get("id", "")))
		var size := _v3(entry.get("size"))

		if id == &"" or size == Vector3.ZERO:
			continue

		props[id] = {
			"id": id,
			"title": str(entry.get("title", id)),
			"kit": str(entry.get("kit", "")),
			"model": str(entry.get("model", "")),
			"scale": float(entry.get("scale", 1.0)),
			"size": size,
			"offset": _v3(entry.get("offset")),
			"disguise": bool(entry.get("disguise", true)),
			"pieces": DotPropPieces.decode(all_pieces.get(String(id), [])),
		}
		order.append(id)

	order.sort()
	return props.size()


func has(id: StringName) -> bool:
	return props.has(id)


func entry(id: StringName) -> Dictionary:
	return props.get(id, {})


func size_of(id: StringName) -> Vector3:
	return (props.get(id, {}) as Dictionary).get("size", Vector3.ZERO)


## [param id]'s convex pieces in its own frame (origin the middle of its footprint on the
## floor), or empty when it collides as its box.
func pieces_of(id: StringName) -> Array:
	return (props.get(id, {}) as Dictionary).get("pieces", [])


## [param id]'s collision: one shape per piece, or one box of its size standing on the origin.
## Each is `[Shape3D, Transform3D]` in the prop's frame. Built once per id and shared.
func shapes_of(id: StringName) -> Array:
	if _shapes.has(id):
		return _shapes[id]

	var out: Array = []
	var pieces := pieces_of(id)

	if pieces.is_empty():
		var size := size_of(id)
		var cube := BoxShape3D.new()
		cube.size = size
		out.append([cube, Transform3D(Basis.IDENTITY, Vector3(0.0, size.y * 0.5, 0.0))])
	else:
		for shape in DotPropPieces.shapes(pieces):
			out.append([shape, Transform3D.IDENTITY])

	_shapes[id] = out
	return out


func title_of(id: StringName) -> String:
	return str((props.get(id, {}) as Dictionary).get("title", id))


## Whether a player may hide as [param id]. A ceiling fan is in a map and cannot be worn.
func may_disguise(id: StringName) -> bool:
	return bool((props.get(id, {}) as Dictionary).get("disguise", false))


## A drawn copy of [param id]: its model under a node whose origin is the middle of its
## footprint on the floor. A box the prop's size stands in for a model that would not load.
func instance(id: StringName) -> Node3D:
	var e := entry(id)
	var holder := Node3D.new()
	holder.name = "Prop_%s" % String(id)

	if e.is_empty():
		return holder

	var packed := _scene(str(e["model"]))

	if packed != null:
		var model := packed.instantiate() as Node3D
		if model != null:
			model.scale = Vector3.ONE * float(e["scale"])
			model.position = e["offset"]
			_recolour_tree(model, str(e["kit"]))
			holder.add_child(model)
			return holder

	holder.add_child(_stand_in(e["size"]))
	return holder


## [param id]'s meshes as `[Mesh, Transform3D]` pairs, in the frame [method instance] places
## them in: scaled, and offset onto the floor. What a [MultiMesh] is built from.
func parts(id: StringName) -> Array:
	var e := entry(id)

	if e.is_empty():
		return []

	var model_path := str(e["model"])

	if not _parts.has(model_path):
		var found: Array = []
		var packed := _scene(model_path)

		if packed != null:
			var node := packed.instantiate()
			_collect(node, Transform3D.IDENTITY, found)
			node.free()

		_parts[model_path] = found

	var frame := Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * float(e["scale"])), e["offset"])
	var out: Array = []

	for part: Array in _parts[model_path]:
		out.append([_recoloured_mesh(part[0], str(e["kit"])), frame * (part[1] as Transform3D)])

	return out


## [param mesh], or a copy of it in [member recolour]'s colours for [param kit].
func _recoloured_mesh(mesh: Mesh, kit: String) -> Mesh:
	var table: Dictionary = recolour.get(kit, {})

	if table.is_empty() or mesh == null:
		return mesh

	if _recoloured.has(mesh):
		return _recoloured[mesh]

	var copy := mesh.duplicate() as Mesh
	var changed := false

	for surface in range(copy.get_surface_count()):
		var material := copy.surface_get_material(surface) as BaseMaterial3D

		if material == null or not table.has(material.resource_name):
			continue

		var painted := material.duplicate() as BaseMaterial3D
		painted.albedo_color = table[material.resource_name]
		copy.surface_set_material(surface, painted)
		changed = true

	_recoloured[mesh] = copy if changed else mesh
	return _recoloured[mesh]


func _recolour_tree(node: Node, kit: String) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).mesh = _recoloured_mesh((node as MeshInstance3D).mesh, kit)

	for child in node.get_children():
		_recolour_tree(child, kit)


static func _collect(node: Node, parent: Transform3D, into: Array) -> void:
	var here := parent

	if node is Node3D:
		here = parent * (node as Node3D).transform

	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		into.append([(node as MeshInstance3D).mesh, here])

	for child in node.get_children():
		_collect(child, here, into)


static func _scene(model_path: String) -> PackedScene:
	if model_path == "":
		return null

	if not _scenes.has(model_path):
		var path := HsPaths.rebase("res://%s" % model_path)
		_scenes[model_path] = load(path) as PackedScene if ResourceLoader.exists(path) else null

		if _scenes[model_path] == null:
			DotLog.warn(CHANNEL, "a prop's model would not load; a box stands in", {"model": model_path})

	return _scenes[model_path]


static func _stand_in(size: Vector3) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = Vector3(0.0, size.y * 0.5, 0.0)
	return mesh


static func _v3(value: Variant) -> Vector3:
	if value is Array and (value as Array).size() == 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))

	return Vector3.ZERO


func describe() -> Dictionary:
	var wearable := 0

	for id: StringName in props:
		if may_disguise(id):
			wearable += 1

	var shaped := 0

	for id: StringName in props:
		if not pieces_of(id).is_empty():
			shaped += 1

	return {"props": props.size(), "wearable": wearable, "shaped": shaped}

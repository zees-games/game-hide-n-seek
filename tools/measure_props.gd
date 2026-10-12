extends SceneTree

## Measures every model a kit in `props/kits.json` names and writes `props/catalogue.json`:
## each prop's id, title, model, scale, its size in metres and the offset that stands it on
## the floor with its footprint centred.
##
## [codeblock]
## godot --headless --path . --script tools/measure_props.gd           # write it
## godot --headless --path . --script tools/measure_props.gd -- --check # fail if it is stale
## [/codeblock]
##
## [b]Measured, never typed.[/b] A prop's collision box is its size, and a size somebody typed
## is a sofa a player walks into a metre before they reach its picture. The
## catalogue is what a server reads, because a headless server can measure nothing it has not
## imported; the tool runs where the models are imported, and `headless_run` checks the file
## agrees with the models.

const KITS := "res://props/kits.json"
const OUT := "res://props/catalogue.json"
const PIECES := "res://props/pieces.json"


func _initialize() -> void:
	var check := "--check" in OS.get_cmdline_user_args()
	var spec: Variant = JSON.parse_string(FileAccess.get_file_as_string(KITS))

	if not (spec is Dictionary):
		printerr("could not read ", KITS)
		quit(1)
		return

	var titles: Dictionary = (spec as Dictionary).get("titles", {})
	var props: Array = []
	var shaped: Dictionary = {}
	var tops: Dictionary = {}

	for kit: Dictionary in (spec as Dictionary).get("kits", []):
		var dir := "res://%s" % str(kit["dir"])
		var fixed: Array = kit.get("fixed", [])
		var files := DirAccess.get_files_at(dir)
		files.sort()

		for file in files:
			if not file.ends_with(".glb"):
				continue

			var model := file.get_basename()
			var scale := _scale_for(model, kit)
			var packed := load(dir.path_join(file)) as PackedScene

			if packed == null:
				printerr("could not load ", dir.path_join(file))
				continue

			var node := packed.instantiate() as Node3D
			var box := _bounds(node, Transform3D.IDENTITY)

			if box.size == Vector3.ZERO:
				printerr("no mesh in ", file)
				node.free()
				continue

			var size := box.size * scale
			var centre := box.get_center() * scale
			var id := "%s_%s" % [str(kit["id"]), _snake(model)]
			# Doubles for the file (a Vector3 is single precision and writes 0.725 as
			# 0.725000023841858); the Vector3 only for the pieces' frame.
			var offset_xyz := [_r(-centre.x), _r(-box.position.y * scale), _r(-centre.z)]
			var offset := Vector3(offset_xyz[0], offset_xyz[1], offset_xyz[2])
			# Collision shaped like the model (dot-props' DotPropPieces): a trunk and its
			# branches, a table's top and legs. Empty for a prop one box fits.
			var pieces := DotPropPieces.measure(node, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * scale), offset))
			node.free()

			props.append({
				"id": id,
				"title": str(titles.get(model, _title(model))),
				"kit": str(kit["id"]),
				"model": "%s/%s" % [str(kit["dir"]), file],
				"scale": scale,
				"size": [_r(size.x), _r(size.y), _r(size.z)],
				# What to add to a model's origin so its footprint is centred on the prop's
				# position and its base is on the floor.
				"offset": offset_xyz,
				"disguise": not fixed.has(model),
			})

			if not pieces.is_empty():
				shaped[id] = DotPropPieces.encode(pieces)
				tops[id] = _tops(pieces, size)

	props.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["id"]) < str(b["id"]))

	var recolour := {}

	for kit: Dictionary in (spec as Dictionary).get("kits", []):
		if kit.has("recolour"):
			recolour[str(kit["id"])] = kit["recolour"]

	var out := {
		"format": 1,
		"comment": "Written by tools/measure_props.gd from props/kits.json. Do not edit by hand.",
		"recolour": recolour,
		"props": props,
	}
	var text := JSON.stringify(out, "  ", false) + "\n"
	var pieces_text := _pieces_text(shaped, tops)

	if check:
		var have := FileAccess.get_file_as_string(OUT)
		if have != text:
			printerr("props/catalogue.json is not what the models measure; run tools/measure_props.gd")
			quit(1)
			return
		if FileAccess.get_file_as_string(PIECES) != pieces_text:
			printerr("props/pieces.json is not what the models measure; run tools/measure_props.gd")
			quit(1)
			return
		print("props/catalogue.json and props/pieces.json match %d models" % props.size())
		quit(0)
		return

	var f := FileAccess.open(OUT, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	f = FileAccess.open(PIECES, FileAccess.WRITE)
	f.store_string(pieces_text)
	f.close()

	var total := 0
	for p: Dictionary in props:
		var count := (shaped.get(p["id"], []) as Array).size()
		total += count
		print("%-34s %5.2f x %5.2f x %5.2f%s%s" % [p["id"], p["size"][0], p["size"][1], p["size"][2],
			"" if p["disguise"] else "  (fixed)", "  %d pieces" % count if count > 0 else ""])

	print("wrote %s: %d props; %s: %d shaped, %d pieces" % [OUT, props.size(), PIECES, shaped.size(), total])

	quit(0)


## The part-shaped collision (dot-props' DotPropPieces), one prop a line so a re-measure's diff
## reads by prop: `pieces` is `{id: [[x, y, z, ...] per convex piece]}` in the prop's frame, and
## `tops` is `{id: [TOPS x TOPS heights]}`, where something set down on the prop rests across
## its footprint (x across, then z; null where nothing is), for a maps builder that stacks props
## and has no hull maths. A prop not listed collides as its catalogue box.
static func _pieces_text(shaped: Dictionary, tops: Dictionary) -> String:
	var ids := shaped.keys()
	ids.sort()
	var lines := PackedStringArray()
	var top_lines := PackedStringArray()
	for id: String in ids:
		lines.append("    %s: %s" % [JSON.stringify(id), JSON.stringify(shaped[id])])
		top_lines.append("    %s: %s" % [JSON.stringify(id), JSON.stringify(tops[id])])
	return "{\n  \"format\": 1,\n  \"comment\": \"Written by tools/measure_props.gd with dot-props' DotPropPieces. Do not edit by hand. A prop not listed collides as its catalogue box.\",\n  \"tops_grid\": %d,\n  \"pieces\": {\n%s\n  },\n  \"tops\": {\n%s\n  }\n}\n" % [TOPS, ",\n".join(lines), ",\n".join(top_lines)]


## Cells a side of a prop's `tops` grid.
const TOPS := 8


static func _tops(pieces: Array, size: Vector3) -> Array:
	var out: Array = []
	for k in range(TOPS):
		for i in range(TOPS):
			var x := -size.x * 0.5 + (i + 0.5) * size.x / TOPS
			var z := -size.z * 0.5 + (k + 0.5) * size.z / TOPS
			var top := DotPropPieces.top_at(pieces, x, z)
			out.append(null if top == -INF else snappedf(top, 0.001))
	return out


func _bounds(node: Node, parent: Transform3D) -> AABB:
	var here := parent
	if node is Node3D:
		here = parent * (node as Node3D).transform

	var box := AABB()
	var any := false

	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		box = here * (node as MeshInstance3D).mesh.get_aabb()
		any = true

	for child in node.get_children():
		var inner := _bounds(child, here)
		if inner.size == Vector3.ZERO:
			continue
		box = inner if not any else box.merge(inner)
		any = true

	return box


## The kit's scale, or the first of its `scales` patterns (`tree_*`) that matches the model.
static func _scale_for(model: String, kit: Dictionary) -> float:
	var scales: Dictionary = kit.get("scales", {})
	for pattern: String in scales:
		if model.match(pattern):
			return float(scales[pattern])
	return float(kit.get("scale", 1.0))


static func _r(value: float) -> float:
	return snappedf(value, 0.001)


static func _snake(name: String) -> String:
	var out := ""
	for i in range(name.length()):
		var c := name[i]
		if c == c.to_upper() and c != c.to_lower() and i > 0 and name[i - 1] != "_":
			out += "_"
		out += c.to_lower()
	return out


static func _title(name: String) -> String:
	var words := _snake(name).replace("_", " ")
	return words.substr(0, 1).to_upper() + words.substr(1)

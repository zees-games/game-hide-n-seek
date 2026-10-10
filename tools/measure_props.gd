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


func _initialize() -> void:
	var check := "--check" in OS.get_cmdline_user_args()
	var spec: Variant = JSON.parse_string(FileAccess.get_file_as_string(KITS))

	if not (spec is Dictionary):
		printerr("could not read ", KITS)
		quit(1)
		return

	var titles: Dictionary = (spec as Dictionary).get("titles", {})
	var props: Array = []

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
			node.free()

			if box.size == Vector3.ZERO:
				printerr("no mesh in ", file)
				continue

			var size := box.size * scale
			var centre := box.get_center() * scale
			var id := "%s_%s" % [str(kit["id"]), _snake(model)]

			props.append({
				"id": id,
				"title": str(titles.get(model, _title(model))),
				"kit": str(kit["id"]),
				"model": "%s/%s" % [str(kit["dir"]), file],
				"scale": scale,
				"size": [_r(size.x), _r(size.y), _r(size.z)],
				# What to add to a model's origin so its footprint is centred on the prop's
				# position and its base is on the floor.
				"offset": [_r(-centre.x), _r(-box.position.y * scale), _r(-centre.z)],
				"disguise": not fixed.has(model),
			})

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

	if check:
		var have := FileAccess.get_file_as_string(OUT)
		if have != text:
			printerr("props/catalogue.json is not what the models measure; run tools/measure_props.gd")
			quit(1)
			return
		print("props/catalogue.json matches %d models" % props.size())
		quit(0)
		return

	var f := FileAccess.open(OUT, FileAccess.WRITE)
	f.store_string(text)
	f.close()

	for p: Dictionary in props:
		print("%-34s %5.2f x %5.2f x %5.2f%s" % [p["id"], p["size"][0], p["size"][1], p["size"][2], "" if p["disguise"] else "  (fixed)"])

	print("wrote %s: %d props" % [OUT, props.size()])
	quit(0)


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

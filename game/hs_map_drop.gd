extends RefCounted

## Maps handed to Hide & Seek outside the game: a map document (`.json` of kind `hideseek_map`) or a folder holding
## some, dragged onto the window, dropped on the executable or named by `--map-path=<path>`, through dot-map's
## DotMapDropIntake (API 26). Solo only: each document is checked as the catalogue checks one ([method
## HsMapDoc.parse_json]), copied to `user://maps/<id>.json` (read on every start) and joins the open catalogue at once,
## so M offers it. Anything else (a converted BSP folder, a zip, a text file) is refused out loud with what the game
## takes. A shared document acceptor in dot-map would replace this file (nightly map-drop-games-1).

const HsConfig := preload("hs_config.gd")
const HsMapDoc := preload("hs_map_doc.gd")

const CHANNEL := "hs.map_drop"
## dot-map's API level with DotMapDropIntake. Older builds take no dropped maps.
const NEEDS_LEVEL := 26
const INTAKE_SCRIPT := "res://addons/dot_map/core/dot_map_drop_intake.gd"
## What the refusal says this game takes.
const TAKES := "a Hide & Seek map (.json of kind hideseek_map) or a folder of them"
## The document kinds a drop may hold.
const KINDS := [HsMapDoc.KIND]
## Options dot-core reads whose next argument is their value (never read as a dropped path).
const VALUE_FLAGS := ["--config"]
## [method HsConfig.cli_prefix]: `--hs-<key> <value>`.
const CONFIG_PREFIX := "--hs-"


## The intake, a child of [param host] watching its window, adding to [param game]'s catalogue; every result is said
## line by line through [param say] (`func(line: String)`), and the paths on this process's command line are handled
## once, deferred. Null, with a warning, on dot-map older than API 26.
static func attach(host: Node, game: Node, say: Callable) -> Node:
	var intake := make(game)
	if intake == null:
		return null
	intake.connect(&"handled", func(result: Dictionary) -> void:
		for line in lines(result):
			say.call(line))
	host.add_child(intake)
	(func() -> void: var _taken := take_cmdline(intake, cmdline())).call_deferred()
	return intake


## A DotMapDropIntake whose one acceptor takes this game's documents into [param game]'s catalogue.
static func make(game: Node) -> Node:
	if DotAddonApi.build_level("dot_map") < NEEDS_LEVEL or not ResourceLoader.exists(INTAKE_SCRIPT):
		DotLog.warn(CHANNEL, "dropped maps are off: this build's dot-map is older than API %d" % NEEDS_LEVEL)
		return null
	var intake: Node = load(INTAKE_SCRIPT).new()
	intake.name = "MapDrop"
	var flags: PackedStringArray = intake.get(&"value_flags")
	flags.append_array(PackedStringArray(VALUE_FLAGS))
	intake.set(&"value_flags", flags)
	intake.call(&"add_acceptor", TAKES, func(path: String, into: String) -> Dictionary:
		return accept(path, into, game, int(intake.get(&"search_depth"))))
	return intake


## The acceptor: [code]{}[/code] when [param path] holds no document of [constant KINDS] (the intake then refuses it),
## else [code]{added, errors}[/code]. [param depth] folders down at most (0 is no limit).
static func accept(path: String, into: String, game: Node, depth: int) -> Dictionary:
	var files := documents_in(path, depth)
	if files.is_empty():
		return {}
	var errors := PackedStringArray()
	var added: Array[Dictionary] = []
	var catalogue: Object = game.get(&"catalogue") if game != null else null
	if catalogue == null or not bool(game.get(&"authoritative")):
		errors.append("%s: dropped maps play in solo only" % path.rstrip("/").get_file())
		return {"added": added, "errors": errors}
	var made := DirAccess.make_dir_recursive_absolute(into)
	if made != OK:
		errors.append("%s: cannot make %s (%s)" % [path.rstrip("/").get_file(), into, error_string(made)])
		return {"added": added, "errors": errors}
	for file in files:
		var text := FileAccess.get_file_as_string(file)
		var parsed := HsMapDoc.parse_json(text, file.get_file())
		if not parsed.ok:
			errors.append("%s: %s %s" % [file.get_file(), parsed.error.message, parsed.error.detail])
			continue
		var doc: Dictionary = parsed.value
		var id := str(doc["id"])
		var target := into.path_join(id + ".json")
		if (catalogue.get(&"maps") as Dictionary).has(StringName(id)) and not (catalogue.get(&"dropped") as Dictionary).has(StringName(id)) \
				and not FileAccess.file_exists(target):
			errors.append("%s: %s is already one of this game's maps" % [file.get_file(), id])
			continue
		var out := FileAccess.open(target, FileAccess.WRITE)
		if out == null:
			errors.append("%s: cannot write %s (%s)" % [file.get_file(), target, error_string(FileAccess.get_open_error())])
			continue
		out.store_string(text)
		out.close()
		catalogue.call(&"add_dropped", doc, target)
		added.append({"id": id, "name": str(doc.get("name", id)), "path": target})
	return {"added": added, "errors": errors}


## [param path] itself when it is a document of [constant KINDS], or every one in the folder [param path] and its
## folders [param depth] down (0 is no limit), sorted by name.
static func documents_in(path: String, depth: int) -> PackedStringArray:
	var out := PackedStringArray()
	if FileAccess.file_exists(path):
		if _is_document(path):
			out.append(path)
	elif DirAccess.dir_exists_absolute(path):
		_collect(path.rstrip("/"), depth if depth > 0 else -1, out)
	return out


static func _collect(dir: String, left: int, out: PackedStringArray) -> void:
	var files := DirAccess.get_files_at(dir)
	files.sort()
	for file in files:
		if _is_document(dir.path_join(file)):
			out.append(dir.path_join(file))
	if left == 0:
		return
	var subs := DirAccess.get_directories_at(dir)
	subs.sort()
	for sub in subs:
		if not sub.begins_with(".") and sub != "__MACOSX":
			_collect(dir.path_join(sub), left - 1 if left > 0 else -1, out)


static func _is_document(file: String) -> bool:
	if file.get_extension().to_lower() != "json":
		return false
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(file))
	return data is Dictionary and KINDS.has(str((data as Dictionary).get("kind", "")))


## What to show for an intake result: the maps added, then what was refused and why.
static func lines(result: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var names := PackedStringArray()
	for entry: Variant in result.get("added", []):
		if entry is Dictionary:
			names.append(str((entry as Dictionary).get("name", (entry as Dictionary).get("id", "?"))))
	if not names.is_empty():
		out.append("Added %s. Press M to play it." % ", ".join(names))
	var errors: PackedStringArray = result.get("errors", PackedStringArray())
	if not errors.is_empty():
		out.append("Could not add: %s" % "; ".join(errors))
	return out


## Handles the dropped paths in [param args] as from the command line; [code]{}[/code] when there are none.
static func take_cmdline(intake: Node, args: PackedStringArray) -> Dictionary:
	var paths := paths_in(intake, args)
	if paths.is_empty():
		return {}
	return intake.call(&"handle", paths, "command line")


## The process's arguments, the engine's and the user's.
static func cmdline() -> PackedStringArray:
	var all := OS.get_cmdline_args()
	all.append_array(OS.get_cmdline_user_args())
	return all


## The dropped paths in [param args] (DotMapDropIntake.paths_in_args, with this game's config options taken out first):
## every path that exists, every `--map-path` value, and every absolute path that does not exist (said as not found).
static func paths_in(intake: Node, args: PackedStringArray) -> PackedStringArray:
	var found: Dictionary = intake.call(&"paths_in_args", drop_args(args), intake.get(&"value_flags"), intake.get(&"path_flag"))
	var paths: PackedStringArray = found["paths"]
	paths.append_array(found["missing"] as PackedStringArray)
	return paths


## [param args] without the config options and their values (`--hs-<key> <value>`, `--<addon>.<key> <value>`): a
## value that happens to be a folder is not a dropped map. A bare `--hs-<bool key>` is a switch, as in
## [method DotConfig.apply_cli]: the argument after it is not its value, nor after an unknown key.
static func drop_args(args: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	var config := HsConfig.new()
	var i := 0
	while i < args.size():
		var a := args[i]
		i += 1
		if a.begins_with(CONFIG_PREFIX) or (a.begins_with("--") and a.get_slice("=", 0).contains(".")):
			var takes_value := not a.contains("=") and i < args.size() and not args[i].begins_with("--")
			if takes_value and a.begins_with(CONFIG_PREFIX):
				var key := config.call(&"_match_key", a.trim_prefix(CONFIG_PREFIX), config.config_keys()) as String
				takes_value = key != "" and typeof(config.get(key)) != TYPE_BOOL
			if takes_value:
				i += 1
			continue
		out.append(a)
	return out

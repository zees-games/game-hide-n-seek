extends RefCounted

## Maps handed to Hide & Seek outside the game: a map document (`.json` of kind `hideseek_map`) or a folder holding
## some, dragged onto the window, dropped on the executable or named by `--map-path=<path>`, through dot-map's
## DotMapDropIntake (API 29). Solo only: each document is checked as the catalogue checks one ([method
## HsMapDoc.parse_json]), copied to `user://maps/<id>.json` (read on every start) and joins the open catalogue at once,
## so M offers it as "<name> (local)". A map document may also sit in a .zip (read in place). Anything else (a converted BSP
## folder, a text file) is refused out loud with what the game takes. The document finding is dot-map's DotMapDocDrop.

const HsConfig := preload("hs_config.gd")
const HsMapDoc := preload("hs_map_doc.gd")

const CHANNEL := "hs.map_drop"
## dot-map's API level with DotMapDropIntake. Older builds take no dropped maps.
const NEEDS_LEVEL := 29
const INTAKE_SCRIPT := "res://addons/dot_map/core/dot_map_drop_intake.gd"
## What the refusal says this game takes.
const TAKES := "a Hide & Seek map (.json of kind hideseek_map, or a .zip or folder of them)"
## The document kinds a drop may hold.
const KINDS := [HsMapDoc.KIND]
## Options dot-core reads whose next argument is their value (never read as a dropped path).
const VALUE_FLAGS := ["--config"]
## [method HsConfig.cli_prefix]: `--hs-<key> <value>`.
const CONFIG_PREFIX := "--hs-"


## The intake, a child of [param host] watching its window, adding to [param game]'s catalogue; every result is said
## line by line through [param say] (`func(line: String)`), and the paths on this process's command line are handled
## once, deferred. Null, with a warning, on dot-map older than API 29.
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
## else [code]{added, errors}[/code]: dot-map's DotMapDocDrop finds the documents (a .json, a folder, a zip) and
## [method _take] checks and stores each. [param depth] folders down at most (0 is no limit).
static func accept(path: String, into: String, game: Node, depth: int) -> Dictionary:
	return DotMapDocDrop.accept(path, into, PackedStringArray(KINDS), depth,
		func(doc: Dictionary, text: String, name: String, dest: String) -> Dictionary:
			return _take(doc, text, name, dest, game))


## One document: checked as the catalogue checks one, written to [param dest] and joined to the catalogue.
static func _take(_raw: Dictionary, text: String, name: String, dest: String, game: Node) -> Dictionary:
	var catalogue: Object = game.get(&"catalogue") if game != null else null
	if catalogue == null or not bool(game.get(&"authoritative")):
		return {"error": "dropped maps play in solo only"}
	var parsed := HsMapDoc.parse_json(text, name)
	if not parsed.ok:
		return {"error": "%s %s" % [parsed.error.message, parsed.error.detail]}
	var doc: Dictionary = parsed.value
	var id := str(doc["id"])
	var target := dest.path_join(id + ".json")
	if (catalogue.get(&"maps") as Dictionary).has(StringName(id)) and not (catalogue.get(&"dropped") as Dictionary).has(StringName(id)) \
			and not FileAccess.file_exists(target):
		return {"error": "%s is already one of this game's maps" % id}
	if DotMapDocDrop.write_doc(dest, id, text) == "":
		return {"error": "cannot write %s" % target}
	catalogue.call(&"add_dropped", doc, target)
	return {"added": {"id": id, "name": str(doc.get("name", id)), "path": target}}


## What to show for an intake result: "Added <name> (local). Press M to play it." then "Not a map: <why>" per refusal.
static func lines(result: Dictionary) -> PackedStringArray:
	return DotMapDocDrop.lines(result, "Press M to play it.")


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


## True for a connect address or URL on the command line (`wss://host:6100/`, `host:6100`): never a dropped path.
## (dot-map's DotMapDropIntake.is_url_arg since the same fix; kept here for an older dot-map.)
static func is_url_arg(arg: String) -> bool:
	if arg.contains("://"):
		return not arg.to_lower().begins_with("file://")
	var colon := arg.rfind(":")
	if colon <= 0 or arg.contains("/") or arg.contains("\\"):
		return false
	return arg.substr(colon + 1).is_valid_int() and not arg.substr(0, colon).contains(":")


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
		if not is_url_arg(a):
			out.append(a)
	return out

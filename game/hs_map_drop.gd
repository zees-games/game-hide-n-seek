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
	(func() -> void: var _taken: Dictionary = intake.call(&"take_cmdline")).call_deferred()
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
	var config := HsConfig.new()
	intake.set(&"config_prefixes", PackedStringArray([CONFIG_PREFIX]))
	intake.set(&"option_takes_value", func(_prefix: String, stem: String) -> bool: return bool(intake.call(&"config_takes_value", config, stem)))
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

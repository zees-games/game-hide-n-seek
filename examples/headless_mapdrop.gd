extends DotGameCheckSuite

## Maps handed to Hide & Seek outside the game (HsMapDrop through dot-map's DotMapDropIntake, API 26): a map document or
## a folder of them, dragged onto the window, dropped on the executable or named by `--map-path=`. Each is checked as the
## catalogue checks one, copied to user://maps and listed at once; anything else is refused out loud with what the game
## takes, and a client of a server refuses every drop.
## [codeblock] ./game.sh test headless_mapdrop [/codeblock]

const HsCatalogue := preload("../game/hs_catalogue.gd")
const HsMapDoc := preload("../game/hs_map_doc.gd")
const HsMapDrop := preload("../game/hs_map_drop.gd")

const SOURCE := "user://zz_headless_mapdrop_src"
const MAP := "zz_mapdrop_drop"
const DROPPED := "user://maps/zz_mapdrop_drop.json"
const SECTIONS := 3


## What the acceptor needs of HsGame: its catalogue, and whether it is the authority (solo).
class FakeGame extends Node:
	var catalogue: HsCatalogue = null
	var authoritative := true


var _said := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	if DotAddonApi.build_level("dot_map") < HsMapDrop.NEEDS_LEVEL:
		print("-- skipped: dot-map API %d < %d (no DotMapDropIntake)" % [DotAddonApi.build_level("dot_map"), HsMapDrop.NEEDS_LEVEL])
		_report_sections(0, 0, 0)
		return
	var entered := 0
	var finished := 0
	_clean()
	entered += 1
	_test_args()
	finished += 1
	var game := FakeGame.new()
	game.catalogue = HsCatalogue.new()
	var _loaded := game.catalogue.load_from("maps")
	add_child(game)
	entered += 1
	_test_intake(game)
	finished += 1
	entered += 1
	await _test_attach(game)
	finished += 1
	game.queue_free()
	_clean()
	_report_sections(entered, finished, SECTIONS)


func _test_args() -> void:
	print("-- the command line: config options are not drops, --map-path and bare paths are")
	var folder := ProjectSettings.globalize_path(SOURCE.path_join("args"))
	DirAccess.make_dir_recursive_absolute(folder)
	var kept := HsMapDrop.drop_args(PackedStringArray(["--hs-map_directory", folder, "--dot_net.port", folder,
		"--hs-doors_enabled", folder, "--hs-no_such_key", folder, "--hs-seed_value=5", "--headless"]))
	_check(kept == PackedStringArray([folder, folder, "--headless"]),
		"a --hs-<key> and --<addon>.<key> value is no drop; a --hs-<bool> switch and an unknown key take none", str(kept))
	var intake := HsMapDrop.make(null)
	if not _check(intake != null, "dot-map 26 makes the shared intake"):
		return
	_check(bool(intake.get(&"watch_window")), "it watches the window itself")
	_check(intake.call(&"accepted_kinds") == PackedStringArray([HsMapDrop.TAKES]), "it takes Hide & Seek map documents only",
		str(intake.call(&"accepted_kinds")))
	var paths := HsMapDrop.paths_in(intake, PackedStringArray(["--path", folder, "--config", folder, "--map-path=" + folder]))
	_check(paths == PackedStringArray([folder]), "--map-path= is a drop; --path and --config values are not", str(paths))
	paths = HsMapDrop.paths_in(intake, PackedStringArray([folder, "--hs-map_directory", folder]))
	_check(paths == PackedStringArray([folder]), "a bare path is a drop (the executable's drop)", str(paths))
	paths = HsMapDrop.paths_in(intake, PackedStringArray(["--headless", "res://examples/headless_mapdrop.tscn"]))
	_check(paths.is_empty(), "no path on a plain start", str(paths))
	paths = HsMapDrop.paths_in(intake, PackedStringArray(["wss://tmcdev.net:6100/", "ws://127.0.0.1:6100", "https://games.tmcdev.net/x", "tmcdev.net:6100", "--join", "wss://tmcdev.net:6100/"]))
	_check(paths.is_empty(), "a connect URL or host:port is never a drop", str(paths))
	_check(paths.is_empty(), "no path on a plain start", str(paths))
	intake.free()


func _test_intake(game: FakeGame) -> void:
	print("-- a drop: a deep folder, a depth limit, a replaced drop, a taken id, junk, another game's map, a server")
	var intake := HsMapDrop.make(game)
	add_child(intake)
	var id := StringName(MAP)
	var deep := SOURCE.path_join("deep")
	_write_doc(deep.path_join("a/b/c/d").path_join(MAP + ".json"), MAP, "Dropped house")
	var result: Dictionary = intake.call(&"handle", _global(deep), "window")
	_check(_errors(result).contains("not a map this game can load (it takes %s)" % HsMapDrop.TAKES),
		"a map deeper than search_depth (3) is refused with what the game takes", _errors(result))
	_check(not game.catalogue.maps.has(id), "and not listed")
	intake.set(&"search_depth", 0)
	result = intake.call(&"handle", _global(deep), "window")
	_check((result.get("added", []) as Array).size() == 1 and _errors(result) == "", "search_depth 0 is no limit: found four folders down",
		str(result))
	_check(game.catalogue.maps.has(id) and game.catalogue.playable(PackedStringArray()).has(id), "M lists it at once")
	_check(FileAccess.file_exists(DROPPED), "copied to user://maps/<id>.json, read on every start")
	_check(HsMapDrop.lines(result) == PackedStringArray(["Added Dropped house (local). Press M to play it."]), "and said",
		str(HsMapDrop.lines(result)))
	intake.set(&"search_depth", 3)
	var again := SOURCE.path_join(MAP + ".json")
	_write_doc(again, MAP, "Dropped house, fixed")
	result = intake.call(&"handle", _global(again), "window")
	_check(_errors(result) == "" and str(game.catalogue.maps[id]["name"]) == "Dropped house, fixed", "a second drop of it replaces the first",
		_errors(result))
	var reloaded := HsCatalogue.new()
	var _loaded := reloaded.load_from("maps")
	_check(reloaded.maps.has(id), "a fresh catalogue reads it from user://maps")

	var zip_path := SOURCE.path_join("pack.zip")
	var zip_id := MAP + "_zip"
	var zipped := _write_zip(zip_path, {"maps/" + zip_id + ".json": _doc_text(zip_id, "Zipped map")})
	_check(zipped, "a test zip is made")
	result = intake.call(&"handle", _global(zip_path), "window")
	_check((result.get("added", []) as Array).size() == 1 and _errors(result) == "", "a zip holding a map document is read in place and added",
		str(result))
	_check(game.catalogue.display_name(StringName(zip_id)) == "Zipped map (local)", "and listed as <title> (local)",
		game.catalogue.display_name(StringName(zip_id)))
	_wipe_file(DROPPED.get_base_dir().path_join(zip_id + ".json"))
	var empty_zip := SOURCE.path_join("empty.zip")
	var _made := _write_zip(empty_zip, {"readme.txt": "hello"})
	result = intake.call(&"handle", _global(empty_zip), "window")
	_check(_errors(result).contains("no map document in the zip"), "a zip with no map document is refused out loud", _errors(result))

	var taken := SOURCE.path_join("taken.json")
	_write_doc(taken, String(HsCatalogue.PRACTICE), "Not the practice house")
	result = intake.call(&"handle", _global(taken), "window")
	_check(_errors(result).contains("is already one of this game's maps"), "a game map's id is refused", _errors(result))
	_check(str(game.catalogue.maps[HsCatalogue.PRACTICE]["name"]) != "Not the practice house", "and the game's map is kept")

	var broken := SOURCE.path_join("broken.json")
	_write(broken, JSON.stringify({"format": HsMapDoc.FORMAT, "kind": HsMapDoc.KIND, "id": "Bad Id"}))
	result = intake.call(&"handle", _global(broken), "window")
	_check(_errors(result).begins_with("broken.json: "), "a document the catalogue would refuse is refused with why", _errors(result))

	var junk := SOURCE.path_join("notes.txt")
	_write(junk, "not a map")
	var other := SOURCE.path_join("other.json")
	_write(other, JSON.stringify({"format": 1, "kind": "zombiezone_map", "id": "zz_other"}))
	var refused := int(intake.get(&"refused_total"))
	var before := game.catalogue.maps.size()
	result = intake.call(&"handle", PackedStringArray([_global(junk)[0], _global(other)[0]]), "window")
	_check(_errors(result).contains("notes.txt: not a map this game can load")
		and _errors(result).contains("other.json: not a map this game can load"), "junk and another game's map are refused out loud",
		_errors(result))
	_check(int(intake.get(&"refused_total")) == refused + 2, "and counted as refused")
	_check(game.catalogue.maps.size() == before, "and add nothing")
	result = intake.call(&"handle", PackedStringArray(["/no/such/zz_mapdrop_drop"]), "window")
	_check(_errors(result).contains("zz_mapdrop_drop: not found"), "a path that does not exist is said", _errors(result))

	game.authoritative = false
	_wipe_file(DROPPED)
	result = intake.call(&"handle", _global(again), "window")
	_check(_errors(result).contains("dropped maps play in solo only") and not FileAccess.file_exists(DROPPED),
		"a client of a server refuses it and copies nothing", _errors(result))
	game.authoritative = true
	intake.queue_free()


func _test_attach(game: FakeGame) -> void:
	print("-- attached to a client: dropped on the executable / --map-path, said line by line")
	_wipe_file(DROPPED)
	var host := Node.new()
	add_child(host)
	_said.clear()
	var intake := HsMapDrop.attach(host, game, func(line: String) -> void: _said.append(line))
	if not _check(intake != null and intake.get_parent() == host, "the client gets the intake as a child"):
		host.queue_free()
		return
	await get_tree().process_frame
	_check(_said.is_empty(), "this suite's own command line drops nothing", str(_said))
	var file := ProjectSettings.globalize_path(SOURCE.path_join(MAP + ".json"))
	var result := HsMapDrop.take_cmdline(intake, PackedStringArray(["--headless", "--map-path=" + file]))
	_check(str(result.get("source", "")) == "command line" and (result.get("added", []) as Array).size() == 1,
		"a --map-path map is added from the command line", str(result))
	_check(_said == PackedStringArray(["Added Dropped house, fixed (local). Press M to play it."]), "and said", str(_said))
	_said.clear()
	result = HsMapDrop.take_cmdline(intake, PackedStringArray([ProjectSettings.globalize_path(SOURCE.path_join("notes.txt"))]))
	_check(_said.size() == 1 and _said[0].begins_with("Not a map: notes.txt: not a map this game can load"),
		"a file dropped on the executable that is no map is refused out loud", str(_said))
	host.queue_free()


func _write_zip(path: String, files: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var packer := ZIPPacker.new()
	if packer.open(path) != OK:
		return false
	for name: String in files:
		var _s := packer.start_file(name)
		var _w := packer.write_file(str(files[name]).to_utf8_buffer())
		var _c := packer.close_file()
	var _closed := packer.close()
	return true


func _doc_text(id: String, title: String) -> String:
	var doc: Dictionary = HsCatalogue.practice().duplicate(true)
	doc["format"] = HsMapDoc.FORMAT
	doc["kind"] = HsMapDoc.KIND
	doc["id"] = id
	doc["name"] = title
	return JSON.stringify(doc)


func _write_doc(path: String, id: String, title: String) -> void:
	var doc: Dictionary = HsCatalogue.practice().duplicate(true)
	doc["format"] = HsMapDoc.FORMAT
	doc["kind"] = HsMapDoc.KIND
	doc["id"] = id
	doc["name"] = title
	_write(path, JSON.stringify(doc))


func _errors(result: Dictionary) -> String:
	return "; ".join(result.get("errors", PackedStringArray()) as PackedStringArray)


func _global(path: String) -> PackedStringArray:
	return PackedStringArray([ProjectSettings.globalize_path(path)])


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _clean() -> void:
	_wipe(SOURCE)
	_wipe_file(DROPPED)


func _wipe_file(path: String) -> void:
	if FileAccess.file_exists(path):
		var _gone := DirAccess.remove_absolute(path)


func _wipe(dir: String) -> void:
	if not DirAccess.dir_exists_absolute(dir):
		return
	for d in DirAccess.get_directories_at(dir):
		_wipe(dir.path_join(d))
	for n in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(n))
	DirAccess.remove_absolute(dir)

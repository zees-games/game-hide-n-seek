extends Node

const HsMapConfig := preload("../game/hs_map_config.gd")

## A map's file sets the round's cvars and the next map puts them back; the client's two keys do the same on a plain config.
##
## [codeblock]
## godot --headless --path . res://examples/headless_mapcfg.tscn
## [/codeblock]
##
## It writes a file into the operator tier for the run and removes it. The cvars start away from the file's values.

const CHECKS := 9
const DIR := "res://cfg/server/game/game-hide-n-seek/dot_map/map"

var _passed := 0
var _failed := 0
var _failures := PackedStringArray()


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-hide-n-seek: per-map cvars from cfg/game/game-hide-n-seek/dot_map/map")
	if not FileAccess.file_exists("res://addons/dot_map/config/dot_map_config.gd"):
		print("SKIPPED: dot-map is not linked at addons/dot_map")
		get_tree().quit(0)
		return
	DirAccess.make_dir_recursive_absolute(DIR)
	var path := DIR.path_join("hs_cfgtest*.yml")
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("hs_round_seconds: 90\nhs_gravity: 12\nhs_catch_mode: 1\nsv_evil: 1\n")
	f.close()

	var console := DotConsole.new()
	add_child(console)
	console.cvar("hs_round_seconds", "240", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("hs_gravity", "20", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("hs_catch_mode", "0", "", DotConVar.FLAG_ARCHIVE)
	console.cvar("sv_evil", "0", "", DotConVar.FLAG_ARCHIVE)
	var cfg := DotGameMapConfig.for_console(HsMapConfig.GAME_ID, console, HsMapConfig.KEYS)

	var got := cfg.apply("hs_cfgtest_a")
	_check(got.size() == 3, "a matching map applies its three whitelisted keys (%s)" % [got])
	_check(console.find_cvar("hs_round_seconds").get_float() == 90.0, "hs_round_seconds is 90 on the map")
	_check(console.find_cvar("hs_gravity").get_float() == 12.0, "hs_gravity is 12 on the map")
	_check(console.find_cvar("sv_evil").get_int() == 0, "a key outside the whitelist is not applied")

	cfg.apply("hs_castle")
	_check(console.find_cvar("hs_round_seconds").get_float() == 240.0, "the next map has the round length back")
	_check(console.find_cvar("hs_gravity").get_float() == 20.0 and console.find_cvar("hs_catch_mode").get_int() == 0, "gravity and catch mode are back too")
	_check(cfg.applied().is_empty(), "a map with no values applies nothing")

	var client := DotGameClient.new()
	var store := {"hs_gravity": "20", "hs_autobhop": "0"}
	client.map_config_keys = HsMapConfig.CLIENT_KEYS
	client.map_config_game = HsMapConfig.GAME_ID
	client.map_config_get_fn = func(key: String) -> Variant: return store.get(key)
	client.map_config_set_fn = func(key: String, value: Variant) -> bool:
		store[key] = str(value)
		return true
	client.map_changed("hs_cfgtest_b")
	_check(float(store["hs_gravity"]) == 12.0, "the client takes the map's gravity")
	client.map_changed("hs_castle")
	_check(float(store["hs_gravity"]) == 20.0, "and gives it back on the next map")
	client.free()

	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(DIR)
	DirAccess.remove_absolute(DIR.get_base_dir())
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	for line in _failures:
		print("  FAIL  %s" % line)
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected." % [_passed + _failed, CHECKS])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
	else:
		_failed += 1
		_failures.append(what)
		print("  FAIL  %s" % what)

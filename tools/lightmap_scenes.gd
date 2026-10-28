extends Node

## Writes one bake scene per map for dot-lighting's baker: the map built as a client builds it, opaque box batches (with UV2), lamps and sun kept,
## a LightmapGI added and the fingerprint recorded (DotMapBoxBake); tools/bake_lightmaps.sh runs this then the bake.
## Needs a display (xvfb-run), not --headless: a headless process keeps no mesh data to save.

const HsConfig := preload("../game/hs_config.gd")
const HsGame := preload("../game/hs_game.gd")
const HsMap := preload("../game/hs_map.gd")

## Per map settings over DotMapBoxBake.DEFAULTS. A large map takes a coarser texel so its file stays a browser download; the emission is how
## much of the live ambient a surface gives into the bake (an open yard has its sky, a closed building has none). Tuned against a live frame.
const SETTINGS := {
	"hs_castle": {"texel_scale": 0.4, "ambient_gain": 1.8, "emit": 0.2},
	"hs_ship": {"texel_scale": 0.5, "ambient_gain": 1.8, "emit": 0.2},
	"hs_museum": {"texel_scale": 0.5, "ambient_gain": 1.8, "emit": 0.2},
	"hs_mall": {"texel_scale": 0.5},
	"hs_school": {"texel_scale": 0.5, "ambient_gain": 1.8, "emit": 0.2},
	"hs_camp": {"texel_scale": 0.4, "ambient_gain": 1.8, "emit": 0.2},
	"hs_village": {"texel_scale": 0.5, "ambient_gain": 1.8, "emit": 0.2},
	"hs_manor": {"texel_scale": 0.5, "ambient_gain": 1.8, "emit": 0.2},
	"hs_apartments": {"texel_scale": 0.5},
	"hs_warehouse": {"texel_scale": 0.5, "ambient_gain": 1.8, "emit": 0.2},
	"hs_park": {"texel_scale": 0.5, "ambient_gain": 1.8, "emit": 0.2},
}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.WARN)
	_run.call_deferred()


func _arg(name: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return fallback


func _run() -> void:
	var out := _arg("out", "res://lightbake_work")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	var wanted := _arg("maps", "")
	HsMap.use_bakes = false
	var written := 0

	var probe := await _game("")
	var ids: Array = probe.catalogue.maps.keys()
	ids.sort()
	probe.queue_free()

	for id: StringName in ids:
		if (wanted != "" and not wanted.split(",").has(String(id))) or not SETTINGS.has(String(id)):
			continue
		var game := await _game(String(id))
		var map: HsMap = game.map
		if map == null or map.id() != id:
			printerr("LIGHTMAP_SCENE fail %s (not built)" % id)
			game.queue_free()
			continue
		var scene := DotMapBoxBake.bake_scene(map.get_node("Drawn"), map.get_node("Lighting"), map.light_fingerprint(),
			HsMap.BAKE_PATH % String(id), SETTINGS[String(id)])
		var path := out.path_join("%s.tscn" % id)
		var packed := PackedScene.new()
		packed.pack(scene)
		var saved := ResourceSaver.save(packed, path)
		print("LIGHTMAP_SCENE %s %s %s" % ["ok" if saved == OK else "fail", id, path])
		written += 1 if saved == OK else 0
		scene.free()
		game.queue_free()
		await get_tree().process_frame

	get_tree().quit(0 if written > 0 else 1)


func _game(id: String) -> HsGame:
	var config := HsConfig.new()
	config.warmup_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	config.map_ids = PackedStringArray([id]) if id != "" else PackedStringArray()
	var game := HsGame.new()
	game.name = "World_%s" % id
	game.config = config
	game.tick_rate = 60
	game.authoritative = true
	game.draw_world = id != ""
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	return game

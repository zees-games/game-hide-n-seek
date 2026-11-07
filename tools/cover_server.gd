extends DotCoverServer

const HsConfig := preload("../game/hs_config.gd")
const HsGame := preload("../game/hs_game.gd")

## A headless dedicated world for tools/render_cover.gd to join: the boot examples/dedicated.gd does, left running.
##   godot --headless --path . res://tools/cover_server.tscn -- --port 27399

var game: HsGame = null


func _max_players() -> int:
	return 4


func _boot(dir: String) -> void:
	var world_config := HsConfig.new()
	world_config.warmup_seconds = 0.0
	world_config.map_ids = PackedStringArray(["hs_practice"])
	world_config.minimum_players = 3
	game = HsGame.new()
	game.name = "World"
	game.config = world_config
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)
	await get_tree().process_frame

	(load("res://game/hs_module.gd") as GDScript).set("punishments_file", "%s/punishments.json" % dir)
	var loaded: DotResult = await server.modules.load_module("res://game/hs_module.gd")
	print("cover_server: module loaded=%s port=%d" % [loaded.ok, port])

extends DotGameNetchaosServer

const HsModule := preload("../game/hs_module.gd")

## Hide And Seek's side of `tools/netchaos.sh` (dot-game's DotGameNetchaosServer): the world scene and the module, as a dedicated server loads them, with no stand-ins.

var _scene: Node = null


func _configure() -> void:
	map_id = "hs_manor"


func _boot_world() -> void:
	if not (await boot_server()).ok:
		return
	_scene = (load("res://scenes/hs_server.tscn") as PackedScene).instantiate()
	add_child(_scene)
	_scene.game.config.map_ids = PackedStringArray([map_id])
	_scene.game.config.warmup_seconds = 0.0
	_scene.game.config.minimum_players = 0
	await get_tree().process_frame
	(HsModule as GDScript).set("punishments_file", "%s/punishments.json" % data_dir)
	var loaded: DotResult = await server.modules.load_module("res://game/hs_module.gd")
	if not loaded.ok:
		printerr("netchaos server: ", loaded.error)
		return
	module = server.modules.get_module("hideseek")
	var bots: DotConVar = server.console.find_cvar("hs_bots")
	if bots != null:
		bots.force_set("0")
	if solid != "":
		var cv: DotConVar = server.console.find_cvar("mp_solidplayers")
		if cv != null:
			cv.force_set(solid)


func _players() -> Array:
	return _scene.game.players.values() if _scene != null and _scene.game != null else []

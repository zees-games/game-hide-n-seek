extends SceneTree

## Rewrites cfg/game/game-hide-n-seek/config_*/game.yml from HsConfig's fields: godot --headless --path . --script tools/cfg_templates.gd

const HsConfig := preload("../game/hs_config.gd")


func _init() -> void:
	var binder := HsConfig.make_binder(HsConfig.new())
	var files := binder.template_files()
	for path: String in files:
		var res := DotPaths.write_text("res://" + path, files[path])
		print("%s %s" % ["wrote" if res.ok else "FAILED", path])
	quit()

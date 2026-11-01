extends DotGameWorkbenchSuite

## game-hide-n-seek: the workbench over the config binder, one edit per profile set, the export and its cfg round trip.
## Run: godot --headless --path . res://examples/headless_workbench.tscn

const HsConfig := preload("../game/hs_config.gd")


func _make_config() -> DotConfig:
	return HsConfig.new()


func _make_binder(config: DotConfig) -> DotGameConfigBinder:
	return HsConfig.make_binder(config)

extends DotLoadProbe

const HsClient := preload("../game/hs_client.gd")

## Boots the solo client and prints, per frame, whether the map, player and camera exist and whether the load gate still covers the screen; a body that moves uncovered, or a frame with no player, is the glitch. Needs xvfb-run, never --headless:
##   xvfb-run -a godot --path . res://tools/load_probe.tscn -- [--frames=90] [--shot=N]


func _make_client() -> Node:
	var c := HsClient.new()
	c.set("force_offline", true)
	return c


func _columns(_gate: Object) -> String:
	var cam: Object = client.get("camera")
	return "map=%s player=%s cam=%s hud=%s" % [client.get("game").map.doc.size() > 0, _body() != null,
		cam != null and cam.is_inside_tree(), client.get("hud") != null]

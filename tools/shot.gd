extends Node

## Renders the game and saves a frame. The check no assertion in this repository makes.
## See `tools/shot.sh` for the views. Any `--hs-*` is the game's own configuration.

const HsClient := preload("../game/hs_client.gd")
const HsGame := preload("../game/hs_game.gd")
const HsMapDoc := preload("../game/hs_map_doc.gd")

var _view := "seeker"
var _seconds := 3.0
var _board := false
var _out := "res://screenshots/shot.png"
var _at := Vector3.INF
var _look := Vector3.INF
var _third := false
## "open" or "shut": every door one way, to see a door's other pose; empty leaves the map's.
var _doors := ""
var _client: Node = null


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):
			_view = arg.trim_prefix("--view=")
		elif arg == "--board":
			_board = true
		elif arg.begins_with("--seconds="):
			_seconds = arg.trim_prefix("--seconds=").to_float()
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--at="):
			_at = _v3(arg.trim_prefix("--at="))
		elif arg.begins_with("--look="):
			_look = _v3(arg.trim_prefix("--look="))
		elif arg == "--third":
			_third = true
		elif arg.begins_with("--doors="):
			_doors = arg.trim_prefix("--doors=")

	_client = HsClient.new()
	_client.name = "Client"
	_client.set("force_offline", true)
	add_child(_client)
	_run.call_deferred()


static func _v3(text: String) -> Vector3:
	var parts := text.split(",")
	return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float()) if parts.size() == 3 else Vector3.INF


func _run() -> void:
	var game: HsGame = _client.get("game")
	await _until_a_round(game)
	var local = _client.get("player")
	var seeker := _view in ["seeker", "blind"]

	# The person at this keyboard on the side the view is about; stand-ins on the other, with
	# at least one seeker among them.
	var a_seeker := seeker
	for id: StringName in game.players:
		var side := HsGame.HIDERS
		if game.players[id] == local:
			side = HsGame.SEEKERS if seeker else HsGame.HIDERS
		elif not a_seeker:
			side = HsGame.SEEKERS
			a_seeker = true
		game._set_side(id, side)

	game._place_everybody()
	game._set_phase(HsGame.Phase.HIDE)

	if _doors != "" and game.map.doors != null:
		for index in range(game.map.doors.count()):
			game.map.doors.apply(index, _doors == "open", false, -1)

	if _third:
		_client.call("toggle_view")

	match _view:
		"overview":
			await _frames(6)
			var box: AABB = game.map.bounds()
			var centre := box.get_center()
			var reach := maxf(box.size.length() * 0.42, 14.0)
			_free_camera().look_at_from_position(centre + Vector3(reach * 0.45, reach * 0.6, reach * 0.55), centre)
		"room":
			await _seconds_of(_seconds)
			_free_camera().look_at_from_position(_at, _look)
		"blind":
			await _seconds_of(1.0)
		"seeker", "hider":
			game._set_phase(HsGame.Phase.SEEK)
			if _at != Vector3.INF:
				local.place_at(_at, 0.0)
			await _seconds_of(_seconds)
		"door":
			# A hider a step in front of the first door, facing it through their own camera, so
			# the prompt is the one the client draws for that aim.
			game._set_phase(HsGame.Phase.SEEK)
			var frame := (game.map.doors.doors[0]["body"] as Node3D).global_transform
			var size := HsMapDoc.v3((game.map.doors.doors[0]["spec"] as Dictionary)["size"])
			var normal := frame.basis.z.normalized()
			var feet := frame.origin + normal * 1.3 - Vector3(0.0, size.y * 0.5, 0.0)
			local.place_at(feet, rad_to_deg(atan2(normal.x, normal.z)))
			await _seconds_of(maxf(_seconds, 1.0))
		"caught":
			game._set_phase(HsGame.Phase.SEEK)
			if _at != Vector3.INF:
				local.place_at(_at, 0.0)
			await _seconds_of(0.5)
			var _got := game.catch(local.player_id, &"", HsGame.CAUGHT_TAG)
			await _seconds_of(0.4)
		_:
			await _seconds_of(_seconds)

	if _board:
		_client.call("_show_board", true)

	await _frames(3)
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(_out)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var saved := image.save_png(path)
	print("saved %s (%s): %s" % [_out, _view, error_string(saved)])
	get_tree().quit(0 if saved == OK else 1)


func _until_a_round(game: HsGame) -> void:
	for _i in range(900):
		if game.phase != HsGame.Phase.IDLE and _client.get("player") != null:
			return
		await get_tree().process_frame


func _free_camera() -> Camera3D:
	var camera := Camera3D.new()
	camera.fov = 75.0
	add_child(camera)
	camera.current = true
	# The HUD is the round's; a free camera is looking at the map.
	var hud: CanvasLayer = _client.get("hud")
	if hud != null:
		hud.visible = false
	return camera


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _seconds_of(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame

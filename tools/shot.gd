extends Node

## Renders the game and saves a frame. The check no assertion in this repository makes.
## See `tools/shot.sh` for the views. Any `--hs-*` is the game's own configuration.

const HsClient := preload("../game/hs_client.gd")
const HsGame := preload("../game/hs_game.gd")
const HsMapDoc := preload("../game/hs_map_doc.gd")
const HsPlayer := preload("../game/hs_player.gd")

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
		elif arg.begins_with("--place="):
			_place = _v3(arg.trim_prefix("--place="))
		elif arg.begins_with("--pick="):
			_pick = arg.trim_prefix("--pick=").to_int()
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


var _pick: int = 0

## Where the person at this keyboard stands for the shot (`--place=x,y,z`), in any view.
var _place: Vector3 = Vector3.INF


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
			if _place != Vector3.INF:
				game._set_phase(HsGame.Phase.SEEK)
				local.place_at(_place, 0.0)
			await _seconds_of(_seconds)
			if _place != Vector3.INF:
				print("the player's feet at %s" % local.controller.state.position.snapped(Vector3.ONE * 0.01))
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
		"bots":
			# The stand-in hiders where they hid: the hide played out, the seekers let go, and a
			# camera a few metres from the [member _pick]th best-hidden one (or the best).
			game._set_phase(HsGame.Phase.HIDE)
			game.phase_elapsed = 0.0
			while game.phase == HsGame.Phase.HIDE:
				await get_tree().process_frame
			await _seconds_of(0.5)
			var hidden: Array = []
			for id: StringName in game.players:
				var p: HsPlayer = game.players[id]
				if p.is_bot and game.team_of(id) == HsGame.HIDERS:
					var spot: Dictionary = game.bots._state_of(p).get("spot", {})
					hidden.append([float(spot.get("exposure", 1.0)), p])
					print("hider %s at %s, exposure %.2f" % [p.display_name, p.controller.state.position.snapped(Vector3.ONE * 0.1), float(spot.get("exposure", 1.0))])
			hidden.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
			var who: HsPlayer = hidden[mini(_pick, hidden.size() - 1)][1]
			var at: Vector3 = who.controller.state.position
			var eye := at + Vector3(0.0, 1.0, 0.0)
			var from := _at if _at != Vector3.INF else at + Vector3(2.6, 2.2, 2.6)
			if _at == Vector3.INF:
				# Back off along a clear line, so the camera is not inside a wall.
				for k in range(8):
					var dir := Vector3(cos(k * TAU / 8.0), 0.55, sin(k * TAU / 8.0)).normalized()
					var hit := get_viewport().world_3d.direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(eye, eye + dir * 4.0))
					var reach := 4.0 if hit.is_empty() else eye.distance_to(hit["position"]) - 0.3
					if reach > 2.4:
						from = eye + dir * reach
						break
			_free_camera().look_at_from_position(from, eye)
			print("looking at %s from %s" % [who.display_name, from.snapped(Vector3.ONE * 0.1)])
		"ragdoll":
			# A stand-in slain in front of a free camera, and [member _seconds] of its fall:
			# `--seconds=0.15`, `0.6` and `2` are the start, the drop and the body at rest.
			game._set_phase(HsGame.Phase.SEEK)
			await _seconds_of(0.6)
			var victim: HsPlayer = null
			for id: StringName in game.players:
				var p: HsPlayer = game.players[id]
				if p != local and p.is_alive() and p.figure != null and p.figure.visible:
					victim = p
					break
			if victim == null:
				print("nobody drawn to slay")
				get_tree().quit(1)
				return
			if _place != Vector3.INF:
				victim.place_at(_place, 0.0)
				await _seconds_of(0.3)
			var feet: Vector3 = victim.controller.state.position
			var camera := _free_camera()
			camera.look_at_from_position(_at if _at != Vector3.INF else feet + Vector3(2.4, 1.6, 2.4), feet + Vector3(0.0, 0.7, 0.0))
			var slay := DotDamage.make(0, victim.entity_id, victim.health.max_health * 10.0, null)
			slay.tick = game._tick
			slay.direction = (feet - camera.global_position) * Vector3(1, 0, 1)
			var _applied: Variant = game.combat.apply_damage(slay)
			print("slew %s at %s: %s" % [victim.display_name, feet.snapped(Vector3.ONE * 0.1), victim.death.describe() if victim.death != null else "no fall"])
			await _seconds_of(_seconds)
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

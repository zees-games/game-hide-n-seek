extends Node

## The cameras and bodies the first play test caught, in the real offline game:
##
## - the third-person and spectator chase cameras flown round the start and every
##   checkpoint of the course (dot-core's DotCameraCheck): never inside, armed by the
##   unprotected camera being in or behind the course on some frames;
## - the player walked (the forward action held) into another player held still: with
##   `mp_solidplayers 1` their capsules never overlap; with 0 they do (the armed half: the
##   play test's face filling the screen);
## - with `--render`, that moment from the player's eyes before (pass-through, no fade) and
##   after, and both views.
##
##   tools/camera_check.sh            # headless; exit 1 on a failure
##   tools/camera_check.sh --render   # and the frames, in screenshots/cameras/

const HsClient := preload("../game/hs_client.gd")
const HsGame := preload("../game/hs_game.gd")
const HsPlayer := preload("../game/hs_player.gd")

var _client: Node = null
var _render := false
var _failed := false


func _ready() -> void:
	_render = OS.get_cmdline_user_args().has("--render")
	_client = HsClient.new()
	_client.name = "Client"
	_client.set("force_offline", true)
	add_child(_client)
	_run.call_deferred()


func _run() -> void:
	var game: HsGame = _client.get("game")
	# Held in the warmup: nobody is blindfolded and held still there, so the walk below is a
	# walk whichever side this player was dealt.
	game.config.warmup_seconds = 300.0
	await _seconds(2.5)

	_fly(game)
	var walks: Array = await _bodies(game)
	var loose_closest: float = walks[0]
	var solid_closest: float = walks[1]
	# Players pass through each other by default here (HsGame._init); with the rule on, the
	# walk may be turned aside round the furniture, so what is held is "never inside anybody".
	_check(not HsGame.new().body_rules.solid, "players pass through each other by default here (mp_solidplayers 0, this game's pick)")
	_check(solid_closest > 0.6, "mp_solidplayers 1: walking into players never ends inside anybody (closest %.2f m apart)" % solid_closest)
	_check(loose_closest < 0.3, "armed: mp_solidplayers 0, the same walk goes through them (closest %.2f m)" % loose_closest)
	game.body_rules.solid = true

	if _render:
		await _views(game)

	print("%s" % ("all passed" if not _failed else "FAILED"))
	get_tree().quit(1 if _failed else 0)


func _fly(game: HsGame) -> void:
	# Beside every wall, tree and piece of furniture of the house: found, not listed.
	var mask: int = _client.game.physics.layer_mask(&"world") | _client.game.physics.layer_mask(&"prop")
	var pivots := DotCameraCheck.pivots_near_walls(_client.get_viewport().world_3d, AABB(Vector3(-80, -10, -80), Vector3(160, 40, 160)), mask, 1.6, 2.5, 3.0, 50)
	var world := _client.get_viewport().world_3d
	var cases := {
		"third_person": Vector3(0.0, HsClient.CHASE_UP, HsClient.CHASE_BACK),
		"chase": Vector3(0.0, 1.2, 4.6),
	}
	for name in cases:
		var total := {}
		for pivot in pivots:
			total = DotCameraCheck.add(total, DotCameraCheck.fly(world, DotCameraCheck.orbit_path(pivot), cases[name], mask))
		_check(DotCameraCheck.passed(total), "%s round %d places in the house: %s" % [name, pivots.size(), DotCameraCheck.summary(total)])


## Walks the player (the real input path: the forward action held) into another player held
## still, with players passing through each other and then solid. Returns
## [code][pass_through_closest, solid_closest][/code], in metres between the capsules' axes.
## Deterministic: the other player is put back on its spot every frame, so its own brain
## cannot steer it away; and the walk is one the pass-through run proved clear (a spot whose
## way in is blocked by a wall or a start gate proves nothing, and is skipped).
func _bodies(game: HsGame) -> Array:
	var me: HsPlayer = _client.get("player")
	var space := _client.get_viewport().world_3d.direct_space_state
	var mask: int = _client.game.physics.layer_mask(&"world") | _client.game.physics.layer_mask(&"prop")
	for id in game.players:
		var other: HsPlayer = game.players[id]
		if other == me:
			continue
		var spot: Vector3 = other.controller.state.position
		for i in 8:
			var angle := TAU * float(i) / 8.0
			var probe := spot + Vector3(sin(angle), 0.0, cos(angle)) * 2.6
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(probe + Vector3.UP, probe + Vector3.DOWN, mask))
			if hit.is_empty() or absf((hit["position"] as Vector3).y - spot.y) > 0.3:
				continue
			if DotCameraProbe.is_inside(space, probe + Vector3.UP * 0.9, 0.36, mask):
				continue
			var from: Vector3 = hit["position"]
			var loose: float = await _walk(game, me, other, spot, from, false)
			if loose > 0.3:
				continue
			var solid: float = await _walk(game, me, other, spot, from, true)
			game.body_rules.solid = true
			return [loose, solid]
	game.body_rules.solid = true
	return [INF, INF]


func _walk(game: HsGame, me: HsPlayer, other: HsPlayer, spot: Vector3, from: Vector3, solid: bool) -> float:
	game.body_rules.solid = solid
	var to_spot := spot - from
	me.controller.teleport(from + Vector3.UP * 0.05, rad_to_deg(atan2(-to_spot.x, -to_spot.z)), 0.0)
	await get_tree().physics_frame
	# Offline the sampler is suspended while the pointer is free, which is always, here: the
	# walk is the same command the sampler would make, handed to the controller each tick.
	var saved_sampler = me.sampler
	me.sampler = null
	var go := DotFpsCommand.new()
	go.yaw = me.controller.state.yaw
	go.move = Vector2(0, 1)
	var closest := INF
	for i in 90:
		other.controller.teleport(spot, NAN, NAN)
		me.controller.apply_command(go)
		await get_tree().physics_frame
		var a := me.controller.state.position
		if solid:
			# Solid, the walk may stop at somebody else first (a start pad is crowded):
			# the closest to ANY other player is what must stay two radii apart.
			for id in game.players:
				var body: HsPlayer = game.players[id]
				if body != me and absf(body.controller.state.position.y - a.y) < 1.6:
					var b := body.controller.state.position
					closest = minf(closest, Vector2(a.x - b.x, a.z - b.z).length())
		else:
			closest = minf(closest, Vector2(a.x - spot.x, a.z - spot.z).length())
	me.sampler = saved_sampler
	print("    %s: closest %.2f m" % ["solid" if solid else "pass-through", closest])
	return closest


func _views(game: HsGame) -> void:
	DirAccess.make_dir_recursive_absolute("screenshots/cameras")
	var me: HsPlayer = _client.get("player")
	await _seconds(0.8)
	await _shot("hideseek_view_first")
	_client.call("toggle_view")
	await _seconds(0.8)
	await _shot("hideseek_view_third")
	_client.call("toggle_view")
	await _seconds(0.3)

	# The play test's face at the lens: a stand-in on the player's eye, where walking through
	# them put it. Before: nothing hides it. After: the fade does (and solid bodies keep it
	# from getting there at all, which the check above measures). Re-placed every frame,
	# because its own brain moves it on.
	var fade: DotCameraFade = _client.get("_fade")
	var camera: Camera3D = _client.get("camera")
	var bot: HsPlayer = null
	for id in game.players:
		var other: HsPlayer = game.players[id]
		if other != me and other.visible and other.figure != null and other.figure.visible:
			bot = other
			break
	if bot == null:
		return
	game.body_rules.solid = false
	var figures: Callable = fade.bodies_fn
	fade.bodies_fn = Callable()
	await _held_in_front(bot, me, camera, "hideseek_walk_in_before")
	fade.bodies_fn = figures
	await _held_in_front(bot, me, camera, "hideseek_walk_in_after")
	game.body_rules.solid = true


func _held_in_front(bot: HsPlayer, me: HsPlayer, camera: Camera3D, file: String) -> void:
	var ahead := -camera.global_basis.z
	ahead.y = 0.0
	ahead = ahead.normalized()
	for i in 20:
		bot.controller.teleport(me.controller.state.position + ahead * 0.35, rad_to_deg(atan2(ahead.x, ahead.z)))
		bot.global_position = bot.controller.state.position
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := "screenshots/cameras/%s.png" % file
	var _saved := get_viewport().get_texture().get_image().save_png(path)
	print("  wrote %s" % path)


func _shot(file: String) -> void:
	for i in 3:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var path := "screenshots/cameras/%s.png" % file
	var _saved := get_viewport().get_texture().get_image().save_png(path)
	print("  wrote %s" % path)


func _check(ok: bool, what: String) -> void:
	print("%s  %s" % ["ok  " if ok else "FAIL", what])
	if not ok:
		_failed = true


func _seconds(s: float) -> void:
	await get_tree().create_timer(s).timeout

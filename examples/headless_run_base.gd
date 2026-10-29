extends DotGameCheckSuite
## The preloads, practice-house positions and helpers of [code]headless_run[/code] (a base layer, split off for size); never run on its own.

const HsBindings := preload("../game/hs_bindings.gd")
const HsCatalogue := preload("../game/hs_catalogue.gd")
const HsConfig := preload("../game/hs_config.gd")
const HsController := preload("../game/hs_controller.gd")
const HsGame := preload("../game/hs_game.gd")
const HsEvents := preload("../game/net/hs_events.gd")
const HsInterest := preload("../game/net/hs_interest.gd")
const HsMapDoc := preload("../game/hs_map_doc.gd")
const HsPlayer := preload("../game/hs_player.gd")
const HsProgress := preload("../game/hs_progress.gd")
const HsProps := preload("../game/hs_props.gd")
const HsSettings := preload("../game/hs_settings.gd")

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

## The first chair round the kitchen table in the practice house: where it stands.
const CHAIR_AT := Vector3(3.6, 0.0, 1.2)

## An open stretch of the kitchen floor, and of the living room's, either side of the wall.
const KITCHEN_A := Vector3(3.0, 0.05, -3.0)
const KITCHEN_B := Vector3(8.0, 0.05, -3.0)
const LIVING := Vector3(-3.0, 0.05, -3.0)

var _sections_entered := 0
var _sections_finished := 0

var _worlds: Array[HsGame] = []



func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


## The use key down for a tick and up again: the game makes a press from the edge.
func _press(game: HsGame, player: HsPlayer) -> void:
	player.wants_use = true
	await _step(game, 1)
	player.wants_use = false
	await _step(game, 1)


func _world(configure: Callable = Callable()) -> HsGame:
	for old in _worlds.duplicate():
		await _dispose(old)

	var config := HsConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.map_ids = PackedStringArray(["hs_practice"])
	config.keep_progress = true
	config.hide_seconds = 2.0
	config.seeker_pick = HsConfig.Pick.RANDOM

	if configure.is_valid():
		configure.call(config)

	var game := HsGame.new()
	game.name = "World%d" % _worlds.size()
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	_worlds.append(game)

	await _physics_frame()
	await _physics_frame()
	return game


## A world in the hide, with a seeker and two hiders.
func _hide_round(configure: Callable = Callable()) -> HsGame:
	var game := await _world(configure)
	var seeker := game.add_player(&"u300", "Seeker")
	game.wish_side(seeker.player_id, HsGame.SEEKERS)
	for i in range(2):
		var hider := game.add_player(StringName("u%d" % (301 + i)), "Hider%d" % i)
		game.wish_side(hider.player_id, HsGame.HIDERS)
	game.start()
	await _wait_for(game, HsGame.Phase.HIDE)
	return game


## A world where the seekers are seeking.
func _seek_round(configure: Callable = Callable()) -> HsGame:
	var game := await _hide_round(func(c: HsConfig) -> void:
		c.hide_seconds = 0.25
		if configure.is_valid():
			configure.call(c))
	await _wait_for(game, HsGame.Phase.SEEK)
	return game


func _wait_for(game: HsGame, phase: int) -> void:
	for i in range(TICK_RATE * 20):
		if game.phase == phase:
			return
		await _step(game, 1)


## Ends the round in play (the seekers win) and waits for the next to begin.
func _end_round(game: HsGame) -> void:
	var number := game.round_number
	while game.phase == HsGame.Phase.HIDE:
		await _step(game, 1)
	var seekers := game.players_on(HsGame.SEEKERS)
	for hider in game.players_on(HsGame.HIDERS):
		var _c := game.catch(hider.player_id, seekers[0].player_id if not seekers.is_empty() else &"", HsGame.CAUGHT_TAG)
	for i in range(TICK_RATE * 20):
		await _step(game, 1)
		if game.round_number > number and game.phase == HsGame.Phase.HIDE:
			return


func _step(game: HsGame, ticks: int) -> void:
	for _i in range(ticks):
		game.simulate(TICK)
		await _physics_frame()


func _physics_frame() -> void:
	await get_tree().physics_frame


func _dispose(game: HsGame) -> void:
	_worlds.erase(game)

	if not is_instance_valid(game):
		return

	remove_child(game)
	game.free()
	await get_tree().process_frame


func _drive(player: HsPlayer, move: Vector2) -> void:
	var command := DotFpsCommand.new()
	command.yaw = player.controller.state.yaw
	command.move = move
	player.controller.apply_command(command)


func _aim(player: HsPlayer, target: Vector3) -> void:
	var look := target - player.eye_position()
	var command := DotFpsCommand.new()
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	player.controller.state.yaw = command.yaw
	player.controller.state.pitch = command.pitch
	player.controller.apply_command(command)


func _prop_near(game: HsGame, at: Vector3) -> int:
	for index in range(game.map.props.size()):
		if ((game.map.props[index] as Dictionary)["transform"] as Transform3D).origin.distance_to(at) < 0.05:
			return index
	return -1


static func _names(of: Array[HsPlayer]) -> PackedStringArray:
	var out := PackedStringArray()
	for p in of:
		out.append(String(p.player_id))
	return out


static func _spread(turns: Dictionary, ids: Array[StringName]) -> Vector2i:
	var lo := 999
	var hi := 0
	for id in ids:
		lo = mini(lo, int(turns.get(id, 0)))
		hi = maxi(hi, int(turns.get(id, 0)))
	return Vector2i(lo, hi)

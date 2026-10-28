extends DotGameCheckSuite
## The wire rig of [code]headless_net[/code] (two worlds joined by queues) and its constants; split off for size.

const HsCatalogue := preload("../game/hs_catalogue.gd")
const HsConfig := preload("../game/hs_config.gd")
const HsEvents := preload("../game/net/hs_events.gd")
const HsGame := preload("../game/hs_game.gd")
const HsMapDoc := preload("../game/hs_map_doc.gd")
const HsNetBridge := preload("../game/net/hs_net_bridge.gd")
const HsPlayer := preload("../game/hs_player.gd")
const HsEvent := preload("../game/net/hs_event.gd")
const HsRequest := preload("../game/net/hs_request.gd")

const CLIENT_PEER := 7
const SESSION := 42
const SERVER_TICK_RATE := 64
const CLIENT_ENGINE_TICK_RATE := 30
const SNAPSHOT_RATE := 30
const INPUT_LEAD := 3

## Two open stretches of the practice house's kitchen floor, five metres apart.
const KITCHEN_A := Vector3(3.0, 0.05, -3.0)
const KITCHEN_B := Vector3(8.0, 0.05, -3.0)

var _server_game: HsGame = null
var _client_game: HsGame = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: HsNetBridge = null
var _client_bridge: HsNetBridge = null
var _stand_in: HsPlayer = null
var _second: HsPlayer = null

var _to_client: Array = []
var _to_server: Array = []
var _tick: int = 0

## What the client was told, by kind, so a section can ask whether an event arrived.
var _heard: Dictionary = {}


## Turns a server-side stand-in to look at [param target], and keeps it looking.
func _look(player: HsPlayer, target: Vector3) -> void:
	var look := target - player.eye_position()
	var command := DotFpsCommand.new()
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	player.controller.state.yaw = command.yaw
	player.controller.state.pitch = command.pitch
	player.controller.apply_command(command)


func _me() -> StringName:
	return HsNetBridge.player_key(SESSION)


func _mine() -> HsPlayer:
	return _client_game.players.get(_me())


func _server_me() -> HsPlayer:
	return _server_game.players[_me()]


## A command that looks from [param player]'s eye at [param target].
func _aim_at(player: HsPlayer, target: Vector3) -> DotFpsCommand:
	var look := target - player.eye_position()
	var command := DotFpsCommand.new()
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	return command


## Into a fresh round's hide, with the client on [param side], the stand-in on the other and
## the second stand-in hiding, everybody put back where the round puts them.
func _hide_with(side: int) -> void:
	for _i in range(SERVER_TICK_RATE * 10):
		if _server_game.phase == HsGame.Phase.HIDE:
			break
		await _step()

	var other := HsGame.HIDERS if side == HsGame.SEEKERS else HsGame.SEEKERS
	_server_game._set_side(_me(), side)
	_server_game._set_side(_stand_in.player_id, other)
	_server_game._set_side(_second.player_id, HsGame.HIDERS)
	_server_game._set_phase(HsGame.Phase.HIDE)
	_server_game._place_everybody()
	_second.place_at(Vector3(-7.0, 0.05, 6.0), 0.0)
	await _steps(8)


func _make_game(server: bool, parent: Node) -> HsGame:
	var config := HsConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.hide_seconds = 60.0
	config.minimum_players = 0
	config.keep_progress = false
	config.auto_taunt_seconds = 0.0
	config.map_ids = PackedStringArray(["hs_practice"])
	config.caught_freeze_seconds = 1.0

	var game := HsGame.new()
	game.name = "World"
	game.config = config
	game.authoritative = server
	game.tick_rate = SERVER_TICK_RATE if server else CLIENT_ENGINE_TICK_RATE
	game.register_service = false
	parent.add_child(game)
	game.set_physics_process(false)
	return game


func _make_manager(server: bool, scope: StringName, peer_id: int, parent: Node, tick_rate: int) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = tick_rate
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 192
	config.world_extent = HsGame.NET_WORLD_EXTENT
	manager.config = config

	parent.add_child(manager)
	var _ready_now := manager.setup()
	return manager


func _on_server_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	if peer_id != 0 and peer_id != CLIENT_PEER:
		return

	_to_client.append({"method": method, "payload": payload})


func _on_client_send(method: StringName, _peer_id: int, payload: PackedByteArray) -> void:
	_to_server.append({"method": method, "payload": payload})


func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])

	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


func _exchange() -> void:
	_flush()
	_flush()


## One tick on both ends, with a real physics frame between them.
func _step(command: DotFpsCommand = null) -> void:
	_tick += 1
	var _ticks := _client_net.clock.advance(1.0 / float(maxi(_client_game.tick_rate, 1)))
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick + INPUT_LEAD, command if command != null else DotFpsCommand.new())
	_flush()
	await get_tree().physics_frame


func _steps(count: int, command: DotFpsCommand = null) -> void:
	for _i in range(count):
		await _step(command)


## sv_workbench_remote over the real frames, in the order HsModule and HsClient register them: an admin gets a
## panel and an edit that applies and replicates; a guest, a non-admin, a revoked admin and the cvar off are refused.

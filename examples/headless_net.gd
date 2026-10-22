extends Node

const HsCatalogue := preload("../game/hs_catalogue.gd")
const HsConfig := preload("../game/hs_config.gd")
const HsEvents := preload("../game/net/hs_events.gd")
const HsGame := preload("../game/hs_game.gd")
const HsMapDoc := preload("../game/hs_map_doc.gd")
const HsNetBridge := preload("../game/net/hs_net_bridge.gd")
const HsPlayer := preload("../game/hs_player.gd")
const HsEvent := preload("../game/net/hs_event.gd")
const HsRequest := preload("../game/net/hs_request.gd")

## The real path minus the socket: two worlds, two managers, two bridges, two links with the
## RPC replaced by a queue, so the codec, the seal, the snapshots, the prediction and the
## reconciliation all run, in one process, in two physics worlds.
##
## [b]What this suite is for is the claims the game rests on over a wire.[/b] The blindfold is
## true on the wire: a seeker's snapshots carry no hider while the hiders hide (`HsInterest`),
## so a client that skipped drawing the black screen would still see nothing. A catch is the
## server's and the client is told: the side, the flag, and a hold its own prediction applies
## on exactly the ticks the server does, so a hider just caught is not predicted walking off
## while the server holds them. The sight meter is its owner's and nobody else's. Then
## everything else that crosses: the map document, the sides, a taunt, the result.
##
## Sections and checks are both counted; mg-smash-copter's notes say why the second matters.

const SECTIONS := 15
const CHECKS := 72

const CLIENT_PEER := 7
const SESSION := 42
const SERVER_TICK_RATE := 64
const CLIENT_ENGINE_TICK_RATE := 30
const SNAPSHOT_RATE := 30
const INPUT_LEAD := 3

## Two open stretches of the practice house's kitchen floor, five metres apart.
const KITCHEN_A := Vector3(3.0, 0.05, -3.0)
const KITCHEN_B := Vector3(8.0, 0.05, -3.0)

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

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


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("hideseek over the wire")
	print("")

	_test_the_codec()

	if await _build():
		await _test_a_client_joins()
		await _test_the_map_arrives()
		await _test_the_blindfold_is_on_the_wire()
		await _test_the_local_player_is_predicted()
		await _test_a_door_crosses()
		await _test_the_sight_meter_is_the_owners()
		await _test_a_catch_crosses()
		await _test_taunting()
		await _test_free_roam_crosses()
		await _test_the_round_ends()
		await _test_the_toys_cross()
		await _test_a_client_without_the_map()
		await _test_leaving()

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished or _sections_entered != SECTIONS:
		print("ERROR: %d of %d sections finished, %d expected." % [
			_sections_finished, _sections_entered, SECTIONS
		])
		code = 1

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		code = 1

	get_tree().quit(code)


# --- The codec ------------------------------------------------------------------

## Every encoder against its decoder. Nothing checks that two ends of a serialisation are
## inverses for you: dot-moderation once wrote "voice muted" and read back a warning.
func _test_the_codec() -> void:
	_section("every event decodes to what was encoded")

	var hello := HsEvents.read_hello(DotNetReader.new(HsEvents.write_hello(SESSION, 64, 1234, 40.0, 240.0, 2.0, 60.0)))
	_check(bool(hello["ok"]) and int(hello["player_id"]) == SESSION
		and absf(float(hello["round_seconds"]) - 240.0) < 0.1 and absf(float(hello["hide_seconds"]) - 40.0) < 0.05
		and absf(float(hello["beacon_period"]) - 2.0) < 0.02 and absf(float(hello["taunt_range"]) - 60.0) < 0.2,
		"HELLO", str(hello))

	var doc := HsCatalogue.practice()
	var sent := HsEvents.read_map(DotNetReader.new(HsEvents.write_map(HsMapDoc.encode(doc))))
	var decoded := HsMapDoc.decode(sent["encoded"]) if bool(sent["ok"]) else DotResult.fail(DotError.CODE_PARSE, "no map")
	_check(decoded.ok and HsMapDoc.digest(decoded.value) == HsMapDoc.digest(doc), "MAP carries the document whole")

	var join := HsEvents.read_join(DotNetReader.new(HsEvents.write_join(SESSION, 9, "Ada", HsGame.SEEKERS, null)))
	_check(bool(join["ok"]) and int(join["team"]) == HsGame.SEEKERS, "JOIN carries the side", str(join.get("team")))

	var round_info := HsEvents.read_round(DotNetReader.new(HsEvents.write_round(3, false, HsGame.HIDERS, "time: 2 stayed hidden")))
	_check(bool(round_info["ok"]) and int(round_info["winner"]) == HsGame.HIDERS
		and str(round_info["why"]) == "time: 2 stayed hidden", "ROUND carries the winning side and the sentence")

	var taunt := HsEvents.read_taunt(DotNetReader.new(HsEvents.write_taunt(SESSION, &"laugh", true)))
	_check(bool(taunt["ok"]) and taunt["taunt_id"] == &"laugh" and bool(taunt["forced"]), "TAUNT", str(taunt))

	var got := HsEvents.read_caught(DotNetReader.new(HsEvents.write_caught(SESSION, 900001, HsGame.CAUGHT_SIGHT)))
	var fell := HsEvents.read_caught(DotNetReader.new(HsEvents.write_caught(SESSION, 0, HsGame.CAUGHT_FELL)))
	_check(bool(got["ok"]) and int(got["by"]) == 900001 and got["how"] == HsGame.CAUGHT_SIGHT
		and bool(fell["ok"]) and int(fell["by"]) == 0 and fell["how"] == HsGame.CAUGHT_FELL,
		"CAUGHT carries who, by whom (or nobody) and how", "%s, %s" % [got, fell])

	var toys := HsEvents.read_toys(DotNetReader.new(HsEvents.write_toys(&"hs_camp", PackedInt64Array([7, 300, 9001]))))
	_check(bool(toys["ok"]) and toys["map_id"] == &"hs_camp" and toys["ids"] == PackedInt64Array([7, 300, 9001]),
		"TOYS carries the map and its toys' ids in order", str(toys))

	var asked := HsEvents.read_ask_taunt(DotNetReader.new(HsEvents.write_ask_taunt(&"whistle")))
	_check(bool(asked["ok"]) and asked["taunt_id"] == &"whistle", "a taunt request")

	var clock := HsEvents.read_clock(DotNetReader.new(HsEvents.write_clock(2, 12.5, 40.25, HsGame.Phase.SEEK, 3, 1, true)))
	_check(bool(clock["ok"]) and int(clock["phase"]) == HsGame.Phase.SEEK
		and absf(float(clock["seek_elapsed"]) - 40.25) < 0.1 and int(clock["hiders"]) == 3
		and int(clock["seekers"]) == 1, "CLOCK", str(clock))

	# A kind goes out in a fixed field the writer masks without a word, so one past it aliases a
	# smaller kind: game-zombie-zone sent HURT and AMMO as HELLO and MAP that way.
	# The largest MAP a reader accepts survives the event's own body cap. At 4096 a 4100-byte map
	# went out whole and was read back as no bytes, silently (hs_park with its toys).
	var biggest := PackedByteArray()
	biggest.resize(HsEvents.MAP_BYTES)
	var outgoing := HsEvent.new(HsEvents.Kind.MAP, HsEvents.write_map(biggest))
	var wire := DotNetWriter.new()
	outgoing._write(wire)
	var incoming := HsEvent.new()
	incoming._read(DotNetReader.new(wire.to_bytes()))
	var carried := HsEvents.read_map(incoming.reader())
	_check(bool(carried["ok"]) and (carried["encoded"] as PackedByteArray).size() == HsEvents.MAP_BYTES,
		"a MAP as large as a reader accepts fits in an event", "%d of %d bytes" % [(carried["encoded"] as PackedByteArray).size(), HsEvents.MAP_BYTES])

	_check(HsEvent.fits(), "every event kind fits the event's kind field",
		"%d kinds in %d bits" % [HsEvents.Kind.size(), HsEvent.KIND_BITS])
	_check(HsRequest.fits(), "every request kind fits the request's kind field",
		"%d kinds in %d bits" % [HsEvents.Ask.size(), HsRequest.KIND_BITS])
	_check(HsEvents.chat_kinds_fit(), "every chat kind fits the chat line's kind field",
		"%d kinds in %d bits" % [DotChatMessage.KIND_NAMES.size(), HsEvents.CHAT_KIND_BITS])

	_finished()


# --- Bringing both halves up ---------------------------------------------------------

func _build() -> bool:
	_section("bringing both halves up")
	var failed_before := _failed

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	# The client's own physics space: two processes would be two worlds, and one world holding
	# both copies of a map is two of every collider in the same cubic metres.
	var client_view := SubViewport.new()
	client_view.name = "ClientView"
	client_view.own_world_3d = true
	client_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(client_view)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	client_view.add_child(client_side)

	_server_game = _make_game(true, server_side)
	_client_game = _make_game(false, client_side)
	await get_tree().process_frame

	_check(_server_game.get_world_3d() != _client_game.get_world_3d(), "two physics worlds, as two processes would have")
	_check(_client_game.map_doc.is_empty() and _client_game.catalogue == null,
		"the client has no map and reads no map files; it will be sent one")

	Engine.physics_ticks_per_second = CLIENT_ENGINE_TICK_RATE

	_server_net = _make_manager(true, &"server", 1, server_side, SERVER_TICK_RATE)
	_client_net = _make_manager(false, &"client", CLIENT_PEER, client_side, CLIENT_ENGINE_TICK_RATE)
	# This harness stamps every command itself (`_tick + INPUT_LEAD`), not from the client's
	# clock, so the client must not ask for dot-net's input-lead report: steered by reports
	# about commands it never stamped, the clock runs away from them (only dot-net's cap
	# holds it). By the constant map, so this parses against a dot-net from before the report.
	var lead_bit := int((DotNetMessageRegistry as Script).get_script_constant_map().get("FEATURE_INPUT_LEAD", 0))
	_client_net.messages.features &= ~lead_bit

	_server_bridge = HsNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)

	_client_bridge = HsNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	var attached := _server_bridge.attach(_server_game, _server_net)
	var client_attached := _client_bridge.attach(_client_game, _client_net)
	_check(attached.ok and client_attached.ok, "both bridges attach")

	_server_bridge.open_link(server_side)
	_client_bridge.open_link(client_side)
	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(_server_net.messages.schema_hash() == _client_net.messages.schema_hash(), "both ends agree on the schema")

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send
	_client_bridge.rtt_source = func() -> float: return 40.0

	var _s := _server_net.start()
	var _c := _client_net.start()

	_client_bridge.map_received.connect(func(id: StringName) -> void:
		_heard["map"] = id)
	_client_bridge.taunt_received.connect(func(who: int, taunt_id: StringName, forced: bool) -> void:
		_heard["taunt"] = [who, taunt_id, forced])
	_client_bridge.caught_received.connect(func(who: int, by: int, how: StringName) -> void:
		_heard["caught"] = [who, by, how])
	_client_bridge.round_changed.connect(func(n: int, began: bool, winner: int, why: String) -> void:
		if not began:
			_heard["round_over"] = [n, winner, why])

	_stand_in = _server_bridge.add_bot("Stand-in")
	_second = _server_bridge.add_bot("Second")
	_check(_stand_in != null and _stand_in.is_bot and _second != null, "two stand-ins are seated before anybody joins")
	# Seated as stand-ins, driven by the suite: a stand-in hides and seeks on its own, and this
	# suite wants them where it puts them.
	_stand_in.is_bot = false
	_second.is_bot = false

	# Started AFTER the bridge exists, which is what the module does: a map laid out before
	# anything listened to `world_rebuilt` would be a map no client is ever sent.
	_server_game.start()
	_check(not _server_game.map_doc.is_empty(), "the server lays its map out on start")
	_finished()
	return _failed == failed_before


func _test_a_client_joins() -> void:
	_section("a client joins, and is told its side")
	# The READY first, as over ENet with loss: a client is PLAYING by its own reckoning once it has
	# sent `loaded`, on another channel, so its READY can reach the server before its seat. Kept,
	# and answered by the seat; a bridge that drops it never tells this client who it is.
	_client_bridge.ask_ready()
	_exchange()
	_check(_client_bridge.local_player_id != SESSION, "a READY before the seat is told nothing yet")
	var seated := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(seated.ok, "the server seats them")
	_exchange()
	_exchange()
	await _steps(6)

	_check(_client_bridge.local_player_id == SESSION, "the client is told who it is")
	_check(_client_game.tick_rate == SERVER_TICK_RATE, "it adopts the server's tick rate", "%d" % _client_game.tick_rate)
	_check(Engine.max_physics_steps_per_frame >= ceili(0.25 * float(SERVER_TICK_RATE)),
		"the engine's step cap covers a quarter second at the adopted rate",
		"%d steps, need %d" % [Engine.max_physics_steps_per_frame, ceili(0.25 * float(SERVER_TICK_RATE))])
	_check(_client_game.players.size() == 3, "it has a body for itself and for both stand-ins", "%d" % _client_game.players.size())

	await _hide_with(HsGame.SEEKERS)
	_check(_client_game.team_of(_me()) == HsGame.SEEKERS and _client_game.team_of(_stand_in.player_id) == HsGame.HIDERS,
		"the client knows who is seeking and who is hiding")
	_check(_client_game.phase == HsGame.Phase.HIDE, "and that the hiders are hiding")

	# The online board is dot-server's roster (sessions only); the stand-ins must be added by the
	# game. Both stand-ins here have is_bot false on the client, as in a browser.
	var client_script: GDScript = load("res://game/hs_client.gd")
	var roster := {"players": [{"id": SESSION, "name": "Ada", "ping": 20, "seconds": 5, "bot": false}]}
	client_script.call("add_bot_rows", roster, _client_game)
	client_script.call("add_bot_rows", roster, _client_game)
	var board_ids: Array = []
	for r in (roster["players"] as Array):
		board_ids.append(str((r as Dictionary)["id"]))
	_check((roster["players"] as Array).size() == 3 and board_ids.has(String(_stand_in.player_id))
		and board_ids.has(String(_second.player_id)),
		"the online board gains a row for each stand-in the roster lacks, once however often it is built", str(board_ids))
	_check(_client_game.team_of(_stand_in.player_id) == HsGame.HIDERS and _client_game.team_of(_second.player_id) == HsGame.HIDERS
		and board_ids.count(String(_stand_in.player_id)) == 1,
		"and the stand-in rows sit on the hiders' side of the board")
	_finished()


func _test_the_map_arrives() -> void:
	_section("the map arrives, as the document the server built")
	_check(not _client_game.map_doc.is_empty(), "the client built a map")
	_check(HsMapDoc.digest(_client_game.map_doc) == HsMapDoc.digest(_server_game.map_doc),
		"the same document, to the byte", HsMapDoc.digest(_client_game.map_doc))
	_check(_client_game.map.props.size() == _server_game.map.props.size() and _client_game.map.props.size() > 0,
		"every prop in it", "%d" % _client_game.map.props.size())
	_check(_heard.has("map"), "and the client said so")
	_finished()


## The black screen is the HUD's; this is the wire's half of it.
func _test_the_blindfold_is_on_the_wire() -> void:
	_section("a seeker is told nothing about the hiders while they hide")
	var copy: HsPlayer = _client_game.players[_stand_in.player_id]
	var was := copy.global_position
	_stand_in.place_at(Vector3(-3.0, 0.05, -2.0), 0.0)
	await _steps(20)
	_check(copy.global_position.distance_to(was) < 0.05 and copy.global_position.distance_to(_stand_in.global_position) > 1.0,
		"the hider moved on the server and the seeker's copy did not",
		"%.2f m from where it was" % copy.global_position.distance_to(was))

	_server_game._set_phase(HsGame.Phase.SEEK)
	await _steps(20)
	_check(copy.global_position.distance_to(_stand_in.global_position) < 0.3,
		"the moment the seekers are let go, the hider is where it is",
		"%.2f m apart" % copy.global_position.distance_to(_stand_in.global_position))
	_finished()


func _test_the_local_player_is_predicted() -> void:
	_section("a hider is predicted, and the server agrees")
	await _hide_with(HsGame.HIDERS)
	var mine := _mine()
	var server_me := _server_me()
	server_me.place_at(Vector3(-2.0, 0.05, 0.0), 0.0)
	await _steps(20)
	var before := mine.controller.state.position
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _step(forward)
	_check(mine.controller.state.position.distance_to(before) > 0.01,
		"a key moves the client's own player on the tick it is pressed")
	await _steps(20, forward)
	await _steps(24)
	var apart := mine.controller.state.position.distance_to(server_me.controller.state.position)
	_check(apart < 0.25, "and after running, the two ends agree", "%.3f m" % apart)
	_finished()


## A door is the server's: a use is one event, a door and the tick it went, and the client
## poses it from that and predicts itself against it. The practice house's garden door.
func _test_a_door_crosses() -> void:
	_section("a door is the server's, and the client predicts against it")
	var heard: Array = []
	_client_bridge.door_received.connect(func(index: int, open: bool, tick: int) -> void:
		heard.append([index, open, tick]))
	var server_doors := _server_game.map.doors
	var client_doors := _client_game.map.doors
	var server_me := _server_me()
	var mine := _mine()
	server_me.place_at(Vector3(8.6, 0.05, 0.0), -90.0)
	await _steps(20)

	var _opened := _server_game.use_door(1, _me())
	await _steps(SERVER_TICK_RATE)
	_check(heard.size() == 1 and int(heard[0][0]) == 1 and bool(heard[0][1]) and client_doors.is_open(1),
		"the client is told a door opened, and on which tick", str(heard))
	var server_panel := (server_doors.doors[1]["body"] as Node3D).global_transform
	var client_panel := (client_doors.doors[1]["body"] as Node3D).global_transform
	_check(server_panel.origin.distance_to(client_panel.origin) < 0.05
		and server_panel.basis.z.dot(client_panel.basis.z) > 0.999,
		"and poses it where the server has it", "%.3f m apart" % server_panel.origin.distance_to(client_panel.origin))

	var _shut := _server_game.use_door(1, _me())
	await _steps(SERVER_TICK_RATE)
	var east := DotFpsCommand.new()
	east.yaw = -90.0
	east.move = Vector2(0.0, 1.0)
	await _steps(SERVER_TICK_RATE * 2, east)
	await _steps(24)
	var apart := mine.controller.state.position.distance_to(server_me.controller.state.position)
	_check(not client_doors.is_open(1) and mine.controller.state.position.x < 10.1
		and server_me.controller.state.position.x < 10.1 and apart < 0.25,
		"a shut door stops the client's own prediction where it stops the server",
		"client x %.2f, server x %.2f, %.3f m apart" % [mine.controller.state.position.x, server_me.controller.state.position.x, apart])
	_finished()


## The toys are the server's physics, drawn on the client from snapshots: the practice house's
## garden has a beach ball, a football, a tyre and a lamp on a switch.
func _test_the_toys_cross() -> void:
	_section("the toys are the server's, and every client sees them where the server has them")
	var server_toys := _server_game.map.toys
	var client_toys := _client_game.map.toys
	_check(server_toys.count() == 5 and client_toys.count() == server_toys.count()
		and _server_bridge.toy_count() == server_toys.count() and _client_bridge.toy_count() == client_toys.count(),
		"both ends build the map's toys, and each is an entity on both", "%d and %d, %d and %d replicated" % [
			server_toys.count(), client_toys.count(), _server_bridge.toy_count(), _client_bridge.toy_count()])
	var ball := server_toys.toy(0)
	var copy := client_toys.toy(0)
	_check(not ball.body.freeze and copy.body.freeze and not copy.authoritative,
		"the server simulates the beach ball; the client's is frozen and drawn")

	# During the hide a seeker is told nothing a hider moved: a ball kicked then stays put.
	await _hide_with(HsGame.SEEKERS)
	var was := copy.body.global_position
	var _kicked := server_toys.use(0, ball.body.global_position + Vector3(-1.0, 1.4, 0.0), Vector3(1.0, -0.3, 0.0))
	await _steps(40)
	_check(ball.body.global_position.distance_to(was) > 1.0 and copy.body.global_position.distance_to(was) < 0.05,
		"a seeker's client is not told a ball moved while the hiders hide",
		"server %.2f m, client %.2f m" % [ball.body.global_position.distance_to(was), copy.body.global_position.distance_to(was)])

	_server_game._set_phase(HsGame.Phase.SEEK)
	await _steps(30)
	_check(copy.body.global_position.distance_to(ball.body.global_position) < 0.3,
		"and once the seekers are let go, it is where the server has it",
		"%.2f m apart" % copy.body.global_position.distance_to(ball.body.global_position))

	var _again := server_toys.use(0, ball.body.global_position + Vector3(0.0, 1.4, 1.0), Vector3(0.0, -0.3, -1.0))
	for _i in range(20):
		await _step()
	var moving := ball.body.linear_velocity.length()
	await _steps(30)
	_check(moving > 0.5 and copy.body.global_position.distance_to(ball.body.global_position) < 0.4,
		"a ball in motion is followed, a snapshot behind", "moving %.1f m/s, %.2f m apart" % [moving, copy.body.global_position.distance_to(ball.body.global_position)])

	var lamp := server_toys.toy(3)
	var switch := server_toys.toy(4)
	var was_lit := lamp.on
	var _pressed := server_toys.use(4, switch.global_position + Vector3(0.0, 1.5, 1.0), Vector3(0.0, -0.4, -1.0))
	await _steps(30)
	_check(lamp.on != was_lit and client_toys.toy(3).on == lamp.on and client_toys.toy(4).count == switch.count and switch.count > 0,
		"the switch is pressed on the server, and the client's lamp goes out with it", "lit %s, count %d" % [client_toys.toy(3).on, client_toys.toy(4).count])
	_finished()


## A client whose MAP never came (one past a browser socket's buffer, or a format behind) still
## reads every snapshot. dot-net stops reading one at the first entity a client does not know,
## so the TOYS for a map it has not built are registered as mirrors anyway, and paired with
## its toys when the map arrives. Armed: registering them only once the map was built here
## froze every player seated after the toys.
func _test_a_client_without_the_map() -> void:
	_section("a client without the server's map still follows every player, and pairs the toys when it comes")
	_server_game._set_phase(HsGame.Phase.SEEK)
	await _steps(4)
	# The server lays out another map (the same house under another id) and this client is sent
	# its TOYS but not its MAP, after losing its own map: a joiner's whose MAP never arrived.
	var other := _server_game.map_doc.duplicate(true)
	other["id"] = "practice_again"
	var ready_peers: Dictionary = _server_bridge.get("_ready_peers")
	ready_peers.erase(CLIENT_PEER)
	var built := _server_game.build_map(other)
	ready_peers[CLIENT_PEER] = true
	_client_game.map.clear()
	_server_bridge._tell(CLIENT_PEER, HsEvents.Kind.TOYS, _server_bridge.get("_toys_body"))
	# Seated after the toys, so listed after them in every snapshot.
	var third := _server_bridge.add_bot("Third")
	third.is_bot = false
	await _steps(8)
	var ids: Array = []
	for behaviour: Node in (_server_bridge.get("_toy_nets") as Array):
		ids.append((behaviour.get("identity") as DotNetIdentity).net_id)
	var known := ids.filter(func(id: int) -> bool: return _client_net.registry.has(id)).size()
	_check(built.ok and ids.size() == 5 and known == ids.size() and _client_bridge.toy_count() == 0,
		"the client registers the new map's toys at once, paired with nothing", "%d of %d known, %d paired" % [known, ids.size(), _client_bridge.toy_count()])

	# Every snapshot read to its end: one abandoned at an unknown toy never says it was applied.
	var applied := [0]
	var count_applied := func(_t: int) -> void: applied[0] += 1
	_client_net.snapshot_applied.connect(count_applied)
	var received := _client_net.stats.snapshots_received
	third.place_at(KITCHEN_B, 0.0)
	await _steps(30)
	_client_net.snapshot_applied.disconnect(count_applied)
	received = _client_net.stats.snapshots_received - received
	var copy: HsPlayer = _client_game.players.get(third.player_id)
	_check(copy != null and copy.global_position.distance_to(third.global_position) < 0.3 and received > 10 and applied[0] == received,
		"and reads every snapshot to its end, a player seated after them included", "%s, %d of %d snapshots applied" % [
			"no copy" if copy == null else "%.2f m apart" % copy.global_position.distance_to(third.global_position), applied[0], received])

	# The MAP arrives late: the same mirrors are handed the toys, nothing registered again.
	_server_bridge._tell(CLIENT_PEER, HsEvents.Kind.MAP, _server_bridge.get("_map_body"))
	await _steps(6)
	var still := ids.filter(func(id: int) -> bool: return _client_net.registry.has(id)).size()
	_check(_client_game.map.id() == &"practice_again" and _client_bridge.toy_count() == 5 and still == ids.size()
		and _client_bridge.toy_entities() == ids.size(),
		"when the map comes, the same mirrors are paired with its toys", "%s, %d paired" % [_client_game.map.id(), _client_bridge.toy_count()])

	var ball := _server_game.map.toys.toy(0)
	var mirror := _client_game.map.toys.toy(0)
	var _kicked := _server_game.map.toys.use(0, ball.body.global_position + Vector3(-1.0, 1.4, 0.0), Vector3(1.0, -0.3, 0.0))
	await _steps(50)
	_check(ball.body.global_position.distance_to(ball.rest.origin) > 1.0 and mirror.body.global_position.distance_to(ball.body.global_position) < 0.3,
		"and a ball kicked on the server is followed on the client", "%.2f m apart" % mirror.body.global_position.distance_to(ball.body.global_position))

	# A TOYS again (a resend, or a new set): the old mirrors leave the tree at once as well as
	# the registry, or a new identity beside a freed one collects it and the next snapshot breaks.
	_server_bridge._tell(CLIENT_PEER, HsEvents.Kind.TOYS, _server_bridge.get("_toys_body"))
	await _steps(2)
	var holder: Node = _client_bridge.get("_toy_holder")
	_check(holder != null and holder.get_child_count() == 5 and _client_bridge.toy_count() == 5,
		"a second TOYS replaces the mirrors, and nothing of the first is left", "%d under the holder" % (holder.get_child_count() if holder != null else -1))
	_finished()


## Under the sight rule a hider's meter tells them they are being watched; it would tell a
## seeker which way to look, so it goes to its owner alone.
func _test_the_sight_meter_is_the_owners() -> void:
	_section("the sight meter reaches the one being watched, and nobody else")
	_server_game._set_phase(HsGame.Phase.SEEK)
	_server_game.config.catch_mode = HsConfig.Catch.SIGHT
	_server_game.config.sight_seconds = 30.0
	var server_me := _server_me()
	server_me.place_at(KITCHEN_A, 0.0)
	_second.place_at(KITCHEN_A + Vector3(0.0, 0.0, 1.2), 0.0)
	_stand_in.place_at(KITCHEN_B, 0.0)
	_look(_stand_in, KITCHEN_A + Vector3(0.0, 1.2, 0.6))
	await _steps(SERVER_TICK_RATE)
	var theirs: HsPlayer = _client_game.players[_second.player_id]
	_check(server_me.sight_meter > 0.01 and _mine().sight_meter > 0.01,
		"a hider being watched is told how close they are", "%.3f on the server, %.3f here" % [server_me.sight_meter, _mine().sight_meter])
	_check(_second.sight_meter > 0.01 and theirs.sight_meter == 0.0,
		"and nobody else is told theirs", "%.3f on the server, %.3f here" % [_second.sight_meter, theirs.sight_meter])
	_server_game.config.catch_mode = HsConfig.Catch.TOUCH
	_finished()


## The claim: a catch is the server's, and the client's own prediction holds a new seeker still
## on the ticks the server does.
func _test_a_catch_crosses() -> void:
	_section("a catch is the server's, and the new seeker is held on both ends")
	var server_me := _server_me()
	var mine := _mine()
	_stand_in.place_at(KITCHEN_B, 0.0)
	await _steps(4)
	var _c := _server_game.catch(_me(), _stand_in.player_id, HsGame.CAUGHT_TAG)
	await _steps(6)
	_check(_heard.has("caught") and int(_heard["caught"][0]) == SESSION
		and int(_heard["caught"][1]) == HsNetBridge.session_of(_stand_in.player_id) and _heard["caught"][2] == HsGame.CAUGHT_TAG,
		"the client is told who was caught, by whom and how", str(_heard.get("caught")))
	_check(_client_game.team_of(_me()) == HsGame.SEEKERS, "and that it is a seeker now")
	_check(mine.caught, "and that it was caught")

	var before := mine.controller.state.position
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _steps(12, forward)
	_check(mine.controller.state.position.distance_to(before) < 0.05,
		"held: a key does not move the caught player's own prediction",
		"%.3f m" % mine.controller.state.position.distance_to(before))

	await _steps(SERVER_TICK_RATE, forward)
	await _steps(24)
	var apart := mine.controller.state.position.distance_to(server_me.controller.state.position)
	_check(mine.controller.state.position.distance_to(before) > 1.0 and apart < 0.25,
		"and let go together", "%.3f m moved, %.3f m apart" % [mine.controller.state.position.distance_to(before), apart])
	_finished()


func _test_taunting() -> void:
	_section("a taunt is asked for, and the server's answer comes back")
	await _hide_with(HsGame.HIDERS)
	_server_game._set_phase(HsGame.Phase.SEEK)
	await _steps(int(_server_game.config.taunt_cooldown * SERVER_TICK_RATE) + 4)
	var server_me := _server_me()
	var points := server_me.points
	_client_bridge.ask_taunt()
	await _steps(4)
	_check(_heard.has("taunt") and int(_heard["taunt"][0]) == SESSION and not bool(_heard["taunt"][2]),
		"a taunt is played, and everybody is told who and which", str(_heard.get("taunt")))
	_check(server_me.points - points == _server_game.config.taunt_points, "and is paid for",
		"+%d" % (server_me.points - points))
	_finished()


func _test_free_roam_crosses() -> void:
	_section("free roam is asked for, the server decides, and the mode crosses the wire")
	await _hide_with(HsGame.HIDERS)
	var spectate := _server_game.spectate
	var key := String(_me())
	# Out for real: a caught hider on a server where the caught sit the round out.
	_server_game.config.caught_become_seekers = false
	_server_game._set_phase(HsGame.Phase.SEEK)
	await _steps(4)
	var _caught := _server_game.catch(_me(), _stand_in.player_id, HsGame.CAUGHT_TAG)
	await _steps(SERVER_TICK_RATE * 4)
	_check(spectate.is_spectating(_me()) and not spectate.is_roaming(_me()),
		"a watcher starts on a player, not in a free camera",
		str(spectate.mode_of(_me())))
	_check(_client_game.spectate.is_spectating(_me()), "and the client's mirror is watching too")

	_client_bridge.ask_roam()
	await _steps(6)
	_check(spectate.is_roaming(_me()), "the server puts a watcher who asks into the free camera")
	_check(_client_game.spectate.is_roaming(_me()), "and the client's mirror is told ROAMING")

	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(_me()) and not _client_game.spectate.is_roaming(_me()),
		"the same key hands the camera back to a player on both ends")

	_server_game.spectate_rules.allow_roaming = false
	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(_me()) and not _client_game.spectate.is_roaming(_me()),
		"mp_freeroam 0 refuses the request")
	_server_game.spectate_rules.allow_roaming = true

	_server_game.spectate_rules.force_camera = 1
	_client_bridge.ask_roam()
	await _steps(6)
	_check(not spectate.is_roaming(_me()), "mp_forcecamera 1 refuses it too")
	_server_game.spectate_rules.force_camera = 0

	_client_bridge.ask_roam()
	await _steps(6)
	_server_game.spectate_rules.allow_roaming = false
	await _steps(6)
	_check(not spectate.is_roaming(_me()) and not _client_game.spectate.is_roaming(_me()),
		"switching mp_freeroam off mid-roam puts the roamer back on a player on both ends")
	_server_game.spectate_rules.allow_roaming = true
	_server_game.config.caught_become_seekers = true
	# Back in the state the next section expects: a hider in the seek, as the taunt left it.
	await _hide_with(HsGame.HIDERS)
	_server_game._set_phase(HsGame.Phase.SEEK)
	await _steps(4)
	_finished()


func _test_the_round_ends() -> void:
	_section("the round ends, and the client is told who won and why")
	var _a := _server_game.catch(_me(), _stand_in.player_id, HsGame.CAUGHT_TAG)
	var _b := _server_game.catch(_second.player_id, _stand_in.player_id, HsGame.CAUGHT_TAG)
	await _steps(6)
	_check(_heard.has("round_over") and int(_heard["round_over"][1]) == HsGame.SEEKERS,
		"the seekers won, and the client is told", str(_heard.get("round_over")))
	_check(_heard.has("round_over") and str(_heard["round_over"][2]) != "", "with the server's own sentence",
		str(_heard.get("round_over")))
	_finished()


func _test_leaving() -> void:
	_section("leaving")
	_server_bridge.remove_peer(CLIENT_PEER)
	await _steps(4)
	_check(not _server_game.players.has(_me()), "the server lets them go")
	_check(_server_bridge.describe()["ready_peers"] == 0, "and stops talking to them")
	_finished()


## Turns a server-side stand-in to look at [param target], and keeps it looking.
func _look(player: HsPlayer, target: Vector3) -> void:
	var look := target - player.eye_position()
	var command := DotFpsCommand.new()
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	player.controller.state.yaw = command.yaw
	player.controller.state.pitch = command.pitch
	player.controller.apply_command(command)

# --- Helpers --------------------------------------------------------------------

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


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return

	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)

extends Node
## The signals, state and wire helpers of [HsNetBridge] (a base layer, split off for size); never used on its own.


const HsEvent := preload("hs_event.gd")
const HsEvents := preload("hs_events.gd")
const HsNetCommand := preload("hs_net_command.gd")
const HsNetLink := preload("hs_net_link.gd")
const HsPlayerNet := preload("hs_player_net.gd")
const HsToyNet := preload("hs_toy_net.gd")
const HsInterest := preload("hs_interest.gd")
const HsRequest := preload("hs_request.gd")

const HsGame := preload("../hs_game.gd")
const HsMapDoc := preload("../hs_map_doc.gd")
const HsPlayer := preload("../hs_player.gd")

const CHANNEL := "hs.net"

## Bytes of acknowledgement in front of every input packet. [method DotNetManager.encode_ack].
const ACK_BYTES := 4

## Commands in every input packet: this tick's and the four before it, so a lost packet costs no tick unless the next four are lost too.
## Over ENet one command a packet ran the server on the previous command for every drop; measured 80% right at 20% loss with one copy, 99-100% with three.
const INPUT_COPIES := 5

## How often the round clock goes out, in ticks: twice a second, since it changes only on a catch or a second passing.
## The client advances the clock between messages ([method _apply_clock]).
const CLOCK_EVERY := 32

## The client has been told who it is. [param player_id] is the session id.
signal hello_received(player_id: int)

## Somebody joined, left or changed sides. Client side; the HUD and a scoreboard read it.
signal roster_changed(player_id: int)

## A round began or ended. [param why] is the server's sentence about who won.
signal round_changed(number: int, began: bool, winner: int, why: String)

## The round changed half. Client side.
signal phase_received(phase: int)

## Somebody died, and what did it.
signal death_received(player_id: int, by: int, why: StringName)

signal notice_received(text: String)

## Client side: the server moved this client's own camera. [param mode] is
## [enum DotSpectatorView.Mode]; the view has already been adopted by the world's mirror.
signal spectate_received(viewer: int, mode: int, target: int)

## Client side: the map was rebuilt from what the server sent. The HUD names it.
signal map_received(map_id: StringName)

## Client side: somebody taunted.
signal taunt_received(player_id: int, taunt_id: StringName, forced: bool)

## Client side: a door set off, on the server's [param tick].
signal door_received(index: int, open: bool, tick: int)

## Client side: a hider was caught. [param by] is the seeker's session, 0 for a fall.
signal caught_received(player_id: int, by: int, how: StringName)

## Somebody pressed Enter. Server side. The bridge carries chat and decides nothing: who may say what is [DotChatRouter]'s.
signal say_requested(peer_id: int, channel_id: StringName, text: String)

## A voice frame arrived. Server side; the payload is unparsed and must not be trusted —
## [method DotVoiceRouter.relay] is what stamps the speaker, from the peer id below.
signal voice_requested(peer_id: int, payload: PackedByteArray)

## Client side: one routed line, and one voice frame.
signal chat_received(wire: Dictionary)
signal voice_arrived(payload: PackedByteArray)

var game: HsGame = null
var net: DotNetManager = null
var link: HsNetLink = null

## Which session this process is. Zero on a server.
var local_player_id: int = 0

## Where the clock learns the link's length in ms; dot-net cannot measure a transport, dot-server's heartbeat does ([method DotClientLink.ping_ms]).
## With no sample the clock assumes an instant link and stamps every command for a tick already simulated, so all are discarded as late.
var rtt_source: Callable = Callable()

## Where a voice frame goes on the server. Assigned by [DotGameModule] to the services
## layer's `relay_voice`, because the bridge is the only thing that names both ends.
var voice_relay_fn: Callable = Callable()

## `func(session_id: int) -> DotAvatar`: what a player looks like, asked once as they are
## seated. Assigned by the module, which is what has the identity layer; unset, or answering
## null, is the stock person, which is what everybody was before there was one.
var avatar_fn: Callable = Callable()

var _entities: Node = null

## session id -> [HsPlayerNet].
var _behaviours: Dictionary = {}

## The next session id for somebody the world made itself, well above anything dot-server issues. Every wire id is `u<session>` and a player
## called `bot` parses to session ZERO, so two bots would be one entry in [member _behaviours] and carry dot-net's broadcast address.
const FIRST_BOT_SESSION := 900000

var _next_bot_session: int = FIRST_BOT_SESSION

var _player_of_peer: Dictionary = {}
var _peer_of_player: Dictionary = {}
var _ready_peers: Dictionary = {}
## Carries the game's profile runtime over this manager; null when the types would not register.
var profile_link: DotNetProfileLink = null
## Server: peers whose READY came before their seat ([method add_player]). Over ENet with loss READY can overtake `loaded`, and a READY
## dropped here left that client waiting for a world for ever. Admitted when seated.
var _ready_unseated: Dictionary = {}

var _tick: int = 0
var _game_ticked_for: int = -1

## Server only: whether [method DotNetManager.server_tick] is on the stack, and the net ids let go of meanwhile. The world ticks inside the first
## behaviour's `_net_simulate`, so a player removed there would get a fresh lag-compensation track recorded after the registry forgot it,
## and nothing would forget it again. Forgotten here once the manager has let go of its list.
var _in_server_tick := false
var _unregistered_in_tick: Array[int] = []
var _client_ticked_for: int = -1

## The map the clients were last sent, so a late joiner is sent the same bytes.
var _map_body: PackedByteArray = PackedByteArray()

## The map's toys on the wire, one behaviour per toy in toy order, and the TOYS event that
## names their net ids (kept for a joiner, as [member _map_body] is).
var _toy_nets: Array = []
var _toys_body: PackedByteArray = PackedByteArray()

## Client: the map the last TOYS was for. Its mirrors are registered the moment it arrives and
## handed this end's toys when this end has built that map ([method _pair_pending_toys]).
var _toys_map: StringName = &""

## Client: where the mirrors live, which is not under the toys: they are registered before this
## end's map may exist, and stay registered through a map change.
var _toy_holder: Node3D = null


## How every dot-net message reaches a peer, routed by DELIVERY: snapshots are unreliable and go on the snapshot call; the rest are reliable,
## events from the server, requests from the client. Sending all as events silently drops every client request.
func _send(peer_id: int, payload: PackedByteArray, delivery: int) -> void:
	if link == null:
		return

	if delivery == DotNetMessage.Delivery.UNRELIABLE:
		link.send_snapshot(peer_id, payload)
	elif net.is_server:
		link.send_event(peer_id, payload)
	else:
		link.send_request(payload)



static func player_key(session_id: int) -> StringName:
	return StringName("u%d" % session_id)


## A stand-in by its id alone: a client's copy of a bot has `is_bot` false (only the server's
## bridge sets it), so the board tells one by the session range `add_bot` allocates from.
static func is_bot_key(id: StringName) -> bool:
	return session_of(id) >= FIRST_BOT_SESSION


static func session_of(id: StringName) -> int:
	return String(id).trim_prefix("u").to_int()


func peer_for_player(session_id: int) -> int:
	return int(_peer_of_player.get(session_id, 0))


func player_for_peer(peer_id: int) -> int:
	return int(_player_of_peer.get(peer_id, 0))


func _build_entity(player: HsPlayer, peer_id: int) -> DotNetIdentity:
	# The behaviour is added BEFORE the identity: [DotNetIdentity] collects behaviours in
	# `_ready` by walking the subtree, and one added afterwards would never be found.
	var behaviour := HsPlayerNet.new()
	behaviour.name = "Net"
	behaviour.player = player
	behaviour.bridge = self
	player.add_child(behaviour)

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = peer_id
	# SHARED: the server corrects, the owner predicts. SERVER would put a player's own
	# movement a round trip behind their keys, and a hider dashing for a cupboard would arrive
	# a round trip after the seeker turned the corner.
	identity.authority = DotNetIdentity.Authority.SHARED
	# [b]Relevant to everybody, except a hider to a seeker while the hiders hide[/b] — see
	# [HsInterest]. Not `always_relevant`, which bypasses the rule; and nothing lingers, or the
	# first second of the hide would still be sent.
	identity.always_relevant = false
	identity.interest_linger_sec = 0.0
	player.add_child(identity)

	var session_id := session_of(player.player_id)
	_behaviours[session_id] = behaviour

	return identity


## Server side. See [member _in_server_tick] for why an id let go of mid-tick is remembered.
func _unregister(net_id: int) -> void:
	net.registry.unregister(net_id)

	if _in_server_tick:
		_unregistered_in_tick.append(net_id)


func _release_entity(session_id: int) -> void:
	var behaviour: HsPlayerNet = _behaviours.get(session_id)
	_behaviours.erase(session_id)

	if behaviour == null or behaviour.identity == null or net == null:
		return

	_unregister(behaviour.identity.net_id)



## Server: an entity for each of the map's toys, and TOYS naming them, after MAP.
func _register_toys() -> void:
	_release_toys()
	var box := game.map.toys if game != null and game.map != null else null
	var ids := PackedInt64Array()
	if box != null:
		for toy in box.toys:
			var behaviour := _toy_entity(toy, toy, 0)
			if behaviour == null:
				break
			ids.append(behaviour.identity.net_id)
	_toys_body = HsEvents.write_toys(game.map.id() if game != null and game.map != null else &"", ids)
	_broadcast(HsEvents.Kind.TOYS, _toys_body)


## A toy's behaviour and identity under [param parent] (the toy on the server, a holder of the client's own), registered under [param net_id]
## (0 allocates one: the server). Null when the registry refused it. The behaviour before the identity, which collects behaviours in `_ready`.
func _toy_entity(toy: DotPropToy, parent: Node, net_id: int) -> HsToyNet:
	var behaviour := HsToyNet.new()
	behaviour.name = "Net"
	behaviour.toy = toy
	var holder := Node3D.new() if parent != toy else null
	if holder != null:
		holder.name = "Toy%d" % _toy_nets.size()
		parent.add_child(holder)
	var at: Node = holder if holder != null else toy
	at.add_child(behaviour)
	if net.is_server:
		behaviour.pull()

	var identity := DotNetIdentity.new()
	identity.name = "Identity"
	identity.owner_peer_id = 0
	identity.authority = DotNetIdentity.Authority.SERVER
	# Relevant to everybody but a seeker while the hiders hide ([HsInterest]): a ball rolling
	# away from where a hider just walked is a hider on the wire.
	identity.always_relevant = false
	identity.interest_linger_sec = 0.0
	at.add_child(identity)

	var registered := net.registry.register(identity, net_id, net.clock.tick, net.config)
	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a toy", {"toy": _toy_nets.size(), "error": str(registered.error)})
		for node: Node in [behaviour, identity]:
			at.remove_child(node)
			node.queue_free()
		if holder != null:
			parent.remove_child(holder)
			holder.queue_free()
		return null
	_toy_nets.append(behaviour)
	return behaviour


## Every toy entity out of the registry [b]and out of the tree at once[/b]: a new identity on
## the same toy collects every behaviour under it in its `_ready`, and a freed one still found
## there broke the next snapshot (game-playground found it). A map change, or a new TOYS.
func _release_toys() -> void:
	for behaviour: HsToyNet in _toy_nets:
		if not is_instance_valid(behaviour):
			continue
		if behaviour.identity != null and net != null and net.registry.has(behaviour.identity.net_id):
			if net.is_server:
				_unregister(behaviour.identity.net_id)
			else:
				net.registry.unregister(behaviour.identity.net_id)
		var at := behaviour.get_parent()
		for node: Node in [behaviour.identity, behaviour]:
			if node != null and is_instance_valid(node) and node.get_parent() != null:
				node.get_parent().remove_child(node)
				node.queue_free()
		if at != null and _toy_holder != null and at.get_parent() == _toy_holder:
			_toy_holder.remove_child(at)
			at.queue_free()
	_toy_nets.clear()


## Client: TOYS. A mirror for every id at once, whether this end has built that map or not: dot-net stops reading a snapshot at the first
## entity it does not know, so a client whose MAP never arrived had every later player frozen. Paired with this end's toys by index when both are here.
func _apply_toys(reader: DotNetReader) -> void:
	var told := HsEvents.read_toys(reader)
	if not bool(told["ok"]) or net == null or net.is_server:
		return
	_release_toys()
	if _toy_holder == null:
		_toy_holder = Node3D.new()
		_toy_holder.name = "ToyMirrors"
		add_child(_toy_holder)
	_toys_map = told["map_id"]
	for id in (told["ids"] as PackedInt64Array):
		var _mirror := _toy_entity(null, _toy_holder, int(id))
	_pair_pending_toys()


## Client: each mirror handed this end's toy at its index, once this end's map is the one TOYS
## named; none while it is not (a map on the way, or one that never came).
func _pair_pending_toys() -> void:
	if net == null or net.is_server or game == null:
		return
	# No id is a server from before TOYS carried one: the map it means is the last MAP.
	var same_map := game.map != null and (_toys_map == &"" or game.map.id() == _toys_map)
	var box := game.map.toys if same_map and game.map.toys != null else null
	if box != null and box.count() != _toy_nets.size():
		DotLog.warn(CHANNEL, "the server's map has a different number of toys", {"server": _toy_nets.size(), "here": box.count()})
	for i in range(_toy_nets.size()):
		var behaviour: HsToyNet = _toy_nets[i]
		if is_instance_valid(behaviour):
			behaviour.toy = box.toy(i) if box != null else null


## Client: the old map's toys are about to go; the mirrors stay registered, without them.
func _unpair_toys() -> void:
	for behaviour: HsToyNet in _toy_nets:
		if is_instance_valid(behaviour):
			behaviour.toy = null


## How many toy entities this end has registered (a client's paired or not). For a check.
func toy_entities() -> int:
	return _toy_nets.size()


## How many toys this end replicates: a client's, mirrors paired with a toy. For a check.
func toy_count() -> int:
	var n := 0
	for behaviour: HsToyNet in _toy_nets:
		if is_instance_valid(behaviour) and (net.is_server or behaviour.toy != null):
			n += 1
	return n


func _clock_body() -> PackedByteArray:
	return HsEvents.write_clock(
		game.round_number,
		game.phase_elapsed,
		game.seek_elapsed,
		game.phase,
		game.alive_on(HsGame.HIDERS),
		game.alive_on(HsGame.SEEKERS),
		game.sides_are_playable()
	)


## [param packet] and the commands before it from the local replay history, oldest first,
## for one input packet. See [constant INPUT_COPIES].
func _input_copies(packet: DotNetInput) -> Array:
	var batch: Array = Array(net.local_inputs().recent(INPUT_COPIES, packet.tick - 1))
	batch = batch.slice(maxi(0, batch.size() - (INPUT_COPIES - 1)))
	batch.append(packet)
	return batch


func _join_body(session_id: int) -> PackedByteArray:
	var behaviour: HsPlayerNet = _behaviours.get(session_id)

	if behaviour == null or behaviour.identity == null or behaviour.player == null:
		return PackedByteArray()

	return HsEvents.write_join(
		session_id,
		behaviour.identity.net_id,
		behaviour.player.display_name,
		game.team_of(behaviour.player.player_id),
		behaviour.player.avatar
	)


## To every peer that has said it is ready, and nobody else. An empty body is dropped rather than sent: it means an encoder was handed something
## already gone, and a zero-length event decodes on the far end as a valid message about nothing.
func _broadcast(kind: int, body: PackedByteArray) -> void:
	if net == null or not net.is_server or body.is_empty():
		return

	for peer_id in _ready_peers.keys():
		_tell(int(peer_id), kind, body)


## One peer, and never zero: `net.send(msg, 0)` is a BROADCAST in dot-net, so passing a missing peer id straight
## through would send one player's private message to everybody.
func _tell(peer_id: int, kind: int, body: PackedByteArray) -> void:
	if peer_id <= 0 or net == null or body.is_empty():
		return

	net.send(HsEvent.new(kind, body), peer_id)



func ask_ready() -> void:
	_ask(HsEvents.Ask.READY, PackedByteArray([0]))


## Says something. The server decides what it means and who hears it.
func ask_say(channel_id: StringName, text: String) -> void:
	if text.strip_edges() == "":
		return

	_ask(HsEvents.Ask.SAY, HsEvents.write_say(channel_id, text))


## Out, and asking to watch somebody else: +1 next, -1 previous, 0 the other camera.
func ask_spectate(direction: int) -> void:
	_ask(HsEvents.Ask.SPECTATE, HsEvents.write_ask_spectate(direction))


func ask_roam() -> void:
	_ask(HsEvents.Ask.ROAM, HsEvents.write_ask_roam())


## Taunt: [param taunt_id] from the list, or empty for any.
func ask_taunt(taunt_id: StringName = &"") -> void:
	_ask(HsEvents.Ask.TAUNT, HsEvents.write_ask_taunt(taunt_id))


func _ask(kind: int, body: PackedByteArray) -> void:
	if net == null or net.is_server:
		return

	net.send(HsRequest.new(kind, body), 1)


## Puts the whole client (world, every controller and the ENGINE) on the server's rate. The engine matters: at 60 against 128 the simulation
## stayed correct but ran in bursts, so the camera moved unevenly. A server never calls this; its rate is `sv_tickrate`.
func _adopt_tick_rate(rate: int) -> void:
	if net == null or net.is_server or game == null or rate <= 0 or rate == game.tick_rate:
		return

	var before := game.tick_rate

	if not game.set_tick_rate(rate):
		return

	net.config.tick_rate = game.tick_rate
	# The LIVE one, which is built from the config back at `setup()` and is therefore not
	# updated by writing the config alone.
	net.clock.tick_rate = game.tick_rate
	# dot-net API 7 has DotNetClock.adopt_tick_rate(), which also raises the engine's step cap to a quarter second of ticks. A shell built
	# before it gets the same rule here; remove this branch when the oldest shell is API 7.
	if DotAddonApi.build_level("dot_net") >= 7:
		DotNetClock.adopt_tick_rate(game.tick_rate)
	else:
		Engine.max_physics_steps_per_frame = maxi(Engine.max_physics_steps_per_frame, ceili(0.25 * float(game.tick_rate)))
		Engine.physics_ticks_per_second = game.tick_rate

	DotLog.info(CHANNEL, "adopted the server's tick rate", {
		"was": before, "now": game.tick_rate, "engine": Engine.physics_ticks_per_second,
	})


## The map, which on a client is a document it builds exactly as the server did. Refused with a line, never half built:
## a client a format behind says so ([HsMapDoc]) rather than building a map with holes in it.
func _apply_map(reader: DotNetReader) -> void:
	var told := HsEvents.read_map(reader)

	if not bool(told["ok"]) or game == null:
		return

	var decoded := HsMapDoc.decode(told["encoded"])

	if not decoded.ok:
		DotLog.warn(CHANNEL, "the server sent a map this build cannot build", {
			"why": decoded.error.message, "detail": decoded.error.detail,
		})
		return

	var built := game.build_map(decoded.value)

	if built.ok:
		map_received.emit(game.map.id())


## Who owns a mirrored player on this client: this client for its own player, the server's 0 otherwise. Never the local peer for anybody else,
## or the client would predict a person whose keys it never had. A client whose local peer is 0 claims nothing (0 is the server's owner id).
func _mirror_owner(session_id: int) -> int:
	if net == null or net.local_peer_id <= 0:
		return 0

	if local_player_id != 0 and session_id == local_player_id:
		return net.local_peer_id

	return 0


## The local player's mirror, claimed if it arrived before HELLO said whose it was. Belt and braces, not a path `_admit` takes:
## otherwise the local player stays unpredicted for the session with every check passing (see [method _apply_join]).
func _claim_local_player() -> void:
	var mine: HsPlayerNet = _behaviours.get(local_player_id)

	if mine == null or mine.identity == null or not mine.identity.is_registered():
		return

	var claimed := _mirror_owner(local_player_id)

	if claimed == 0 or mine.identity.owner_peer_id == claimed:
		return

	DotLog.debug(CHANNEL, "claimed the local player after HELLO", {
		"session": local_player_id, "net_id": mine.identity.net_id,
	})
	var _changed := net.registry.change_owner(mine.identity.net_id, claimed)


func _apply_clock(reader: DotNetReader) -> void:
	var clock := HsEvents.read_clock(reader)

	if not bool(clock["ok"]):
		return

	game.round_number = int(clock["round"])
	game.phase_elapsed = float(clock["elapsed"])
	game.seek_elapsed = float(clock["seek_elapsed"])
	game.phase = int(clock["phase"])
	game.remote_hiders = int(clock["hiders"])
	game.remote_seekers = int(clock["seekers"])
	game.remote_playable = bool(clock["playable"])

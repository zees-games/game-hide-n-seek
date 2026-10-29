extends "hs_net_bridge_io.gd"

## Joins an [HsGame] to a [DotNetManager]: the netcode seam, and the only file here that names both. Map arrives once as `MAP`;
## then only `CAUGHT`, `TEAM` and `TAUNT` cross. dot-net simulates per entity but this game ticks as a whole world,
## so [method ensure_game_ticked] lets the first behaviour on a tick run everything and the rest find it done.



func _exit_tree() -> void:
	# The link and the runtime hold each other through broadcast; left, both outlive the process's exit.
	if profile_link != null:
		profile_link.release()
		profile_link = null


## [param p_game] and [param p_net], in the shape [DotGameNetcode] calls it.
func attach(p_game: Object, p_net: DotNetManager) -> DotResult:
	var world := p_game as HsGame

	if world == null or p_net == null:
		return DotResult.fail(DotError.CODE_INVALID, "A bridge needs a world and a manager.")

	if world.authoritative != p_net.is_server:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The world and the manager disagree about who is authoritative.",
			"world=%s net.is_server=%s" % [world.authoritative, p_net.is_server]
		)

	game = world
	net = p_net

	_entities = Node.new()
	_entities.name = "Entities"
	add_child(_entities)

	net.send_fn = _send

	var event := net.messages.register(
		HsEvent.NAME, HsEvent,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_CLIENT
	)

	if not event.ok:
		return event

	var request := net.messages.register(
		HsRequest.NAME, HsRequest,
		DotNetMessage.Delivery.RELIABLE, DotNetMessage.Direction.TO_SERVER
	)

	if not request.ok:
		return request

	net.messages.on(HsEvent.NAME, _on_event)
	net.messages.on(HsRequest.NAME, _on_request)

	# Edited profiles reach every client, so a remote admin's panel shows what the server holds; edits themselves go through the remote workbench.
	profile_link = DotNetProfileLink.attach(net, world.ensure_runtime())

	# Both ends. The server's tick is `server_tick` and the client's is `client_tick`, which
	# simulates what it predicts and leaves the rest to interpolation. A world still running
	# its own `_physics_process` would move every player twice.
	game.external_tick = true

	# The old map's toys: the server's leave the registry before their nodes go; a client's
	# mirrors stay registered without them, and are handed the new map's when it is built.
	if net.is_server:
		game.world_clearing.connect(_release_toys)
	else:
		game.world_clearing.connect(_unpair_toys)
		game.world_rebuilt.connect(_pair_pending_toys)

	if net.is_server:
		# See [HsInterest]: no hider in a seeker's snapshot while the hiders hide.
		var interest := HsInterest.new()
		interest.game = game
		net.interest = interest

		game.player_added.connect(_on_player_added)
		game.player_removed.connect(_on_player_removed)
		game.world_rebuilt.connect(_on_world_rebuilt)
		game.round_began.connect(_on_round_began)
		game.round_over.connect(_on_round_over)
		game.phase_changed.connect(_on_phase_changed)
		game.player_died.connect(_on_player_died)
		game.side_changed.connect(func(id: StringName, side: int) -> void:
			_broadcast(HsEvents.Kind.TEAM, HsEvents.write_team(session_of(id), side))
		)
		game.taunted.connect(func(id: StringName, taunt_id: StringName, forced: bool) -> void:
			_broadcast(HsEvents.Kind.TAUNT, HsEvents.write_taunt(session_of(id), taunt_id, forced)))
		game.door_used.connect(func(index: int, open: bool, flip: bool, tick: int, _by: StringName) -> void:
			_broadcast(HsEvents.Kind.DOOR, HsEvents.write_door(index, open, flip, tick)))
		game.caught.connect(func(id: StringName, by: StringName, how: StringName) -> void:
			_broadcast(HsEvents.Kind.CAUGHT, HsEvents.write_caught(
				session_of(id), session_of(by) if by != &"" else 0, how)))
		# To the one who asked, never broadcast: a refusal is that person's business.
		game.refused.connect(func(id: StringName, why: String) -> void:
			var peer_id := peer_for_player(session_of(id))
			if peer_id > 0:
				notice(peer_id, why))
		if game.spectate != null:
			game.spectate.view_changed.connect(_on_spectate_changed)

	return DotResult.success(true)


## Opens the link under [param parent], whose NAME is half the RPC routing: a [DotServer] and a [DotClientLink] both called `Server`, this node under each.
## Godot routes an RPC by node path, so a link opened anywhere else lands nowhere, with no error on either side.
func open_link(parent: Node) -> void:
	if parent == null or link != null:
		return

	link = HsNetLink.attached_to(parent, self, net != null and net.is_server)
	# Not parent.add_child: the link has to sit under `Server` (RPCs route by path) but must
	# die with this bridge. A bare add_child left a second link after every module reload, and
	# Godot renamed the live one `@Node@n`, so RPCs to real clients were silently lost.
	DotGameLink.attach(link, parent, self, HsNetLink.NODE_NAME)



## Puts a connected peer into the game. What [DotGameRoster] calls.
func add_player(peer_id: int, session_id: int, display_name: String) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server adds players.")

	if peer_id > 0:
		# FIRST, because `game.add_player` emits `player_added` and the handler has to be
		# able to find which peer this player belongs to.
		_player_of_peer[peer_id] = session_id
		_peer_of_player[session_id] = peer_id

	var player := game.add_player(player_key(session_id), display_name)

	if player == null:
		_player_of_peer.erase(peer_id)
		_peer_of_player.erase(session_id)
		return DotResult.fail(DotError.CODE_STATE, "The game refused the player.")

	if _ready_unseated.has(peer_id):
		_ready_unseated.erase(peer_id)
		_admit(peer_id)

	return DotResult.success(player)


## Somebody the world drives itself: a stand-in, or a test's player. The same entity a peer gets, with a peer id of zero;
## it is replicated, scored and crushed like a person and just has no socket.
func add_bot(display_name: String, team: int = 0) -> HsPlayer:
	if net == null or not net.is_server or game == null:
		return null

	var session_id := _next_bot_session
	_next_bot_session += 1

	var player := game.add_player(player_key(session_id), display_name, team)

	if player == null:
		return null

	player.is_bot = true
	return player


func remove_peer(peer_id: int) -> void:
	_ready_unseated.erase(peer_id)

	if _player_of_peer.has(peer_id):
		remove_player(int(_player_of_peer[peer_id]))


## Removes a player whether or not a peer is behind it — a bot has none.
func remove_player(session_id: int) -> void:
	if not _behaviours.has(session_id):
		return

	var peer_id := peer_for_player(session_id)
	var was_ready := _ready_peers.has(peer_id)

	_player_of_peer.erase(peer_id)
	_peer_of_player.erase(session_id)
	_ready_peers.erase(peer_id)

	# Released BEFORE the game is told: `game.remove_player` emits `player_removed`, which `_on_player_removed` answers by releasing and
	# broadcasting the LEAVE. Releasing first empties `_behaviours`, so this stays the one place a leaving player is announced.
	_release_entity(session_id)
	game.remove_player(player_key(session_id))

	if net != null and peer_id > 0:
		if was_ready:
			net.remove_peer(peer_id)

		if net.interest != null:
			net.interest.forget_peer(peer_id)

	_broadcast(HsEvents.Kind.LEAVE, HsEvents.write_player(session_id))
	roster_changed.emit(session_id)


func _on_player_added(id: StringName) -> void:
	if net == null or not net.is_server:
		return

	var session_id := session_of(id)

	if _behaviours.has(session_id):
		return

	# Every wire id is `u<session>` and anything else parses to zero (also dot-net's broadcast address), so a second player called `bot`
	# would silently replace the first in this table. Refused with a line rather than accepted quietly.
	if player_key(session_id) != id:
		DotLog.warn(CHANNEL, "a player whose id is not a session key is not replicated", {
			"id": String(id), "hint": "use add_bot() or HsNetBridge.player_key()",
		})
		return

	var player: HsPlayer = game.players.get(id)

	if player == null:
		return

	var identity := _build_entity(player, peer_for_player(session_id))
	var registered := net.registry.register(identity, 0, net.clock.tick, net.config)

	if not registered.ok:
		DotLog.warn(CHANNEL, "could not replicate a player", {"error": str(registered.error)})
		return

	# Before the JOIN, so the first thing anybody hears about this person is their face.
	if player.avatar == null and avatar_fn.is_valid():
		var avatar: Variant = avatar_fn.call(session_id)
		player.avatar = avatar as DotAvatar if avatar is DotAvatar else null

	_broadcast(HsEvents.Kind.JOIN, _join_body(session_id))
	roster_changed.emit(session_id)


func _on_player_removed(id: StringName) -> void:
	var session_id := session_of(id)

	if _behaviours.has(session_id):
		# The game removed them itself; the entity and the LEAVE are still ours.
		_release_entity(session_id)
		_broadcast(HsEvents.Kind.LEAVE, HsEvents.write_player(session_id))
		roster_changed.emit(session_id)



## A new map: the whole document, to everybody, before anything that stands on it.
func _on_world_rebuilt() -> void:
	if net == null or not net.is_server or game.map == null or game.map.doc.is_empty():
		return

	var encoded := HsMapDoc.encode(game.map.doc)

	if encoded.size() > HsMapDoc.WIRE_LIMIT:
		# Sent anyway: a client on a native transport will take it, and the line says why a
		# browser does not. A WebSocket message past its outbound buffer is never delivered.
		DotLog.warn(CHANNEL, "a map is larger than a browser can be sent in one message", {
			"map": String(game.map.id()), "bytes": encoded.size(), "limit": HsMapDoc.WIRE_LIMIT,
		})

	_map_body = HsEvents.write_map(encoded)
	_broadcast(HsEvents.Kind.MAP, _map_body)
	_register_toys()



func server_tick(tick: int) -> void:
	_tick = tick
	_game_ticked_for = -1

	if net != null:
		# The toys where the physics left them, before the snapshot goes.
		for behaviour: HsToyNet in _toy_nets:
			behaviour.pull()

		_in_server_tick = true
		net.server_tick(tick)
		_in_server_tick = false

		for net_id in _unregistered_in_tick:
			if not net.registry.has(net_id):
				net.history.forget(net_id)

		_unregistered_in_tick.clear()

	# Belt and braces: `net.server_tick` drives the entities and the first player behaviour calls `ensure_game_ticked`, but a server with nobody
	# on it has no behaviours, and a world that ticked only with players would stop its round clock between them.
	ensure_game_ticked(tick)

	if tick % CLOCK_EVERY == 0:
		_broadcast(HsEvents.Kind.CLOCK, _clock_body())



func _on_request(message: DotNetMessage) -> void:
	var ask := message as HsRequest

	if ask == null or net == null or not net.is_server:
		return

	# [b]From the message, which dot-net stamped from the TRANSPORT.[/b] A peer id inside a
	# body is a claim; `sender_peer_id` is what the socket said, which is the only version
	# of it a server may act on.
	var peer_id := ask.sender_peer_id

	match ask.kind:
		HsEvents.Ask.READY:
			_admit(peer_id)
		HsEvents.Ask.SAY:
			var said := HsEvents.read_say(ask.reader())

			if bool(said["ok"]):
				# Emitted rather than acted on: everything about what a line means is
				# [DotChatRouter]'s, and the router is the module's.
				say_requested.emit(
					peer_id, StringName(str(said["channel"])), str(said["text"])
				)
		HsEvents.Ask.SPECTATE:
			var step := HsEvents.read_ask_spectate(ask.reader())

			if bool(step["ok"]):
				_spectate_step(peer_id, int(step["direction"]))
		HsEvents.Ask.ROAM:
			_spectate_roam(peer_id)
		HsEvents.Ask.TAUNT:
			var asked := HsEvents.read_ask_taunt(ask.reader())
			if bool(asked["ok"]):
				var _said := game.taunt(player_key(player_for_peer(peer_id)), asked["taunt_id"])


## Everything in the world, to one peer, once its own copy exists. On READY and not on connect: dot-server's signon finishes and THEN the client
## builds its scene, so JOIN and MAP sent at connect land on a node that does not exist yet.
func _admit(peer_id: int) -> void:
	if peer_id <= 0:
		return

	if not _player_of_peer.has(peer_id):
		_ready_unseated[peer_id] = true
		return

	_ready_peers[peer_id] = true

	if not net.peers().has(peer_id):
		net.add_peer(peer_id)

	var session_id := int(_player_of_peer[peer_id])

	_tell(peer_id, HsEvents.Kind.HELLO, HsEvents.write_hello(
		session_id,
		game.tick_rate,
		net.clock.tick,
		game.hide_limit(),
		game.round_limit(),
		game.config.beacon_period,
		game.config.taunt_range
	))

	if profile_link != null:
		profile_link.peer_joined(peer_id)

	# The map, before anything that stands on it.
	if not _map_body.is_empty():
		_tell(peer_id, HsEvents.Kind.MAP, _map_body)

	if not _toys_body.is_empty():
		_tell(peer_id, HsEvents.Kind.TOYS, _toys_body)

	for other in _behaviours.keys():
		_tell(peer_id, HsEvents.Kind.JOIN, _join_body(int(other)))

	_tell(peer_id, HsEvents.Kind.PHASE, HsEvents.write_phase(game.phase))
	_tell(peer_id, HsEvents.Kind.CLOCK, _clock_body())

	# Every door that has moved this round, with the tick it went: a joiner who was not told
	# would draw a door shut that is open, and predict themselves into it.
	if game.map != null and game.map.doors != null:
		var doors := game.map.doors

		for index in range(doors.count()):
			if int(doors.doors[index]["since"]) >= 0:
				_tell(peer_id, HsEvents.Kind.DOOR, HsEvents.write_door(
					index, doors.is_open(index), doors.is_flipped(index), int(doors.doors[index]["since"])))


## Tells everybody who somebody is now: a late profile, a wardrobe change, a rename. Server only. Through JOIN, which a client already applies
## and which is idempotent, rather than a second message with a second arrival order. An empty [param display_name] keeps the current one.
func refresh_player(session_id: int, display_name: String, avatar: DotAvatar) -> bool:
	if net == null or not net.is_server or game == null:
		return false

	var player: HsPlayer = game.players.get(player_key(session_id))

	if player == null or not _behaviours.has(session_id):
		return false

	if display_name != "":
		player.display_name = display_name

	player.avatar = avatar
	_broadcast(HsEvents.Kind.JOIN, _join_body(session_id))
	return true


func _on_event(message: DotNetMessage) -> void:
	var event := message as HsEvent

	if event == null or game == null or net == null or net.is_server:
		return

	var reader := event.reader()

	match event.kind:
		HsEvents.Kind.HELLO:
			_apply_hello(reader)
		HsEvents.Kind.MAP:
			_apply_map(reader)
		HsEvents.Kind.TOYS:
			_apply_toys(reader)
		HsEvents.Kind.JOIN:
			_apply_join(reader)
		HsEvents.Kind.LEAVE:
			var session_id := HsEvents.read_player(reader)
			_release_entity(session_id)
			game.remove_player(player_key(session_id))
			roster_changed.emit(session_id)
		HsEvents.Kind.TEAM:
			var side := HsEvents.read_team(reader)

			if bool(side["ok"]):
				var id := player_key(int(side["player_id"]))
				game.sides[id] = int(side["team"])

				if game.players.has(id):
					(game.players[id] as HsPlayer).team = int(side["team"])

				roster_changed.emit(int(side["player_id"]))
		HsEvents.Kind.CLOCK:
			_apply_clock(reader)
		HsEvents.Kind.ROUND:
			var round_info := HsEvents.read_round(reader)

			if bool(round_info["ok"]):
				game.round_number = int(round_info["round"])

				if bool(round_info["began"]):
					game.phase_elapsed = 0.0
					game.seek_elapsed = 0.0

					# Every door home: the uses were last round's.
					if game.map != null and game.map.doors != null:
						game.map.doors.reset()

				round_changed.emit(
					int(round_info["round"]),
					bool(round_info["began"]),
					int(round_info["winner"]),
					str(round_info["why"])
				)
		HsEvents.Kind.PHASE:
			var moved := HsEvents.read_phase(reader)

			if bool(moved["ok"]):
				game.phase = int(moved["phase"])
				game.phase_elapsed = 0.0

				phase_received.emit(int(moved["phase"]))
		HsEvents.Kind.DEATH:
			var death := HsEvents.read_death(reader)

			if bool(death["ok"]):
				# The fall goes on the player before anybody hears of the death, so the client
				# that draws it reads the server's pick.
				var fell: HsPlayer = game.players.get(player_key(int(death["player_id"]))) \
					if game != null else null
				if fell != null and death.has("death"):
					fell.death = death["death"]
				death_received.emit(
					int(death["player_id"]), int(death["by"]), death["why"]
				)
		HsEvents.Kind.CHAT:
			var wire := HsEvents.read_chat(reader)

			if bool(wire["ok"]):
				chat_received.emit(wire)
		HsEvents.Kind.NOTICE:
			var text := HsEvents.read_notice(reader)

			if bool(text["ok"]):
				notice_received.emit(str(text["text"]))
		HsEvents.Kind.SPECTATE:
			var view := HsEvents.read_spectate(reader)

			if bool(view["ok"]) and game.spectate != null:
				game.spectate.apply_view(
					player_key(int(view["viewer"])),
					int(view["mode"]),
					player_key(int(view["target"])) if int(view["target"]) != 0 else &"",
					player_key(int(view["killer"])) if int(view["killer"]) != 0 else &"",
					view["death_at"]
				)
				spectate_received.emit(
					int(view["viewer"]), int(view["mode"]), int(view["target"])
				)
		HsEvents.Kind.TAUNT:
			var heard := HsEvents.read_taunt(reader)

			if bool(heard["ok"]):
				taunt_received.emit(int(heard["player_id"]), heard["taunt_id"], bool(heard["forced"]))
		HsEvents.Kind.DOOR:
			var door := HsEvents.read_door(reader)

			if bool(door["ok"]) and game.map != null and game.map.doors != null \
					and int(door["index"]) < game.map.doors.count():
				game.apply_door(int(door["index"]), bool(door["open"]), bool(door["flip"]), int(door["tick"]))
				door_received.emit(int(door["index"]), bool(door["open"]), int(door["tick"]))
		HsEvents.Kind.CAUGHT:
			var got := HsEvents.read_caught(reader)

			if bool(got["ok"]):
				var who: HsPlayer = game.players.get(player_key(int(got["player_id"])))
				if who != null:
					who.caught = true
					who.sight_meter = 0.0
				caught_received.emit(int(got["player_id"]), int(got["by"]), got["how"])

func _apply_hello(reader: DotNetReader) -> void:
	var hello := HsEvents.read_hello(reader)

	if not bool(hello["ok"]):
		return

	local_player_id = int(hello["player_id"])

	# The server's tick rate, before anything is derived from it: HELLO carries it and a client that ignores it counts at its own export's rate,
	# skewing the correction rate and every replicated time. Before `sync_from_server`, which converts through `tick_rate`.
	_adopt_tick_rate(int(hello["tick_rate"]))

	var rtt := float(rtt_source.call()) if rtt_source.is_valid() else 0.0
	net.clock.sync_from_server(int(hello["server_tick"]), maxf(0.0, rtt))

	game.config.hide_seconds = float(hello["hide_seconds"])
	game.config.round_seconds = float(hello["round_seconds"])
	game.config.beacon_period = float(hello["beacon_period"])
	game.config.taunt_range = float(hello["taunt_range"])

	_claim_local_player()

	hello_received.emit(local_player_id)


func _apply_join(reader: DotNetReader) -> void:
	var join := HsEvents.read_join(reader)

	if not bool(join["ok"]):
		return

	var session_id := int(join["player_id"])
	var id := player_key(session_id)
	var player: HsPlayer = game.players.get(id)

	if player == null:
		player = game.add_player(id, str(join["name"]), int(join["team"]))

		if player == null:
			return

		# A client never samples: the client loop hands it commands, and the local player is
		# the only one whose commands exist at all.
		player.sampler = null
		player.samples_input = false

		# This client's own player is owned by this client, and nobody else's is; otherwise `is_owner` is false for the local player,
		# `registry.predicted()` is empty and the player moves only when a snapshot returns. By session, not a wire peer id: JOIN carries none,
		# and `is_owner` compares against THIS registry's local peer. [method _apply_hello] still claims a player that got here before HELLO.
		var identity := _build_entity(player, _mirror_owner(session_id))
		var registered := net.registry.register(
			identity, int(join["net_id"]), net.clock.tick, net.config
		)

		if not registered.ok:
			DotLog.warn(CHANNEL, "could not mirror a player", {"error": str(registered.error)})
			return
	else:
		player.display_name = str(join["name"])

	# Both branches: a JOIN for somebody this client already has is the server saying who
	# they are NOW — see [method refresh_player].
	player.avatar = join["avatar"]
	game.sides[id] = int(join["team"])
	player.team = int(join["team"])
	roster_changed.emit(session_id)



func describe() -> Dictionary:
	var out := {
		"server": net != null and net.is_server,
		"players": _behaviours.size(),
		"ready_peers": _ready_peers.size(),
		"tick": _tick,
	}

	if not (net != null and net.is_server):
		out["local_player"] = local_player_id

	if link != null:
		out["link"] = link.describe()

	return out


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray([
		"bridge     %s" % ("server" if net != null and net.is_server else "client"),
		"players    %d" % _behaviours.size(),
		"peers      %d ready" % _ready_peers.size(),
		"tick       %d" % _tick,
	])

	if link != null:
		lines.append_array(link.describe_lines())

	return lines

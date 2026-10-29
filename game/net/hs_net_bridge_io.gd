extends "hs_net_bridge_state.gd"
## The packets in and out of [HsNetBridge]: input, voice, ticks, the server's event handlers (a middle layer, split off for size); never used on its own.




func _on_round_began(number: int, _layout_id: StringName) -> void:
	_broadcast(HsEvents.Kind.ROUND, HsEvents.write_round(number, true, 0))


func _on_round_over(number: int, winner: int, why: String) -> void:
	_broadcast(HsEvents.Kind.ROUND, HsEvents.write_round(number, false, winner, why))


func _on_phase_changed(phase: int) -> void:
	_broadcast(HsEvents.Kind.PHASE, HsEvents.write_phase(phase))



func _on_player_died(player_id: StringName, by: StringName, why: StringName) -> void:
	var who: HsPlayer = game.players.get(player_id) if game != null else null
	_broadcast(HsEvents.Kind.DEATH, HsEvents.write_death(
		session_of(player_id), session_of(by) if by != &"" else 0, why,
		who.death if who != null else null
	))


## A view changed on the server. Told to its owner only, because who somebody is watching is private;
## a stand-in (peer zero) is told nothing, which `_tell` guarantees.
func _on_spectate_changed(player_id: StringName) -> void:
	if game == null or game.spectate == null or game.spectate.manager == null:
		return

	var session_id := session_of(player_id)
	var peer_id := peer_for_player(session_id)

	if peer_id <= 0 or not _ready_peers.has(peer_id):
		return

	var view := game.spectate.manager.view(String(player_id))
	var target := session_of(StringName(view.target)) if view.target != "" else 0
	var killer := session_of(StringName(view.killer)) if view.killer != "" else 0

	_tell(peer_id, HsEvents.Kind.SPECTATE, HsEvents.write_spectate(
		session_id, int(view.mode), target, killer, view.death_position
	))


func ensure_game_ticked(tick: int) -> void:
	if _game_ticked_for == tick or game == null:
		return

	_game_ticked_for = tick

	for session_id in _behaviours:
		var behaviour: HsPlayerNet = _behaviours[session_id]

		# Only what a peer sent. A bot has no peer and is driven by the game itself, and an
		# empty command applied over the top of that would stand it still.
		if behaviour.player != null and behaviour.identity != null \
				and behaviour.identity.owner_peer_id > 0:
			behaviour.player.controller.apply_command(behaviour.last_move.duplicate_command())
			behaviour.player.wants_use = behaviour.last_move.is_pressed(HsPlayer.USE_BUTTON)

	game.tick_once(tick)


func client_tick(tick: int, command: DotFpsCommand) -> void:
	if net == null or net.is_server or game == null:
		return

	_tick = tick

	var packet := HsNetCommand.new()
	packet.tick = tick
	packet.delta = net.clock.tick_duration()
	packet.move = command if command != null else DotFpsCommand.new()

	# Into the local history BEFORE predicting: reconciliation replays it.
	net.local_inputs().push(packet)

	# The behaviour simulates from `last_move` on a fresh tick and on a replayed one alike —
	# the predictor's replay sets it through `_net_apply_input`, and this is the fresh tick's
	# equivalent.
	var mine: HsPlayerNet = _behaviours.get(local_player_id)

	if mine != null:
		mine.last_move = packet.move

	if link != null:
		var payload := net.encode_ack()
		var writer := DotNetWriter.new()
		DotNetInput.write_batch(writer, _input_copies(packet))
		payload.append_array(writer.to_bytes())
		link.send_input(payload)

	# One predicted player, and nothing else: everybody else is drawn from snapshots. The
	# doors first, posed for this tick, because the player is predicted against them.
	if _client_ticked_for != tick:
		_client_ticked_for = tick

		if game.map != null and game.map.doors != null:
			game.map.doors.pose_at(tick)

		for identity in net.registry.predicted():
			for behaviour in identity.behaviours:
				behaviour._net_simulate(tick, net.clock.tick_duration())

		# The clock a client shows, advanced between the twice-a-second messages that
		# correct it. Without this the round timer ticks in half-second steps.
		game.phase_elapsed += net.clock.tick_duration()

		if game.phase == HsGame.Phase.SEEK:
			game.seek_elapsed += net.clock.tick_duration()



func receive_snapshot(payload: PackedByteArray) -> DotResult:
	if net == null or net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only a client receives these.")

	if rtt_source.is_valid():
		net.stats.note_rtt(float(rtt_source.call()))

	return net.receive_snapshot(payload)


func receive_input(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null or not net.is_server:
		return DotResult.fail(DotError.CODE_FORBIDDEN, "Only the server takes input.")

	if not _player_of_peer.has(peer_id):
		return DotResult.fail(DotError.CODE_FORBIDDEN, "That peer has no player.")

	if payload.size() <= ACK_BYTES:
		return DotResult.fail(DotError.CODE_PARSE, "Input packet is too short.")

	net.receive_ack_payload(peer_id, payload.slice(0, ACK_BYTES))

	# A batch: this tick's command and the ones before it (see [constant INPUT_COPIES]).
	# Copies of ticks already simulated are skipped rather than pushed, or each would count
	# as a late input; the packet's own tick is always pushed, so a late one still counts.
	var batch := DotNetInput.read_batch(
		DotNetReader.new(payload.slice(ACK_BYTES)),
		func() -> DotNetInput: return HsNetCommand.new()
	)
	if batch.is_empty():
		return DotResult.fail(DotError.CODE_PARSE, "Input packet carries no command.")
	var buffer := net.input_buffer_for(peer_id)
	var newest := batch[batch.size() - 1]
	var pushed := DotResult.success(false)
	for input in batch:
		if input != newest and input.tick <= buffer.last_consumed_tick():
			continue
		pushed = buffer.push(input)
	return pushed


## Text for one player: a refusal, a rate limit, a command's reply. Sent to the one person who asked, because
## "you are talking too fast" is nobody else's business.
func notice(peer_id: int, text: String) -> void:
	_tell(peer_id, HsEvents.Kind.NOTICE, HsEvents.write_notice(text))


## One routed line to one peer. What [DotGameServices] sends through, via the link.
func send_chat(peer_id: int, wire: Dictionary) -> void:
	_tell(peer_id, HsEvents.Kind.CHAT, HsEvents.write_chat(wire))


## A voice frame, in either direction. Not an [HsEvent]: voice is fifty packets a second and every event is reliable, and the message registry
## seals and hashes its message set, so an opaque fifty-hertz blob does not belong in it; [DotVoicePacket] has its own header and validation.
func receive_voice(peer_id: int, payload: PackedByteArray) -> DotResult:
	if payload.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "An empty voice frame.")

	if net != null and net.is_server:
		if peer_id <= 0 or player_for_peer(peer_id) == 0:
			# A peer with nobody in the world. Refused rather than relayed: the router
			# stamps the speaker from this id, so relaying one that belongs to nobody puts
			# a voice in the game with no name on it.
			return DotResult.fail(
				DotError.CODE_FORBIDDEN, "That peer has nobody in the world."
			)

		# One path or the other, never both: [DotGameModule] assigns `voice_relay_fn` to the services layer's `relay_voice`, and a game that also
		# connected `voice_requested` to the same router would relay every frame twice, doubling the rate limit and reversing sequence numbers.
		if voice_relay_fn.is_valid():
			voice_relay_fn.call(peer_id, payload)
		else:
			voice_requested.emit(peer_id, payload)

		return DotResult.success(null)

	voice_arrived.emit(payload)
	return DotResult.success(null)


func receive_event(payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, 1)


func receive_request(peer_id: int, payload: PackedByteArray) -> DotResult:
	if net == null:
		return DotResult.fail(DotError.CODE_STATE, "No manager.")

	return net.receive(payload, peer_id)


## Somebody who is out asked to look at somebody else; the server's list, the server's rule. A refusal goes back as a notice rather than
## being dropped, because a key that silently does nothing is reported as broken.
func _spectate_step(peer_id: int, direction: int) -> void:
	var session_id := player_for_peer(peer_id)

	if session_id == 0 or game.spectate == null:
		return

	var moved: DotResult = game.spectate.step(player_key(session_id), direction)

	if not moved.ok:
		notice(peer_id, moved.error.message)


## Somebody who is out pressed the free-roam key. The mode is the server's; the refusal
## ("Free roam is off on this server") goes back as a notice, like a refused step.
func _spectate_roam(peer_id: int) -> void:
	var session_id := player_for_peer(peer_id)

	if session_id == 0 or game.spectate == null:
		return

	var toggled: DotResult = game.spectate.toggle_roam(player_key(session_id))

	if not toggled.ok:
		notice(peer_id, toggled.error.message)


## Sends one encoded voice packet to the server. Client side.
func send_voice(payload: PackedByteArray) -> void:
	if link != null and net != null and not net.is_server:
		link.send_voice(1, payload)

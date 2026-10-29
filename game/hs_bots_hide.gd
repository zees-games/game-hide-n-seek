extends "hs_bots_move.gd"

## The hider half of the stand-ins: picking a spot, watching for seekers and fleeing.


func _hide(player: HsPlayer, command: DotFpsCommand) -> void:
	var state := _state_of(player)
	var t := now()
	var phase: int = game.get("phase")
	var at := player.controller.state.position

	if (state["spot"] as Dictionary).is_empty():
		# The survey lands a frame or two after the map; until then, nowhere to go.
		if (spots.is_empty() and _surveyed != _baked) or now() < float(state.get("retry_at", -INF)):
			return
		_pick_spot(player, state, PackedVector3Array())
		if (state["spot"] as Dictionary).is_empty():
			return

	if phase == 2:
		_watch_for_seekers(player, state)

		# The game's standing-still clock (the same meter the HUD shows a person): before it
		# forces a taunt, move to another place close by, when no seeker is near.
		var taunts: DotPropTaunts = game.get("taunts")
		var meter := taunts.meter(player.player_id, t) if taunts != null else 0.0
		if meter > 0.85 and state["mode"] == &"hidden" \
				and (state["threat"] == Vector3.INF or (state["threat"] as Vector3).distance_to(at) > 15.0):
			_pick_spot(player, state, PackedVector3Array([at]), 14.0)

		# Now and then (about once in five minutes), a taunt of its own for the points, and only
		# when it has not seen or heard a seeker for a while: a taunt is a shout every seeker in
		# earshot walks to.
		var stream: DotRandomStream = state["stream"]
		if state["mode"] == &"hidden" and stream.next_unit() < dt() / 300.0 and state["threat"] == Vector3.INF \
				and t - float(state["threat_at"]) > 30.0:
			var _taunted: bool = game.call("taunt", player.player_id)

	var goal: Vector3 = (state["spot"] as Dictionary).get("at", at)
	var sprint: bool = state["sprint"]

	# Shutting the door it just came through: stopped, turned to it, the use key.
	if _shut_door(player, command, state):
		return

	var arrived := _walk_to(player, command, state, goal, sprint)
	_note_doorway(player, state, goal)

	if arrived:
		state["mode"] = &"hidden"
		state["sprint"] = false
		command.move = Vector2.ZERO
		command.set_button(DotFpsCommand.BUTTON_CROUCH, true)
		# Face the way it came, which is the way somebody would come.
		var back: Vector3 = state.get("came_from", at + Vector3(0.0, 0.0, 1.0))
		_look(player, command, Vector3(back.x, player.eye_position().y, back.z))
	elif state["crouch"]:
		command.set_button(DotFpsCommand.BUTTON_CROUCH, true)


## Remembers where the threat was last seen or heard, and forgets it after a while.
func _note_threat(state: Dictionary, nearest: HsPlayer, heard: Dictionary, t: float, profile: DotBotProfile) -> void:
	if nearest != null:
		state["threat"] = nearest.controller.state.position
		state["threat_at"] = t
	elif not heard.is_empty():
		state["threat"] = heard["at"]
		state["threat_at"] = t
	elif t - float(state["threat_at"]) > profile.memory + 4.0:
		state["threat"] = Vector3.INF


## Seekers it can see or hear: run from one that sees it, creep away from one coming close.
func _watch_for_seekers(player: HsPlayer, state: Dictionary) -> void:
	var t := now()
	var at := player.controller.state.position
	var profile := settings().profile
	var nearest := _nearest_seen_seeker(player, at, profile.sight)
	var nearest_d := INF if nearest == null else at.distance_to(nearest.controller.state.position)

	var heard := _heard(player, 2)
	# Seen by it: it will make the hider out in a moment whatever the hider does, so go now, at a
	# sprint, while the gap is widest. One walking past with its back turned is let pass.
	var seen := nearest != null and _sees(nearest, player)
	# About to walk into the hider whatever it has seen.
	var bumping := nearest != null and nearest_d < BUMP_FROM
	# The beacon has given it away: every seeker knows where it is, so keeping still is waiting
	# to be caught. Run from any seeker in sight or earshot.
	var marked_chase := player.marked and (nearest != null or not heard.is_empty())

	_note_threat(state, nearest, heard, t, profile)

	if t - float(state["moved_at"]) < (MARKED_SETTLE if player.marked else SETTLE):
		return

	# Coming to the hider's own place (a seeker searches the hidden places, and this is one):
	# keeping still only works for a seeker passing by. Seen walking at it, or heard getting
	# closer, it is coming here.
	var coming := _seeker_coming(state, at, nearest, nearest_d, seen, heard)
	var catch_near := _catch_heard_near(player, state, at, t, profile)

	if not (seen or bumping or coming or catch_near or marked_chase):
		return

	# In its sight but close, hidden still and low: running from a seeker a few metres off is caught inside two seconds, and a still
	# crouched body is made out later. Keep still and hope to be passed over; a step closer is a bump, and then it runs.
	if seen and not (bumping or marked_chase) and state["mode"] == &"hidden" and nearest_d < FREEZE_WITHIN:
		return

	var threat: Vector3 = state["threat"]
	if threat == Vector3.INF:
		return
	var threat_eye := threat + Vector3(0.0, HsPlayer.EYE_HEIGHT, 0.0)
	# In its line of sight if it turned: going quietly is no use, it would see a creeping body at
	# twice the distance of a still one. Behind a wall from it: slip away low and quiet.
	var in_view := _los(threat_eye, player.eye_position())

	# Coming, or two seekers about to start from a catch close by, and it could see the hider if
	# it looked: moving now is what it would see. Keep still and low, and hope to be passed over.
	# Out of its sight, slip away low and quiet.
	if (coming or catch_near) and not (seen or bumping or marked_chase) and in_view:
		return

	var running := seen or bumping or marked_chase
	var away := _flee_spot_for(player, state, at, threat, threat_eye, running, marked_chase)
	# Running to a place that is still away from the threat: a new choice behind the runner is the
	# other end of a fenced yard, and taking it each settle paced a hider between the two for 17 s.
	var held: Dictionary = state.get("spot", {})
	if state["mode"] == &"fleeing" and not held.is_empty() and not away.is_empty():
		var held_at: Vector3 = held["at"]
		var ahead := Vector2(held_at.x - at.x, held_at.z - at.z)
		var turned := Vector2((away["at"] as Vector3).x - at.x, (away["at"] as Vector3).z - at.z)
		if ahead.length() > 1.5 and ahead.dot(turned) < 0.0 and threat.distance_to(held_at) > threat.distance_to(at) + FLEE_KEEP:
			state["moved_at"] = t
			return
	state["spot"] = away
	state["came_from"] = threat
	state["mode"] = &"fleeing"
	state["path"] = PackedVector3Array()
	state["moved_at"] = t
	state["sprint"] = running
	state["crouch"] = not running
	# What sent it, for `headless_bots`' trace.
	state["why"] = "%s %.1f" % ["seen" if seen else ("bump" if bumping else ("beacon" if marked_chase else ("coming" if coming else "catch"))), at.distance_to(threat)]


## The nearest living seeker within `sight` that the hider can see, or null.
func _nearest_seen_seeker(player: HsPlayer, at: Vector3, sight: float) -> HsPlayer:
	var nearest: HsPlayer = null
	var nearest_d := INF
	for other in (game.call("players_on", 2) as Array):
		var seeker := other as HsPlayer
		if not seeker.is_alive() or seeker.watching:
			continue
		var d := at.distance_to(seeker.controller.state.position)
		if d < nearest_d and d < sight and _sees(player, seeker):
			nearest_d = d
			nearest = seeker
	return nearest


## Whether the seeker seen walking at the hider, or heard getting closer, is coming to its place. Keeps the last heard position.
func _seeker_coming(state: Dictionary, at: Vector3, nearest: HsPlayer, nearest_d: float, seen: bool, heard: Dictionary) -> bool:
	var coming := false
	if nearest != null and not seen:
		var v := nearest.controller.state.velocity
		var to_me := Vector3(at.x - nearest.controller.state.position.x, 0.0, at.z - nearest.controller.state.position.z)
		var flat_v := Vector3(v.x, 0.0, v.z)
		if nearest_d < COMING_FROM and flat_v.length() > 1.0 and to_me.length() > 0.01 \
				and rad_to_deg(flat_v.angle_to(to_me)) < COMING_CONE:
			coming = true
	elif nearest == null and not heard.is_empty():
		var was: Vector3 = state.get("heard_from", Vector3.INF)
		var now_at: Vector3 = heard["at"]
		var d_now := at.distance_to(now_at)
		if was != Vector3.INF and d_now < COMING_FROM and d_now < at.distance_to(was) - 0.8:
			coming = true
		state["heard_from"] = now_at
	return coming


## A catch heard close by: two seekers are about to start from there, one held a moment. Notes it as the threat.
func _catch_heard_near(player: HsPlayer, state: Dictionary, at: Vector3, t: float, profile: DotBotProfile) -> bool:
	var catch_near := false
	for sound: Dictionary in _sounds:
		if sound.get("caught", false) and at.distance_to(sound["at"]) < minf(profile.hearing, 15.0) \
				and t - float(sound["t"]) < 0.5 and StringName(sound["by"]) != player.player_id:
			catch_near = true
			state["threat"] = sound["at"]
			state["threat_at"] = t
	return catch_near


## Where a hider flees to: running goes round a corner and well away, slipping away takes the nearest place out of sight.
func _flee_spot_for(player: HsPlayer, state: Dictionary, at: Vector3, threat: Vector3, threat_eye: Vector3, running: bool, marked_chase: bool) -> Dictionary:
	var taken := PackedVector3Array()
	for id: StringName in _state:
		if id != player.player_id and not ((_state[id] as Dictionary).get("spot", {}) as Dictionary).is_empty():
			taken.append((_state[id]["spot"] as Dictionary)["at"])
	# Only places a short walk away: with the annotator's links a place across a drop is near as the crow flies and far by path.
	var runnable: Array[Dictionary] = []
	var start := nav.closest(at) if nav.is_ready() else at
	for spot in spots:
		var there: Vector3 = spot["at"]
		if there.distance_to(at) <= FLEE_WITHIN + 5.0 and (not nav.is_ready() or (nav.joined(start, there) and nav.path_length(start, there) <= (FLEE_WITHIN + 5.0) * 1.5)):
			runnable.append(spot)
	runnable.assign(_without_avoided(state, runnable, now()))
	var away := DotBotHiding.flee_spot(runnable, at, threat, threat_eye, _los, taken, FLEE_WITHIN + 5.0, FLEE_CLEAR + 4.0) if marked_chase \
		else DotBotHiding.flee_spot(runnable, at, threat, threat_eye, _los, taken, FLEE_WITHIN, FLEE_CLEAR) if running \
		else DotBotHiding.flee_spot(runnable, at, threat, threat_eye, _los, taken)
	if away.is_empty():
		var dir := Vector3(at.x - threat.x, 0.0, at.z - threat.z).normalized()
		away = {"at": nav.closest(at + dir * 10.0), "exposure": 1.0}
	return away

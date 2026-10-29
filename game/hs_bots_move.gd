extends "hs_bots_walk.gd"

## The stand-ins' senses, doors and walking: what both the hider and the seeker lean on.


func _state_of(player: HsPlayer) -> Dictionary:
	if not _state.has(player.player_id):
		var seed := hash(String(player.player_id))
		_state[player.player_id] = {
			"aim": DotBotAim.new(seed, settings()),
			"stream": DotRandomStream.new(seed, &"hs_bot"),
			"goal": Vector3.INF, "path": PackedVector3Array(), "corner": 0, "path_at": -INF,
			"mode": &"", "since": now(), "stuck": [player.controller.state.position, now()],
			"spot": {}, "threat": Vector3.INF, "threat_at": -INF, "moved_at": -INF,
			"search": null, "target": StringName(), "seen_since": -INF, "last_seen": Vector3.INF,
			"last_seen_at": -INF, "still_since": now(), "sprint": false, "crouch": false, "who": player.player_id,
		}
	return _state[player.player_id]


func _aim_of(player: HsPlayer) -> DotBotAim:
	return _state_of(player)["aim"]


## Every moving body makes footsteps: how loud is how it moves.
func _hear_steps(players: Dictionary) -> void:
	var t := now()
	# Four times a second is enough to hear somebody coming.
	if int(game.get("_tick")) % maxi(int(game.get("tick_rate")) / 4, 1) != 0:
		return
	for id: StringName in players:
		var body: HsPlayer = players[id]
		if not body.is_alive() or body.watching:
			continue
		var v := body.controller.state.velocity
		var speed := Vector2(v.x, v.z).length()
		if speed < 1.0:
			continue
		var loud := LOUD_RUN
		if body.controller.state.crouch_fraction > 0.5:
			loud = LOUD_CROUCH
		elif speed > body.controller.tunables.max_speed * 1.1:
			loud = LOUD_SPRINT
		_sounds.append({"at": body.controller.state.position, "loud": loud, "by": id, "t": t})


## The loudest sound from [param side] this bot heard in the last second, or an empty dictionary.
func _heard(player: HsPlayer, side: int) -> Dictionary:
	var hearing := settings().profile.hearing
	var best: Dictionary = {}
	var best_near := INF
	for sound: Dictionary in _sounds:
		var by: StringName = sound["by"]
		if by == player.player_id or int(game.call("team_of", by)) != side:
			continue
		var d := player.controller.state.position.distance_to(sound["at"])
		if d <= hearing * float(sound["loud"]) and d < best_near:
			best_near = d
			best = sound
	return best


## Whether [param player] sees [param other]'s head or chest with its own eyes and settings. Movement draws the eye: somebody still or creeping
## is noticed at half `bot_sight`, still and crouched only at [constant STILL_LOW_SIGHT] of it and only whole.
func _sees(player: HsPlayer, other: HsPlayer) -> bool:
	var profile := settings().profile
	var sight := profile.sight
	var v := other.controller.state.velocity
	var crouched := other.controller.state.crouch_fraction > 0.5
	var still_low := Vector2(v.x, v.z).length() < 0.5 and crouched
	if Vector2(v.x, v.z).length() < 0.5:
		sight *= STILL_LOW_SIGHT if crouched else 0.5
	elif crouched:
		# Creeping draws the eye less than walking.
		sight *= 0.5
	var eye := player.eye_position()
	var forward := DotBotAim.direction(player.controller.state.yaw, player.controller.state.pitch)
	var head := other.eye_position()
	var chest := other.controller.state.position + Vector3(0.0, 0.6, 0.0)
	# At arm's length a person is felt whichever way they face.
	if eye.distance_to(chest) < FELT_WITHIN and _los(eye, chest):
		return true
	var head_seen := DotBotHiding.sees(eye, forward, profile.fov, sight, head, _los)
	var chest_seen := DotBotHiding.sees(eye, forward, profile.fov, sight, chest, _los)
	# Somebody keeping still and low in cover is made out only whole: a head over a sofa's back,
	# or a body half behind a hedge, still, is passed over.
	if still_low:
		return head_seen and chest_seen
	return head_seen or chest_seen


## Remembers the doorway the hider is in and, once through and clear of the panel's sweep, decides whether to shut the door behind it:
## always when running from a seeker behind it. A shut door is a wall to a seeker's eye, and opening it costs the swing.
func _note_doorway(player: HsPlayer, state: Dictionary, goal: Vector3) -> void:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	if doors == null or int(doors.call("count")) == 0:
		return
	var at := player.controller.state.position
	var through: int = state.get("door_through", -1)
	if through < 0:
		for index in range(int(doors.call("count"))):
			var panel: Vector3 = (doors.call("panel_transform", index, 0.0) as Transform3D).origin
			if Vector2(panel.x - at.x, panel.z - at.z).length() < 0.9 and absf(panel.y - at.y) < 2.0:
				state["door_through"] = index
				state["door_side"] = at
				return
		return
	var panel_at: Vector3 = (doors.call("panel_transform", through, 0.0) as Transform3D).origin
	var away := Vector2(panel_at.x - at.x, panel_at.z - at.z).length()
	if away < DOOR_CLEAR:
		return
	state["door_through"] = -1
	if away > DOOR_CLEAR + 1.5 or not bool(doors.call("is_open", through)):
		return
	# Through it, not back out the way it came in.
	var entered: Vector3 = state.get("door_side", at)
	if Vector2(entered.x - at.x, entered.z - at.z).length() < DOOR_CLEAR:
		return
	var threat: Vector3 = state["threat"]
	var chased: bool = state["mode"] == &"fleeing" and threat != Vector3.INF and threat.distance_to(at) > 3.0 \
		and threat.distance_to(panel_at) < threat.distance_to(at) + 1.0
	var settling: bool = state["mode"] == &"going" and goal.distance_to(at) < 9.0
	if chased or settling:
		state["shut"] = {"index": through, "until": now() + 1.2}


## Turns to the door in `state.shut` and presses use until it is shut or the moment has passed.
## Returns true while it is at it.
func _shut_door(player: HsPlayer, command: DotFpsCommand, state: Dictionary) -> bool:
	var shut: Dictionary = state.get("shut", {})
	if shut.is_empty():
		return false
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	var index: int = shut["index"]
	if doors == null or now() > float(shut["until"]) or not bool(doors.call("is_open", index)):
		if doors != null and not bool(doors.call("is_open", index)) and bool(shut.get("count", true)):
			doors_shut += 1
		if doors != null and bool(doors.call("is_open", index)):
			# The moment passed with it still open (out of reach, or somebody in its sweep).
			_note_shut_failed(state, index)
		state["shut"] = {}
		return false
	var panel_at: Vector3 = (doors.call("panel_transform", index, 0.0) as Transform3D).origin
	command.move = Vector2.ZERO
	command.set_button(DotFpsCommand.BUTTON_CROUCH, bool(state["crouch"]))
	_look(player, command, panel_at)
	var facing: int = doors.call("door_for", player.eye_position(), player.aim_direction())
	state["use_now"] = facing == index and not bool(doors.call("moving", index, int(game.get("_tick"))))
	return true


## A shut door the walk goes into that would swing into the bot itself (pinned to open one way): the game refuses a use while anybody
## stands where the panel will pass, so a person steps back first. Plans a point out of the swing; true when it did,
## and `_open_from_clear` walks there and opens it.
func _plan_open_from_clear(player: HsPlayer, state: Dictionary, dir: Vector3) -> bool:
	if dir.length() < 0.01 or _before(state, "open_check"):
		return false
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	if doors == null or int(doors.call("count")) == 0:
		return false
	var at := player.controller.state.position
	var index: int = doors.call("door_for", player.eye_position(), dir.normalized(), 1.6)
	if index < 0 or bool(doors.call("is_open", index)) or bool(doors.call("moving", index, int(game.get("_tick")))):
		return false
	var spec: Dictionary = ((doors.get("doors") as Array)[index] as Dictionary)["spec"]
	if str(spec["motion"]) != "swing":
		return false
	var flip := 1 if bool(doors.call("flips_for", index, player.eye_position())) else 0
	if not bool(doors.call("sweeps", index, at, HsPlayer.BODY_RADIUS, player.hull_height(), 0.0, 1.0, flip)):
		return false
	state["open_check"] = now() + 1.0
	var shut: Transform3D = doors.call("panel_transform", index, 0.0)
	var normal := shut.basis.z.normalized()
	normal.y = 0.0
	if normal.dot(at - shut.origin) < 0.0:
		normal = -normal
	var width := float((spec["size"] as Array)[0])
	var point := Vector3(shut.origin.x, at.y, shut.origin.z) + normal * (width + HsPlayer.BODY_RADIUS + 0.2)
	if nav.is_ready():
		var floor_at := nav.closest(point)
		if Vector2(floor_at.x - point.x, floor_at.z - point.z).length() > 0.5 or absf(floor_at.y - at.y) > HsPlayer.BODY_STEP + 0.1:
			_give_up_goal(player, state)
			return true
		point = floor_at
	if bool(doors.call("sweeps", index, point, HsPlayer.BODY_RADIUS, player.hull_height(), 0.0, 1.0, flip)):
		# No room on this side to stand clear of it (a cupboard's door): somewhere else.
		_give_up_goal(player, state)
		return true
	state["opening"] = {"index": index, "at": point, "until": now() + 3.0}
	return true


## The other half of the same: an open panel across the way with no room round it, and the bot
## standing in the arc it would sweep shutting. Plans a point out of that arc, back from the
## hinge, on the mesh; true when it did.
func _plan_shut_from_clear(player: HsPlayer, state: Dictionary, index: int) -> bool:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors")
	var at := player.controller.state.position
	var f: float = doors.call("fraction", index, int(game.get("_tick")))
	var spec: Dictionary = ((doors.get("doors") as Array)[index] as Dictionary)["spec"]
	var hinge: Vector3 = (doors.call("panel_ends", index, f) as PackedVector3Array)[0]
	var out := Vector3(at.x - hinge.x, 0.0, at.z - hinge.z)
	if out.length() < 0.05:
		return false
	var width := float((spec["size"] as Array)[0])
	var point := Vector3(hinge.x, at.y, hinge.z) + out.normalized() * (width + HsPlayer.BODY_RADIUS + 0.25)
	if not nav.is_ready():
		return false
	var floor_at := nav.closest(point)
	if Vector2(floor_at.x - point.x, floor_at.z - point.z).length() > 0.5 or absf(floor_at.y - at.y) > HsPlayer.BODY_STEP + 0.1 \
			or bool(doors.call("sweeps", index, floor_at, HsPlayer.BODY_RADIUS, player.hull_height(), f, 0.0)):
		return false
	state["opening"] = {"index": index, "at": floor_at, "until": now() + 3.0, "open": false}
	return true


## Walks back to `state.opening`'s point, facing the door, and presses use once it is out of the
## swing: to open it, or (`open` false) to shut it. Returns true while it is at it.
func _open_from_clear(player: HsPlayer, command: DotFpsCommand, state: Dictionary) -> bool:
	var opening: Dictionary = state.get("opening", {})
	if opening.is_empty():
		return false
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	var index: int = opening["index"]
	var want_open := bool(opening.get("open", true))
	if doors == null or now() > float(opening["until"]) or bool(doors.call("is_open", index)) == want_open:
		state["opening"] = {}
		state["path"] = PackedVector3Array()
		if doors != null and bool(doors.call("is_open", index)) != want_open:
			# It would not move (somebody else in its swing): somewhere else, or the next step
			# plans the same step back.
			state["open_check"] = now() + 2.0
			_give_up_goal(player, state)
			if not want_open:
				_note_shut_failed(state, index)
		return false
	var at := player.controller.state.position
	var tick := int(game.get("_tick"))
	var f: float = doors.call("fraction", index, tick)
	var panel_at: Vector3 = (doors.call("panel_transform", index, f) as Transform3D).origin
	_look(player, command, panel_at)
	var point: Vector3 = opening["at"]
	var in_swing: bool = doors.call("sweeps", index, at, HsPlayer.BODY_RADIUS, player.hull_height(), f, 0.0) if not want_open \
		else doors.call("sweeps", index, at, HsPlayer.BODY_RADIUS, player.hull_height(), 0.0, 1.0,
			1 if bool(doors.call("flips_for", index, player.eye_position())) else 0)
	if in_swing and Vector2(point.x - at.x, point.z - at.z).length() > 0.2:
		_walk(command, point - at)
		return true
	command.move = Vector2.ZERO
	# Out of the swing and pressing: a second of that without the door moving is somebody else
	# in its way, and the rest of the three seconds was a bot standing facing a door at the top
	# of a flats stair (`headless_bots` round 44).
	if not opening.has("pressing"):
		opening["pressing"] = now()
	elif now() - float(opening["pressing"]) > 1.0 and not bool(doors.call("moving", index, tick)):
		opening["until"] = now()
	var facing: int = doors.call("door_for", player.eye_position(), player.aim_direction())
	state["use_now"] = facing == index and not bool(doors.call("moving", index, int(game.get("_tick"))))
	return true


func _before(state: Dictionary, key: String) -> bool:
	return now() < float(state.get(key, -INF))


## The detour round an open door's panel on the way to [param corner]. Returns [true, corner] when the walk should stop this tick, else [false, the corner to head for].
func _detour_step(player: HsPlayer, state: Dictionary, at: Vector3, corner: Vector3, t: float, seeker: bool) -> Array:
	# An open door's panel across the way (the mesh is baked without doors): round its free edge, then on. Without it a bot stood
	# pressed into the corner behind an open fire door.
	var detour: PackedVector3Array = state.get("detour", PackedVector3Array())
	if detour.is_empty() and t >= float(state.get("detour_check", -INF)):
		var round_door := _door_detour(at, corner, seeker)
		detour = round_door[1]
		if detour.is_empty() and int(round_door[0]) >= 0:
			# A panel across the way with no floor round it: shut it, as a person would, and the
			# walk opens it again away from this side. Not while standing where it swings.
			var index := int(round_door[0])
			var map: Node3D = game.get("map")
			var doors: Object = map.get("doors")
			var f: float = doors.call("fraction", index, int(game.get("_tick")))
			if not _shut_failed(state, index) \
					and not bool(doors.call("sweeps", index, at, HsPlayer.BODY_RADIUS, player.hull_height(), f, 0.0)):
				state["shut"] = {"index": index, "until": t + 1.5, "count": false}
			elif not _shut_failed(state, index) and _plan_shut_from_clear(player, state, index):
				# Standing where it swings: a step back out of its way first, then shut it.
				state["detour_check"] = t + 1.0
				return [true, corner]
			else:
				# It would not shut, or there is no floor to stand clear of it on: somewhere else,
				# by another way. Giving up every second while standing in the swing of a panel
				# across a manor landing kept a hider there for twenty seconds.
				_give_up_goal(player, state)
				state["detour_check"] = t + 1.0
				return [true, corner]
			state["detour_check"] = t + 0.7
		elif not detour.is_empty():
			# Round the same panel again soon after: the way on goes back through it (the path
			# is baked as if the door were not there). Somewhere else, rather than circling it
			# (`headless_bots` round 3, a hider round a village door for half a minute).
			if int(round_door[0]) == int(state.get("detour_door", -1)) and t - float(state.get("detour_at", -INF)) < DETOUR_AGAIN:
				state["detour_door"] = -1
				_give_up_goal(player, state)
				state["detour"] = PackedVector3Array()
				return [true, corner]
			state["detour_door"] = int(round_door[0])
			state["detour_at"] = t
			state["detour_until"] = t + DETOUR_SECONDS
			state["detour_pose"] = _door_fraction(int(round_door[0]))
	if not detour.is_empty():
		var round_index := int(state.get("detour_door", -1))
		if round_index >= 0 and absf(_door_fraction(round_index) - float(state.get("detour_pose", 0.0))) > 0.05:
			# The panel has moved since the way round it was planned (somebody was opening it):
			# planned on a door still swinging, a seeker pushed into where the panel came to rest
			# for four seconds at the school's fire door (`headless_bots` round 41). Again, now.
			detour = PackedVector3Array()
			state["detour_check"] = -INF
		elif t > float(state.get("detour_until", -INF)):
			detour = PackedVector3Array()
			state["detour_check"] = t + 1.0
		elif Vector2(detour[0].x - at.x, detour[0].z - at.z).length() < 0.35:
			detour.remove_at(0)
			if detour.is_empty():
				# Past it: a fresh path from here.
				state["path"] = PackedVector3Array()
		if not detour.is_empty():
			corner = detour[0]
	state["detour"] = detour
	return [false, corner]


## Hops at a jump-up link's foot and crouches under a low ceiling ahead.
func _hop_and_duck(command: DotFpsCommand, at: Vector3, corner: Vector3, dir: Vector3, player: HsPlayer) -> void:
	# A jump-up link (the annotator found a ledge within a body's jump): hop at its foot.
	if corner.y - at.y > HsPlayer.BODY_STEP + 0.05 and player.controller.state.is_grounded():
		for foot in _jump_feet:
			if Vector2(foot.x - at.x, foot.z - at.z).length() < 1.2 and absf(foot.y - at.y) < 0.6:
				command.set_button(DotFpsCommand.BUTTON_JUMP, true)
				break

	# A ceiling low ahead: crouch under it.
	if dir.length() > 0.01:
		var ahead := at + dir.normalized() * 0.6
		if not _los(ahead + Vector3(0.0, 0.5, 0.0), ahead + Vector3(0.0, HsPlayer.BODY_HEIGHT + 0.05, 0.0)):
			command.set_button(DotFpsCommand.BUTTON_CROUCH, true)


## Walks [param player] along the mesh to [param goal]. Returns true when there.
func _walk_to(player: HsPlayer, command: DotFpsCommand, state: Dictionary, goal: Vector3, sprint: bool, look: bool = true, seeker: bool = false) -> bool:
	# Shutting a door that stands open across the way (see the detour below).
	if _shut_door(player, command, state):
		return false
	# Stepping back out of a shut door's swing to open it (see `_open_from_clear`).
	if _open_from_clear(player, command, state):
		return false
	var at := player.controller.state.position
	var flat := Vector2(goal.x - at.x, goal.z - at.z).length()
	if player.controller.has_modifier(HsPlayer.HsController.HOLD):
		# Held (a new seeker's freeze): going nowhere is the rule, not being stuck, and the
		# walk starts its count afresh when let go.
		state["stuck"] = [at, now()]
		state["linger_at"] = Vector3.INF
		return false

	if flat < 0.6 and absf(goal.y - at.y) < 1.2:
		state["path"] = PackedVector3Array()
		# There: whatever held it up on the way is over.
		state["stuck_at"] = Vector3.INF
		state["stuck_count"] = 0
		state["linger_at"] = Vector3.INF
		return true

	_note_lingering(state, at, now())

	var t := now()
	if _linger_by_door(player, state, at, t):
		return false
	var path: PackedVector3Array = state["path"]
	if path.is_empty() or (state["goal"] as Vector3).distance_to(goal) > 1.0 or t - float(state["path_at"]) > 3.0:
		path = nav.path(at, goal) if nav.is_ready() else PackedVector3Array()
		# A path that goes nowhere (ends where the bot stands, short of the goal) starts on an island of the mesh, a landing or desk top it
		# climbed onto. Go straight for the goal, which steps it off; following the path kept a hider there.
		if path.size() < 2 or (path.size() == 2 and Vector2(path[1].x - at.x, path[1].z - at.z).length() < 0.5 \
				and Vector2(goal.x - at.x, goal.z - at.z).length() > 2.0):
			path = PackedVector3Array([at, goal])
		state["path"] = path
		state["corner"] = 1
		state["goal"] = goal
		state["path_at"] = t

	var corner := _next_corner(state, at)

	var round_door_step := _detour_step(player, state, at, corner, t, seeker)
	if bool(round_door_step[0]):
		return false
	corner = round_door_step[1]
	var dir := Vector3(corner.x - at.x, 0.0, corner.z - at.z)
	var detour: PackedVector3Array = state["detour"]
	if detour.is_empty() and _plan_open_from_clear(player, state, dir):
		return false

	# Stuck on something the mesh does not know (an open door's panel stands across a path baked
	# without doors): step round it, sideways and back, for a moment.
	if t < float(state.get("sidestep_until", -INF)) and dir.length() > 0.01:
		dir = dir.normalized().rotated(Vector3.UP, deg_to_rad(110.0) * float(state.get("sidestep_side", 1.0)))

	if look:
		_look(player, command, Vector3(corner.x, player.eye_position().y + (corner.y - at.y) * 0.5, corner.z))
	state["walk_dir"] = dir
	_walk(command, dir)
	command.set_button(DotFpsCommand.BUTTON_SPRINT, sprint)

	_hop_and_duck(command, at, corner, dir, player)
	_unstick(player, command, state)
	return false


## Turns toward [param point] at the bot's turn rate.
func _look(player: HsPlayer, command: DotFpsCommand, point: Vector3) -> void:
	var view := _aim_of(player).look_at_point(player.eye_position(), point, dt())
	command.yaw = view.x
	command.pitch = clampf(view.y, -60.0, 60.0)
	# The walk was worked out against the old view; keep it going the same way in the world.


## Hops, then steps aside, then asks for somewhere else, when it has made no headway for [constant STUCK_SECONDS]. The count resets only once
## the bot is [constant STUCK_LEFT] from where it first stuck: a reset on any small move let a step aside and back reset it every time.
func _unstick(player: HsPlayer, command: DotFpsCommand, state: Dictionary) -> void:
	var mark: Array = state["stuck"]
	var at := player.controller.state.position
	var t := now()
	if t - float(mark[1]) < STUCK_SECONDS:
		return
	var stuck := Vector2(at.x - (mark[0] as Vector3).x, at.z - (mark[0] as Vector3).z).length() < 0.3
	var first: Vector3 = state.get("stuck_at", Vector3.INF)
	if not stuck and first != Vector3.INF and Vector2(at.x - first.x, at.z - first.z).length() < STUCK_LEFT:
		# Moving, but round the same spot.
		state["stuck"] = [at, t]
		return
	# On the ground, or caught on an edge in the air without rising or falling: a bot pressed
	# into a door's jamb at the top of a camp cabin's steps hung a few centimetres up for half a
	# minute, never on the ground, so it was never stuck (`headless_bots` round 18).
	var hung := player.controller.state.mode == DotFpsState.Mode.AIR and absf(player.controller.state.velocity.y) < 1.0
	if stuck and (player.controller.state.mode == DotFpsState.Mode.GROUND or hung):
		if first == Vector3.INF:
			state["stuck_at"] = at
		# A panel it could not see coming: round it, before anything blinder.
		state["detour_check"] = -INF
		# Caught on a doorway's frame on the way through: square to the doorway's middle and
		# through, before a hop or a step aside.
		if int(state.get("stuck_count", 0)) == 0 and _through_doorway(state, at, t):
			state["stuck_count"] = 1
			state["stuck"] = [at, t]
			return
		var stream: DotRandomStream = state["stream"]
		# Every other time a hop (a kerb, a step), else a step aside. Never a hop at something
		# waist-high: that is a desk, and a bot hopped up on one stood there for half a minute
		# (`headless_bots` round 11, a school classroom).
		var ahead := _next_corner(state, at) - at
		ahead.y = 0.0
		var waist := at + Vector3(0.0, 0.6, 0.0)
		# Nor under a low ceiling (a crawl space): a hop there goes nowhere but into the floor above.
		var headroom := _los(at + Vector3(0.0, 0.5, 0.0), at + Vector3(0.0, HsPlayer.BODY_HEIGHT + 0.05, 0.0))
		var low_only := headroom and (ahead.length() < 0.01 or _los(waist, waist + ahead.normalized() * 0.8))
		# Or the next corner is a step or more up and close: a bot beside a stair's side edge (the
		# path cuts the flight's corner) pushed at a riser it can hop and sidestepped away from it
		# (`headless_bots` round 36, the camp cabin's steps, eight seconds).
		var up := _next_corner(state, at).y - at.y
		var hop_up := up > 0.3 and up < 0.8 and ahead.length() < 0.8 and headroom
		if (int(state.get("stuck_count", 0)) % 2 == 0 and low_only) or hop_up:
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		else:
			state["sidestep_until"] = t + 0.7
			state["sidestep_side"] = _sidestep_side(at, ahead, stream)
		state["path"] = PackedVector3Array()
		state["stuck_count"] = int(state.get("stuck_count", 0)) + 1
		# Stuck three times on the way to one place: somewhere else.
		if int(state["stuck_count"]) >= 3:
			_give_up_goal(player, state)
	elif not stuck:
		state["stuck_count"] = 0
		state["stuck_at"] = Vector3.INF
	state["stuck"] = [at, t]


## Round and round one spot beside an open door's panel for [constant LINGER_SHUT]: the panel is the thing in the way, so the bot shuts it
## and the walk opens it again from its own side; standing where it swings, it steps back first, or with no floor goes elsewhere.
## Once for each spot. True when it started any of them.
func _linger_by_door(player: HsPlayer, state: Dictionary, at: Vector3, t: float) -> bool:
	var anchor: Vector3 = state.get("linger_at", Vector3.INF)
	var since := float(state.get("linger_since", t))
	if anchor == Vector3.INF:
		return false
	# A hider's goal lies under the open panel (the door was shut when the place was chosen): shutting or stepping back cannot get it there,
	# so choose again at LINGER_POCKET instead of after the shut attempt.
	if t - since >= LINGER_POCKET and t - since < LINGER_SHUT and float(state.get("linger_gave", -INF)) != since \
			and (not (state.get("spot", {}) as Dictionary).is_empty() or state.get("target", StringName()) != StringName()) and _open_door_near(state.get("goal", Vector3.INF), HsPlayer.BODY_RADIUS + 0.3):
		state["linger_gave"] = since
		_give_up_goal(player, state)
		state["detour"] = PackedVector3Array()
		return true
	if t - since < LINGER_SHUT:
		return false
	if float(state.get("linger_acted", -INF)) == since:
		# Shut it, or stepped back to, and still round the same spot: somewhere else, once.
		# Again every LINGER_GIVE_UP seconds more: the new place can lie behind the same pile of
		# props, and a single try left a hider beside a doorway for 132 s (`headless_bots`, hs_frontyard).
		var gave := float(state.get("linger_gave_at", -INF))
		if t - since < LINGER_GIVE_UP or t - gave < LINGER_GIVE_UP * 0.5 or _open_door_index_near(anchor, 2.0) < 0:
			return false
		state["linger_gave"] = since
		state["linger_gave_at"] = t
		_give_up_goal(player, state)
		state["detour"] = PackedVector3Array()
		return true
	var index := _open_door_index_near(anchor, 2.0)
	if index < 0:
		return false
	state["linger_acted"] = since
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors")
	var f: float = doors.call("fraction", index, int(game.get("_tick")))
	if not bool(doors.call("sweeps", index, at, HsPlayer.BODY_RADIUS, player.hull_height(), f, 0.0)):
		state["shut"] = {"index": index, "until": t + 1.5, "count": false}
		state["path"] = PackedVector3Array()
		state["detour"] = PackedVector3Array()
		return true
	if _shut_failed(state, index) or not _plan_shut_from_clear(player, state, index):
		_give_up_goal(player, state)
	return true


## Somewhere else: a seeker's next place, a hider's next spot (not this one).
func _give_up_goal(player: HsPlayer, state: Dictionary) -> void:
	var at := player.controller.state.position
	state["stuck_count"] = 0
	state["stuck_at"] = Vector3.INF
	# A seeker's place is the search's own entry: crossed off for now, or the search hands the
	# same place straight back (`headless_bots` round 22, a seeker at a park door for a minute).
	var place: Dictionary = state.get("goal_place", {})
	if place.has("seen_at"):
		place["seen_at"] = now()
	state["goal_place"] = {}
	if game.call("team_of", player.player_id) != 1:
		state["chase_off_until"] = now() + CHASE_OFF_FOR
	# The tour's remaining stops are as far across the map as the one given up, and the way to
	# them is the same doorway: the nearest-first sweep takes over (`headless_bots`, a camp
	# corridor, eleven seconds beside a panel that a stop at a time kept being sent through).
	state["tour"] = []
	var ahead_path: PackedVector3Array = state["path"]
	var ahead_at := int(state.get("corner", 1))
	state["shunned"] = ahead_path[ahead_at] if ahead_at < ahead_path.size() else at
	state["shunned_until"] = now() + SHUN_FOR
	state["path"] = PackedVector3Array()
	if game.call("team_of", player.player_id) == 1 and state["mode"] != &"hidden":
		# A hider that was running stays near: the annotator's spots are all over the map, and
		# one told to give up its goal sent itself across it, through the same doorway, a place
		# at a time (`headless_bots`, a camp corridor for eleven seconds).
		var near := 14.0 if state["mode"] == &"fleeing" else INF
		_pick_spot(player, state, PackedVector3Array([(state["spot"] as Dictionary).get("at", at)]), near)



func _pick_spot(player: HsPlayer, state: Dictionary, avoid: PackedVector3Array, within: float = INF) -> void:
	var at := player.controller.state.position
	var taken := PackedVector3Array()
	for id: StringName in _state:
		if id == player.player_id:
			continue
		var other: Dictionary = (_state[id] as Dictionary).get("spot", {})
		if not other.is_empty():
			taken.append(other["at"])
	taken.append_array(avoid)

	var threats := PackedVector3Array()
	var map: Node3D = game.get("map")
	var seats: int = 2
	for i in range(seats):
		var spawn: Array = map.call("spawn", "seekers", i)
		threats.append(spawn[0])

	var phase: int = game.get("phase")
	var left: float = float(game.call("seconds_left")) if phase == 1 else 30.0
	var speed := player.controller.tunables.max_speed
	var pool := _hider_pool(threats)
	if within < INF:
		pool = spots.filter(func(s: Dictionary) -> bool: return (s["at"] as Vector3).distance_to(at) < within)
	pool.assign(_without_avoided(state, pool, now()))

	var start := nav.closest(at) if nav.is_ready() else at
	# A shuffle "within" so many metres is within so many metres of walking: a place 9 m away
	# through a wall, reached round a corridor and through a door, was a hider walking in the
	# open for ten seconds (`headless_bots` round 1).
	var walk_limit := within * 1.3 if within < INF else INF
	var shun: Vector3 = state.get("shunned", Vector3.INF)
	var seeker_start := nav.closest(threats[0]) if nav.is_ready() and not threats.is_empty() else Vector3.INF
	var reachable := func(spot: Vector3) -> bool:
		# Joined first: a path query between islands is a navigation server error.
		if nav.is_ready() and not nav.joined(start, spot):
			return false
		var length := nav.path_length(start, spot) if nav.is_ready() else at.distance_to(spot)
		# A place the seekers cannot walk to (a basement the importer left unjoined) is not a
		# hiding place, it is a round nobody can win.
		if seeker_start != Vector3.INF and not nav.joined(seeker_start, spot):
			return false
		# Not by the way it just gave up on (see `_give_up_goal`).
		if nav.is_ready() and length < INF and shun != Vector3.INF and now() < float(state.get("shunned_until", -INF)):
			var way := nav.path(start, spot)
			for i in range(way.size()):
				if Vector2(way[i].x - shun.x, way[i].z - shun.z).length() < SHUN_RADIUS and absf(way[i].y - shun.y) < 2.0:
					return false
		return length < maxf(left - 4.0, 8.0) * speed * 0.9 and length < walk_limit

	var stream: DotRandomStream = state["stream"]
	var chosen := DotBotHiding.choose(pool, at, threats, taken, stream, settings().profile.map_knowledge, reachable)

	# Asked three times and nothing reachable from here (a spawn just off the walkable mesh):
	# the best spot regardless, and the walk will find its way or hop.
	if chosen.is_empty() and int(state.get("retries", 0)) >= 3:
		# Still only where the seekers can walk: a hider shut in a basement is a round nobody wins.
		chosen = DotBotHiding.choose(pool, at, threats, taken, stream, settings().profile.map_knowledge,
				func(spot: Vector3) -> bool: return seeker_start == Vector3.INF or nav.joined(seeker_start, spot))
	state["retries"] = int(state.get("retries", 0)) + 1

	if chosen.is_empty():
		# Nothing reachable from here yet (in the air at the start, or nothing surveyed): stay, and
		# ask again in a second.
		state["spot"] = {}
		state["retry_at"] = now() + 1.0
		return

	state["spot"] = chosen
	state["came_from"] = at
	state["mode"] = &"going"
	state["path"] = PackedVector3Array()


## The hiding spots as a hider sees them: out of sight first (exposure), tucked in (enclosure), best behind cover from the seekers' start
## ([method cover_from]). Folded into `exposure` so [DotBotHiding.choose] ranks them as before; the measured share stays in `seen_exposure`.
func _hider_pool(threats: PackedVector3Array) -> Array[Dictionary]:
	if not _pool.is_empty() and _pool_threats == threats:
		return _pool
	_pool.clear()
	_pool_threats = threats
	var covered := {}
	if annotations != null and not annotations.hiding.is_empty():
		var behind := {}
		for threat in threats:
			for spot in annotations.cover_from(threat, threat, 1000.0, "low"):
				behind[spot["at"]] = int(behind.get(spot["at"], 0)) + 1
		for at: Vector3 in behind:
			if int(behind[at]) >= threats.size():
				covered[at] = true
	for spot in spots:
		var copy := spot.duplicate()
		var raw := float(spot["exposure"])
		copy["seen_exposure"] = raw
		copy["covered"] = covered.has(spot["at"])
		copy["exposure"] = clampf(raw - ENCLOSED_BONUS * float(spot.get("enclosure", 0.0)) - (COVER_BONUS if covered.has(spot["at"]) else 0.0), 0.0, 1.0)
		_pool.append(copy)
	return _pool

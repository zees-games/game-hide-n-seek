extends "hs_bots_hide.gd"

## The stand-ins: hiders that hide and seekers that search, on dot-bot's settings. The map is surveyed once in `_prepare`
## (DotBotNav mesh, DotBotHiding.survey scoring places by sight lines); a hider picks a hidden place apart from the others, a seeker searches with DotBotSearch.
## Nobody cheats: a bot knows another body only by seeing or hearing it, the last-hiders beacon being the one exception.


func _init(p_game: Node = null) -> void:
	game = p_game


## What every stand-in presses this tick. Called by the game before the bodies move.
func drive() -> void:
	var players: Dictionary = game.get("players")
	var any := false

	for id: StringName in players:
		if (players[id] as HsPlayer).is_bot:
			any = true
			break

	if not any:
		return

	var phase: int = game.get("phase")

	if phase != 0:
		_prepare()

	_hear_steps(players)

	for id: StringName in players:
		var player: HsPlayer = players[id]

		if not player.is_bot or not player.is_alive() or player.watching:
			continue

		var command := DotFpsCommand.new()
		command.yaw = player.controller.state.yaw
		command.pitch = player.controller.state.pitch
		var aim := _aim_of(player)
		aim.view_from(command.yaw, command.pitch)

		var side: int = game.call("team_of", id)

		if legacy:
			_legacy(player, command, side, phase)
		elif phase == 0:
			pass
		elif side == 1:
			_hide(player, command)
		elif phase == 2:
			_seek(player, command)

		_step_round_people(player, command, players)
		player.controller.apply_command(command)
		# Pressed and let go on alternate ticks, so the game sees an edge each time.
		if bool(_state_of(player).get("use_now", false)):
			_state_of(player)["use_now"] = false
			player.wants_use = not player.wants_use
		else:
			player.wants_use = _wants_door(player, command)

	# Sounds older than a second are gone.
	var t := now()
	for i in range(_sounds.size() - 1, -1, -1):
		if t - float(_sounds[i]["t"]) > 1.0:
			_sounds.remove_at(i)


## [member legacy]: hiders stand still; a seeker walks in a straight line to the far corner of the
## map, through whatever is in the way, with no search and no chase.
func _legacy(player: HsPlayer, command: DotFpsCommand, side: int, phase: int) -> void:
	if side == 1 or phase != 2:
		return
	var box: AABB = (game.get("map") as Node3D).call("bounds")
	var at := player.controller.state.position
	var far := box.position + box.size * (Vector3(1.0, 0.0, 1.0) if at.x + at.z < box.get_center().x + box.get_center().z else Vector3.ZERO)
	var dir := Vector3(far.x - at.x, 0.0, far.z - at.z)
	if dir.length() < 1.0:
		return
	_look(player, command, Vector3(far.x, player.eye_position().y, far.z))
	_walk(command, dir)
	command.move = command.move.limit_length(_search_pace())


func _seek(player: HsPlayer, command: DotFpsCommand) -> void:
	var state := _state_of(player)
	var t := now()
	var profile := settings().profile
	var at := player.controller.state.position
	var stream: DotRandomStream = state["stream"]

	_ensure_search(state, at, profile)
	var search: DotBotSearch = state["search"]

	# Who it can see; a hider marked by the game's beacon is known to every seeker.
	var prey := _visible_prey(player, at)
	var prey_d := INF if prey == null else at.distance_to(prey.controller.state.position)

	# A chase that has lingered at a door's panel (`_give_up_goal`) is dropped for a few seconds:
	# the prey keeps circling the same doorway and the re-targeted walk went back to it each time.
	if t < float(state.get("chase_off_until", -INF)):
		prey = null
		state["target"] = StringName()

	var aim := _aim_of(player)

	if prey != null:
		# Noticed after the reaction time: a person does not move the instant something appears.
		var eye := player.eye_position()
		var head := prey.eye_position()
		var _new := aim.engage(prey.entity_id, eye, head, t)
		state["last_seen"] = prey.controller.state.position
		state["last_seen_at"] = t
		state["target"] = prey.player_id
		# A body keeping still and low takes a moment longer to make out, more the further off.
		var v := prey.controller.state.velocity
		var still := Vector2(v.x, v.z).length() < 0.5 and prey.controller.state.crouch_fraction > 0.5
		var extra := (0.5 + prey_d * 0.06) if still and prey_d > 3.0 else 0.0
		if t >= aim.react_at + extra or prey.marked:
			var view := aim.track(eye, head, prey.controller.state.velocity, t, dt())
			command.yaw = view.x
			command.pitch = clampf(view.y, -89.0, 89.0)
			state["sprint"] = true
			var _arrived := _walk_to(player, command, state, prey.controller.state.position, true, false, true)
			return
		# Seen, not yet noticed: keep doing what it was, turning that way.
	elif state["target"] != StringName() and t - float(state["last_seen_at"]) < profile.memory:
		# Lost: to where it went, then look round there.
		aim.release()
		var where: Vector3 = state["last_seen"]
		if _walk_to(player, command, state, where, true, true, true):
			search.heard(where, t, 9.0)
			state["target"] = StringName()
		search.observe(player.eye_position(), player.aim_direction(), profile.fov, profile.sight, _los, t)
		return
	else:
		state["target"] = StringName()

	# Heard something: the places round it first, and go if it is the going kind.
	var heard := _heard(player, 1)
	if not heard.is_empty():
		var where: Vector3 = heard["at"]
		var d := at.distance_to(where)
		# The further, the vaguer.
		var vague := where + Vector3(stream.next_range_f(-1.0, 1.0), 0.0, stream.next_range_f(-1.0, 1.0)) * d * 0.15
		search.heard(vague, t)
		if stream.next_unit() < profile.aggression * 0.5 or float(heard["loud"]) >= LOUD_TAUNT:
			state["goal_place"] = {"at": nav.closest(vague)}
			state["path"] = PackedVector3Array()

	# Search: look at what is in view, go to the next likely place.
	if int(game.get("_tick")) % 4 == 0:
		var _crossed := search.observe(player.eye_position(), player.aim_direction(), profile.fov, profile.sight, _los, t)

	var place := _goal_place_for(player, state, search, at, t, stream)

	state["sprint"] = false
	var _there := _walk_to(player, command, state, place["at"], false, true, true)
	# Searching is done at a walk: somebody running through a house looks at nothing. Crouched (a crawl space) at the same pace,
	# not that pace slowed again by the crouch.
	var pace := _search_pace()
	if command.is_pressed(DotFpsCommand.BUTTON_CROUCH):
		pace = minf(1.0, _search_pace() / maxf(player.controller.tunables.crouch_speed_scale, 0.01))
	# Not at the search pace while it lingers round one spot (`headless_bots`): a slow walk near a
	# doorway is ten seconds within 1.5 m of it.
	if t - float(state.get("linger_since", t)) < LINGER_POCKET:
		command.move = command.move.limit_length(pace)
	if not (state.get("opening", {}) as Dictionary).is_empty() or not (state.get("shut", {}) as Dictionary).is_empty():
		# Facing a door to open or shut it: the search's glances would turn it away, and the
		# use key goes to the door it faces.
		return

	_look_while_searching(player, command, state, place, search, at, t)


## Gives a seeker its search (the places it can walk to from where it stands) and its tour, once.
func _ensure_search(state: Dictionary, at: Vector3, profile: DotBotProfile) -> void:
	if state["search"] != null:
		return
	var search := DotBotSearch.new()
	var places: Array[Dictionary] = []
	places.append_array(spots)
	places.append_array(sweep)
	# Only the places this seeker can walk to: a basement the stair does not reach was a goal
	# three seekers pressed against the floor over for a whole round (`headless_bots`,
	# hs_restaurant).
	if nav.is_ready():
		var from := nav.closest(at)
		places = places.filter(func(place: Dictionary) -> bool: return nav.joined(from, place["at"]))
	search.setup(places, profile.map_knowledge)
	state["search"] = search
	state["tour"] = _tour(at, profile.map_knowledge)


## The nearest living hider the seeker can see; a hider marked by the game's beacon is known to every seeker.
func _visible_prey(player: HsPlayer, at: Vector3) -> HsPlayer:
	var prey: HsPlayer = null
	var prey_d := INF
	for other in (game.call("players_on", 1) as Array):
		var hider := other as HsPlayer
		if not hider.is_alive() or hider.watching or hider.caught:
			continue
		var d := at.distance_to(hider.controller.state.position)
		if d < prey_d and (hider.marked or _sees(player, hider)):
			prey_d = d
			prey = hider
	return prey


## The place a seeker is walking to: kept until reached, stale or looked at, else the next of the tour, the search, or any point.
func _goal_place_for(player: HsPlayer, state: Dictionary, search: DotBotSearch, at: Vector3, t: float, stream: DotRandomStream) -> Dictionary:
	var place: Dictionary = state.get("goal_place", {})
	# Stood on it: looked at, whether or not the eye had it in view. A place inside a bush is never
	# in view from anywhere (the line to it ends in leaves), and was picked again, nearest, every
	# time: a park round's seeker stood on one for three minutes and caught nobody.
	if not place.is_empty() and at.distance_to(place["at"]) < 1.2 and place.has("seen_at"):
		place["seen_at"] = t
	if place.is_empty() or at.distance_to(place["at"]) < 1.2 or t - float(place.get("since", t)) > 25.0 \
			or float(place.get("seen_at", -INF)) > float(place.get("picked_at", -INF)):
		var claimed := PackedVector3Array()
		for id: StringName in _state:
			if id != player.player_id:
				var theirs: Dictionary = (_state[id] as Dictionary).get("goal_place", {})
				if not theirs.is_empty():
					claimed.append(theirs["at"])
		# A walk that went through the spot it last gave up at (a doorway whose panel it could not
		# pass) is a long way round, whatever its length: the nearest places were all on the far
		# side of that panel and it gave up at it once a second (`headless_bots`, a camp corridor).
		var shunned: Vector3 = state.get("shunned", Vector3.INF)
		var shun := shunned != Vector3.INF and t < float(state.get("shunned_until", -INF))
		var distance := func(a: Vector3, b: Vector3) -> float:
			if not nav.is_ready():
				return a.distance_to(b)
			if not nav.joined(a, b):
				return INF
			if shun:
				var way := nav.path(a, b)
				for i in range(way.size()):
					if Vector2(way[i].x - shunned.x, way[i].z - shunned.z).length() < SHUN_RADIUS and absf(way[i].y - shunned.y) < 2.0:
						return nav.path_length(a, b) + SHUN_COST
			return nav.path_length(a, b)
		place = _tour_next(state, at, claimed, search, t)
		if place.is_empty():
			place = search.next(at, t, claimed, stream, distance)
		if place.is_empty():
			# Everything looked at: start over, nearest first.
			search.recheck = 20.0
			place = search.next(at, t, claimed, stream, distance)
		if place.is_empty():
			place = {"at": nav.random_point(stream) if nav.is_ready() else at}
		place["since"] = t
		place["picked_at"] = t
		state["goal_place"] = place
		state["path"] = PackedVector3Array()
	return place


## Where a searching seeker looks: at the place once near it, else along the way with a glance from side to side.
func _look_while_searching(player: HsPlayer, command: DotFpsCommand, state: Dictionary, place: Dictionary, search: DotBotSearch, at: Vector3, t: float) -> void:
	var target: Vector3 = place["at"]
	# Only while the walk is heading that way too: staring at a place across a wall while the path leaves by a doorway is walking
	# sideways at a fifth of the pace, which reads as stuck and gives up the goal.
	var to_place := Vector2(target.x - at.x, target.z - at.z)
	var walking: Vector3 = state.get("walk_dir", Vector3.ZERO)
	var heading := Vector2(walking.x, walking.z)
	var along := to_place.length() < 2.0 or heading.length() < 0.1 or absf(to_place.angle_to(heading)) < deg_to_rad(90.0)
	if at.distance_to(target) < search.look_reach and along:
		_look(player, command, target + Vector3(0.0, 0.6, 0.0))
	else:
		var sweep := sin(t * 1.3 + float(player.entity_id % 7)) * 35.0
		var dir := Vector3(walking.x, 0.0, walking.z)
		if dir.length() > 0.1:
			dir = dir.normalized().rotated(Vector3.UP, deg_to_rad(sweep))
			_look(player, command, player.eye_position() + dir * 5.0)


## The places a seeker goes to before it sweeps: the best hiding spots (as many as its knowledge
## of the map allows) and the map's chokepoints (the doorways everything walks through, so a
## hider slipping past is seen), nearest next from where it starts. `[{at}]`.
func _tour(from: Vector3, knowledge: float) -> Array[Dictionary]:
	var stops: Array[Dictionary] = []
	if annotations == null:
		return stops
	var count := roundi(lerpf(float(TOUR_MIN), float(TOUR_SPOTS), clampf(knowledge, 0.0, 1.0)))
	for i in range(mini(count, spots.size())):
		stops.append({"at": spots[i]["at"]})
	for i in range(mini(TOUR_CHOKES, annotations.chokepoints.size())):
		stops.append({"at": annotations.chokepoints[i]["at"]})
	var ordered: Array[Dictionary] = []
	var here := from
	while not stops.is_empty():
		var best := 0
		var best_d := INF
		for i in range(stops.size()):
			var d := here.distance_to(stops[i]["at"])
			if d < best_d:
				best_d = d
				best = i
		here = stops[best]["at"]
		ordered.append(stops[best])
		stops.remove_at(best)
	return ordered


## The next tour stop this seeker can reach that no other seeker is heading for, or empty when
## the tour is done: the sweep takes over. A stop it has had in view on the way is dropped.
func _tour_next(state: Dictionary, at: Vector3, claimed: PackedVector3Array, search: DotBotSearch, t: float) -> Dictionary:
	var tour: Array = state.get("tour", [])
	while not tour.is_empty():
		var stop: Dictionary = tour.pop_front()
		var there: Vector3 = stop["at"]
		var taken := false
		for other in claimed:
			if other.distance_to(there) < TOUR_APART:
				taken = true
				break
		if taken or (nav.is_ready() and not nav.joined(at, there)):
			continue
		var seen := false
		for place in search.places:
			if (place["at"] as Vector3).distance_to(there) < 1.5 and t - float(place["seen_at"]) < search.recheck:
				seen = true
				break
		if seen:
			continue
		return {"at": there, "tour": true}
	return {}


## How well a body crouched at [param at] is hidden, by one measure: `[exposure, enclosure]`, the share of this map's watchers within 30 m
## that see a crouched head there, and the share of sixteen directions with something within 2 m. `headless_bots` holds the hiders to it.
func quality(at: Vector3) -> Array:
	if _watch_eyes.is_empty() and nav.is_baked():
		var stream := DotRandomStream.new(7, &"hs_bot_quality")
		for _i in range(QUALITY_WATCHERS):
			_watch_eyes.append(nav.random_point(stream) + Vector3(0.0, HsPlayer.EYE_HEIGHT, 0.0))
	var head := at + Vector3(0.0, HsPlayer.BODY_CROUCH * 0.85, 0.0)
	var near := 0
	var seen := 0
	for eye in _watch_eyes:
		var d := eye.distance_to(head)
		if d > 30.0 or d < 1.0:
			continue
		near += 1
		if _los(eye, head):
			seen += 1
	var blocked := 0
	for k in range(16):
		var a := float(k) * TAU / 16.0
		if not bool(game.call("_clear_between", head, head + Vector3(cos(a), 0.0, sin(a)) * 2.0, false)):
			blocked += 1
	return [float(seen) / float(near) if near > 0 else 0.5, float(blocked) / 16.0]


## Where the old stand-ins' hiders would have gone on this map: [param count] hiders each
## choosing from the old random survey (dot-bot's own scoring, apart from one another, away from
## the seekers' start), which is the yardstick the annotator's spots are measured against.
func legacy_picks(count: int) -> PackedVector3Array:
	var picks := PackedVector3Array()
	var map: Node3D = game.get("map")
	if map == null or not nav.is_baked():
		return picks
	var stream := DotRandomStream.new(11, &"hs_bot_legacy")
	var old := _random_survey(map, stream, SURVEY_POINTS, SURVEY_PROPS)
	var threats := PackedVector3Array()
	for i in range(2):
		threats.append((map.call("spawn", "seekers", i) as Array)[0])
	for _i in range(count):
		var chosen := DotBotHiding.choose(old, Vector3.ZERO, threats, picks, stream, settings().profile.map_knowledge)
		if not chosen.is_empty():
			picks.append(chosen["at"])
	return picks


func describe() -> Dictionary:
	return {"spots": spots.size(), "survey_ms": snappedf(survey_ms, 0.1), "nav": nav.describe(), "bots": _state.size()}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["bots  %d hiding spots (%d sweep) in %.0f ms, %d links, %d chokepoints, annotated in %.0f ms%s" % [
		spots.size(), sweep.size(), survey_ms, links_used, annotations.chokepoints.size() if annotations != null else 0, annotate_ms, " (cached)" if annotate_cached else ""]])
	lines.append_array(nav.describe_lines())
	for id: StringName in _state:
		var s: Dictionary = _state[id]
		lines.append("  %-10s %-8s goal %s" % [String(id), String(s["mode"]), str((s.get("spot", {}) as Dictionary).get("at", "-"))])
	return lines

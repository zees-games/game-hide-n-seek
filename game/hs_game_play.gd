extends "hs_game_state.gd"
## The round's rules in play of [HsGame]: catching, doors, toys, taunts, beacons (a middle layer, split off for size); never used on its own.



func _on_round_started(number: int) -> void:
	round_number = number
	_round_seed = config.seed_value + number * 7919
	random.reseed(_round_seed)

	# A new map once this one has had its rounds, or as soon as the players voted for one.
	if next_map_id != &"" or (_rounds_on_map >= config.rounds_per_map and not _map_unplayed):
		_lay_out_map()

	_map_unplayed = false
	_decided = false
	_winner = 0
	_winner_name = ""
	seek_elapsed = 0.0
	bots.reset()
	_to_respawn.clear()

	if taunts != null:
		taunts.reset()

	# Every door back to how the map has it: last round's open cupboard is not this round's
	# clue.
	if map.doors != null:
		map.doors.reset()

	# And every toy home: a ball kicked into last round's hiding place is not a pointer to it.
	if map.toys != null:
		map.toys.reset()

	_draw_sides()
	_first_caught_before = first_caught
	first_caught = &""
	_place_everybody()

	if progress != null:
		progress.on_round_began()

	_set_phase(Phase.HIDE)
	round_began.emit(number, map.id())

	DotLog.info(CHANNEL, "round began", {
		"number": number, "map": String(map.id()), "seed": _round_seed,
		"players": players.size(), "seekers": ", ".join(_names(players_on(SEEKERS))),
	})


func _on_round_ended(number: int, winner: int, _outcome: int) -> void:
	_set_phase(Phase.IDLE)
	_rounds_on_map += 1

	if not _decided:
		_winner_name = "the round ran out"

	if progress != null:
		progress.on_round_over(winner)

	round_over.emit(number, winner, _winner_name)
	DotLog.info(CHANNEL, "round over", {"number": number, "winner": _winner_name})


## Who seeks first this round: [DotTeamRotation], with the server's mode and the players'
## wishes — or, under FIRST_CAUGHT, whoever was caught first last round and the draw for the
## rest.
func _draw_sides() -> void:
	var keys: Array[StringName] = []

	for id: StringName in players:
		keys.append(id)

	keys.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	var wishes := {}

	if config.allow_side_choice:
		for id in keys:
			match (players[id] as HsPlayer).side_wish:
				SEEKERS:
					wishes[id] = 1
				HIDERS:
					wishes[id] = -1

	var want := seekers_for(keys.size())
	var chosen: Array[StringName] = []
	var why := ""

	# The one picked by being caught first is picked whatever they wished: being found first
	# IS the wish, and a server that wants wishes to win has the other three modes.
	if config.seeker_pick == HsConfig.Pick.FIRST_CAUGHT and want > 0 and keys.has(first_caught):
		chosen.append(first_caught)
		why = "%s was caught first" % String(first_caught)

	var rest: Array[StringName] = []

	# Nobody behind a loading cover is drawn to seek while there are others to draw: a seeker
	# that cannot see would be frozen out of the round. If too few are loaded, take them all.
	var ready: Array[StringName] = []

	for id in keys:
		if not chosen.has(id):
			rest.append(id)
			if not is_loading(id):
				ready.append(id)

	if ready.size() >= want - chosen.size():
		rest = ready

	var mode := DotTeamRotation.Mode.RANDOM if config.seeker_pick == HsConfig.Pick.FIRST_CAUGHT \
		else config.seeker_pick as DotTeamRotation.Mode

	if want - chosen.size() > 0:
		var picked: Dictionary = DotTeamRotation.pick(
			rest, want - chosen.size(), mode, seeker_history, _round_seed, wishes
		)

		for id: StringName in picked["picked"]:
			chosen.append(id)

		why = "%s%s" % [why + "; " if why != "" else "", str(picked["why"])]

	DotTeamRotation.note(seeker_history, keys, chosen, round_number)

	for id in keys:
		_set_side(id, SEEKERS if chosen.has(id) else HIDERS)

	if not keys.is_empty():
		DotLog.debug(CHANNEL, "seekers drawn", {"why": why})


func _advance_phase(delta: float) -> void:
	if phase == Phase.IDLE:
		return

	phase_elapsed += delta

	match phase:
		Phase.HIDE:
			if phase_elapsed >= hide_limit():
				seek_elapsed = 0.0
				_set_phase(Phase.SEEK)
			else:
				_check_round(false)
		Phase.SEEK:
			seek_elapsed += delta
			_check_round(true)


## Who is caught this tick: by a touch, by being watched, or both, as the server is set.
## A touch is two capsules within tag_range with no wall between (the wall test stops a tag through a partition).
## Being watched is a meter that drains when nobody watches, so breaking line of sight is the answer.
func _advance_catching(delta: float) -> void:
	if phase != Phase.SEEK:
		return

	var hunting: Array[HsPlayer] = []

	for seeker in players_on(SEEKERS):
		if seeker.is_alive() and not seeker.watching and seeker.held_until < 0.0 \
				and not is_loading(seeker.player_id):
			hunting.append(seeker)

	for hider in players_on(HIDERS):
		if phase != Phase.SEEK or _decided:
			return

		if not hider.is_alive() or hider.watching or hider.caught:
			continue

		# Behind its cover a client cannot see or run: no touch, no sight, and the meter rests.
		# [method catch] itself stays open to an admin's hs_catch and to a fall.
		if is_loading(hider.player_id):
			hider.watched_by = &""
			continue

		if config.catches_by_touch():
			var toucher := _toucher(hider, hunting)

			if toucher != null:
				catch(hider.player_id, toucher.player_id, CAUGHT_TAG)
				continue

		if config.catches_by_sight():
			var watcher := _watcher(hider, hunting)

			if watcher != null:
				hider.watched_by = watcher.player_id
				hider.sight_meter = minf(hider.sight_meter + delta / maxf(config.sight_seconds, 0.05), 1.0)
			else:
				hider.sight_meter = maxf(hider.sight_meter - delta * config.sight_decay, 0.0)

			if hider.sight_meter >= 1.0:
				catch(hider.player_id, hider.watched_by, CAUGHT_SIGHT)


## The first seeker touching [param hider], or null.
func _toucher(hider: HsPlayer, hunting: Array[HsPlayer]) -> HsPlayer:
	var at := hider.controller.state.position

	for seeker in hunting:
		var there := seeker.controller.state.position
		var flat := Vector2(at.x - there.x, at.z - there.z).length()

		if flat > config.tag_range or absf(at.y - there.y) > TAG_HEIGHT:
			continue

		var middle := Vector3(0.0, 0.9, 0.0)

		if _clear_between(there + middle, at + middle):
			return seeker

	return null


## A seeker who can see [param hider] now, or null: in range, inside their view cone, nothing solid
## between their eyes and the hider's head or chest. Furniture blocks sight, people do not, so a
## seeker standing in front of another seeker has seen the hider too.
func _watcher(hider: HsPlayer, hunting: Array[HsPlayer]) -> HsPlayer:
	var half := deg_to_rad(config.sight_fov * 0.5)
	var crouched := hider.controller.state.crouch_fraction > 0.5
	var points: Array[Vector3] = [
		hider.controller.state.position + Vector3(0.0, 0.7 if crouched else 1.6, 0.0),
		hider.controller.state.position + Vector3(0.0, 0.45 if crouched else 1.0, 0.0),
	]

	for seeker in hunting:
		var eye := seeker.eye_position()
		var forward := seeker.aim_direction()

		for point in points:
			var toward := point - eye

			if toward.length() > config.sight_range or toward.length() < 0.01:
				continue

			if forward.angle_to(toward) > half:
				continue

			if _clear_between(eye, point, true):
				return seeker

	return null


## [param id] is caught: by [param by] (a seeker, or empty for a fall), [param how] one of the
## CAUGHT_ constants. Server side; public so a suite and an admin can do it directly.
## A caught hider becomes a seeker where they stand, held still so they cannot pass the catch on.
func catch(id: StringName, by: StringName, how: StringName) -> bool:
	var hider: HsPlayer = players.get(id)

	if hider == null or team_of(id) != HIDERS or hider.caught or hider.watching or not hider.is_alive():
		return false

	if phase != Phase.SEEK:
		return false

	hider.caught = true
	hider.sight_meter = 0.0
	hider.watched_by = &""
	hider.marked = false

	if first_caught == &"":
		first_caught = id

	if authoritative and by != &"" and players.has(by):
		(players[by] as HsPlayer).points += config.catch_points

	if progress != null:
		progress.on_caught(id, by, how)

	if match_node != null:
		var _fed := match_node.report_kill(String(by), String(id), how, _tick)

	if taunts != null:
		taunts.forget(id)

	if config.caught_become_seekers:
		_set_side(id, SEEKERS)
		# A fall is put back at the start by the respawn that called this.
		if config.caught_seek_from == HsConfig.CAUGHT_SEEK_START and how != CAUGHT_FELL and map != null:
			var spot := map.spawn(_spawn_side(SEEKERS), players_on(SEEKERS).size() - 1)
			hider.place_at(spot[0], spot[1])
		_hold(hider, config.caught_freeze_seconds)
	else:
		_bench(hider)

	caught.emit(id, by, how)
	bots.on_caught(id)
	DotLog.debug(CHANNEL, "caught", {"id": String(id), "by": String(by), "how": String(how)})
	_check_round(true)
	return true


## Holds [param player] still for [param seconds] from now. 0 lets them go at once.
func _hold(player: HsPlayer, seconds: float) -> void:
	if seconds <= 0.0:
		player.held_until = -1.0
		var _let_go := player.controller.remove_modifier(HsController.HOLD)
		return

	player.held_until = _now() + seconds
	var _held := player.controller.add_modifier(HsController.HOLD)


## Lets go of every seeker whose hold has run out.
func _advance_holds() -> void:
	var now := _now()

	for id: StringName in players:
		var player: HsPlayer = players[id]

		if player.held_until >= 0.0 and now >= player.held_until:
			player.held_until = -1.0

			if not (phase == Phase.HIDE and team_of(id) == SEEKERS):
				var _let_go := player.controller.remove_modifier(HsController.HOLD)


## Everybody's hand on the doors: a use is the use key going down in front of one, made an edge
## here from the held state (the key rides in every input packet, so a use is never a round trip
## behind it), and every door is posed for this tick before anybody moves against it.
func _advance_doors() -> void:
	if map == null or map.doors == null or map.doors.count() == 0:
		return

	map.doors.pose_at(_tick)


## The use key going down, for everybody: on a toy looked at (a ray, so only the one in the
## middle of the view), else on the nearest door in reach.
func _advance_use() -> void:
	for id: StringName in players:
		var player: HsPlayer = players[id]
		var pressed := player.wants_use and not player.use_was_held
		player.use_was_held = player.wants_use

		if not pressed or not player.is_alive() or player.watching or map == null:
			continue

		# Held is held: a seeker counting with the blindfold on does not open the cupboard
		# they are facing, and a hider just caught does not shut the door on the next one.
		if player.controller.has_modifier(HsController.HOLD):
			continue

		var toy := toy_aimed(player)

		if toy >= 0:
			var _played := use_toy(toy, id)
			continue

		if map.doors == null or map.doors.count() == 0:
			continue

		var index := map.doors.door_for(player.eye_position(), player.aim_direction())

		if index >= 0:
			var _used := use_door(index, id)


## Opens or shuts door [param index] for [param by], now, if it can be. What the use key does,
## and what a suite and a bot do directly.
func use_door(index: int, by: StringName) -> bool:
	if map == null or map.doors == null or index < 0 or index >= map.doors.count():
		return false

	if not config.doors_enabled:
		return false

	if map.doors.moving(index, _tick):
		return false

	# Nobody anywhere the panel will pass through: see HsDoors. Opening, it goes away from
	# whoever opened it.
	var from := map.doors.fraction(index, _tick)
	var to := 0.0 if map.doors.is_open(index) else 1.0
	var user := (players[by] as HsPlayer).eye_position() if players.has(by) else Vector3.INF
	var flip := map.doors.is_flipped(index)

	if to > 0.5 and user != Vector3.INF:
		flip = map.doors.flips_for(index, user)

	for id: StringName in players:
		var player: HsPlayer = players[id]

		if not player.is_alive() or player.watching:
			continue

		if map.doors.sweeps(index, player.controller.state.position, HsPlayer.BODY_RADIUS,
				player.hull_height(), from, to, 1 if flip else 0):
			if players.has(by) and not (players[by] as HsPlayer).is_bot:
				refused.emit(by, "Somebody is in the way of the %s." % map.doors.name_of(index))
			return false

	var open := to > 0.5
	map.doors.apply(index, open, flip, _tick)
	door_used.emit(index, open, flip, _tick, by)

	if progress != null and players.has(by):
		progress.on_door(by)

	DotLog.debug(CHANNEL, "a door was used", {
		"door": map.doors.name_of(index), "open": open, "by": String(by), "tick": _tick,
	})
	return true


## The toy [param player] is looking at within reach, or -1. Both ends: the client asks it
## for the use prompt.
func toy_aimed(player: HsPlayer) -> int:
	if map == null or map.toys == null or player == null:
		return -1
	return map.toys.aimed(player.eye_position(), player.aim_direction(), TOY_REACH)


## How far the use key reaches a toy: a ball at your feet, a switch at arm's length.
const TOY_REACH := 2.3


## Toy [param index] used by [param by]: a kick, a push, a switch, a honk. Server side.
func use_toy(index: int, by: StringName) -> bool:
	var player: HsPlayer = players.get(by)
	if map == null or map.toys == null or player == null:
		return false
	return map.toys.use(index, player.eye_position(), player.aim_direction())


## Everybody against the toys this tick, after they moved: a walk into a ball pushes it, weight
## on a see-saw tips it, and then the box's own tick (the awake cap, the lost sent home). A
## person is not a rigid body, so this is how one touches a toy at all. Server side.
func _advance_toys(delta: float) -> void:
	if map == null or map.toys == null or not authoritative:
		return

	for id: StringName in players:
		var player: HsPlayer = players[id]

		if not player.is_alive() or player.watching:
			continue

		var state := player.controller.state
		var _pushed := map.toys.push_from(state.position, state.velocity, HsPlayer.BODY_RADIUS, player.hull_height())

		if state.mode == DotFpsState.Mode.GROUND:
			var _bore := map.toys.stand_on(state.position, PERSON_MASS)

	map.toys.advance(delta)


## The trampolines and bounce pads, for every player's movement on both ends
## ([member HsController.launcher]): `{velocity, index}` or empty.
func _launch(feet: Vector3, velocity: Vector3) -> Dictionary:
	if map == null or map.toys == null:
		return {}
	return map.toys.launch_for(feet, velocity)


## A turning roundabout under a person, for their movement on both ends
## ([member HsController.carrier]): `{offset, yaw, index}` or empty.
func _carry(feet: Vector3, delta: float, ground_id: int) -> Dictionary:
	if map == null or map.toys == null:
		return {}
	return map.toys.carry_for(feet, delta, ground_id)


## A person thrown by a toy: its count goes up, which every client hears. Server side.
func _on_bounced(index: int) -> void:
	if authoritative and map != null and map.toys != null:
		map.toys.launched(index)


## A use the server made, applied on a client.
func apply_door(index: int, open: bool, flip: bool, tick: int) -> void:
	if map != null and map.doors != null:
		map.doors.apply(index, open, flip, tick)


## A hider taunts, by choice. [param taunt_id] empty picks one. Server side.
func taunt(id: StringName, taunt_id: StringName = &"") -> bool:
	var player: HsPlayer = players.get(id)

	if player == null or not player.is_alive() or player.watching or team_of(id) != HIDERS:
		return false

	# Taunts start with the seek. A seeker cannot move yet, so a taunt during the hide is no
	# risk; and the seeker's client is told nothing about where the hiders are then, so it
	# would play the sound from wherever it last saw them, which is the wrong place.
	if phase != Phase.SEEK:
		refused.emit(id, "Taunts start when the seekers are let go.")
		return false

	var may := taunts.may_taunt(id, _now())

	if not may.ok:
		refused.emit(id, may.error.message)
		return false

	var played := taunts.taunt(id, _now(), taunt_id, false, _tick)

	if played.is_empty():
		return false

	player.points += int(played["points"])
	player.taunting_id = played["id"]

	if progress != null:
		progress.on_taunted(id, false)

	taunted.emit(id, played["id"], false)
	bots.on_taunted(id)
	return true


## Every hider standing still too long, made to taunt; and the meter on the way there.
func _advance_taunts() -> void:
	if taunts == null or phase != Phase.SEEK:
		return

	var now := _now()

	for player in players_on(HIDERS):
		if not player.is_alive() or player.watching:
			continue

		taunts.observe(player.player_id, player.controller.state.position, now)
		player.taunt_meter = taunts.meter(player.player_id, now) if config.show_taunt_meter else 0.0

		if taunts.due(player.player_id, now):
			var played := taunts.taunt(player.player_id, now, &"", true, _tick + int(player.entity_id % 997))

			if played.is_empty():
				continue

			player.points += int(played["points"])
			player.taunting_id = played["id"]

			if progress != null:
				progress.on_taunted(player.player_id, true)

			taunted.emit(player.player_id, played["id"], true)
			bots.on_taunted(player.player_id)


## The last hiders given away: everybody still hidden is marked once few enough are left or
## little enough time is.
func _advance_beacons() -> void:
	var hiders_left := alive_on(HIDERS)
	var on := phase == Phase.SEEK and hiders_left > 0 and (
		(config.beacon_hiders_left > 0 and hiders_left <= config.beacon_hiders_left)
		or (config.beacon_seconds_left > 0.0 and round_limit() - seek_elapsed <= config.beacon_seconds_left)
	)

	# Shown now and then rather than held (`beacon_every`), counted from when it began.
	if not on:
		_beacon_since = -1.0
	elif config.beacon_every > 0.0:
		if _beacon_since < 0.0:
			_beacon_since = seek_elapsed
		on = fmod(seek_elapsed - _beacon_since, config.beacon_every) < config.beacon_reveal

	for player in players_on(HIDERS):
		player.marked = on and player.is_alive() and not player.watching


## Somebody below the map has fallen. A height test, not a trigger volume: something falling
## fast crosses a thin trigger between two ticks without ever being inside it.
func _watch_world() -> void:
	if map == null or map.doc.is_empty():
		return

	for id: StringName in players:
		var player: HsPlayer = players[id]

		if not player.is_alive() or player.watching:
			continue

		if player.controller.state.position.y < map.kill_height():
			var fall := DotDamage.make(0, player.entity_id, player.health.max_health * 10.0, null)
			fall.tick = _tick
			fall.context = {"why": DIED_FELL}
			var _applied := combat.apply_damage(fall)


## A fall is not the end of anybody here. A hider who falls while the seekers are out is
## caught by it (and seeks, from the seekers' start); anybody else starts again where their side
## does.
func _respawn_the_fallen() -> void:
	if _to_respawn.is_empty():
		return

	var queue := _to_respawn.duplicate()
	_to_respawn.clear()

	for id: StringName in queue:
		var player: HsPlayer = players.get(id)

		if player == null:
			continue

		_heal(player)

		if phase == Phase.SEEK and team_of(id) == HIDERS:
			var _caught := catch(id, &"", CAUGHT_FELL)

		if player.watching:
			continue

		var spot := map.spawn(_spawn_side(team_of(id)), 0)
		player.place_at(spot[0], spot[1])

		if spectate != null:
			spectate.on_spawned(id)


func _on_player_died(player: HsPlayer, damage: DotDamage) -> void:
	var by := entities.key_for_id(damage.attacker)
	var why: StringName = damage.context.get("why", DIED_SLAIN)

	player.marked = false

	if not authoritative:
		player_died.emit(player.player_id, by, why)
		return

	# A fall is a respawn (and, for a hider while the seekers are out, a catch); see
	# [method _respawn_the_fallen]. Anything else — an administrator's slay — is out for the
	# round, which is what a slay means.
	if why == DIED_FELL:
		if not _to_respawn.has(player.player_id):
			_to_respawn.append(player.player_id)
	elif spectate != null:
		spectate.on_died(
			player.player_id, by, why == DIED_FELL,
			damage.point if damage.point != Vector3.ZERO else player.global_position,
			map.kill_height() + 8.0, _tick
		)

	if progress != null and why == DIED_FELL:
		progress.on_fell(player.player_id)

	# How the body falls, picked once, here, and carried on DEATH to every client.
	player.death = decide_death(player, damage)

	player_died.emit(player.player_id, by, why)
	DotLog.debug(CHANNEL, "player died", {"id": String(player.player_id), "by": String(by), "why": String(why)})

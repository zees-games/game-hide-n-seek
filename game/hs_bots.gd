extends RefCounted

const HsPlayer := preload("hs_player.gd")

## The stand-ins: hiders that hide and seekers that search, on dot-bot's settings.
##
## [b]What the first play test saw.[/b] Bot hiders stood together in the open and three were
## tagged inside one second; seekers ran in a cluster; a bot walked into his camera. A hider then
## walked to a random spot beside a random piece of furniture, and a seeker wandered from prop to
## prop. Now:
##
## - [b]The map is surveyed once[/b] when it is built (`_prepare`): dot-bot's [DotBotNav] bakes
##   where a body can walk from the map's colliders (stairs, crawl spaces, doorways whatever their
##   doors), and [DotBotHiding.survey] scores a few hundred places on it by how many of the map's
##   sight lines reach a crouched head there. A cupboard scores near 0, a field near 1.
## - [b]A hider picks a hidden place apart from the others[/b] ([DotBotHiding.choose]: spots
##   taken nearby cost, so do the seekers' start, and a place it cannot reach before the seekers
##   are let go is out), walks the mesh's path there, crouches and keeps still. It watches and
##   listens with its own `bot_fov`, `bot_sight` and `bot_hearing`: a seeker that comes close
##   and can see it, or is heard coming close, sends it to a place out of that seeker's sight
##   ([DotBotHiding.flee_spot]), at a sprint when it is seen and quietly when it is only heard.
##   Before the standing-still clock forces a taunt it shuffles to another place nearby.
## - [b]A seeker searches[/b] with a [DotBotSearch]: the most hidden places first as far as
##   `bot_map_knowledge` goes, the nearest first, crossing off every place it has had in view, and
##   never where another seeker is already going. Footsteps and taunts it hears put the places
##   round them first. A hider it sees is noticed after `bot_reaction` (more off to the side,
##   `bot_notice`) and chased; one lost from sight is looked for where it went for `bot_memory`.
## - [b]Nobody cheats.[/b] A bot knows of another body only by seeing it (cone, range, nothing
##   solid between: the game's own sight test) or hearing it; the beacon the game puts on the
##   last hiders is the one exception, because it is the rules telling every seeker.
## - [b]The view turns at `bot_turn_rate`[/b] through [DotBotAim], never in one tick, and the bot
##   walks along its path whatever way it is looking.
## - [b]People do not collide with people,[/b] so a bot steps round anybody within a metre
##   rather than through their camera.

const CHANNEL := "hs.bots"

## How loud moving is, as a share of `bot_hearing`: sprinting, running, crouched.
const LOUD_SPRINT := 0.45
const LOUD_RUN := 0.28
const LOUD_CROUCH := 0.06

## A taunt is a shout.
const LOUD_TAUNT := 1.0

## Places surveyed: points across the walkable floor, and beside the props.
const SURVEY_POINTS := 260
const SURVEY_PROPS := 160
const WATCHERS := 80

## A seeker this near, walking straight at the hider without having seen it, is coming to its
## place. Out of the hider's sight line it slips away low; in it, the hider keeps still, because
## moving is what the seeker would see. One passing any other way is let pass.
const COMING_FROM := 12.0
const COMING_CONE := 30.0

## Where a running hider goes: out of the seeker's sight, at least this far from it, at most
## this far from where it was.
const FLEE_CLEAR := 12.0
const FLEE_WITHIN := 30.0

## A seeker this close is about to walk into the hider whatever it has seen: run.
const BUMP_FROM := 2.4

## How far past a doorway a body is clear of the panel's swing (a door is at most about a
## metre wide), before it turns to shut it.
const DOOR_CLEAR := 1.4

## How far off, as a share of `bot_sight`, somebody keeping still and crouched is made out, and
## then only whole (head and chest): a head over a sofa's back is passed over. 10 m at medium.
## It was 0.25 with either showing, and a seeker that walked the hidden places found nearly
## everybody (`headless_bots`: 4% of hiders left at medium).
const STILL_LOW_SIGHT := 0.18

## Metres from the eye within which somebody is felt whichever way the bot faces: an arm's
## length, about, past the touch's reach.
const FELT_WITHIN := 2.0

## How fast a seeker searches, as a share of a run: a walk, looking (2.1 m/s). Chasing is a sprint.
## At a run the seekers searched the hidden places of a house in a minute, and a round with one
## seeker was over long before its clock.
const SEARCH_PACE := 0.35

## Seconds a hider waits after a move before it may move again for the same seeker.
const SETTLE := 2.5

## The same for a hider the beacon is giving away, which keeps moving.
const MARKED_SETTLE := 1.0

var game: Node = null

var nav: DotBotNav = DotBotNav.new()

## `[{at, exposure}]` for the map built, or empty.
var spots: Array[Dictionary] = []

## Which map the survey is of, and which the mesh was baked for.
var _surveyed: String = ""
var _baked: String = ""
var _survey_at: int = 0

## player id -> the bot's own state.
var _state: Dictionary = {}

## Sounds this tick and the last second: `[{at, loud, by, side, t}]`.
var _sounds: Array[Dictionary] = []

## Doors stand-ins have shut behind them this round, for the suite.
var doors_shut: int = 0

## How long the last survey took, milliseconds.
var survey_ms: float = 0.0


func _init(p_game: Node = null) -> void:
	game = p_game


func settings() -> DotBotSettings:
	return DotBotSettings.of(game)


func now() -> float:
	return float(int(game.get("_tick"))) / float(maxi(int(game.get("tick_rate")), 1))


func dt() -> float:
	return 1.0 / float(maxi(int(game.get("tick_rate")), 1))


## A new round or map: every bot forgets what it was doing.
func reset() -> void:
	_state.clear()
	_sounds.clear()
	doors_shut = 0


func forget(player_id: StringName) -> void:
	_state.erase(player_id)


## Somebody was caught: the shout, and the new seeker standing where they were, is a sound every
## hider within earshot hears and moves away from.
func on_caught(player_id: StringName) -> void:
	var players: Dictionary = game.get("players")
	if not players.has(player_id):
		return
	var who: HsPlayer = players[player_id]
	_sounds.append({"at": who.controller.state.position, "loud": LOUD_TAUNT, "by": player_id, "t": now(), "caught": true})


## A taunt was played: a shout every bot within earshot hears.
func on_taunted(player_id: StringName) -> void:
	var players: Dictionary = game.get("players")
	if not players.has(player_id):
		return
	var who: HsPlayer = players[player_id]
	_sounds.append({"at": who.controller.state.position, "loud": LOUD_TAUNT, "by": player_id, "t": now()})


# --- The map ------------------------------------------------------------------

## Bakes and surveys the map now built, once per map. Only where bots run (the server, or solo).
func _prepare() -> void:
	var map: Node3D = game.get("map")
	var doc: Dictionary = game.get("map_doc")
	var key := "%s|%d" % [str(doc.get("id", "")), map.get_instance_id() if map != null else 0]

	if map == null or key == _surveyed:
		return

	if key != _baked:
		_baked = key
		spots.clear()
		# The walls, floors and furniture, never the doors: a door baked shut is a doorway the
		# mesh does not go through.
		var still: Array = [map.get("_solid"), map.get("_furniture")]
		var baked := nav.bake(map, {"radius": HsPlayer.BODY_RADIUS, "height": HsPlayer.BODY_CROUCH, "climb": HsPlayer.BODY_STEP}, 0, still)
		if not baked.ok:
			_surveyed = key
			DotLog.warn(CHANNEL, "no walkable mesh for the bots; they walk straight", {"map": str(doc.get("id", "")), "why": baked.error.message})
		# The navigation server takes the mesh in on a later frame; survey a quarter of a second
		# of game time on, always the same tick, so a round plays the same however the frames
		# fall (and later still only when the server is that slow).
		_survey_at = int(game.get("_tick")) + maxi(int(game.get("tick_rate")) / 4, 1)
		return

	if int(game.get("_tick")) < _survey_at or not nav.is_ready():
		return

	_surveyed = key
	var started := Time.get_ticks_usec()

	var random: DotRandomManager = game.get("random")
	var stream := random.stream_for(&"bot_survey", hash(str(doc.get("id", ""))) % 65536)
	var candidates := PackedVector3Array()

	for _i in range(SURVEY_POINTS):
		candidates.append(nav.random_point(stream))

	# Beside furniture, where people hide: a point a little out from a side of the prop, put
	# on the walkable mesh.
	var props: Array = map.get("props")
	var step := maxi(1, props.size() / SURVEY_PROPS)
	for i in range(0, props.size(), step):
		var prop: Dictionary = props[i]
		var frame: Transform3D = prop["transform"]
		var size: Vector3 = prop["size"]
		var side := Vector3(1.0, 0.0, 0.0).rotated(Vector3.UP, stream.next_range_f(0.0, TAU))
		var beside := frame.origin + side * (maxf(size.x, size.z) * 0.5 + 0.5)
		var on := nav.closest(beside)
		if on.distance_to(beside) < 0.8:
			candidates.append(on)

	var watchers := PackedVector3Array()
	for _i in range(WATCHERS):
		watchers.append(nav.random_point(stream) + Vector3(0.0, HsPlayer.EYE_HEIGHT, 0.0))

	var los := func(a: Vector3, b: Vector3) -> bool: return bool(game.call("_clear_between", a, b, true))
	spots = DotBotHiding.survey(candidates, watchers, los)
	survey_ms = (Time.get_ticks_usec() - started) / 1000.0 + nav.bake_ms
	DotLog.debug(CHANNEL, "surveyed the map for the bots", {
		"map": str(doc.get("id", "")), "spots": spots.size(), "nav_ms": snappedf(nav.bake_ms, 0.1), "ms": snappedf(survey_ms, 0.1),
	})


func _los(a: Vector3, b: Vector3) -> bool:
	return bool(game.call("_clear_between", a, b, true))


# --- Every tick -----------------------------------------------------------------

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

		if phase == 0:
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
			"last_seen_at": -INF, "still_since": now(), "sprint": false, "crouch": false,
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


## Whether [param player] sees [param other]'s head or chest with its own eyes and settings.
## Movement draws the eye: somebody keeping still, or creeping crouched, is noticed at half
## `bot_sight`, and keeping still crouched only at [constant STILL_LOW_SIGHT] of it and only
## whole, which is how a person in a corner gets passed by.
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


# --- Hiding ---------------------------------------------------------------------

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
	var pool := spots
	if within < INF:
		pool = spots.filter(func(s: Dictionary) -> bool: return (s["at"] as Vector3).distance_to(at) < within)

	var start := nav.closest(at) if nav.is_ready() else at
	var reachable := func(spot: Vector3) -> bool:
		var length := nav.path_length(start, spot) if nav.is_ready() else at.distance_to(spot)
		return length < maxf(left - 4.0, 8.0) * speed * 0.9

	var stream: DotRandomStream = state["stream"]
	var chosen := DotBotHiding.choose(pool, at, threats, taken, stream, settings().profile.map_knowledge, reachable)

	# Asked three times and nothing reachable from here (a spawn just off the walkable mesh):
	# the best spot regardless, and the walk will find its way or hop.
	if chosen.is_empty() and int(state.get("retries", 0)) >= 3:
		chosen = DotBotHiding.choose(pool, at, threats, taken, stream, settings().profile.map_knowledge)
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


## Seekers it can see or hear: run from one that sees it, creep away from one coming close.
func _watch_for_seekers(player: HsPlayer, state: Dictionary) -> void:
	var t := now()
	var at := player.controller.state.position
	var profile := settings().profile
	var nearest: HsPlayer = null
	var nearest_d := INF

	for other in (game.call("players_on", 2) as Array):
		var seeker := other as HsPlayer
		if not seeker.is_alive() or seeker.watching:
			continue
		var d := at.distance_to(seeker.controller.state.position)
		if d < nearest_d and d < profile.sight and _sees(player, seeker):
			nearest_d = d
			nearest = seeker

	var heard := _heard(player, 2)
	# Seen by it: it will make the hider out in a moment whatever the hider does, so go now, at a
	# sprint, while the gap is widest. One walking past with its back turned is let pass.
	var seen := nearest != null and _sees(nearest, player)
	# About to walk into the hider whatever it has seen.
	var bumping := nearest != null and nearest_d < BUMP_FROM
	# The beacon has given it away: every seeker knows where it is, so keeping still is waiting
	# to be caught. Run from any seeker in sight or earshot.
	var marked_chase := player.marked and (nearest != null or not heard.is_empty())

	if nearest != null:
		state["threat"] = nearest.controller.state.position
		state["threat_at"] = t
	elif not heard.is_empty():
		state["threat"] = heard["at"]
		state["threat_at"] = t
	elif t - float(state["threat_at"]) > profile.memory + 4.0:
		state["threat"] = Vector3.INF

	if t - float(state["moved_at"]) < (MARKED_SETTLE if player.marked else SETTLE):
		return

	# Coming to the hider's own place (a seeker searches the hidden places, and this is one):
	# keeping still only works for a seeker passing by. Seen walking at it, or heard getting
	# closer, it is coming here.
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

	# A catch heard close by: two seekers are about to start from there, one held a moment.
	var catch_near := false
	for sound: Dictionary in _sounds:
		if sound.get("caught", false) and at.distance_to(sound["at"]) < minf(profile.hearing, 15.0) \
				and t - float(sound["t"]) < 0.5 and StringName(sound["by"]) != player.player_id:
			catch_near = true
			state["threat"] = sound["at"]
			state["threat_at"] = t

	if not (seen or bumping or coming or catch_near or marked_chase):
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
	var taken := PackedVector3Array()
	for id: StringName in _state:
		if id != player.player_id and not ((_state[id] as Dictionary).get("spot", {}) as Dictionary).is_empty():
			taken.append((_state[id]["spot"] as Dictionary)["at"])
	# Running: round a corner and well away, so it has to search again. Slipping away: the
	# nearest place out of its sight.
	var away := DotBotHiding.flee_spot(spots, at, threat, threat_eye, _los, taken, FLEE_WITHIN + 5.0, FLEE_CLEAR + 4.0) if marked_chase \
		else DotBotHiding.flee_spot(spots, at, threat, threat_eye, _los, taken, FLEE_WITHIN, FLEE_CLEAR) if running \
		else DotBotHiding.flee_spot(spots, at, threat, threat_eye, _los, taken)
	if away.is_empty():
		# Nowhere out of its sight: away from it, whatever the place.
		var dir := Vector3(at.x - threat.x, 0.0, at.z - threat.z).normalized()
		away = {"at": nav.closest(at + dir * 10.0), "exposure": 1.0}
	state["spot"] = away
	state["came_from"] = threat
	state["mode"] = &"fleeing"
	state["path"] = PackedVector3Array()
	state["moved_at"] = t
	state["sprint"] = running
	state["crouch"] = not running
	# What sent it, for `headless_bots`' trace.
	state["why"] = "%s %.1f" % ["seen" if seen else ("bump" if bumping else ("beacon" if marked_chase else ("coming" if coming else "catch"))), at.distance_to(threat)]


## Remembers the doorway the hider is in, and once it is through and clear of the panel's
## sweep, decides whether to shut the door behind it: always running from a seeker behind it,
## and going to a place close beyond the door. A shut door is a wall to a seeker's eye until it
## is opened, and opening it costs the seeker the panel's swing.
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
		if doors != null and not bool(doors.call("is_open", index)):
			doors_shut += 1
		state["shut"] = {}
		return false
	var panel_at: Vector3 = (doors.call("panel_transform", index, 0.0) as Transform3D).origin
	command.move = Vector2.ZERO
	command.set_button(DotFpsCommand.BUTTON_CROUCH, bool(state["crouch"]))
	_look(player, command, panel_at)
	var facing: int = doors.call("door_for", player.eye_position(), player.aim_direction())
	state["use_now"] = facing == index and not bool(doors.call("moving", index, int(game.get("_tick"))))
	return true


# --- Seeking ----------------------------------------------------------------------

func _seek(player: HsPlayer, command: DotFpsCommand) -> void:
	var state := _state_of(player)
	var t := now()
	var profile := settings().profile
	var at := player.controller.state.position
	var stream: DotRandomStream = state["stream"]

	if state["search"] == null:
		var search := DotBotSearch.new()
		search.setup(spots, profile.map_knowledge)
		state["search"] = search
	var search: DotBotSearch = state["search"]

	# Who it can see; a hider marked by the game's beacon is known to every seeker.
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
			var _arrived := _walk_to(player, command, state, prey.controller.state.position, true, false)
			return
		# Seen, not yet noticed: keep doing what it was, turning that way.
	elif state["target"] != StringName() and t - float(state["last_seen_at"]) < profile.memory:
		# Lost: to where it went, then look round there.
		aim.release()
		var where: Vector3 = state["last_seen"]
		if _walk_to(player, command, state, where, true):
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
		var distance := func(a: Vector3, b: Vector3) -> float: return nav.path_length(a, b) if nav.is_ready() else a.distance_to(b)
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

	state["sprint"] = false
	var _there := _walk_to(player, command, state, place["at"], false)
	# Searching is done at a walk: somebody running through a house looks at nothing.
	command.move = command.move.limit_length(SEARCH_PACE)

	# Looking: at the place once near it, else along the way with a glance from side to side.
	var target: Vector3 = place["at"]
	if at.distance_to(target) < search.look_reach:
		_look(player, command, target + Vector3(0.0, 0.6, 0.0))
	else:
		var ahead := _next_corner(state, at)
		var sweep := sin(t * 1.3 + float(player.entity_id % 7)) * 35.0
		var dir := Vector3(ahead.x - at.x, 0.0, ahead.z - at.z)
		if dir.length() > 0.1:
			dir = dir.normalized().rotated(Vector3.UP, deg_to_rad(sweep))
			_look(player, command, player.eye_position() + dir * 5.0)


# --- Moving -------------------------------------------------------------------------

## Walks [param player] along the mesh to [param goal]. Returns true when there.
func _walk_to(player: HsPlayer, command: DotFpsCommand, state: Dictionary, goal: Vector3, sprint: bool, look: bool = true) -> bool:
	var at := player.controller.state.position
	var flat := Vector2(goal.x - at.x, goal.z - at.z).length()

	if flat < 0.6 and absf(goal.y - at.y) < 1.2:
		state["path"] = PackedVector3Array()
		return true

	var t := now()
	var path: PackedVector3Array = state["path"]
	if path.is_empty() or (state["goal"] as Vector3).distance_to(goal) > 1.0 or t - float(state["path_at"]) > 3.0:
		path = nav.path(at, goal) if nav.is_ready() else PackedVector3Array()
		if path.size() < 2:
			path = PackedVector3Array([at, goal])
		state["path"] = path
		state["corner"] = 1
		state["goal"] = goal
		state["path_at"] = t

	var corner := _next_corner(state, at)
	var dir := Vector3(corner.x - at.x, 0.0, corner.z - at.z)

	# Stuck on something the mesh does not know (an open door's panel stands across a path baked
	# without doors): step round it, sideways and back, for a moment.
	if t < float(state.get("sidestep_until", -INF)) and dir.length() > 0.01:
		dir = dir.normalized().rotated(Vector3.UP, deg_to_rad(110.0) * float(state.get("sidestep_side", 1.0)))

	if look:
		_look(player, command, Vector3(corner.x, player.eye_position().y + (corner.y - at.y) * 0.5, corner.z))
	_walk(command, dir)
	command.set_button(DotFpsCommand.BUTTON_SPRINT, sprint)

	# A ceiling low ahead: crouch under it.
	if dir.length() > 0.01:
		var ahead := at + dir.normalized() * 0.6
		if not _los(ahead + Vector3(0.0, 0.5, 0.0), ahead + Vector3(0.0, HsPlayer.BODY_HEIGHT + 0.05, 0.0)):
			command.set_button(DotFpsCommand.BUTTON_CROUCH, true)

	_unstick(player, command, state)
	return false


func _next_corner(state: Dictionary, at: Vector3) -> Vector3:
	var path: PackedVector3Array = state["path"]
	var corner: int = state["corner"]
	# Passed when near it flat and on its level: on a switchback stair the corner of the flight
	# above is right over the bot's head, and skipping it sent bots round in circles.
	while corner < path.size() - 1 and Vector2(path[corner].x - at.x, path[corner].z - at.z).length() < 0.5 \
			and absf(path[corner].y - at.y) < 0.9:
		corner += 1
	state["corner"] = corner
	return path[mini(corner, path.size() - 1)] if not path.is_empty() else at


## Moves along [param world_dir] (flat) whatever way the view is turned.
static func _walk(command: DotFpsCommand, world_dir: Vector3) -> void:
	var flat := Vector3(world_dir.x, 0.0, world_dir.z)
	if flat.length() < 0.01:
		command.move = Vector2.ZERO
		return
	flat = flat.normalized()
	var yaw := deg_to_rad(command.yaw)
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	command.move = Vector2(flat.dot(right), flat.dot(forward)).limit_length(1.0)


## Turns toward [param point] at the bot's turn rate.
func _look(player: HsPlayer, command: DotFpsCommand, point: Vector3) -> void:
	var view := _aim_of(player).look_at_point(player.eye_position(), point, dt())
	command.yaw = view.x
	command.pitch = clampf(view.y, -60.0, 60.0)
	# The walk was worked out against the old view; keep it going the same way in the world.


## Steps round anybody within a metre: people pass through people here, and a bot that walks
## through somebody walks through their camera.
func _step_round_people(player: HsPlayer, command: DotFpsCommand, players: Dictionary) -> void:
	if command.move.length() < 0.1:
		return
	var at := player.controller.state.position
	var yaw := deg_to_rad(command.yaw)
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var push := Vector3.ZERO
	for id: StringName in players:
		var other: HsPlayer = players[id]
		if other == player or not other.is_alive() or other.watching:
			continue
		var off := at - other.controller.state.position
		off.y = 0.0
		var d := off.length()
		if d < 1.1 and d > 0.001 and absf(at.y - other.controller.state.position.y) < 1.5:
			push += off / d * (1.1 - d)
	if push == Vector3.ZERO:
		return
	var world := forward * command.move.y + right * command.move.x + push * 2.0
	command.move = Vector2(world.dot(right), world.dot(forward)).limit_length(1.0)


## Opens a shut door it is walking into, and leaves open ones alone. Released between presses,
## so the game sees an edge.
func _wants_door(player: HsPlayer, command: DotFpsCommand) -> bool:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	if doors == null or int(doors.call("count")) == 0 or command.move.length() < 0.1 or player.wants_use:
		return false
	var yaw := deg_to_rad(command.yaw)
	var forward := Vector3(-sin(yaw), 0.0, -cos(yaw))
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var going := (forward * command.move.y + right * command.move.x).normalized()
	var index: int = doors.call("door_for", player.eye_position(), going, 1.6)
	return index >= 0 and not bool(doors.call("is_open", index)) and not bool(doors.call("moving", index, int(game.get("_tick"))))


## Hops, then asks for a fresh path, when it has not moved in a second.
func _unstick(player: HsPlayer, command: DotFpsCommand, state: Dictionary) -> void:
	var mark: Array = state["stuck"]
	var at := player.controller.state.position
	var t := now()
	if t - float(mark[1]) < 1.0:
		return
	var stuck := Vector2(at.x - (mark[0] as Vector3).x, at.z - (mark[0] as Vector3).z).length() < 0.35
	if stuck and player.controller.state.mode == DotFpsState.Mode.GROUND:
		var stream: DotRandomStream = state["stream"]
		# Every other time a hop (a kerb, a step), else a step aside.
		if int(state.get("stuck_count", 0)) % 2 == 0:
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		else:
			state["sidestep_until"] = t + 0.7
			state["sidestep_side"] = 1.0 if stream.next_unit() < 0.5 else -1.0
		state["path"] = PackedVector3Array()
		state["stuck_count"] = int(state.get("stuck_count", 0)) + 1
		# Stuck three times on the way to one place: somewhere else.
		if int(state["stuck_count"]) >= 3:
			state["stuck_count"] = 0
			state["goal_place"] = {}
			if game.call("team_of", player.player_id) == 1 and state["mode"] != &"hidden":
				_pick_spot(player, state, PackedVector3Array([(state["spot"] as Dictionary).get("at", at)]))
	else:
		state["stuck_count"] = 0
	state["stuck"] = [at, t]


func describe() -> Dictionary:
	return {"spots": spots.size(), "survey_ms": snappedf(survey_ms, 0.1), "nav": nav.describe(), "bots": _state.size()}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["bots  %d spots surveyed in %.0f ms" % [spots.size(), survey_ms]])
	lines.append_array(nav.describe_lines())
	for id: StringName in _state:
		var s: Dictionary = _state[id]
		lines.append("  %-10s %-8s goal %s" % [String(id), String(s["mode"]), str((s.get("spot", {}) as Dictionary).get("at", "-"))])
	return lines

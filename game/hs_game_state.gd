extends "hs_game_rotation.gd"
## The state and the queries of [HsGame] (a middle layer, split off for size); never used on its own.

## `sv_falldamage*`: landing hard hurts. On in this game (dot-combat's default is off); the
## server applies it through [member combat], a client never does.
var fall_rules: DotFallDamageRules = make_fall_rules()
## The ambience cvars (`hs_ambient*`): bound by the module (REPLICATED), followed by a client through its link.
var ambient_rules: DotAmbienceRules = HsAmbience.make_rules()

## Binds [member config] to cvars, the cfg/ yml layers and the workbench; made by the server scene or the client.
var config_binder: DotGameConfigBinder = null

## The workbench's profile rows, made on first ask: the bridge's profile link must exist before the netcode seals, the workbench after.
var profile_runtime: DotProfileRuntime = null

## dot-team's block rules (`!block`, `!noblock`, `mp_teamblock`), set by the server module or `DotGameClient.add_noblock`. They feed [member body_rules]'s `pair_fn`.
var block_rules: Object = null:
	set(value):
		if block_rules != null and block_rules.is_connected(&"changed", body_rules.refresh):
			block_rules.disconnect(&"changed", body_rules.refresh)
		block_rules = value
		if block_rules != null and block_rules.has_signal(&"changed"):
			block_rules.connect(&"changed", body_rules.refresh)

## player id -> side.
var sides: Dictionary = {}

## The map the next round plays, set by the players' vote or an operator, used once.
var next_map_id: StringName = &""

var round_number: int = 0

## Seconds into the current phase, and into the seeking. Simulated, never a wall clock.
var phase_elapsed: float = 0.0
var seek_elapsed: float = 0.0

var phase: int = Phase.IDLE

## The map this round is played on.
var map_doc: Dictionary = {}

var entities := DotEntityTable.new()

## What the server last said about numbers a client cannot count. Negative is "count it".
var remote_hiders: int = -1
var remote_seekers: int = -1
var remote_playable: bool = false

## Who has had the seekers' role, for [DotTeamRotation].
var seeker_history: Dictionary = {}

## Who was caught first this round, and last round: the next round's seeker under
## [constant HsConfig.Pick.FIRST_CAUGHT].
var first_caught: StringName = &""
var _first_caught_before: StringName = &""

var _tick: int = 0
var _round_seed: int = 0
var _rounds_on_map: int = 0
var _map_unplayed: bool = false
var _decided: bool = false
var _winner: int = 0
var _winner_name: String = ""

## Players whose health ran out to a fall, put back on their feet at the top of the next tick:
## not inside the signal that said they died, which fires in the middle of the damage.
var _to_respawn: Array[StringName] = []

## When the beacon's rule began to apply this round, in seconds of seeking; -1 while it does not.
var _beacon_since: float = -1.0

## The stand-ins: hiders that hide and seekers that search ([code]hs_bots.gd[/code], on dot-bot).
var bots: HsBots = HsBots.new(self)

## What the stand-ins are called, solo and on a server alike; past the end dot-bot numbers them.
const BOT_NAMES := ["Pip", "Moss", "Juniper", "Quill", "Basil", "Wren", "Clover", "Sorrel", "Fern", "Rowan", "Hazel", "Linden"]


func _decision() -> Dictionary:
	return {"decided": _decided, "winner": _winner}


func taunt_ids() -> Array[StringName]:
	return taunts.order if taunts != null else ([] as Array[StringName])


# --- Players ----------------------------------------------------------------

static func make_fall_rules() -> DotFallDamageRules:
	var rules := DotFallDamageRules.new()
	rules.enabled = true
	# Mild: hiding high on props is core play, so only a very long drop (about 40 m/s) kills.
	rules.lethal_speed = 40.0
	return rules


static func _spawn_side(side: int) -> String:
	return "seekers" if side == SEEKERS else "hiders"


func _bench(player: HsPlayer) -> void:
	player.watching = true
	player.marked = false

	if player.health != null:
		player.health.invulnerable = true

	if spectate != null:
		spectate.on_died(player.player_id, &"", false, player.controller.state.position,
			map.kill_height() + 8.0, _tick)


func team_of(player_id: StringName) -> int:
	return int(sides.get(player_id, 0))


## The side id dot-team's block rules compare ("" for none): hiders pass hiders and seekers pass seekers under `mp_teamblock 0`.
func team_of_side(player_id: Variant) -> Variant:
	var key := StringName(str(player_id))
	var side := team_of(key)
	if side == 0 and players.has(key):
		side = int((players[key] as HsPlayer).team)
	return str(side) if side > 0 else ""


## Hands every controller the bodies it passes through under `block_rules`; the same call on every machine, or a client predicts a wall.
func apply_pass_through() -> void:
	var entries := {}
	for id: Variant in players:
		var who := players[id] as HsPlayer
		if who != null and who.controller != null:
			entries[id] = {"body": who, "controller": who.controller}
	body_rules.apply_exceptions(entries)


func side_name(side: int) -> String:
	if side == HIDERS or side == SEEKERS:
		return TEAM_NAMES[side - 1]

	return "nobody"


func side_colour(side: int) -> Color:
	if side == HIDERS or side == SEEKERS:
		return TEAM_COLOURS[side - 1]

	return Color(0.7, 0.7, 0.7)


func players_on(side: int) -> Array[HsPlayer]:
	var out: Array[HsPlayer] = []

	for id: StringName in players:
		if int(sides.get(id, 0)) == side:
			out.append(players[id])

	return out


## Whether a player's client is still behind its loading cover: `func(player_key: StringName) -> bool`.
## The server module fills it from dot-game's roster; unset (offline, a suite, a bot) nobody is
## loading, so every offline suite is unchanged. A covered client froze itself and cannot see, so
## it is neither caught nor drawn to seek nor allowed to catch; it still counts as alive.
var loading_fn: Callable = Callable()


func is_loading(id: StringName) -> bool:
	return loading_fn.is_valid() and bool(loading_fn.call(id))


## How many of a side are up and in the round.
func alive_on(side: int) -> int:
	if not authoritative:
		if side == HIDERS and remote_hiders >= 0:
			return remote_hiders
		if side == SEEKERS and remote_seekers >= 0:
			return remote_seekers

	var total := 0

	for player in players_on(side):
		if player.is_alive() and not player.watching:
			total += 1

	return total


func sides_are_playable() -> bool:
	if not authoritative:
		return remote_playable

	return players.size() >= 2


# --- The round --------------------------------------------------------------

func start() -> void:
	if not authoritative:
		return

	# Built again here: on a server nothing was listening when the world opened (the module
	# builds the bridge after), and a map built before it is a map no client is ever sent.
	var id := StringName(str(map_doc.get("id", "")))

	if not map_doc.is_empty() and catalogue != null and catalogue.playable(config.map_ids).has(id):
		var _rebuilt := build_map(map_doc)
		_place_everybody()
	else:
		_lay_out_map()

	match_node.start(_tick)


## A player's wish, from chat. Server side. Takes effect at the next draw.
func wish_side(id: StringName, side: int) -> void:
	var player: HsPlayer = players.get(id)
	if player != null:
		player.side_wish = side if side == HIDERS or side == SEEKERS else 0


func _set_side(id: StringName, side: int) -> void:
	var player: HsPlayer = players.get(id)

	if player == null:
		return

	var was := int(sides.get(id, 0))
	sides[id] = side
	player.team = side

	if was != side:
		apply_pass_through()

	if match_node != null and was != side:
		var _moved := match_node.switch_team(String(id), side, _tick)

	if was != side:
		side_changed.emit(id, side)


static func _names(of: Array[HsPlayer]) -> PackedStringArray:
	var out := PackedStringArray()
	for player in of:
		out.append(player.display_name)
	return out


## The next map, built.
## Every map this server plays, as the map menu (M) lists them: `{id, name, detail, current}`,
## the blurb under the name. Solo the client's list, online the server's (the module hands it
## to dot-vote's map menu), so both say the same.
func map_rows() -> Array:
	var out: Array = []
	if catalogue == null:
		return out
	var now := StringName(str(map_doc.get("id", "")))
	for id in catalogue.playable(config.map_ids):
		var doc: Dictionary = catalogue.maps.get(id, {})
		var title := catalogue.pack_title(id) if catalogue.is_content(id) else ""
		var shown := str(doc.get("name", id))
		var detail := str(doc.get("blurb", ""))
		if not catalogue.in_rotation(id):
			detail = ("%s (not in rotation)" % detail).strip_edges()
		var row := {"id": String(id), "name": shown if title == "" else "%s [%s]" % [shown, title],
			"current": id == now,
			"detail": detail}
		if doc.has("thumbnail"):
			row["thumbnail"] = str(doc["thumbnail"])
		out.append(row)
	return out


## The map menu's change: [param id] now, not after this map's rounds. The next map is set and
## a fresh round begins on it (dot-match's `begin_round_now`: the round called off has no
## winner); with no match running it is simply built. Authority only.
func change_map_now(id: StringName) -> DotResult:
	if not authoritative:
		return DotResult.fail(DotError.CODE_STATE, "Only the server changes the map.")
	if catalogue == null or not catalogue.playable(config.map_ids).has(id):
		return DotResult.fail(DotError.CODE_INVALID, "There is no map called '%s' here." % id)
	next_map_id = id
	if match_node == null or not match_node.begin_round_now(_tick):
		_lay_out_map()
	DotLog.info(CHANNEL, "map changed from the map menu", {"map": String(id)})
	return DotResult.success(id)


func _lay_out_map() -> void:
	if catalogue == null:
		return

	var doc: Dictionary = {}

	if next_map_id != &"" and catalogue.playable(config.map_ids).has(next_map_id):
		doc = catalogue.maps[next_map_id]

	next_map_id = &""

	if doc.is_empty():
		doc = catalogue.next_map(
			config.map_ids, shuffles_maps(), random.stream(&"map"),
			StringName(str(map_doc.get("id", "")))
		)

	var _built := build_map(doc)
	_rounds_on_map = 0
	_map_unplayed = true
	_place_everybody()


## Builds [param doc] as the map. What the server does between rounds, and what a client does
## when it is sent one.
func build_map(doc: Dictionary) -> DotResult:
	world_clearing.emit()

	var built := map.build(doc)

	if not built.ok:
		DotLog.error(CHANNEL, "a map would not build", {"id": str(doc.get("id", "?")), "why": built.error.message})
		return built

	map_doc = map.doc

	if spectate != null:
		spectate.set_overviews(map.overview(), map.overview())

	world_rebuilt.emit()
	return built


## Everybody to where their side starts, at full health, nothing caught.
func _place_everybody() -> void:
	var ids := players.keys()
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	var seats := {HIDERS: 0, SEEKERS: 0}

	for id: StringName in ids:
		var player: HsPlayer = players[id]
		var side := team_of(id)
		player.reset_round()
		_heal(player)

		var spot := map.spawn(_spawn_side(side), int(seats.get(side, 0)))
		seats[side] = int(seats.get(side, 0)) + 1
		player.place_at(spot[0], spot[1])

		if spectate != null:
			spectate.on_spawned(player.player_id)


func _heal(player: HsPlayer) -> void:
	if player.health != null:
		player.health.max_health = config.player_health
		player.health.health = player.health.max_health
		player.health.alive = true
		player.health.invulnerable = false


func _set_phase(to: int) -> void:
	if phase == to:
		return

	phase = to
	phase_elapsed = 0.0

	# The blindfold is a modifier, so a predicting client holds its own seeker still on exactly
	# the ticks the server does. See [HsController].
	for player in players_on(SEEKERS):
		if to == Phase.HIDE:
			var _held := player.controller.add_modifier(HsController.HOLD)
		elif player.held_until < 0.0:
			var _let_go := player.controller.remove_modifier(HsController.HOLD)

	if to == Phase.SEEK and taunts != null:
		# The standing-still clock starts with the seeking: a hider standing still while the
		# seekers are blindfolded is doing what hiding is.
		taunts.reset()

	phase_changed.emit(to)
	DotLog.debug(CHANNEL, "the round changed phase", {"phase": Phase.keys()[to]})


## Rounds still to play on this map, this one included. 1 is the last.
func rounds_left_on_map() -> int:
	return maxi(config.rounds_per_map - _rounds_on_map, 1)


## How long the hiders get to hide: the map's, under the server's.
func hide_limit() -> float:
	var asked := float(map_doc.get("hide_seconds", 0.0))
	return minf(asked, config.hide_seconds) if asked > 0.0 else config.hide_seconds


## How many seekers a round of [param players] starts with: the server's rule, or the map's
## when it asks for more. A map names the number of players one seeker can search for
## ([code]players_per_seeker[/code]), because a building on three storeys is more than one seeker
## clears in a round whatever the lobby (a 50 by 60 m restaurant: the hiders won 24 rounds of 24).
## It can only ask for more seekers than the server's rule gives, never fewer.
func seekers_for(players: int) -> int:
	var asked := float(map_doc.get("players_per_seeker", 0.0))
	if asked > 0.0 and asked < config.players_per_seeker:
		return DotTeamRotation.count_for(players, asked, config.min_seekers, config.max_seekers)
	return config.seekers_for(players)


## How long the seekers get to seek: the map's, under the server's ceiling.
func round_limit() -> float:
	var asked := float(map_doc.get("round_seconds", 0.0))
	return minf(asked, config.round_seconds) if asked > 0.0 else config.round_seconds


## Last side standing, or the clock. [param seeking] is whether the clock counts yet.
func _check_round(seeking: bool) -> void:
	var hiders_left := alive_on(HIDERS)
	var seekers_left := alive_on(SEEKERS)

	if hiders_left == 0 and seekers_left == 0:
		_decide(0, "nobody is left")
	elif hiders_left == 0:
		_decide(SEEKERS, "the seekers found everybody" if seeking else "nobody was hiding")
	elif seekers_left == 0:
		_decide(HIDERS, "the seekers are gone" if players_on(SEEKERS).size() > 0 else "nobody was seeking")
	elif seeking and seek_elapsed >= round_limit():
		match config.timeout_winner:
			HIDERS:
				_decide(HIDERS, "time: %d stayed hidden" % hiders_left)
			SEEKERS:
				_decide(SEEKERS, "time: the seekers hold the map")
			_:
				_decide(0, "time")


func _decide(winner: int, why: String) -> void:
	if _decided:
		return

	_decided = true
	_winner = winner
	_winner_name = why

	if authoritative:
		for id: StringName in players:
			var player: HsPlayer = players[id]

			if winner != 0 and team_of(id) == winner:
				player.points += config.winner_points

			if team_of(id) == HIDERS and player.is_alive() and not player.watching:
				player.points += config.survive_points

				if progress != null:
					progress.on_survived(id)

	DotLog.info(CHANNEL, "the round is decided", {"winner": winner, "why": why})


func current_tick() -> int:
	return _tick


## Simulated seconds, from the tick. What every timer in the game counts.
func _now() -> float:
	return float(_tick) / float(maxi(tick_rate, 1))


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	tick_rate = rate

	for id: StringName in players:
		(players[id] as HsPlayer).tick_rate = rate

	if match_node != null and match_node.config != null:
		match_node.config.tick_rate = rate

	if map != null:
		map.tick_rate = rate

		if map.doors != null:
			map.doors.set_tick_rate(rate)

	return true


## Whether nothing solid is between two points: the walls, and with [param furniture] the
## map's props as well.
func _clear_between(from: Vector3, to: Vector3, furniture: bool = false) -> bool:
	var world := get_world_3d()

	if world == null:
		return true

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collision_mask = physics.layer_mask(&"world") if physics != null else 1

	if furniture and physics != null:
		# The toys too: a hider crouched behind a barrel or the roundabout is behind something.
		query.collision_mask |= physics.layer_mask(&"prop") | physics.layer_mask(&"toy")

	return world.direct_space_state.intersect_ray(query).is_empty()


## The fall a death gets: dot-player-char's reaction rule over the server's weights, seeded from
## the player and the tick. Nothing here shoots, so there is no weapon def: an administrator's
## slay pushes the body away from whoever did it, and a fall below the map pushes nothing.
func decide_death(player: HsPlayer, damage: DotDamage) -> DotPlayerDeath:
	var direction := damage.direction
	var attacker: HsPlayer = players.get(entities.key_for_id(damage.attacker)) if damage.attacker != 0 else null
	if direction.length_squared() < 0.0001 and attacker != null and attacker != player:
		direction = player.controller.state.position - attacker.controller.state.position
	return DotPlayerDeath.decide(
		ragdoll_rules.reactions(), damage.is_headshot(), damage.amount, direction,
		DotPlayerDeath.seed_of(player.entity_id, _tick)
	)


# --- Reporting --------------------------------------------------------------

func seconds_left() -> float:
	match phase:
		Phase.HIDE:
			return maxf(hide_limit() - phase_elapsed, 0.0)
		Phase.SEEK:
			return maxf(round_limit() - seek_elapsed, 0.0)
		_:
			return 0.0

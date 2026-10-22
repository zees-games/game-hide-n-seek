extends Node3D

const HsCatalogue := preload("hs_catalogue.gd")
const HsConfig := preload("hs_config.gd")
const HsMap := preload("hs_map.gd")
const HsMapDoc := preload("hs_map_doc.gd")
const HsPaths := preload("hs_paths.gd")
const HsPlayer := preload("hs_player.gd")
const HsProgress := preload("hs_progress.gd")
const HsProps := preload("hs_props.gd")
const HsRules := preload("hs_rules.gd")
const HsSpectate := preload("hs_spectate.gd")
const HsController := preload("hs_controller.gd")
const HsBots := preload("hs_bots.gd")

## The simulation. Headless, authoritative, and the only thing that decides anything.
##
## [b]A round is hiding and then seeking.[/b] At the top of each round one or two players are
## drawn as seekers and everybody else hides. For [member HsConfig.hide_seconds] the hiders run
## off and find somewhere while the seekers stand blindfolded and held where they started. Then
## the seekers are let go to catch them — by touching them, by default, or by watching them
## long enough, as the server decides — and every hider caught becomes a seeker where they
## stand. Every hider caught is the seekers' round; any hider still hidden when the clock runs
## out is the hiders'.
##
## [b]What it owns and what it borrows.[/b] The round, the sides and the scoreboard are
## dot-match's (decided through [HsRules]); who seeks first is dot-team's [DotTeamRotation];
## the taunts are dot-props' [DotPropTaunts]; health (for falls and the admin tools) is
## dot-combat's. The map, the furniture, catching and the rules of this game are its own.
##
## [b]A catch is measured by the server between two bodies it simulates.[/b] Nothing is shot
## and nothing is claimed: a client cannot say "I touched them", only move, and the server
## looks at where it has both of them every tick (see [method _advance_catching]).

const CHANNEL := "hs.game"

## Where this world publishes itself, so a module can find it. A registry name and not an
## autoload: a server and a client in one process are two of these.
const SERVICE := &"hs_game"

## Where a host that runs this game with no server (the client shell's Solo play) publishes
## the map packs it mounted for it. See [method solo_map_dirs].
const SOLO_SERVICE := &"dot_solo"

## Snapshots a second. What a seeker reads continuously is somebody running across a room.
const NET_SNAPSHOT_RATE := 30

## How far a position may be from the origin, in metres, on the wire. Both ends read it here.
const NET_WORLD_EXTENT := 512.0

## The two sides. Fixed ids, because the whole game is about which of the two somebody is.
const HIDERS := 1
const SEEKERS := 2

## The brief: hiders in blue. Seekers in an orange that cannot be mistaken for it in any light.
const TEAM_COLOURS: Array[Color] = [
	Color(0.22, 0.52, 1.0),
	Color(0.98, 0.42, 0.12),
]

const TEAM_NAMES: Array[String] = ["Hiders", "Seekers"]

## Which part of the round it is.
enum Phase {
	## Between rounds, or waiting for enough people.
	IDLE,
	## The hiders hide; the seekers are blindfolded and held still.
	HIDE,
	## The seekers are let go.
	SEEK,
}

## Why somebody's health ran out: below the map, or an administrator.
const DIED_FELL := &"fell"
const DIED_SLAIN := &"slain"

## How a hider was caught.
const CAUGHT_TAG := &"tag"
const CAUGHT_SIGHT := &"sight"
const CAUGHT_FELL := &"fell"

## How far apart two bodies' feet may be in height and still touch, in metres.
const TAG_HEIGHT := 1.6

signal player_added(player_id: StringName)
signal player_removed(player_id: StringName)
signal round_began(number: int, map_id: StringName)
signal world_clearing()
signal world_rebuilt()
signal round_over(number: int, winner: int, winner_name: String)
signal phase_changed(phase: int)
signal side_changed(player_id: StringName, side: int)
signal player_died(player_id: StringName, by: StringName, why: StringName)

## A hider was caught: by a seeker ([param by]), or by a fall (empty), [param how] being one of
## the CAUGHT_ constants.
signal caught(player_id: StringName, by: StringName, how: StringName)

## Somebody taunted: [param taunt_id] from the taunt list, forced or chosen.
signal taunted(player_id: StringName, taunt_id: StringName, forced: bool)

## Somebody used door [param index] on [param tick]: it is on its way to [param open].
signal door_used(index: int, open: bool, flip: bool, tick: int, by: StringName)

## Something a player asked for was refused, and why. Told to them alone.
signal refused(player_id: StringName, why: String)

signal achievement_earned(player_id: StringName, title: String, points: int)

@export var config: HsConfig = null
@export var authoritative: bool = true
@export_range(1, 240, 1) var tick_rate: int = 64
@export var external_tick: bool = false
@export var register_service: bool = true

## Whether the map is drawn. A client sets it.
@export var draw_world: bool = false

var map: HsMap = null
var catalogue: HsCatalogue = null
var props_catalogue: HsProps = null
var combat: DotCombatManager = null
var match_node: DotMatch = null
var random: DotRandomManager = null
var physics: DotPhysicsLayout = null

## What a dead body does, and which death reactions the server allows: dot-player-char's
## `sv_ragdoll*` cvars, bound by the module (REPLICATED) and followed by a client through its
## link, because the client draws the bodies.
var ragdoll_rules: DotPlayerRagdollRules = DotPlayerRagdollRules.new()

## dot-props' `sv_toys*` (whether a map's toys are there, how many simulate at once, how hard a
## walk pushes one). Bound by the module (REPLICATED) and followed by a client, which draws them.
var toy_rules: DotPropToyRules = DotPropToyRules.new()

## What a person weighs on a see-saw, kg.
const PERSON_MASS := 70.0
var effects: DotFxManager = null
var spectate: HsSpectate = null
var progress: HsProgress = null
var taunts: DotPropTaunts = null

## player id -> HsPlayer.
var players: Dictionary = {}

## dot-player-controller's `mp_forceview` (may a player switch to third person) and
## `mp_solidplayers` (do players and stand-ins block each other). Bound by the module
## (REPLICATED) and followed by a client through its link.
var view_rules: DotPlayerViewRules = DotPlayerViewRules.new()
## Who a spectator may watch and whether they may fly a free camera: dot-spectate's
## `mp_forcecamera`, `mp_freeroam` and `mp_freeroam_speed`. One object for the life of the
## game, shared with [HsSpectate]'s manager, so a cvar change reaches the rules in use. Bound
## by the module (REPLICATED) and followed by a client, which is the end that flies the camera.
var spectate_rules: DotSpectatorRules = DotSpectatorRules.new()
var body_rules: DotPlayerBodyRules = DotPlayerBodyRules.new()


func _init() -> void:
	# This game's pick: people pass through people (see `_build_physics`). Measured, not
	# assumed: with bodies solid, headless_bots' stand-in hiders lost 6 rounds of 6, crowded
	# out of their spots. The camera fade keeps a body that walks through you out of the lens;
	# an owner who wants bodies sets `mp_solidplayers 1`.
	body_rules.solid = false

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


func _ready() -> void:
	if config == null:
		config = HsConfig.new()

	var valid := config.validate()

	if not valid.ok:
		DotLog.error(CHANNEL, "the configuration is not usable", {"why": valid.error.message})
		return

	_round_seed = config.seed_value

	_build_physics()
	if not body_rules.changed.is_connected(_on_body_rules_changed):
		body_rules.changed.connect(_on_body_rules_changed)
	_apply_gravity()
	_build_random()
	_build_props()
	_build_map()
	_build_combat()
	_build_effects()
	_build_match()
	_build_spectate()
	_build_progress()
	_build_taunts()

	if authoritative:
		catalogue = HsCatalogue.new()
		var _loaded := catalogue.load_from(config.map_directory)
		# Solo in the client shell: the map packs it mounted for this game, which a server
		# would have named. See [method solo_map_dirs].
		for root in solo_map_dirs("maps"):
			var _added := catalogue.add_directory(root)
		# Subscribed maps (solo) and delivered ones (online) that the content index holds, of the
		# kind provides.json's `accepts` names. Own ids win; the index shows one session only.
		catalogue.follow_content(DotContentIndex.shared(),
			PackedStringArray([HsCatalogue.CONTENT_KIND]))
		# Laid out now, not on the first round: a warmup on an empty world is
		# indistinguishable from a map that failed to load.
		_lay_out_map()

	if register_service:
		DotRegistry.register(SERVICE, self)

	DotLog.info(CHANNEL, "world ready", config.describe())


## The `<pack>/<subdir>` directories of the map packs a host running this game with no server
## has mounted for it: the client shell's Solo play, which fetches the packs a server owner
## would name (dot-server-deploy's `client/solo.json`) because a tab has no server to name
## them. Read the way the module reads its server's ([DotGameContent]). Empty everywhere else:
## a server, a suite, a run from the repository. Looked up by name and duck-typed, because a
## delivered game may not name a host's class.
static func solo_map_dirs(subdir: String) -> PackedStringArray:
	var host: Object = DotRegistry.get_service(SOLO_SERVICE)
	if host == null or not host.has_method(&"map_dirs"):
		return PackedStringArray()
	return host.call(&"map_dirs", subdir)


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


# --- Building ---------------------------------------------------------------

## The player's motor mask under `mp_solidplayers`, and the standing hull the others stop at
## (a player's body has no shape of its own). With the rule on, a stand-in stops at your
## shoulder instead of walking into your camera (the first play test, 1:37 and 2:20).
func _apply_body_mask(player: HsPlayer) -> void:
	if physics == null or player == null or player.controller == null:
		return
	body_rules.apply_to(player.controller, physics.collision_mask(&"player"), physics.layer_mask(&"player"))
	var tunables := player.controller.tunables
	body_rules.apply_hull(player, tunables.stand_height, tunables.radius)


## `mp_solidplayers` changed: every player's mask and hull now.
func _on_body_rules_changed() -> void:
	for id in players:
		_apply_body_mask(players[id] as HsPlayer)


## Three layers: the building, the people, and the furniture.
##
## [b]People do not collide with people in the layout.[/b] Two players shoving is a race
## decided by who walked into whom, drawn in the past on every client; a hider who could be
## pinned in a corner by a seeker's body, or block a doorway with their own, would be
## playing a different game. So `mp_solidplayers` is 0 here by default (`_init`); the first
## play test's stand-in walking into the camera is handled by the camera fade, which hides a
## body at the lens. An owner who sets 1 gets each player's motor mask and hull; a touch is a
## distance the server measures (`tag_range` 1.2 m, past the 0.7 m two bodies keep), so
## tagging works either way.
func _build_physics() -> void:
	physics = DotPhysicsLayout.custom(&"hideseek", [&"world", &"player", &"prop", &"toy", &"footprint"])

	for layer in physics.layers:
		match layer.id:
			&"player":
				layer.collides_with = [&"world", &"prop"]
			# A loose toy: the rooms, the furniture and the other toys, never a person, who
			# walks through it and pushes it (see [method _advance_toys]).
			&"toy":
				layer.collides_with = [&"world", &"prop", &"toy"]
			# A toy's footprint, for the bots' walkable mesh only: nothing collides with it.
			&"footprint":
				layer.collides_with = []
			_:
				layer.collides_with = [&"player"]

	var built := physics.build()

	if not built.ok:
		DotLog.error(CHANNEL, "the collision layout would not build", {"why": built.error.message})
		physics = null


## The gravity the movement is tuned against, on this world's own physics SPACE: a project
## setting does not travel with a delivered pack.
func _apply_gravity() -> void:
	var world := get_world_3d()

	if world == null:
		return

	PhysicsServer3D.area_set_param(world.space, PhysicsServer3D.AREA_PARAM_GRAVITY, config.gravity)


func _build_random() -> void:
	random = DotRandomManager.new()
	random.name = "Random"
	random.register_as_service = false
	add_child(random)
	var _started := random.setup()
	random.reseed(_round_seed)


func _build_props() -> void:
	props_catalogue = HsProps.new()
	var count := props_catalogue.load_file()

	if count == 0:
		DotLog.error(CHANNEL, "no props: every map will be empty rooms", {})


func _build_map() -> void:
	map = HsMap.new()
	map.name = "Map"
	map.physics = physics
	map.catalogue = props_catalogue
	map.draw_world = draw_world
	map.tick_rate = tick_rate
	map.authoritative = authoritative
	map.toy_rules = toy_rules
	map.gravity = config.gravity
	add_child(map)


## Health, and nothing that shoots. What still takes it away is a fall and an administrator,
## and both arrive as damage so dot-moderation's god and buddha work as they do everywhere.
func _build_combat() -> void:
	combat = DotCombatManager.new()
	combat.name = "Combat"
	combat.is_authority = authoritative
	combat.register_service = false

	var damage_rules := DotDamageRules.new()
	damage_rules.friendly_fire = false
	damage_rules.self_damage = true
	combat.rules = damage_rules

	var settings := DotCombatConfig.new()
	settings.lag_compensation = false
	combat.config = settings
	# A trace nothing here fires, set anyway: without one dot-combat warns at every boot that
	# shots pass through walls, and a warning about nothing is how a reader learns to skim.
	var trace := DotTracePhysics.for_world(get_world_3d())

	if physics != null:
		trace.collision_mask = physics.layer_mask(&"world") | physics.layer_mask(&"prop")

	combat.trace = trace
	combat.resolver = DotDamageResolver.with_rules(damage_rules)
	add_child(combat)


func _build_effects() -> void:
	if authoritative and not draw_world:
		return

	var fx := DotFxCatalogue.new()

	var go := DotFxDef.new()
	go.id = &"go"
	go.kind = DotFxDef.Kind.SCREEN
	go.flash_peak = 0.18
	go.flash_colour = Color(0.98, 0.86, 0.35, 1.0)
	go.flash_decay_ms = 380
	fx.add(go)

	var got := DotFxDef.new()
	got.id = &"caught"
	got.kind = DotFxDef.Kind.SCREEN
	got.flash_peak = 0.35
	got.flash_colour = TEAM_COLOURS[1]
	got.flash_decay_ms = 600
	fx.add(got)

	effects = DotFxManager.new()
	effects.name = "Effects"
	effects.catalogue = fx
	effects.config = DotFxConfig.new()
	effects.register_as_service = false
	add_child(effects)
	DotLog.result(CHANNEL, "the effects layer", effects.setup())


func _build_match() -> void:
	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.register_service = false

	var match_config := DotMatchConfig.new()
	match_config.tick_rate = tick_rate
	match_config.auto_start = false
	match_config.log_transitions = false
	# Off: the sides are this game's to draw (see [method _draw_sides]), and they are uneven on
	# purpose.
	match_config.balance_between_rounds = false
	match_node.config = match_config

	var match_rules: DotMatchRules = HsRules.make()
	match_rules.intermission_sec = config.intermission_seconds
	match_rules.warmup_sec = config.warmup_seconds
	match_rules.countdown_sec = 0.0
	match_rules.team_based = true
	match_rules.min_players = 2
	match_rules.set(&"decision_fn", _decision)
	match_rules.time_limit_sec = config.hide_seconds + config.round_seconds + 60.0
	match_node.rules = match_rules

	# Scoped to the match node, which finds nothing: this game places its own players.
	match_node.spawns_ref = DotNodeRef.of_path(^".")
	add_child(match_node)

	match_node.round_started.connect(_on_round_started)
	match_node.round_ended.connect(_on_round_ended)

	var teams: Array[DotTeam] = [
		DotTeam.make(HIDERS, TEAM_NAMES[0], TEAM_COLOURS[0]),
		DotTeam.make(SEEKERS, TEAM_NAMES[1], TEAM_COLOURS[1]),
	]
	match_node.teams.teams = teams
	match_node.teams.force_balance = false
	match_node.teams.allow_choice = false
	match_node.teams.max_difference = 0
	match_node.teams.reindex()


func _decision() -> Dictionary:
	return {"decided": _decided, "winner": _winner}


func _build_spectate() -> void:
	spectate = HsSpectate.new()
	spectate.name = "Spectate"
	spectate.players = players
	spectate.sides = sides
	spectate.phase_fn = func() -> int: return phase
	add_child(spectate)

	# The config's number is only the starting point: from here `mp_forcecamera` is the rule.
	spectate_rules.force_camera = clampi(config.spectate_camera, 0, 2)
	var ready_now := spectate.setup(authoritative, tick_rate, spectate_rules)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "spectating is off", {"why": ready_now.error.message})
		remove_child(spectate)
		spectate.queue_free()
		spectate = null


func _build_progress() -> void:
	if not authoritative or not config.keep_progress:
		return

	progress = HsProgress.new()
	progress.name = "Progress"
	progress.players = players
	progress.sides = sides
	add_child(progress)

	var ready_now := progress.setup(config.progress_directory, config.report_progress)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "progress is off", {"why": ready_now.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null
		return

	progress.earned.connect(func(id: StringName, title: String, points: int) -> void:
		achievement_earned.emit(id, title, points)
	)


## The taunt list, on both ends: the server decides when a taunt plays, every client plays it.
func _build_taunts() -> void:
	taunts = DotPropTaunts.new()
	taunts.auto_after = config.auto_taunt_seconds
	taunts.auto_radius = config.auto_taunt_radius
	taunts.cooldown = config.taunt_cooldown
	taunts.points_voluntary = config.taunt_points
	taunts.points_forced = config.forced_taunt_points

	var text := FileAccess.get_file_as_string(HsPaths.rebase("res://" + config.taunt_file.trim_prefix("res://")))
	var parsed: Variant = JSON.parse_string(text) if text != "" else null
	var list: Variant = (parsed as Dictionary).get("taunts", []) if parsed is Dictionary else parsed

	if list is Array:
		var _added := taunts.add_all(list)

	if taunts.order.is_empty():
		DotLog.warn(CHANNEL, "no taunts; a hider can only be found by looking", {"file": config.taunt_file})


func taunt_ids() -> Array[StringName]:
	return taunts.order if taunts != null else ([] as Array[StringName])


# --- Players ----------------------------------------------------------------

## Puts somebody in the world. [param wanted_side] is a side, or 0 to be placed.
##
## [b]Somebody who joins while the seekers are out seeks.[/b] A hider dropped into a round that
## is half over has had no time to hide, and benching them would leave them watching for
## minutes; a seeker more is a round that ends a little sooner, which is what a seeker
## is for.
func add_player(
	player_id: StringName,
	display_name: String,
	wanted_side: int = 0,
	samples_input: bool = false
) -> HsPlayer:
	if players.has(player_id):
		return players[player_id]

	var side := SEEKERS if wanted_side == SEEKERS else HIDERS

	if authoritative and phase == Phase.SEEK and wanted_side == 0:
		side = SEEKERS

	var player := HsPlayer.new()
	player.name = "Player_%s" % String(player_id)
	player.player_id = player_id
	player.display_name = display_name
	player.samples_input = samples_input
	player.tick_rate = tick_rate
	player.config = config
	player.team = side
	add_child(player)

	if physics != null:
		var applied := physics.apply_to(player, &"player")

		if not applied.ok:
			DotLog.warn(CHANNEL, "a player could not be put on its collision layer", {"why": applied.error.message})

		_apply_body_mask(player)

	var opened := entities.open(
		DotEntity.KIND_PLAYER, player, &"", player_id, float(_tick) / float(maxi(tick_rate, 1))
	)
	player.entity_id = (opened.value as DotEntityHandle).id if opened.ok else 0

	var health := DotHealth.new()
	health.name = "Health"
	health.max_health = config.player_health
	health.health = health.max_health
	player.add_child(health)
	player.health = health

	if combat != null:
		combat.register_health(player.entity_id, health)

	health.died.connect(func(damage: DotDamage) -> void: _on_player_died(player, damage))

	players[player_id] = player
	sides[player_id] = side

	# The trampolines and pads: in the movement, so a predicting client is thrown on the tick
	# the server throws it.
	player.controller.launcher = _launch
	var _b := player.controller.bounced.connect(_on_bounced)
	# And a turning roundabout carries whoever stands on it, after the move, the same way.
	player.controller.carrier = _carry

	if match_node != null:
		var seated := match_node.add_player(String(player_id), display_name, _tick, side)

		if not seated.ok:
			DotLog.error(CHANNEL, "dot-match refused a player", {"id": String(player_id), "why": seated.error.message})

	place_one(player)
	DotLog.debug(CHANNEL, "player joined", {"id": String(player_id), "side": side})
	player_added.emit(player_id)
	return player


## Puts one player where their side starts.
func place_one(player: HsPlayer) -> void:
	if map == null or map.doc.is_empty():
		return

	var spot := map.spawn(_spawn_side(team_of(player.player_id)), players.size() - 1)
	player.place_at(spot[0], spot[1])

	if spectate != null:
		spectate.on_spawned(player.player_id)


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


func remove_player(player_id: StringName) -> void:
	if not players.has(player_id):
		return

	var player: HsPlayer = players[player_id]

	if combat != null and is_instance_valid(combat) and player.entity_id != 0:
		combat.forget(player.entity_id)
		var _closed := entities.close(player.entity_id, DotEntityTable.REASON_OWNER_LEFT)

	if match_node != null:
		match_node.remove_player(String(player_id))

	players.erase(player_id)
	sides.erase(player_id)
	bots.forget(player_id)
	_to_respawn.erase(player_id)

	if taunts != null:
		taunts.forget(player_id)

	player.queue_free()

	if spectate != null:
		spectate.on_left(player_id)

	if progress != null:
		progress.leave(player_id)

	player_removed.emit(player_id)


func team_of(player_id: StringName) -> int:
	return int(sides.get(player_id, 0))


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


## The server's maps.yml, or null when there is none (every map rotates, as it always did).
var rotation_file: DotMapRotationFile = null

# dot-map's rotation file marks and orders [DotMapDef]s in a [DotMapCatalogue]; this game keeps
# its maps as documents, so a def per map id is mirrored here and the file applied to those.
var _rot_catalogue: DotMapCatalogue = null
var _rot: DotMapRotation = null


## Reads maps.yml (the game's shipped `res://maps.yml` under the server's
## [member HsConfig.map_rotation_file], looked for in the `--config` directory too) and applies
## it. A file that is present and unreadable is an ERROR and changes nothing: rotating every map
## is a better failure than rotating none.
func load_rotation() -> DotResult:
	var stem := config.map_rotation_file if config != null else ""
	var dir := DotMapRotationFile.config_dir_arg()
	var found := DotMapRotationFile.find(stem, dir)

	if found == "" and stem != "" and (dir != "" or stem != HsConfig.new().map_rotation_file):
		# The default name being absent is an install with no maps.yml; a name or a directory
		# somebody chose that finds nothing is a typo they would otherwise never hear about.
		DotLog.warn(CHANNEL, "the map rotation file was not found; every map rotates", {
			"file": stem, "config_dir": dir,
		})

	var paths := PackedStringArray()
	for candidate in ["res://maps.yml", found]:
		if candidate != "" and not paths.has(candidate) and FileAccess.file_exists(candidate):
			paths.append(candidate)

	var read := DotMapRotationFile.load_files(paths, "game-hide-n-seek")

	if not read.ok:
		DotLog.error(CHANNEL, "the map rotation file could not be read; every map rotates", {
			"why": read.error.message,
		})
		rotation_file = null
		apply_rotation()
		return read

	rotation_file = read.value
	if rotation_file.has_rotations():
		DotLog.info(CHANNEL, "the map rotation file", {
			"paths": ", ".join(rotation_file.sources), "active": rotation_file.active_name(),
		})

	apply_rotation()
	return read


## Marks every catalogue map in or out of rotation from the file. With no file, or one with no
## rotations, every map is in: what this game did before maps.yml.
func apply_rotation() -> void:
	if catalogue == null:
		return

	catalogue.in_rotation_fn = Callable()
	catalogue.rotation_order = []

	if rotation_file == null or not rotation_file.has_rotations():
		_rot = null
		_rot_catalogue = null
		return

	_rot_catalogue = DotMapCatalogue.new()

	for id in catalogue.playable(PackedStringArray()):
		var def := DotMapDef.new()
		def.id = id
		def.display_name = str(catalogue.maps[id].get("name", id))
		def.scene_path = "doc:%s" % id
		def.content_id = StringName(catalogue.content_ref(id))
		var _added := _rot_catalogue.add(def)

	_rot = DotMapRotation.of(_rot_catalogue)
	# An empty rotation plays every installed map: the same set as having no file.
	rotation_file.fallback_in = func(_map: DotMapDef) -> bool: return true
	var _applied := rotation_file.apply(_rot)
	var marks := {}

	for def in _rot_catalogue.maps:
		marks[def.id] = def.in_rotation

	# Ids the mirror has not seen (a pack map subscribed since) are out of a file's rotation
	# unless it matches them, which needs a re-apply; the next apply_rotation does that.
	catalogue.in_rotation_fn = func(id: StringName) -> bool: return bool(marks.get(id, true))
	catalogue.rotation_order = _rot.order.duplicate()


## Whether maps.yml's active rotation plays [param id]. A map the catalogue lacks is not.
func in_rotation(id: StringName) -> bool:
	return catalogue != null and catalogue.maps.has(id) and catalogue.in_rotation(id)


## Whether the next map is drawn at random: the rotation's mode when a file is in force,
## [member HsConfig.shuffle_maps] otherwise.
func shuffles_maps() -> bool:
	if _rot != null:
		return _rot.mode == DotMapRotation.Mode.RANDOM

	return config.shuffle_maps


## maps.yml's `commands:` block (prefix and names), or empty with no file.
func rotation_commands() -> Dictionary:
	return rotation_file.commands() if rotation_file != null else {}


## The name a game-specific command answers to: maps.yml's `commands: names:` role (and prefix)
## over [param default]. The first name is the one registered; see [method command_aliases].
func command_name(role: String, default: String) -> String:
	return command_aliases(role, default)[0]


## Every name [param role] answers to, primary first.
func command_aliases(role: String, default: String) -> PackedStringArray:
	var target := DotCommandNamesHolder.new()
	DotCommandNames.apply(target, rotation_commands())
	return DotCommandNames.all_of(target.prefix, target.names, {role: default}, role)


class DotCommandNamesHolder extends RefCounted:
	var prefix: String = ""
	var names: Dictionary = {}


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


# --- Catching -------------------------------------------------------------------

## Who is caught this tick: by a touch, by being watched, or both, as the server is set.
##
## [b]A touch is two bodies within [member HsConfig.tag_range] of each other with no wall
## between.[/b] Horizontal distance between the capsules' axes, and feet within
## [constant TAG_HEIGHT] of each other, so a seeker on the floor below a hider standing on a
## shelf above their head has not touched them. The wall test is what stops a tag through a
## thin partition, which two capsules either side of one would otherwise pass.
##
## [b]Being watched is a meter, not a moment.[/b] A seeker who glimpses a hider across a room
## for a frame has not caught them; one who keeps them in view for
## [member HsConfig.sight_seconds] has. The meter drains when nobody is watching, so breaking
## line of sight is the hider's answer and a chase is still a chase.
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


## A seeker who can see [param hider] now, or null: within range, inside their view cone, and
## nothing solid between their eyes and the hider's head or chest.
##
## [b]The furniture blocks sight; the people do not.[/b] Hiding behind a sofa is the game, and
## a seeker standing between another seeker and a hider is a seeker who has seen them too.
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
##
## [b]A caught hider becomes a seeker where they stand[/b], held still for
## [member HsConfig.caught_freeze_seconds] so they cannot pass the catch straight on to
## whoever was hiding beside them. On a server where the caught are out, they watch instead.
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


# --- Doors ----------------------------------------------------------------------

## Everybody's hand on the doors: a use is the use key going down in front of one, and then
## every door is posed for this tick, before anybody moves against it.
##
## [b]An edge, made here from the held state,[/b] as mg-deathrun makes its button presses: the
## key rides in every input packet, so a use is never a round trip behind the key that made it.
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


# --- Toys ----------------------------------------------------------------------

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


# --- Taunts ---------------------------------------------------------------------

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


# --- The tick ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not authoritative or match_node == null or external_tick:
		return

	simulate(delta)


## One tick, counted by this world. What an offline client and the suite use.
func simulate(delta: float) -> void:
	_tick += 1
	_step(delta)


## One tick, numbered by the netcode. What the bridge uses.
func tick_once(tick: int) -> void:
	if match_node == null:
		return

	_tick = tick
	_step(delta_for_tick())


func current_tick() -> int:
	return _tick


## Simulated seconds, from the tick. What every timer in the game counts.
func _now() -> float:
	return float(_tick) / float(maxi(tick_rate, 1))


func _step(delta: float) -> void:
	_respawn_the_fallen()
	_advance_phase(delta)
	_advance_holds()
	_drive_bots()
	_advance_use()
	_advance_doors()

	for id: StringName in players:
		var player: HsPlayer = players[id]

		if player.is_alive() and not player.watching:
			player.simulate(_tick, delta)

	_advance_toys(delta)

	_watch_world()
	_advance_catching(delta)
	_advance_taunts()
	_advance_beacons()

	if combat != null:
		combat.tick(_tick, delta)

	if spectate != null:
		spectate.advance(_tick)

	if not sides_are_playable() and phase == Phase.IDLE:
		return

	match_node.tick(_tick)


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


# --- Bots ------------------------------------------------------------------

## What every stand-in presses this tick: [code]hs_bots.gd[/code].
func _drive_bots() -> void:
	bots.drive()


# --- Reacting ---------------------------------------------------------------

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


func describe() -> Dictionary:
	return {
		"round": round_number,
		"phase": Phase.keys()[phase],
		"left": "%.0f s" % seconds_left(),
		"map": str(map_doc.get("id", "-")),
		"players": players.size(),
		"hiders": alive_on(HIDERS),
		"seekers": alive_on(SEEKERS),
		"first_caught": String(first_caught) if first_caught != &"" else "-",
		"decided": _winner_name if _decided else "-",
		"maps": catalogue.maps.size() if catalogue != null else 0,
		"phase_id": phase,
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["hideseek, round %d" % round_number])
	var facts := describe()

	for key: String in facts:
		lines.append("  %-12s %s" % [key, facts[key]])

	for id: StringName in players:
		var player: HsPlayer = players[id]
		lines.append("  %-8s %-18s %s%s%s" % [
			side_name(team_of(id)), player.display_name,
			"caught" if player.caught else "-",
			" seen %d%%" % int(player.sight_meter * 100.0) if player.sight_meter > 0.0 else "",
			"" if player.is_alive() else " (out)",
		])

	if map != null:
		lines.append_array(map.describe_lines())

	return lines

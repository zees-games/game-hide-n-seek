extends "hs_game_play.gd"

## The simulation. Headless, authoritative, and the only thing that decides anything.
## A round is hiding and then seeking: one or two players are drawn as seekers, the hiders hide for [member HsConfig.hide_seconds] while the seekers are held blindfolded, then seekers catch hiders (a touch, or watching them, as the server decides) and each caught hider seeks where they stand. The round, sides and scoreboard are dot-match's (via [HsRules]); seeker rotation, taunts and health are dot-team's, dot-props' and dot-combat's.
## A catch is measured by the server between two bodies it simulates: a client cannot say "I touched them" (see [method _advance_catching]).



func ensure_runtime() -> DotProfileRuntime:
	if profile_runtime == null:
		profile_runtime = DotProfileRuntime.new()
		# A method, not a lambda: a static may keep the runtime past the tree, and a lambda
		# there retains this path-based base script until exit frees it mid-walk (exit 134).
		profile_runtime.permit = _local_permit
	return profile_runtime


func _local_permit(actor: Variant, _flag: String) -> bool:
	return typeof(actor) == TYPE_STRING_NAME and actor == &"local"


func _init() -> void:
	# This game's pick: people pass through people (see `_build_physics`). With bodies solid, headless_bots' stand-in hiders lost 6 rounds of 6; the camera fade keeps a body out of the lens, and `mp_solidplayers 1` restores them.
	body_rules.solid = false


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


## The `<pack>/<subdir>` directories of the map packs a host running this game with no server has mounted for it (the client shell's Solo play, `client/solo.json`), read as the module reads its server's ([DotGameContent]). Empty elsewhere.
## Looked up by name and duck-typed, because a delivered game may not name a host's class.
static func solo_map_dirs(subdir: String) -> PackedStringArray:
	var host: Object = DotRegistry.get_service(SOLO_SERVICE)
	if host == null or not host.has_method(&"map_dirs"):
		return PackedStringArray()
	return host.call(&"map_dirs", subdir)


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)



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
	apply_pass_through()


## Three layers: the building, the people, and the furniture.
## People do not collide with people: shoving is a race decided by who walked into whom, drawn in the past on every client, and a hider pinned by a seeker's body would be playing a different game. So `mp_solidplayers` is 0 by default (`_init`); a touch is a distance the server measures (`tag_range` 1.2 m, past the 0.7 m two bodies keep), so tagging works either way.
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


## Puts somebody in the world. [param wanted_side] is a side, or 0 to be placed.
## Somebody who joins while the seekers are out seeks: a hider dropped into a half-over round has had no time to hide, and benching them leaves them watching for minutes.
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

	if combat != null and player.controller != null:
		var fall := DotFallDamage.new()
		fall.name = "FallDamage"
		fall.rules = fall_rules
		fall.victim = player.entity_id
		fall.controller = DotNodeRef.of_path(player.controller.get_path())
		fall.controller.mode = DotNodeRef.Mode.ABSOLUTE
		fall.combat = DotNodeRef.of_path(combat.get_path())
		fall.combat.mode = DotNodeRef.Mode.ABSOLUTE
		# No ladders or noclip here; nobody is hurt between rounds (the intermission).
		fall.context_checks = {&"protected": func() -> bool: return phase == Phase.IDLE}
		player.add_child(fall)

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
	apply_pass_through()
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
	if block_rules != null:
		block_rules.call(&"forget", player_id)
	apply_pass_through()

	if spectate != null:
		spectate.on_left(player_id)

	if progress != null:
		progress.leave(player_id)

	player_removed.emit(player_id)



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



## What every stand-in presses this tick: [code]hs_bots.gd[/code].
func _drive_bots() -> void:
	bots.drive()


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

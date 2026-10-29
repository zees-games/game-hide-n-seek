extends "headless_run_base.gd"
## The world, round and catching sections of [code]headless_run[/code] (a middle layer, split off for size); never run on its own.



func _test_config() -> void:
	_section("the configuration")
	var config := HsConfig.new()
	_check(config.validate().ok, "the defaults validate")
	_check(config.seekers_for(1) == 0, "one person is not a round")
	_check(config.seekers_for(2) == 1 and config.seekers_for(8) == 1, "one seeker up to eight players")
	_check(config.seekers_for(9) == 2 and config.seekers_for(64) == config.max_seekers,
		"two from nine, and never more than the most")
	_check(config.catches_by_touch() and not config.catches_by_sight(), "a touch catches by default, and being seen does not")
	config.catch_mode = HsConfig.Catch.EITHER
	_check(config.catches_by_touch() and config.catches_by_sight(), "either, when the server says so")
	config.catch_mode = 7
	_check(not config.validate().ok, "a way of catching that is none of the three is refused")
	config.catch_mode = 0
	config.seeker_pick = 9
	_check(not config.validate().ok, "a way of picking seekers that is none of the four is refused")
	_finished()


func _test_catalogue() -> void:
	_section("the prop catalogue is what the models measure")
	var props := HsProps.new()
	var count := props.load_file()
	_check(count > 100, "it reads (%d props)" % count)
	_check((props.size_of(&"furniture_chair") - Vector3(0.46, 1.08, 0.46)).length() < 0.01,
		"a chair is the size measured", str(props.size_of(&"furniture_chair")))

	var bad := 0
	for id in props.order:
		var e := props.entry(id)
		if not ResourceLoader.exists("res://" + str(e["model"])):
			bad += 1
	_check(bad == 0, "every prop's model is in the game", "%d missing" % bad)

	# Part-shaped collision (props/pieces.json, dot-props' DotPropPieces): a tree is pieces, a
	# fridge stays its box, and no piece reaches outside the prop's measured box by more than
	# the decomposition's slack, or a player would bump into air beside the model.
	var outside := PackedStringArray()
	var shaped := 0
	for id in props.order:
		var pieces := props.pieces_of(id)
		if pieces.is_empty():
			continue
		shaped += 1
		var size := props.size_of(id)
		var box := AABB(Vector3(-size.x * 0.5, 0.0, -size.z * 0.5), size).grow(0.08)
		var inner := DotPropPieces.bounds(pieces)
		if not box.encloses(inner):
			outside.append(String(id))
	_check(not props.pieces_of(&"nature_tree_default").is_empty() and props.pieces_of(&"furniture_kitchen_fridge").is_empty()
		and props.shapes_of(&"nature_tree_default").size() == props.pieces_of(&"nature_tree_default").size(),
		"a tree collides as pieces (%d props shaped) and a fridge as its box" % shaped)
	_check(outside.is_empty(), "every prop's pieces stay inside its measured box", ", ".join(outside))
	_finished()


func _test_documents() -> void:
	_section("a map is a document, and a bad one is refused with a reason")
	var practice := HsCatalogue.practice()
	_check(str(practice.get("id", "")) == "hs_practice", "the practice house validates")
	_check(practice["boxes"][0]["at"] is Array, "positions are normalised to plain arrays")

	var props := HsProps.new()
	var _n := props.load_file()
	var unknown := 0
	for prop: Dictionary in practice["props"]:
		if not props.has(StringName(str(prop["id"]))):
			unknown += 1
	_check(unknown == 0, "every prop it names is in the catalogue")

	var bare := practice.duplicate(true)
	bare["spawns"] = {"hiders": [], "seekers": [{"at": [0, 0, 0]}]}
	var refused := HsMapDoc.validate(bare)
	_check(not refused.ok and str(refused.error).contains("hiders"), "a map with no hiders' spawns is refused, saying so")

	var wrong := practice.duplicate(true)
	wrong["kind"] = "prophunt_map"
	_check(not HsMapDoc.validate(wrong).ok, "a document of another kind is refused")

	var encoded := HsMapDoc.encode(practice)
	var decoded := HsMapDoc.decode(encoded)
	_check(decoded.ok and HsMapDoc.digest(decoded.value) == HsMapDoc.digest(practice),
		"it survives the wire whole (%d bytes)" % encoded.size())

	var torn := encoded.slice(0, encoded.size() - 3)
	_check(not HsMapDoc.decode(torn).ok, "a torn one is refused rather than half built")
	_finished()


func _test_world_builds() -> void:
	_section("the practice house builds, solid where it should be")
	var game := await _world()
	_check(game.map.id() == &"hs_practice", "the map is built")
	_check(game.map.props.size() == (game.map_doc["props"] as Array).size(), "every prop is in it (%d)" % game.map.props.size())

	var space := game.get_world_3d().direct_space_state
	var clear := 0
	var floored := 0
	var spawns: Array = (game.map_doc["spawns"] as Dictionary)["hiders"] + (game.map_doc["spawns"] as Dictionary)["seekers"]

	for spawn: Dictionary in spawns:
		var at := HsMapDoc.v3(spawn["at"])
		var hull := CapsuleShape3D.new()
		hull.radius = 0.35
		hull.height = 1.8
		var query := PhysicsShapeQueryParameters3D.new()
		query.shape = hull
		query.transform = Transform3D(Basis.IDENTITY, at + Vector3(0.0, 0.95, 0.0))
		query.collision_mask = game.physics.collision_mask(&"player")
		if space.intersect_shape(query, 1).is_empty():
			clear += 1
		var ray := PhysicsRayQueryParameters3D.create(at + Vector3.UP * 0.5, at + Vector3.DOWN * 1.0)
		if not space.intersect_ray(ray).is_empty():
			floored += 1

	_check(clear == spawns.size(), "nobody starts inside anything (%d of %d clear)" % [clear, spawns.size()])
	_check(floored == spawns.size(), "and every spawn has a floor under it (%d of %d)" % [floored, spawns.size()])

	var chair := _prop_near(game, CHAIR_AT)
	_check(chair >= 0 and game.map.prop_id(chair) == &"furniture_chair", "the chair is where the document puts it")
	_finished()


func _test_the_draw() -> void:
	_section("who seeks first: the draw, the wishes and the equal share")
	var game := await _world(func(c: HsConfig) -> void:
		c.seeker_pick = HsConfig.Pick.QUEUE
		c.players_per_seeker = 3.0)
	var ids: Array[StringName] = []
	for i in range(6):
		var p := game.add_player(StringName("u%d" % (100 + i)), "P%d" % i)
		ids.append(p.player_id)

	game.start()
	await _step(game, 2)
	_check(game.players_on(HsGame.SEEKERS).size() == 2, "six players at one per three, two seekers")

	var turns := {}
	for round_index in range(6):
		for id in ids:
			if game.team_of(id) == HsGame.SEEKERS:
				turns[id] = int(turns.get(id, 0)) + 1
		await _end_round(game)
	var spread := _spread(turns, ids)
	_check(spread.y - spread.x <= 1, "an equal share over six rounds (%d..%d each)" % [spread.x, spread.y])

	for id in ids:
		game.wish_side(id, HsGame.HIDERS)
	game.wish_side(ids[3], HsGame.SEEKERS)
	await _end_round(game)
	_check(game.team_of(ids[3]) == HsGame.SEEKERS, "somebody who asked to seek seeks")
	_finished()


func _test_first_caught() -> void:
	_section("the first one caught seeks next round")
	var game := await _world(func(c: HsConfig) -> void:
		c.seeker_pick = HsConfig.Pick.FIRST_CAUGHT
		c.hide_seconds = 0.25)
	for i in range(5):
		var _p := game.add_player(StringName("u%d" % (150 + i)), "P%d" % i)
	game.start()
	await _wait_for(game, HsGame.Phase.SEEK)
	_check(game.players_on(HsGame.SEEKERS).size() == 1, "five players, one seeker")
	var seeker: HsPlayer = game.players_on(HsGame.SEEKERS)[0]
	var hiders := game.players_on(HsGame.HIDERS)
	var first: HsPlayer = hiders[hiders.size() - 1]
	var _a := game.catch(first.player_id, seeker.player_id, HsGame.CAUGHT_TAG)
	var _b := game.catch(hiders[0].player_id, seeker.player_id, HsGame.CAUGHT_TAG)
	_check(game.first_caught == first.player_id, "the first catch is remembered", String(game.first_caught))
	await _end_round(game)
	_check(game.players_on(HsGame.SEEKERS).size() == 1 and game.team_of(first.player_id) == HsGame.SEEKERS,
		"and they are next round's seeker, alone", "%s" % [_names(game.players_on(HsGame.SEEKERS))])
	_finished()


func _test_the_hide() -> void:
	_section("the hide: seekers held still and blind, hiders free")
	var game := await _world(func(c: HsConfig) -> void: c.hide_seconds = 1.0)
	var seeker := game.add_player(&"u200", "Seeker")
	var hider := game.add_player(&"u201", "Hider")
	game.wish_side(seeker.player_id, HsGame.SEEKERS)
	game.wish_side(hider.player_id, HsGame.HIDERS)
	game.start()
	await _step(game, 2)
	_check(game.phase == HsGame.Phase.HIDE, "a round starts with the hide")
	_check(game.team_of(seeker.player_id) == HsGame.SEEKERS and seeker.controller.has_modifier(HsController.HOLD),
		"the seeker is held")

	var seeker_from := seeker.controller.state.position
	var hider_from := hider.controller.state.position
	for i in range(30):
		_drive(seeker, Vector2(0.0, 1.0))
		_drive(hider, Vector2(0.0, 1.0))
		await _step(game, 1)
	var walked := Vector2(seeker.controller.state.position.x - seeker_from.x, seeker.controller.state.position.z - seeker_from.z)
	_check(walked.length() < 0.05, "a blindfolded seeker does not move", "%.2f m" % walked.length())
	_check(hider.controller.state.position.distance_to(hider_from) > 1.0, "a hider does")

	await _step(game, TICK_RATE)
	_check(game.phase == HsGame.Phase.SEEK and not seeker.controller.has_modifier(HsController.HOLD),
		"after the hide the seekers are let go")
	_finished()


func _test_tag() -> void:
	_section("a touch catches, a wall stops it, and the caught seek")
	var game := await _seek_round(func(c: HsConfig) -> void:
		c.caught_freeze_seconds = 1.0)
	var seeker: HsPlayer = game.players_on(HsGame.SEEKERS)[0]
	var hiders := game.players_on(HsGame.HIDERS)
	var hider: HsPlayer = hiders[0]
	var other: HsPlayer = hiders[1]
	other.place_at(Vector3(-6.0, 0.05, 5.0), 0.0)

	# Through the wall between the rooms: a metre apart, and not a touch.
	hider.place_at(Vector3(-0.5, 0.05, -4.0), 0.0)
	seeker.place_at(Vector3(0.5, 0.05, -4.0), 0.0)
	await _step(game, 4)
	_check(game.team_of(hider.player_id) == HsGame.HIDERS and not hider.caught, "a seeker a metre away through a wall has not touched anybody")

	hider.place_at(KITCHEN_A, 0.0)
	seeker.place_at(KITCHEN_A + Vector3(3.0, 0.0, 0.0), 90.0)
	var points := seeker.points
	var heard: Array = []
	game.caught.connect(func(id: StringName, by: StringName, how: StringName) -> void: heard.append([id, by, how]))
	await _step(game, 4)
	_check(not hider.caught, "three metres is not a touch")

	for i in range(TICK_RATE * 2):
		_drive(seeker, Vector2(0.0, 1.0))
		await _step(game, 1)
		if hider.caught:
			break
	_check(hider.caught and heard.size() == 1 and heard[0][1] == seeker.player_id and heard[0][2] == HsGame.CAUGHT_TAG,
		"a seeker who runs into a hider tags them", str(heard))
	_check(game.team_of(hider.player_id) == HsGame.SEEKERS, "and the caught hider is a seeker now")
	_check(seeker.points == points + game.config.catch_points, "the seeker is paid for the catch (+%d)" % (seeker.points - points))
	_check(hider.controller.has_modifier(HsController.HOLD), "a new seeker is held for a moment")
	await _step(game, TICK_RATE + 8)
	_check(not hider.controller.has_modifier(HsController.HOLD) and hider.held_until < 0.0, "and let go after it")
	_finished()


func _test_sight() -> void:
	_section("being watched fills a meter, and a full one is caught")
	var game := await _seek_round(func(c: HsConfig) -> void:
		c.catch_mode = HsConfig.Catch.SIGHT
		c.sight_seconds = 1.0
		c.sight_decay = 1.0)
	var seeker: HsPlayer = game.players_on(HsGame.SEEKERS)[0]
	var hider: HsPlayer = game.players_on(HsGame.HIDERS)[0]
	game.players_on(HsGame.HIDERS)[1].place_at(Vector3(-6.0, 0.05, 5.0), 0.0)

	# Behind the wall: in front of the seeker's eyes, and not seen.
	hider.place_at(LIVING, 0.0)
	seeker.place_at(KITCHEN_A, 0.0)
	_aim(seeker, LIVING + Vector3(0.0, 1.2, 0.0))
	await _step(game, TICK_RATE / 2)
	_check(hider.sight_meter == 0.0, "a wall between them hides a hider")

	# Touching is not a catch under this rule.
	hider.place_at(KITCHEN_A + Vector3(-0.6, 0.0, 0.0), 0.0)
	_aim(seeker, Vector3(10.0, 1.6, -3.0))
	await _step(game, 4)
	_check(not hider.caught and hider.sight_meter == 0.0, "nor does standing behind somebody, under the sight rule")

	hider.place_at(KITCHEN_A, 0.0)
	seeker.place_at(KITCHEN_B, 0.0)
	_aim(seeker, KITCHEN_A + Vector3(0.0, 1.2, 0.0))
	await _step(game, TICK_RATE / 2)
	_check(hider.sight_meter > 0.3 and hider.sight_meter < 0.7 and not hider.caught,
		"half a second in plain sight half fills it (%.2f)" % hider.sight_meter)

	_aim(seeker, KITCHEN_B + Vector3(5.0, 1.6, 0.0))
	await _step(game, TICK_RATE / 4)
	var drained := hider.sight_meter
	_check(drained < 0.4, "looking away lets it drain (%.2f)" % drained)

	_aim(seeker, KITCHEN_A + Vector3(0.0, 1.2, 0.0))
	await _step(game, TICK_RATE + 4)
	_check(hider.caught and game.team_of(hider.player_id) == HsGame.SEEKERS, "and a second of being watched catches them")
	_finished()


func _test_out() -> void:
	_section("on a server where the caught are out, they watch")
	var game := await _seek_round(func(c: HsConfig) -> void:
		c.caught_become_seekers = false)
	var seeker: HsPlayer = game.players_on(HsGame.SEEKERS)[0]
	var hider: HsPlayer = game.players_on(HsGame.HIDERS)[0]
	_check(game.catch(hider.player_id, seeker.player_id, HsGame.CAUGHT_TAG), "the catch is made")
	_check(game.team_of(hider.player_id) == HsGame.HIDERS and hider.watching, "they stay a hider, and sit the round out")
	_check(game.alive_on(HsGame.HIDERS) == 1, "and are not counted as hidden")
	_check(not game.catch(hider.player_id, seeker.player_id, HsGame.CAUGHT_TAG), "nobody is caught twice")
	_finished()


func _test_free_roam() -> void:
	_section("whoever is out may free-roam by default, unless an operator says otherwise")
	_check(HsConfig.new().spectate_camera == 0, "the config lets anybody be watched, so a free camera is not ruled out")
	var game := await _seek_round(func(c: HsConfig) -> void:
		c.caught_become_seekers = false)
	var seeker: HsPlayer = game.players_on(HsGame.SEEKERS)[0]
	var hider: HsPlayer = game.players_on(HsGame.HIDERS)[0]
	var id := hider.player_id
	_check(game.spectate_rules.roaming_permitted() and game.spectate.manager.rules == game.spectate_rules,
		"the game's rules allow roaming and are the manager's own")
	_check(game.catch(id, seeker.player_id, HsGame.CAUGHT_TAG), "a hider is caught and sits out")
	game.spectate.manager.set_mode(String(id), DotSpectatorView.Mode.CHASE)
	_check(game.spectate.can_roam(id), "and may roam")
	_check(game.spectate.toggle_roam(id).ok and game.spectate.is_roaming(id), "the key enters the free camera")
	var cam := DotSpectatorFreeCam.new()
	cam.rules = game.spectate_rules
	cam.seed_from(Transform3D(Basis.IDENTITY, Vector3(0, 2, 0)))
	var pose := cam.step(Vector3(0, 0, 1), false, false, 0.5)
	_check(pose.origin.distance_to(Vector3(0, 2, 0)) > 0.5, "and flying moves it", str(pose.origin))
	_check(game.spectate.manager.move_free(String(id), pose.origin, pose.basis).ok
		and game.spectate.camera_for(id).origin.is_equal_approx(pose.origin), "the manager keeps where it is")
	_check(game.spectate.toggle_roam(id).ok and not game.spectate.is_roaming(id), "the key again goes back to a player")

	var _off := game.spectate_rules.set_cvar("mp_freeroam", "0")
	var refused := game.spectate.toggle_roam(id)
	_check(not refused.ok and refused.error.code == DotError.CODE_FORBIDDEN and not game.spectate.is_roaming(id),
		"mp_freeroam 0 refuses it")
	var _on := game.spectate_rules.set_cvar("mp_freeroam", "1")
	var _own := game.spectate_rules.set_cvar("mp_forcecamera", "1")
	_check(not game.spectate.toggle_roam(id).ok and not game.spectate.is_roaming(id), "mp_forcecamera 1 refuses it")

	var restricted := await _world(func(c: HsConfig) -> void:
		c.spectate_camera = 1)
	_check(restricted.spectate_rules.force_camera == 1 and not restricted.spectate_rules.roaming_permitted(),
		"a config that restricts the camera turns roaming off")
	_finished()


func _test_taunts() -> void:
	_section("taunts: chosen and paid, or forced on a hider that stands still")
	var game := await _hide_round(func(c: HsConfig) -> void:
		c.hide_seconds = 0.5
		c.auto_taunt_seconds = 2.0
		c.taunt_cooldown = 0.25
		c.taunt_points = 2)
	var hider: HsPlayer = game.players_on(HsGame.HIDERS)[0]
	var seeker: HsPlayer = game.players_on(HsGame.SEEKERS)[0]
	seeker.place_at(Vector3(8.0, 0.05, 6.0), 0.0)
	hider.place_at(LIVING, 0.0)
	game.players_on(HsGame.HIDERS)[1].place_at(Vector3(-6.0, 0.05, 5.0), 0.0)
	_check(game.taunt_ids().size() > 10, "the taunt list is read (%d)" % game.taunt_ids().size())

	var heard: Array = []
	game.taunted.connect(func(id: StringName, taunt_id: StringName, forced: bool) -> void:
		heard.append([id, taunt_id, forced]))
	var points := hider.points
	_check(not game.taunt(hider.player_id, &"you_lose") and hider.points == points,
		"no taunt while the seekers are blindfolded")
	_check(not game.taunt(seeker.player_id, &"you_lose"), "and never from a seeker")

	while game.phase != HsGame.Phase.SEEK:
		await _step(game, 1)

	_check(game.taunt(hider.player_id, &"you_lose") and hider.points == points + 2,
		"a chosen taunt while they seek is paid (+%d)" % (hider.points - points))
	_check(not game.taunt(hider.player_id), "and a second straight after is refused")

	await _step(game, TICK_RATE)
	_check(hider.taunt_meter > 0.3 and hider.taunt_meter < 0.8, "standing still fills the meter (%.2f at one second of two)" % hider.taunt_meter)
	await _step(game, TICK_RATE + 4)
	var forced := heard.filter(func(h: Array) -> bool: return bool(h[2]) and h[0] == hider.player_id)
	_check(forced.size() == 1, "and two seconds of it forces one taunt", "%d" % forced.size())
	_finished()


func _test_the_round() -> void:
	_section("a round: the seekers catch everybody, or the hiders hold out")
	var game := await _seek_round(func(c: HsConfig) -> void:
		c.round_seconds = 30.0)
	var winners: Array = []
	game.round_over.connect(func(_n: int, winner: int, _why: String) -> void: winners.append(winner))
	var seeker: HsPlayer = game.players_on(HsGame.SEEKERS)[0]
	var points := seeker.points

	for hider in game.players_on(HsGame.HIDERS):
		var _c := game.catch(hider.player_id, seeker.player_id, HsGame.CAUGHT_TAG)
	_check(game.players_on(HsGame.SEEKERS).size() == 3, "everybody ends it seeking")
	await _step(game, 4)
	_check(winners == [HsGame.SEEKERS], "every hider caught is the seekers' round")
	_check(seeker.points >= points + game.config.winner_points + 2 * game.config.catch_points,
		"and the seeker is paid for each catch and for winning")

	await _wait_for(game, HsGame.Phase.SEEK)
	_check(game.players_on(HsGame.SEEKERS).size() == 1, "the next round draws the sides afresh")
	var survivor: HsPlayer = game.players_on(HsGame.HIDERS)[0]
	var kept := survivor.points
	game.seek_elapsed = game.round_limit() - 0.05
	await _step(game, 6)
	_check(winners.size() == 2 and winners[1] == HsGame.HIDERS, "the clock is the hiders' round")
	_check(survivor.points >= kept + game.config.winner_points + game.config.survive_points,
		"and a hider never caught is paid for winning and for surviving")
	_finished()


func _test_falls() -> void:
	_section("a fall: a hider is caught by it, a seeker starts again")
	var game := await _seek_round()
	var seeker: HsPlayer = game.players_on(HsGame.SEEKERS)[0]
	var hider: HsPlayer = game.players_on(HsGame.HIDERS)[0]
	var seeker_start: Vector3 = game.map.spawn("seekers", 0)[0]

	hider.place_at(Vector3(0.0, game.map.kill_height() - 5.0, 0.0), 0.0)
	await _step(game, 3)
	_check(hider.caught and game.team_of(hider.player_id) == HsGame.SEEKERS and hider.is_alive(),
		"a hider who falls off the map is caught, and is on their feet as a seeker")
	_check(hider.controller.state.position.distance_to(seeker_start) < 1.0, "at the seekers' start")

	seeker.place_at(Vector3(0.0, game.map.kill_height() - 5.0, 0.0), 0.0)
	await _step(game, 3)
	_check(seeker.is_alive() and seeker.controller.state.position.distance_to(seeker_start) < 1.0,
		"a seeker who falls is put back at the start")
	_finished()


func _death_sounds_listed() -> bool:
	var catalogue: DotAudioCatalogue = (load("res://game/hs_audio.gd") as GDScript).call("sound_catalogue")
	for row: Dictionary in DotPlayerDeathSounds.rows():
		if catalogue.find(row["id"]) == null:
			return false
	return not DotPlayerDeathSounds.rows().is_empty()


func _test_the_beacon() -> void:
	_section("the last hider is given away")
	var game := await _seek_round(func(c: HsConfig) -> void:
		c.beacon_hiders_left = 1
		c.beacon_seconds_left = 0.0)
	var hiders := game.players_on(HsGame.HIDERS)
	await _step(game, 2)
	_check(hiders.filter(func(p: HsPlayer) -> bool: return p.marked).is_empty(), "nobody is marked while several are hidden")
	var _c := game.catch(hiders[0].player_id, game.players_on(HsGame.SEEKERS)[0].player_id, HsGame.CAUGHT_TAG)
	await _step(game, 2)
	_check(hiders[1].marked and not hiders[0].marked, "the last one is, and the caught one is not")
	_finished()


func _test_joiners() -> void:
	_section("somebody who joins while the seekers are out seeks")
	var game := await _seek_round()
	var late := game.add_player(&"u399", "Late")
	_check(game.team_of(late.player_id) == HsGame.SEEKERS and not late.watching, "they join the seekers, and play")
	await _end_round(game)
	var early := game.add_player(&"u398", "Early")
	_check(game.phase == HsGame.Phase.HIDE and game.team_of(early.player_id) == HsGame.HIDERS,
		"somebody who joins during the hide hides")
	_finished()


func _test_interest() -> void:
	_section("a seeker is told nothing about the hiders while they hide")
	var game := HsGame.new()
	var config := HsConfig.new()
	game.config = config
	var interest := HsInterest.new()
	interest.game = game
	var seeker := HsPlayer.new()
	seeker.player_id = &"u1"
	var hider := HsPlayer.new()
	hider.player_id = &"u2"
	game.sides[&"u1"] = HsGame.SEEKERS
	game.sides[&"u2"] = HsGame.HIDERS
	var watcher := DotNetIdentity.new()
	var seen := DotNetIdentity.new()
	seeker.add_child(watcher)
	hider.add_child(seen)

	game.phase = HsGame.Phase.HIDE
	_check(not interest._is_relevant(watcher, seen, {}), "a hider is not in a seeker's snapshot while the hiders hide")
	_check(interest._is_relevant(seen, watcher, {}), "a seeker is in a hider's")
	game.phase = HsGame.Phase.SEEK
	_check(interest._is_relevant(watcher, seen, {}), "and once the seekers are let go, everybody is in everybody's")

	seeker.free()
	hider.free()
	game.free()
	_finished()


func _test_progress() -> void:
	_section("what a catch is worth to a player's numbers")
	var game := await _seek_round()
	var seeker: HsPlayer = game.players_on(HsGame.SEEKERS)[0]
	var hiders := game.players_on(HsGame.HIDERS)
	var _a := game.catch(hiders[0].player_id, seeker.player_id, HsGame.CAUGHT_TAG)
	var _b := game.catch(hiders[1].player_id, seeker.player_id, HsGame.CAUGHT_SIGHT)
	var mine := game.progress.session_values(seeker.player_id)
	var first := game.progress.session_values(hiders[0].player_id)
	var second := game.progress.session_values(hiders[1].player_id)
	_check(mine.get_value(HsProgress.CAUGHT_OTHERS) == 2.0, "the seeker counted two catches")
	_check(first.get_value(HsProgress.FIRST_CAUGHT) == 1.0 and second.get_value(HsProgress.FIRST_CAUGHT) == 0.0,
		"only the first caught is counted first")
	_check(second.get_value(HsProgress.SPOTTED) == 1.0 and first.get_value(HsProgress.SPOTTED) == 0.0,
		"and only the one seen was spotted")

	var declared := HsProgress.ids()
	var unread: Array = []
	for achievement in HsProgress.catalogue().achievements:
		for rule in achievement.requirements:
			if not declared.has(rule.stat):
				unread.append(String(achievement.id))
	_check(unread.is_empty(), "every achievement reads a number this game records", str(unread))
	_finished()


func _test_bots() -> void:
	_section("stand-ins hide and seek")
	var game := await _world(func(c: HsConfig) -> void:
		c.hide_seconds = 6.0
		c.players_per_seeker = 3.0)
	for i in range(6):
		var bot := game.add_player(StringName("u%d" % (900 + i)), "Bot%d" % i)
		bot.is_bot = true
	game.start()
	await _step(game, 2)
	var starts := {}
	for p in game.players_on(HsGame.HIDERS):
		starts[p.player_id] = p.controller.state.position
	await _step(game, TICK_RATE * 6)
	var moved := 0
	for p in game.players_on(HsGame.HIDERS):
		if p.controller.state.position.distance_to(starts.get(p.player_id, Vector3.ZERO)) > 1.5:
			moved += 1
	_check(moved >= starts.size() - 1, "the stand-in hiders went somewhere to hide (%d of %d)" % [moved, starts.size()])
	var round_before := game.round_number
	await _step(game, TICK_RATE * 8)
	# Stand-in seekers can find everybody in a house this small, and the next round begins.
	_check(game.phase == HsGame.Phase.SEEK or game.phase == HsGame.Phase.IDLE or game.round_number > round_before,
		"and the round goes on without anybody at the keyboard", "phase %d, round %d" % [game.phase, game.round_number])
	_finished()

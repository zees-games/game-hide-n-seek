extends Node

const HsCatalogue := preload("../game/hs_catalogue.gd")
const HsConfig := preload("../game/hs_config.gd")
const HsController := preload("../game/hs_controller.gd")
const HsGame := preload("../game/hs_game.gd")
const HsInterest := preload("../game/net/hs_interest.gd")
const HsMapDoc := preload("../game/hs_map_doc.gd")
const HsPlayer := preload("../game/hs_player.gd")
const HsProgress := preload("../game/hs_progress.gd")
const HsProps := preload("../game/hs_props.gd")

## The simulation, headless: the prop catalogue and the map documents, the draw, the hide,
## catching by a touch and by being watched, what happens to the caught, taunts, falls, the
## beacon, and how a round is decided.
##
## [b]Counts sections AND checks, and the second is the one that matters.[/b] A script error
## inside a section aborts that function and the section counter is already satisfied,
## because the section announced itself on the way in. dot-settings has the story.
##
## Every number about the map here is the built-in practice house's
## ([method HsCatalogue.practice]), whose comment lists where everything is: the wall between
## the rooms at x 0 with its door at z -1..0.8, the kitchen east of it, the living room west.

const SECTIONS := 20

const CHECKS := 94

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

## The first chair round the kitchen table in the practice house: where it stands.
const CHAIR_AT := Vector3(3.6, 0.0, 1.2)

## An open stretch of the kitchen floor, and of the living room's, either side of the wall.
const KITCHEN_A := Vector3(3.0, 0.05, -3.0)
const KITCHEN_B := Vector3(8.0, 0.05, -3.0)
const LIVING := Vector3(-3.0, 0.05, -3.0)

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

var _worlds: Array[HsGame] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("hideseek headless run")
	print("")

	_test_config()
	_test_catalogue()
	_test_documents()
	await _test_world_builds()
	await _test_the_draw()
	await _test_first_caught()
	await _test_the_hide()
	await _test_tag()
	await _test_sight()
	await _test_out()
	await _test_taunts()
	await _test_the_round()
	await _test_falls()
	await _test_the_beacon()
	await _test_joiners()
	_test_interest()
	await _test_progress()
	await _test_bots()
	await _test_doors()
	await _test_the_client()

	for world in _worlds.duplicate():
		await _dispose(world)

	await get_tree().process_frame

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished or _sections_entered != SECTIONS:
		print("ERROR: %d of %d sections finished, %d expected." % [
			_sections_finished, _sections_entered, SECTIONS
		])
		code = 1

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		code = 1

	get_tree().quit(code)


# --- Without a world ------------------------------------------------------------

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


# --- A world ---------------------------------------------------------------------

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
	await _step(game, TICK_RATE * 8)
	_check(game.phase == HsGame.Phase.SEEK or game.phase == HsGame.Phase.IDLE, "and the round goes on without anybody at the keyboard")
	_finished()


func _test_the_client() -> void:
	_section("the client boots offline: the keys, the HUD, the taunt list, the board")
	var client: Node = (load("res://game/hs_client.gd") as GDScript).new()
	client.set(&"force_offline", true)
	client.set(&"config_file", "user://cfg/headless-none.json")
	add_child(client)

	for i in 8:
		await get_tree().process_frame

	_check(InputMap.has_action(&"hs_taunt") and InputMap.has_action(&"hs_taunt_menu"),
		"the game's keys are actions, from the bindings table")
	_check(client.get("player") != null and client.get("hud") != null and (client.get("hud") as Node).get("game") != null,
		"a player and a HUD bound to the world")
	client.call("open_taunts")
	var menu: Variant = (client.get("settings") as Node).get("menu") if client.get("settings") != null else null
	_check(menu != null and (menu as DotMenu).picker.is_open(), "the taunt picker opens")
	if menu != null:
		(menu as DotMenu).picker.close()
	var snapshot: Dictionary = client.call("board_snapshot")
	_check((snapshot["players"] as Array).size() >= 2, "the board lists the room")

	var world: HsGame = client.get("game")
	world.wish_side(&"local", HsGame.SEEKERS)
	world._on_round_started(world.round_number + 1)
	for i in 4:
		await get_tree().process_frame
	var hud: Node = client.get("hud")
	_check(world.team_of(&"local") == HsGame.SEEKERS and bool(hud.call("is_blindfolded")),
		"a seeker counting is blindfolded on their own screen")

	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()


# --- Helpers --------------------------------------------------------------------

func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return

	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)


## A world on the practice house, stepped by hand. The previous one is freed first: every
## world here shares ONE physics space, and every map is built at the origin.
## The practice house's garden door: shut, in the east wall, swinging out into the garden.
const GARDEN_DOOR := 1
const GARDEN_DOOR_AT := Vector3(10.1, 1.1, 0.0)


func _test_doors() -> void:
	_section("a door opens with the use key, stops what a wall stops, and never shuts on anybody")
	var game := await _seek_round()
	var doors := game.map.doors
	var seeker: HsPlayer = game.players_on(HsGame.SEEKERS)[0]
	var hider: HsPlayer = game.players_on(HsGame.HIDERS)[0]
	var other: HsPlayer = game.players_on(HsGame.HIDERS)[1]
	other.place_at(Vector3(-6.0, 0.05, 5.0), 0.0)
	seeker.place_at(Vector3(-6.0, 0.05, -5.0), 0.0)
	var used: Array = []
	var refusals: Array = []
	game.door_used.connect(func(index: int, open: bool, _flip: bool, _tick: int, by: StringName) -> void:
		used.append([index, open, by]))
	game.refused.connect(func(id: StringName, why: String) -> void: refusals.append([id, why]))

	# From inside: the use key, looking at it.
	hider.place_at(Vector3(8.6, 0.05, 0.0), -90.0)
	_aim(hider, GARDEN_DOOR_AT)
	await _press(game, hider)
	_check(doors.is_open(GARDEN_DOOR) and used.size() == 1 and used[0][2] == hider.player_id,
		"the use key opens the door in front of them", str(used))
	await _step(game, TICK_RATE)
	var panel := (doors.doors[GARDEN_DOOR]["body"] as Node3D).global_position
	_check(panel.x > GARDEN_DOOR_AT.x + 0.4 and doors.flips_for(GARDEN_DOOR, Vector3(12.0, 1.6, 0.4)),
		"it swings away from whoever opened it, whichever side they are on", "panel at %s" % panel.snapped(Vector3.ONE * 0.1))

	for i in range(TICK_RATE * 2):
		_drive(hider, Vector2(0.0, 1.0))
		await _step(game, 1)
	_check(hider.controller.state.position.x > 11.0, "an open door is a way through",
		"x %.2f" % hider.controller.state.position.x)

	# From the garden, out of its way: shut it.
	hider.place_at(Vector3(12.8, 0.05, 0.4), 90.0)
	_aim(hider, panel)
	await _press(game, hider)
	await _step(game, TICK_RATE)
	_check(not doors.is_open(GARDEN_DOOR) and not doors.moving(GARDEN_DOOR, game.current_tick()),
		"and the use key shuts it again", str(used))

	hider.place_at(Vector3(11.5, 0.05, 0.0), 90.0)
	for i in range(TICK_RATE * 2):
		_drive(hider, Vector2(0.0, 1.0))
		await _step(game, 1)
	_check(hider.controller.state.position.x > GARDEN_DOOR_AT.x, "a shut door stops a body, as a wall does",
		"x %.2f" % hider.controller.state.position.x)

	# A metre apart with the door between: no touch, as through a wall.
	hider.place_at(Vector3(10.65, 0.05, 0.0), 90.0)
	seeker.place_at(Vector3(9.55, 0.05, 0.0), -90.0)
	await _step(game, 4)
	_check(not hider.caught, "and a touch through it")

	# The seeker opens it, into the hider standing against it: refused, and the door stays.
	_aim(seeker, GARDEN_DOOR_AT)
	var before := used.size()
	await _press(game, seeker)
	_check(not doors.is_open(GARDEN_DOOR) and used.size() == before and not refusals.is_empty()
		and refusals[-1][0] == seeker.player_id, "a door does not open into somebody", str(refusals))

	hider.place_at(Vector3(16.0, 0.05, 6.0), 0.0)
	game._hold(seeker, 5.0)
	await _press(game, seeker)
	_check(not doors.is_open(GARDEN_DOOR), "somebody held still cannot use a door")
	game._hold(seeker, 0.0)
	await _press(game, seeker)
	await _step(game, 4)

	await _end_round(game)
	_check(not doors.is_open(GARDEN_DOOR) and doors.is_open(0), "a new round puts every door back as the map has it",
		"garden %s, kitchen %s" % [doors.is_open(GARDEN_DOOR), doors.is_open(0)])

	# A stand-in walking out to the garden opens the door on its way.
	var bot := game.add_player(&"u990", "DoorBot")
	bot.is_bot = true
	game.wish_side(bot.player_id, HsGame.HIDERS)
	game._set_side(bot.player_id, HsGame.HIDERS)
	bot.place_at(Vector3(8.4, 0.05, 0.2), -90.0)
	game._bot[bot.player_id] = {"goal": Vector3(16.0, 0.0, 0.2), "since": game.current_tick(),
		"stuck": [bot.controller.state.position, game.current_tick()]}
	for i in range(TICK_RATE * 4):
		await _step(game, 1)
		if bot.controller.state.position.x > 12.0:
			break
	_check(bot.controller.state.position.x > 12.0, "a stand-in opens a shut door it walks into",
		"at %s; the door is %s" % [bot.controller.state.position.snapped(Vector3.ONE * 0.1), "open" if doors.is_open(GARDEN_DOOR) else "shut"])
	_finished()


## The use key down for a tick and up again: the game makes a press from the edge.
func _press(game: HsGame, player: HsPlayer) -> void:
	player.wants_use = true
	await _step(game, 1)
	player.wants_use = false
	await _step(game, 1)


func _world(configure: Callable = Callable()) -> HsGame:
	for old in _worlds.duplicate():
		await _dispose(old)

	var config := HsConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.map_ids = PackedStringArray(["hs_practice"])
	config.keep_progress = true
	config.hide_seconds = 2.0
	config.seeker_pick = HsConfig.Pick.RANDOM

	if configure.is_valid():
		configure.call(config)

	var game := HsGame.new()
	game.name = "World%d" % _worlds.size()
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	_worlds.append(game)

	await _physics_frame()
	await _physics_frame()
	return game


## A world in the hide, with a seeker and two hiders.
func _hide_round(configure: Callable = Callable()) -> HsGame:
	var game := await _world(configure)
	var seeker := game.add_player(&"u300", "Seeker")
	game.wish_side(seeker.player_id, HsGame.SEEKERS)
	for i in range(2):
		var hider := game.add_player(StringName("u%d" % (301 + i)), "Hider%d" % i)
		game.wish_side(hider.player_id, HsGame.HIDERS)
	game.start()
	await _wait_for(game, HsGame.Phase.HIDE)
	return game


## A world where the seekers are seeking.
func _seek_round(configure: Callable = Callable()) -> HsGame:
	var game := await _hide_round(func(c: HsConfig) -> void:
		c.hide_seconds = 0.25
		if configure.is_valid():
			configure.call(c))
	await _wait_for(game, HsGame.Phase.SEEK)
	return game


func _wait_for(game: HsGame, phase: int) -> void:
	for i in range(TICK_RATE * 20):
		if game.phase == phase:
			return
		await _step(game, 1)


## Ends the round in play (the seekers win) and waits for the next to begin.
func _end_round(game: HsGame) -> void:
	var number := game.round_number
	while game.phase == HsGame.Phase.HIDE:
		await _step(game, 1)
	var seekers := game.players_on(HsGame.SEEKERS)
	for hider in game.players_on(HsGame.HIDERS):
		var _c := game.catch(hider.player_id, seekers[0].player_id if not seekers.is_empty() else &"", HsGame.CAUGHT_TAG)
	for i in range(TICK_RATE * 20):
		await _step(game, 1)
		if game.round_number > number and game.phase == HsGame.Phase.HIDE:
			return


func _step(game: HsGame, ticks: int) -> void:
	for _i in range(ticks):
		game.simulate(TICK)
		await _physics_frame()


func _physics_frame() -> void:
	await get_tree().physics_frame


func _dispose(game: HsGame) -> void:
	_worlds.erase(game)

	if not is_instance_valid(game):
		return

	remove_child(game)
	game.free()
	await get_tree().process_frame


func _drive(player: HsPlayer, move: Vector2) -> void:
	var command := DotFpsCommand.new()
	command.yaw = player.controller.state.yaw
	command.move = move
	player.controller.apply_command(command)


func _aim(player: HsPlayer, target: Vector3) -> void:
	var look := target - player.eye_position()
	var command := DotFpsCommand.new()
	command.yaw = rad_to_deg(atan2(-look.x, -look.z))
	command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
	player.controller.state.yaw = command.yaw
	player.controller.state.pitch = command.pitch
	player.controller.apply_command(command)


func _prop_near(game: HsGame, at: Vector3) -> int:
	for index in range(game.map.props.size()):
		if ((game.map.props[index] as Dictionary)["transform"] as Transform3D).origin.distance_to(at) < 0.05:
			return index
	return -1


static func _names(of: Array[HsPlayer]) -> PackedStringArray:
	var out := PackedStringArray()
	for p in of:
		out.append(String(p.player_id))
	return out


static func _spread(turns: Dictionary, ids: Array[StringName]) -> Vector2i:
	var lo := 999
	var hi := 0
	for id in ids:
		lo = mini(lo, int(turns.get(id, 0)))
		hi = maxi(hi, int(turns.get(id, 0)))
	return Vector2i(lo, hi)

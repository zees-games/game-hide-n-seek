extends "headless_run_client.gd"

## The simulation, headless: the prop catalogue and map documents, the draw, the hide, catching by touch and by being watched, the caught, taunts, falls, the beacon, and how a round is decided.
## Counts sections AND checks: a script error aborts a section after it announced itself. Map numbers are the practice house's ([method HsCatalogue.practice]): the wall at x 0 with its door at z -1..0.8, kitchen east, living room west.


const SECTIONS := 26

const CHECKS := 152


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
	await _test_free_roam()
	await _test_taunts()
	await _test_the_round()
	await _test_falls()
	await _test_fall_damage()
	await _test_the_beacon()
	await _test_joiners()
	_test_interest()
	await _test_progress()
	await _test_bots()
	await _test_doors()
	await _test_toys()
	await _test_the_client()
	await _test_help_and_menu()
	await _test_the_map_menu()
	await _test_wheel_jump()

	for world in _worlds.duplicate():
		await _dispose(world)

	await get_tree().process_frame

	_report_sections(_sections_entered, _sections_finished, SECTIONS, CHECKS)




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
	var walk: Dictionary = game.bots._state_of(bot)
	walk["spot"] = {"at": Vector3(16.0, 0.0, 0.2), "exposure": 0.0}
	walk["mode"] = &"going"
	for i in range(TICK_RATE * 4):
		await _step(game, 1)
		if bot.controller.state.position.x > 12.0:
			break
	_check(bot.controller.state.position.x > 12.0, "a stand-in opens a shut door it walks into",
		"at %s; the door is %s" % [bot.controller.state.position.snapped(Vector3.ONE * 0.1), "open" if doors.is_open(GARDEN_DOOR) else "shut"])
	_finished()


## The practice house's garden toys (dot-props'): the beach ball at 16.5, -2.5, the football at
## 14, 3, the tyre, and the lamp (3) on its switch (4) at 12, -3.
func _test_toys() -> void:
	_section("toys: walked into, kicked, switched, bounced on, home again at the next round")
	var game := await _seek_round()
	var toys := game.map.toys
	var hider: HsPlayer = game.players_on(HsGame.HIDERS)[0]

	# A person is not a rigid body: walking into the ball is the game's push, every tick.
	var ball := toys.toy(0)
	var start := ball.body.global_position
	hider.place_at(Vector3(13.0, 0.05, -2.5), -90.0)
	for _i in range(TICK_RATE):
		_drive(hider, Vector2(0.0, 1.0))
		await _step(game, 1)
	_check(ball.body.global_position.x > start.x + 0.8, "walking into the beach ball sends it on ahead",
		"%.2f m" % (ball.body.global_position.x - start.x))

	var football := toys.toy(1)
	var kick_from := football.body.global_position
	hider.place_at(kick_from + Vector3(0.0, 0.05, 1.3), 0.0)
	_drive(hider, Vector2.ZERO)
	await _step(game, 2)
	_aim(hider, kick_from)
	_check(game.toy_aimed(hider) == football.index and toys.toy(game.toy_aimed(hider)).prompt() == "Kick the football",
		"looking at the football, the use key's prompt says so", toys.toy(game.toy_aimed(hider)).prompt() if game.toy_aimed(hider) >= 0 else "nothing aimed")
	await _press(game, hider)
	await _step(game, TICK_RATE / 2)
	_check(football.body.global_position.distance_to(kick_from) > 1.5, "and the use key kicks it",
		"%.2f m" % football.body.global_position.distance_to(kick_from))

	var lamp := toys.toy(3)
	var switch := toys.toy(4)
	var was_lit := lamp.on
	hider.place_at(switch.global_position + Vector3(0.0, 0.05, 1.2), 0.0)
	await _step(game, 2)
	_aim(hider, switch.global_position + Vector3(0.0, 0.9, 0.0))
	await _press(game, hider)
	_check(lamp.on != was_lit and switch.count == 1, "the switch turns the lamp", "lit %s" % lamp.on)

	# A trampoline: landing on it throws a person up, from inside their movement (so a
	# predicting client is thrown on the same tick), and counts the bounce for everybody to hear.
	var placements: Array = (game.map_doc["toys"] as Array).duplicate()
	placements.append({"toy": "trampoline", "at": [19.5, 0.0, 0.0]})
	placements.append({"toy": "merry_go_round", "at": [16.0, 0.0, 4.5]})
	var _rebuilt := toys.build(placements)
	var tramp := toys.toy(placements.size() - 2)
	var deck := toys.toy(placements.size() - 1)
	hider.place_at(Vector3(19.5, 1.2, 0.0), 0.0)
	var highest := 0.0
	for _i in range(TICK_RATE * 2):
		_drive(hider, Vector2.ZERO)
		await _step(game, 1)
		highest = maxf(highest, hider.controller.state.position.y)
	_check(highest > 2.0, "landing on the trampoline throws a person up", "%.2f m at the top" % highest)
	_check(tramp.count >= 2, "and every bounce is counted, which is what a client hears", str(tramp.count))

	# A roundabout: a person standing on it a metre from the hub goes round with it, in their
	# movement (HsController.carrier, dot-props' carry_for), and is still a metre out after.
	var hub := deck.global_position
	hider.place_at(hub + Vector3(1.0, 0.5, 0.0), 0.0)
	for _i in range(TICK_RATE / 2):
		_drive(hider, Vector2.ZERO)
		await _step(game, 1)
	var before := hider.controller.state.position - hub
	var _spun := toys.use(deck.index, hub + Vector3(0.0, 1.5, 2.5), Vector3(1.0, -0.3, 0.0))
	var turned := 0.0
	var last := atan2(before.z, before.x)
	for _i in range(TICK_RATE):
		_drive(hider, Vector2.ZERO)
		await _step(game, 1)
		var now := hider.controller.state.position - hub
		turned += absf(wrapf(atan2(now.z, now.x) - last, -PI, PI))
		last = atan2(now.z, now.x)
	var after := hider.controller.state.position - hub
	var out := Vector2(after.x, after.z).length()
	_check(turned > 0.8 and hider.controller.state.is_grounded(), "standing on a turning roundabout carries a person round its hub",
		"%.0f degrees in a second" % rad_to_deg(turned))
	_check(absf(out - Vector2(before.x, before.z).length()) < 0.25, "and leaves them as far out as they stood",
		"%.2f m from the hub, from %.2f" % [out, Vector2(before.x, before.z).length()])

	var _off := game.toy_rules.set_cvar(DotPropToyRules.CVAR_ENABLED, "0")
	_check(not toys.toy(0).visible and toys.toy(0).process_mode == Node.PROCESS_MODE_DISABLED, "sv_toys 0 takes the toys away")
	var _on := game.toy_rules.set_cvar(DotPropToyRules.CVAR_ENABLED, "1")

	await _end_round(game)
	var home := toys.toy(1)
	_check(home.body.global_position.distance_to(home.rest.origin) < 0.05, "a new round puts every toy home",
		"%.2f m away" % home.body.global_position.distance_to(home.rest.origin))
	_finished()

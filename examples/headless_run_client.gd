extends "headless_run_world.gd"
## The client, menu and fall-damage sections of [code]headless_run[/code] (a middle layer, split off for size); never run on its own.

const HsFigure := preload("res://game/hs_figure.gd")


func _test_the_client() -> void:
	_section("the client boots offline: the keys, the HUD, the taunt list, the board")
	var client: Node = (load("res://game/hs_client.gd") as GDScript).new()
	client.set(&"force_offline", true)
	client.set(&"config_file", "user://cfg/headless-none.json")
	add_child(client)
	# Guard: the map must not be drawn, or steered, while it is still being built.
	var platform: DotGameClient = client.get("platform")
	var covered := platform != null and platform.gate != null and not platform.is_shown() \
		and platform.is_input_blocked()
	for i in 240:
		await get_tree().process_frame
		if platform != null and platform.is_shown():
			break
	for i in 8:
		await get_tree().process_frame

	_check(covered and platform.is_shown() and not platform.is_input_blocked() and platform.console != null,
		"the loading cover is up at the start and lifts once the player is in, with the console built",
		str(platform.describe()) if platform != null else "no platform")
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
	var tab := InputEventKey.new()
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	(menu as DotMenu).handle_event(tab)
	var board: DotMenuScoreboard = client.get("board")
	_check(board != null and board.is_open() and board.rows().any(func(r: Dictionary) -> bool: return bool(r.get("you", false))),
		"Tab holds the scoreboard up, with this player picked out")
	tab.pressed = false
	(menu as DotMenu).handle_event(tab)

	var world: HsGame = client.get("game")
	world.wish_side(&"local", HsGame.SEEKERS)
	world._on_round_started(world.round_number + 1)
	for i in 4:
		await get_tree().process_frame
	var hud: Node = client.get("hud")
	_check(world.team_of(&"local") == HsGame.SEEKERS and bool(hud.call("is_blindfolded")),
		"a seeker counting is blindfolded on their own screen")

	hud.call("_process", 0.0)
	var xh: DotCrosshair = hud.get("_crosshair")
	_check(xh != null and xh.suppressed and not xh.is_shown(), "the blindfolded seeker's crosshair is suppressed")
	# The clock is dot-ui's DotScoreStrip, the two sides still in it as its plates.
	hud.call("_process", 0.0)
	var strip: DotScoreStrip = hud.get("strip")
	_check(
		strip.clock == DotScoreStrip.clock_text(world.seconds_left()) and strip.sides
		and strip.left_score == world.alive_on(HsGame.HIDERS) and strip.right_score == world.alive_on(HsGame.SEEKERS),
		"the clock is DotScoreStrip's, with the hiders hidden and the seekers as its plates",
		str(strip.describe())
	)

	_client_theme(client, hud, strip)
	await _client_ragdoll(client, world)
	_client_death_codec()
	await _client_door_prompt(client, world, hud)
	remove_child(client)
	client.free()
	await get_tree().process_frame
	_finished()


## A darker HUD by default, restyled live by the menu's theme.
func _client_theme(client: Node, hud: Node, strip: DotScoreStrip) -> void:
	var themed: DotMenu = (client.get("settings") as Node).get("menu")
	var plate := strip.colour(&"plate")
	_check(plate.get_luminance() < 0.1 and plate.a >= 0.7 and strip.colour(&"highlight") == (load("res://game/hs_hud.gd") as GDScript).get("MAP_COLOUR"),
		"the HUD is dark by default, in the menu's theme, with this game's colour as its accent", str(plate))
	var _t: Variant = themed.settings.set_value(&"ui_theme", &"contrast")
	var hints: Label = hud.get("_hints")
	_check(strip.colour(&"plate") == themed.palette().hud_plate and hints.get_theme_color(&"font_color") == themed.palette().hud_text
		and strip.colour(&"highlight") == (load("res://game/hs_hud.gd") as GDScript).get("MAP_COLOUR"),
		"a theme picked in the menu reaches the clock and the HUD's lines at once, the accent kept")
	_t = themed.settings.set_value(&"ui_theme", &"midnight")


## A slain stand-in falls as dot-player-char's ragdoll, copied by the client from the figure it draws.
func _client_ragdoll(client: Node, world: HsGame) -> void:
	world._set_phase(HsGame.Phase.SEEK)
	var ragdolls: DotPlayerRagdolls = client.get("ragdolls")
	var victim: HsPlayer = null
	for id: StringName in world.players:
		var p: HsPlayer = world.players[id]
		if p != client.get("player") and p.is_alive() and p.figure != null and p.figure.visible:
			victim = p
			break
	_check(victim != null and ragdolls != null and ragdolls.rules == world.ragdoll_rules,
		"the client keeps the dead under the game's sv_ragdoll* rules")
	if victim != null:
		var slay := DotDamage.make(0, victim.entity_id, victim.health.max_health * 10.0, null)
		slay.tick = world._tick
		var _applied := world.combat.apply_damage(slay)
		await get_tree().process_frame
		_check(victim.death != null and DotPlayerDeathReactions.stock().has(victim.death.reaction),
			"the world picked how the body falls", str(victim.death.describe()) if victim.death != null else "none")
		var bodies := ragdolls.live()
		_check(bodies.size() == 1 and not victim.figure.visible,
			"and the client laid the body down from the figure, which is hidden", str(bodies.size()))
		for i in 30:
			await get_tree().physics_frame
		for i in 60:
			await get_tree().physics_frame
		var down := bodies.size() == 1 and is_instance_valid(bodies[0])
		_check(down and bodies[0].centre().y < 0.8 and bodies[0].lowest_point() > -0.25,
			"a second on, the body lies on the floor: not standing, not through it",
			str(bodies[0].describe()) if down else "gone")
	else:
		for k in 3:
			_check(false, "a stand-in drawn to slay")
	var fig := HsFigure.new()
	add_child(fig)
	fig.build(1.8, HsFigure.ATLASES[0], Color.RED)
	await get_tree().process_frame
	fig.pose(Vector3.ZERO, 0.0, 4.0)
	await get_tree().process_frame
	fig.pose(Vector3.ZERO, 0.0, 4.0)
	# The wall-clock step kept a timestamp; game time leaves it alone.
	_check(fig.person != null and fig.clip != &"" and fig._posed_at_usec == -1,
		"a figure animates by game time (frame_delta), not the wall clock", str(fig._posed_at_usec))
	fig.queue_free()
	_check(_death_sounds_listed(), "the death sounds are in the game's catalogue")


func _client_death_codec() -> void:
	var fall := DotPlayerDeath.new()
	fall.reaction = &"face_plant"
	fall.roll_seed = 1234
	fall.direction = Vector3(1, 0, 0)
	var died := HsEvents.read_death(DotNetReader.new(HsEvents.write_death(5, 6, HsGame.DIED_SLAIN, fall)))
	var carried: DotPlayerDeath = died.get("death")
	_check(bool(died["ok"]) and carried != null and carried.reaction == &"face_plant" and carried.roll_seed == 1234
		and carried.direction.distance_to(Vector3(1, 0, 0)) < 0.02, "a DEATH carries the fall the server picked")
	var bare := HsEvents.read_death(DotNetReader.new(HsEvents.write_death(5, 6, HsGame.DIED_SLAIN)))
	_check(bool(bare["ok"]) and not bare.has("death"), "and one without a fall still reads")


## A hider in front of a door is prompted with the use key as bound; then the pack's dot-ui floor.
func _client_door_prompt(client: Node, world: HsGame, hud: Node) -> void:
	# The seek first, which lets this seeker's blindfold hold go; then a hider.
	world._set_phase(HsGame.Phase.SEEK)
	world._set_side(&"local", HsGame.HIDERS)
	var me: HsPlayer = client.get("player")
	var frame := (world.map.doors.doors[0]["body"] as Node3D).global_transform
	var size := HsMapDoc.v3((world.map.doors.doors[0]["spec"] as Dictionary)["size"])
	var normal := frame.basis.z.normalized()
	me.place_at(frame.origin + normal * 1.3 - Vector3(0.0, size.y * 0.5, 0.0), rad_to_deg(atan2(normal.x, normal.z)))
	for i in 4:
		await get_tree().process_frame
	hud.call("_process", 0.0)
	var prompt: DotKeyPrompt = hud.get("prompt")
	var bound := str(client.call("_key", &"hs_use"))
	_check(
		prompt.visible and (prompt.words.begins_with("Open") or prompt.words.begins_with("Shut"))
		and prompt.key == bound and bound != "",
		"at a door, DotKeyPrompt names it with the use key as bound", prompt.text()
	)

	# A pack naming these classes does not parse on a shell whose dot-ui predates them, so
	# the requires.json dot-ci derives must ask for dot-ui 4, and nothing may lower it.
	var asks := DotAddonApi.derive()
	_check(
		int(asks.get("dot_ui", 0)) >= 4 and not FileAccess.file_exists("res://" + DotAddonApi.FLOOR_FILE),
		"the pack asks a shell for dot-ui level 4, the glance pieces",
		str(asks.get("dot_ui"))
	)


## The family's rule since the first play test: H opens help in every game, nothing else in
## the table is on H, and the Escape menu has Help & commands and Leave.
func _test_help_and_menu() -> void:
	_section("H opens help, and the Escape menu has Help and Leave")
	var settings := HsSettings.new()
	add_child(settings)
	var built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	var keys: DotMenuBindings = settings.bindings
	_check(built.ok and keys != null and keys.key_for(DotMenuBindings.HELP_ACTION) == "H", "help is on H")
	_check(keys.defaults_on("H").size() == 1, "and nothing else in the table defaults to H",
		str(keys.defaults_on("H").map(func(r: Dictionary) -> String: return str(r["label"]))))
	# Chat is two rows, so help lists Y and U and the Controls page moves them.
	var _k := settings.settings.set_value(&"bind_chat", "K")
	_check(keys.key_for(HsBindings.CHAT) == "K" and DotInputBinding.describe_action(HsBindings.CHAT) == "K"
		and keys.key_for(HsBindings.CHAT_TEAM) == "U", "chat (Y) and team chat (U) are rows: rebinding one moves its key",
		"%s %s" % [keys.key_for(HsBindings.CHAT), keys.key_for(HsBindings.CHAT_TEAM)])
	var h := InputEventKey.new()
	h.physical_keycode = KEY_H
	h.keycode = KEY_H
	h.pressed = true
	_check(settings.menu.handle_event(h) and settings.menu.help.is_open(), "H opens the help screen")
	_check(settings.menu.help.about != "" and settings.menu.help.heading() == "How to play Hide & Seek",
		"which says what the game is before the keys")
	settings.menu.help.close()
	settings.open()
	var help_button := settings.menu.screen.find_child("Action_help", true, false) as Button
	var leave_button := settings.menu.screen.find_child("Action_leave", true, false) as Button
	_check(help_button != null and leave_button != null and leave_button.visible,
		"the Escape menu has Help & commands and Leave")
	settings.close()
	settings.queue_free()
	await get_tree().process_frame
	_finished()


## The family's rule since the first play test: M opens the map list, and solo a choice
## changes it now. The server's half (the owner's flag, the vote) is in `dedicated` and dot-vote.
func _test_the_map_menu() -> void:
	_section("M opens the map list, and solo a choice changes it")
	var game := await _world(func(c: HsConfig) -> void: c.map_ids = PackedStringArray())
	var _a := game.add_player(&"u1", "Ada")
	var _b := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, 4)
	var settings := HsSettings.new()
	add_child(settings)
	var _built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	var keys: DotMenuBindings = settings.bindings
	_check(keys.key_for(DotMenuBindings.MAPS_ACTION) == "M" and keys.defaults_on("M").size() == 1,
		"the map menu is on M, and nothing else in the table defaults to M",
		str(keys.defaults_on("M").map(func(r: Dictionary) -> String: return str(r["label"]))))
	var rows: Array = game.map_rows()
	_check(rows.size() > 1 and rows.filter(func(r: Dictionary) -> bool: return bool(r["current"])).size() == 1,
		"there is more than one to choose, the one playing marked", "%d" % rows.size())
	var _maps := settings.use_maps(game.map_rows, game.change_map_now)
	var m := InputEventKey.new()
	m.physical_keycode = KEY_M
	m.keycode = KEY_M
	m.pressed = true
	_check(settings.menu.handle_event(m) and settings.menu.picker.is_open(), "M opens the picker")
	var wanted: StringName = &""
	var key := KEY_NONE
	for row in range(1, DotMenuPicker.PAGE_SIZE + 1):
		var it: Variant = settings.menu.picker.at_row(row)
		if it is Dictionary and not bool((it as Dictionary)["current"]):
			wanted = StringName(str((it as Dictionary)["id"]))
			key = KEY_0 + row
			break
	var digit := InputEventKey.new()
	digit.physical_keycode = key
	digit.keycode = key
	digit.pressed = true
	var _k := settings.menu.handle_event(digit)
	for _i in 4:
		await get_tree().physics_frame
	_check(wanted != &"" and StringName(str(game.map_doc.get("id", ""))) == wanted, "choosing one changes to it now", "%s, now %s" % [wanted, StringName(str(game.map_doc.get("id", "")))])
	_check(not settings.menu.picker.is_open(), "and the picker is closed")
	settings.queue_free()
	await get_tree().process_frame
	_finished()


## The mouse wheel jumps, rebindably, and a tick (press and release together) is one jump.
func _test_wheel_jump() -> void:
	_section("the wheel jumps")
	var settings := HsSettings.new()
	add_child(settings)
	var _built: DotResult = settings.setup(DotSettingsStoreMemory.new())
	var rows := 0
	var found := 0
	for row in settings.bindings.rows:
		if StringName(row["action"]) == &"dot_fps_jump":
			rows += 1
			if str(row["default"]) == "Wheel up" or str(row["default"]) == "Wheel down":
				found += 1
	_check(rows >= 3, "jump has Space plus two wheel rows", str(rows))
	_check(found == 2, "the rows are Wheel up and Wheel down", str(found))
	var sampler := DotFpsSampler.new(DotFpsTunables.new())
	var _added := DotFpsSampler.register_default_actions(sampler)
	var tick := InputEventMouseButton.new()
	tick.button_index = MOUSE_BUTTON_WHEEL_UP
	tick.pressed = true
	sampler.handle_event(tick)
	var rel := InputEventMouseButton.new()
	rel.button_index = MOUSE_BUTTON_WHEEL_UP
	rel.pressed = false
	sampler.handle_event(rel)
	_check(sampler.sample(0.016).is_pressed(DotFpsCommand.BUTTON_JUMP), "a wheel-up tick is a jump in the next command")
	_check(not sampler.sample(0.016).is_pressed(DotFpsCommand.BUTTON_JUMP), "and only that one")
	settings.queue_free()
	await get_tree().process_frame
	_finished()


func _test_fall_damage() -> void:
	_section("sv_falldamage: a hard landing costs health, a short drop and the cvar off cost none")
	var game := await _seek_round()
	var me = game.players_on(HsGame.SEEKERS)[0]
	_check(game.fall_rules.enabled and me.get_node_or_null("FallDamage") != null, "on in this game, a component per player")
	var floor_at: Vector3 = me.controller.state.position
	var hurt := {}
	for case in [["high", 14.0, true], ["short", 0.6, true], ["off", 14.0, false]]:
		game.fall_rules.enabled = case[2]
		me.health.health = me.health.max_health
		me.place_at(floor_at + Vector3(0.0, case[1], 0.0), 0.0)
		await _step(game, TICK_RATE * 2)
		hurt[case[0]] = me.health.max_health - me.health.health
	_check(hurt["high"] > 0.0, "a drop from 14 m hurts", "lost %.1f" % hurt["high"])
	_check(hurt["short"] == 0.0, "a short drop does not", "lost %.1f" % hurt["short"])
	_check(hurt["off"] == 0.0, "cvar off: a 14 m drop does not hurt", "lost %.1f" % hurt["off"])
	_finished()

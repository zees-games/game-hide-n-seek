extends "hs_client_view.gd"

## One local player, a camera and a HUD over a [HsGame] — offline, or against a server.
##
## [b]One client for both, and the offline half is not a demo mode.[/b] It is the same world
## class with `authoritative` true, stand-ins on both sides, and nothing else different. What
## changes is where the answers come from, and the whole of that difference is [HsNetBridge].
##
## [b]Which half runs is decided by whether there is a link in the registry.[/b] A dot-server
## client publishes a [DotClientLink] under `dot_client_link` before the game scene loads; no
## link means nobody connected us to anything, and the honest answer is a playable round.
## `--offline` forces it.
##
## [b]First person for everybody[/b], because hide-and-seek is about what you can see from
## where you are standing; F5 hangs the camera behind you instead, which is presentation only.
## The simulation is the same either way.


func _ready() -> void:
	# First, before anything can be drawn: the platform puts the loading cover up, held until the
	# player exists and the camera is current, and finds the link.
	platform = DotGameClient.new()
	platform.name = "Platform"
	platform.force_offline = force_offline
	platform.spawned_fn = func() -> bool: return player != null and camera != null and camera.is_inside_tree()
	platform.scoreboard_action = HsBindings.SCOREBOARD
	add_child(platform)
	gate = platform.gate

	var config := HsConfig.new()
	var binder := HsConfig.make_binder(config, config_file)
	var loaded := binder.load_layers()

	if not loaded.ok:
		DotGameConfigBinder.fail_boot(get_tree(), loaded)
		return

	link = platform.link as Node
	_offline = platform.offline

	game = HsGame.new()
	game.name = "World"
	game.config = config
	game.config_binder = binder
	game.authoritative = _offline
	game.register_service = _offline
	game.tick_rate = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 64))
	game.draw_world = true
	# Before the world is added: a server-less world lays its first map out in its own _ready.
	_hold_for_maps()
	add_child(game)
	_build_ragdolls()

	_sampler = DotFpsSampler.new(HsPlayer.tunables_for(config))
	HsPlayer.register_actions(_sampler)

	_build_hud()
	_build_chat()
	_build_audio()
	_build_settings()

	if _offline:
		_start_offline()
	else:
		var netted := _build_netcode()
		DotLog.result(CHANNEL, "the netcode", netted)
		if netted.ok and link != null:
			_start_remote_workbench()


## The load gate is [member DotGameClient.gate]: covered, and the local body and the input still,
## until the level is built, the local player exists and its camera is current.
##
## [b]Without it the first frames showed a half-built world.[/b] Offline the body spawned and
## fell in the tick the first map landed, a connected client drew a HUD with no player and no
## camera until JOIN, and a map change tore the level down in front of a body that kept
## falling. A frozen player is also skipped by [method HsPlayer.simulate], which the world
## calls by name and `process_mode` does not stop.

## A map is built: held from the moment the old one starts to go, released once the new one
## stands. [signal HsGame.world_clearing] and [signal HsGame.world_rebuilt] fire for the first
## map, a map change, and a map a server sent.
func _hold_for_maps() -> void:
	game.world_clearing.connect(func() -> void: gate.hold(&"map", "Loading the map"))
	game.world_rebuilt.connect(_draw_world_then_release)


## The map's converted world pack is drawn under the cover when it has one ([method HsMap.load_world]); the boxes otherwise.
func _draw_world_then_release() -> void:
	var wanted := game.map.id()
	if link != null and link.has_method(&"replicated_cvar"):
		game.map.use_worlds = str(link.call(&"replicated_cvar", "hs_use_worlds", "1")).strip_edges() != "0"
	await game.map.load_world()
	if game.map.id() == wanted:
		gate.release(&"map")


func _start_offline() -> void:
	for i in range(offline_bots):
		var bot := game.add_player(StringName("u%d" % (HsNetBridge.FIRST_BOT_SESSION + i)), _bot_name(i))
		bot.is_bot = true

	_adopt(game.add_player(&"local", "You", 0, true))
	_hear_the_world()

	game.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		if player != null and id == player.player_id and chat != null:
			chat.say_locally("Achievement: %s (+%d)" % [title, points], Color(0.98, 0.84, 0.40))
	)
	game.start()
	DotLog.result(CHANNEL, "chat, offline", chat.attach(null))


## A solo stand-in's name: the server's list, through dot-bot's pick, so solo and a server
## name them alike.
static func _bot_name(index: int) -> String:
	var taken: Array = []
	for i in range(index):
		taken.append(DotBotNames.pick(taken, i, HsGame.BOT_NAMES))
	return DotBotNames.pick(taken, index, HsGame.BOT_NAMES)


## Online: no local trust and no panel until the server names this player an admin (sv_workbench_remote). The sets are the game's own; the rows are the server's, through the bridge's profile link.
func _start_remote_workbench() -> void:
	if workbench_remote == null:
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.remote_client = workbench_remote
	wb.remote_fn = func() -> bool: return true
	if game.config_binder != null:
		for set: DotProfileSet in game.config_binder.profile_sets():
			wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	add_child(wb)
	var started := wb.start(game.ensure_runtime())
	DotLog.result(CHANNEL, "the remote workbench", started)
	if not started.ok:
		wb.queue_free()
		return
	workbench = wb
	platform.add_workbench(wb)


func _build_netcode() -> DotResult:
	net = DotNetManager.new()
	net.name = "Net"
	net.is_server = false
	net.local_peer_id = multiplayer.get_unique_id() if multiplayer != null else 2
	net.auto_tick = false
	net.config_file = ""

	var net_config := DotNetConfig.new()
	net_config.tick_rate = game.tick_rate
	net_config.snapshot_rate = HsGame.NET_SNAPSHOT_RATE
	net_config.enable_prediction = true
	net_config.enable_lag_compensation = false
	net_config.max_entities_per_snapshot = 64
	net_config.world_extent = HsGame.NET_WORLD_EXTENT
	net.config = net_config
	add_child(net)

	var started := net.setup()

	if not started.ok:
		return started

	bridge = HsNetBridge.new()
	bridge.name = "Bridge"
	add_child(bridge)

	var attached := bridge.attach(game, net)

	if not attached.ok:
		return attached

	bridge.open_link(link)
	# The server's mp_forceview and mp_solidplayers: this end places its own camera and
	# predicts its own player.
	var _view := game.view_rules.follow_cvars(link)
	var _solid := game.body_rules.follow_cvars(link)
	var _ambient := game.ambient_rules.follow_cvars(link)
	# The server's sv_ragdoll* set: this end draws the bodies.
	var _dead := game.ragdoll_rules.follow_cvars(link)
	# And sv_toys*: a client hides the toys a server took away.
	var _toys := game.toy_rules.follow_cvars(link)
	# And mp_forcecamera / mp_freeroam*: this end flies the spectator's free camera.
	var _spectate := game.spectate_rules.follow_cvars(link)
	# Before the seal and in the server's order (after the bridge), or the actions stay local.
	DotLog.result(CHANNEL, "avatar action message", DotGameAvatarActionMessage.register(net))
	# The server's order again (after the avatar frame): the remote workbench's frame.
	workbench_remote = DotGameWorkbenchRemoteClient.attach(net)
	net.messages.seal()

	bridge.hello_received.connect(_on_hello)
	bridge.roster_changed.connect(_on_roster_changed)
	bridge.phase_received.connect(_on_phase)
	bridge.round_changed.connect(_on_round)
	bridge.death_received.connect(_on_death)
	bridge.map_received.connect(_on_map)
	bridge.taunt_received.connect(_on_taunt)
	bridge.caught_received.connect(_on_caught)
	bridge.notice_received.connect(func(text: String) -> void:
		if chat != null:
			chat.notice(text)
		if audio != null:
			var _denied := audio.deny())
	if link != null and link.has_method("ping_ms"):
		bridge.rtt_source = func() -> float:
			return float(maxi(0, int(link.call("ping_ms"))))

	DotLog.result(CHANNEL, "chat and voice", chat.attach(bridge))

	if link != null and link.has_method("is_playing") and bool(link.call("is_playing")):
		_say_ready()
	elif link != null and link.has_signal("spawned"):
		link.connect("spawned", _say_ready, CONNECT_ONE_SHOT)

	return net.start()


func _say_ready() -> void:
	if workbench_remote != null:
		workbench_remote.ask()
	if bridge != null:
		bridge.ask_ready()


func _on_hello(session_id: int) -> void:
	_watch_id = session_id
	_adopt(game.players.get(HsNetBridge.player_key(session_id)))


func _on_roster_changed(session_id: int) -> void:
	if session_id == _watch_id and player == null:
		_adopt(game.players.get(HsNetBridge.player_key(session_id)))


func _adopt(candidate: HsPlayer) -> void:
	if candidate == null or player == candidate:
		return

	player = candidate
	gate.freeze(player)
	_build_camera()

	if settings != null:
		settings.bind_camera(camera)
		if player.sampler != null:
			settings.bind_look(player.sampler.tunables)

	if hud != null:
		hud.bind(game, player)


## The map's own gravity and auto-hop, on this end's copy of the config, because it is what predicts the body.
func _wire_map_config() -> void:
	platform.map_config_keys = HsMapConfig.CLIENT_KEYS
	platform.map_config_game = HsMapConfig.GAME_ID
	platform.map_config_get_fn = func(key: String) -> Variant:
		match key:
			"hs_gravity": return str(game.config.gravity)
			"hs_autobhop": return "1" if game.config.auto_bunny_hop else "0"
		return null
	platform.map_config_set_fn = func(key: String, value: Variant) -> bool:
		match key:
			"hs_gravity": game.config.gravity = float(value)
			"hs_autobhop": game.config.auto_bunny_hop = float(value) >= 0.5
			_: return false
		return true
	game.world_rebuilt.connect(func() -> void: platform.map_changed(String(game.map.id())))


## Offline: the world is the authority, so its own signals are what happened. A connected
## client hears the same from the bridge and calls the same functions with the same arguments,
## so the two can only differ in where a fact came from.
func _hear_the_world() -> void:
	_wire_map_config()
	game.world_rebuilt.connect(func() -> void: _on_map(game.map.id()))
	game.phase_changed.connect(_on_phase)
	game.round_began.connect(func(n: int, _map: StringName) -> void: _on_round(n, true, 0))
	game.round_over.connect(func(n: int, winner: int, why: String) -> void: _on_round(n, false, winner, why))
	game.player_died.connect(func(id: StringName, by: StringName, why: StringName) -> void:
		_on_death(_session(id), _session(by) if by != &"" else 0, why))
	game.caught.connect(func(id: StringName, by: StringName, how: StringName) -> void:
		_on_caught(_session(id), _session(by) if by != &"" else 0, how))
	game.refused.connect(func(id: StringName, why: String) -> void:
		if id == &"local" and chat != null:
			chat.notice(why)
			if audio != null:
				var _denied := audio.deny())


func _on_phase(phase: int) -> void:
	if hud == null or player == null:
		return

	var seeker := is_seeker()

	match phase:
		HsGame.Phase.HIDE:
			if audio != null:
				var _heard := audio.on_hide()
			if seeker:
				hud.shout("YOU ARE IT — count while they hide", 3.5)
			else:
				hud.shout("HIDE — the seekers are counting", 3.5)
		HsGame.Phase.SEEK:
			if audio != null:
				var _heard := audio.on_seek()
			if game.effects != null:
				var _flashed := game.effects.flash(&"go")
			hud.shout("READY OR NOT, HERE I COME" if seeker else "THE SEEKERS ARE COMING", 2.4)


func is_seeker() -> bool:
	return player != null and game != null and game.team_of(player.player_id) == HsGame.SEEKERS


func _on_map(map_id: StringName) -> void:
	if ragdolls != null:
		# A body on the old map would hang in the new one's air.
		ragdolls.clear()

	# The new map's toys are heard: a bounce, a knock, a switch, a honk.
	if game.map != null and game.map.toys != null and not game.map.toys.sound.is_connected(_toy_sound):
		var _c := game.map.toys.sound.connect(_toy_sound)

	if audio != null:
		audio.on_map_doc(map_id, game.map_doc)

	var name_of := str(game.map_doc.get("name", ""))
	hud.shout(name_of, 3.0)

	if chat != null and name_of != "":
		var author := str(game.map_doc.get("author", ""))
		var blurb := str(game.map_doc.get("blurb", ""))
		chat.say_locally("%s%s%s" % [name_of, " by %s" % author if author != "" else "",
			" — %s" % blurb if blurb != "" else ""], Color(0.80, 0.90, 1.0))


func _on_round(number: int, began: bool, winner: int, why: String = "") -> void:
	if began:
		hud.shout("ROUND %d" % number, 2.0)
		return

	if audio != null and player != null:
		var _heard := audio.on_round_end(winner != 0 and game.team_of(player.player_id) == winner)

	var who := game.side_name(winner).to_upper() + " WIN" if winner != 0 else "DRAW"
	hud.shout("%s — %s" % [who, why] if why != "" else who, 4.0)

	if chat != null and why != "":
		chat.say_locally(why, Color(0.98, 0.86, 0.40))


func _on_death(session_id: int, _by: int, why: StringName) -> void:
	var who := _player_of(session_id)
	_fall(who)

	if chat == null or who == null:
		return

	if why == HsGame.DIED_FELL:
		chat.say_locally("%s fell" % who.display_name, Color(0.80, 0.82, 0.86))
	else:
		chat.say_locally("%s is out" % who.display_name, Color(0.80, 0.82, 0.86))


func _physics_process(delta: float) -> void:
	# The use key, held: the game makes the press from the edge, on the server or here.
	var use := _pointer_ours() and not _covered() and InputMap.has_action(HsBindings.USE) and Input.is_action_pressed(HsBindings.USE)

	if _offline:
		if player != null:
			player.wants_use = use
		return

	if net == null or not net.is_running() or bridge == null:
		return

	var ticks := net.clock.advance(delta)

	# The clock has advanced; only the sampling waits, so the mouse does not pile up a turn
	# behind the cover and the server sees an idle body until it lifts.
	if _covered():
		return

	var move := _sampler.sample(delta) if _sampler != null else DotFpsCommand.new()
	move.set_button(HsPlayer.USE_BUTTON, use)

	if is_roaming():
		# The roaming spectator flies a camera and does not walk the dead body about.
		move.move = Vector2.ZERO
		move.buttons = 0

	for i in range(ticks):
		if not net.clock.is_synced():
			continue

		bridge.client_tick(net.clock.input_tick() - (ticks - 1 - i), move)


func _process(delta: float) -> void:
	var _shown := present_frame(net, game, player, not third_person, delta, -1.0, _watched_through_eyes())
	_present_hide()
	if audio != null and audio.ambient != null and camera != null and camera.is_inside_tree() and game.physics != null:
		audio.ambient.follow_roof(delta, camera.global_position, camera.get_world_3d().direct_space_state, game.physics.mask_of([&"world"]))

	if camera == null or player == null:
		return

	if _drive_spectator_camera():
		_present_effects(delta)
		return

	var state := player.controller.state
	var pitch := deg_to_rad(state.pitch)
	var yaw := deg_to_rad(state.yaw)
	var rig: Node3D = _arm if _arm != null and is_instance_valid(_arm) else camera
	rig.rotation = Vector3(pitch, yaw, 0.0)

	var drawn := player.controller.render_state()
	var eye_height := _rig_height

	# First person follows a crouch down, as the server's eye does for the sight rule.
	if not third_person:
		eye_height = player.eye_position().y - state.position.y

	rig.global_position = drawn.position + Vector3(0.0, eye_height, 0.0)

	_present_effects(delta)


## The last seconds of the hide, beeped.
func _present_hide() -> void:
	if game == null or game.phase != HsGame.Phase.HIDE:
		_beeped = -1
		return

	var second := int(ceilf(game.seconds_left()))

	if second != _beeped and second <= 5 and second > 0:
		_beeped = second

		if audio != null:
			var _heard := audio.on_countdown()


func _present_effects(delta: float) -> void:
	if audio != null:
		audio.listen_from(camera.global_position)
		audio.keep_walkers(game.players.values())

	if game.effects != null:
		game.effects.viewer_position = camera.global_position
		game.effects.advance(delta)


func _unhandled_input(event: InputEvent) -> void:
	if _covered():
		return

	# Tab, M and a click taking the pointer back are the platform's (DotGameClient).
	if event.is_action_pressed("ui_cancel"):
		if settings != null:
			settings.open()
		return

	if event is InputEventKey and (event as InputEventKey).pressed and not event.is_echo():
		if _key_pressed(event):
			get_viewport().set_input_as_handled()
			return

	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton

		if is_spectating():
			if button.pressed and button.button_index == MOUSE_BUTTON_LEFT:
				spectate_step(1)
			elif button.pressed and button.button_index == MOUSE_BUTTON_RIGHT:
				spectate_step(-1)
			return

	if player == null:
		return

	# EVERY event, not only motion: the sampler latches presses, which is how a wheel tick (press
	# and release in one pair) reaches a command as one jump. `suspended` gates it for menus.
	if is_roaming() and event is InputEventMouseMotion:
		# The free camera turns on the mouse, and the dead body's view stays put.
		if _pointer_ours():
			_roam_look += (event as InputEventMouseMotion).relative
		return

	if _pointer_ours():
		if _offline and player.sampler != null:
			player.sampler.handle_event(event)
		elif _sampler != null:
			_sampler.handle_event(event)


## The game's own keys, from the bindings. True when one was used.
func _key_pressed(event: InputEvent) -> bool:
	if event.is_action_pressed(HsBindings.ROAM) and is_spectating():
		toggle_roam()
		return true

	if event.is_action_pressed(HsBindings.VIEW):
		if is_spectating():
			spectate_step(0)
		else:
			toggle_view()
		return true

	if player == null or not player.is_alive() or is_spectating():
		return false

	if is_seeker():
		return false

	if event.is_action_pressed(HsBindings.TAUNT):
		ask_taunt()
	elif event.is_action_pressed(HsBindings.TAUNT_MENU):
		open_taunts()
	else:
		return false

	return true


func describe() -> Dictionary:
	var out := {
		"offline": _offline,
		"session": _watch_id,
		"player": player != null,
		"view": "third" if third_person else "first",
	}

	if bridge != null:
		out["bridge"] = bridge.describe()

	if chat != null:
		out["chat"] = chat.describe()

	if game != null:
		out["world"] = game.describe()

	return out

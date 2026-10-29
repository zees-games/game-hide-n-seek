extends "hs_client_base.gd"

## The client's parts: dead bodies, the camera, the HUD, chat, audio, settings and the taunt keys.

const CHANNEL := "hs.client"

## Where the dead lie: dot-player-char's ragdolls under the game's (the server's) rules.
var ragdolls: DotPlayerRagdolls = null


func _build_ragdolls() -> void:
	ragdolls = DotPlayerRagdolls.new()
	ragdolls.name = "Ragdolls"
	ragdolls.rules = game.ragdoll_rules
	ragdolls.sound_fn = _ragdoll_sound
	add_child(ragdolls)


func _toy_sound(id: StringName, at: Vector3, strength: float) -> void:
	if audio != null:
		var _played := audio.on_toy(id, at, strength)


func _ragdoll_sound(id: StringName, at: Vector3, volume: float) -> void:
	if audio != null:
		var _played := audio.on_body(id, at, volume)


## [param who]'s body falls the way the server picked ([member HsPlayer.death]), copied from the
## figure this client draws; the figure itself stays hidden ([method HsPlayer.present_body]).
## No figure drawn here (a first-person player) means no body. Called from [method _on_death].
func _fall(who: HsPlayer) -> void:
	if who == null or ragdolls == null or who.figure == null or not who.figure.is_inside_tree():
		return
	if game.physics != null:
		# The rooms and the props: a body lands on them and on nothing else (not on a person).
		game.ragdoll_rules.collision_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")
	var velocity := who.controller.state.velocity if who.controller != null else Vector3.ZERO
	var _body := ragdolls.spawn(who.figure, who.death if who.death != null else DotPlayerDeath.new(), velocity)


## A hider was caught. Everybody hears it; the one caught is told what they are now.
func _on_caught(session_id: int, by: int, how: StringName) -> void:
	var who := _player_of(session_id)
	var seeker := _player_of(by) if by != 0 else null
	var mine := session_id == _watch_id

	if audio != null and who != null:
		var _heard := audio.on_caught(who.global_position, mine)

	if mine:
		if game.effects != null:
			var _flashed := game.effects.flash(&"caught")
		if hud != null:
			hud.shout("CAUGHT — now you seek" if game.config.caught_become_seekers else "CAUGHT", 3.0)
	elif by == _watch_id and hud != null and who != null:
		hud.shout("You caught %s" % who.display_name, 1.8)

	if chat == null or who == null:
		return

	# "You were", not "You was": the local player's name offline is "You".
	var subject := "You were" if mine else "%s was" % who.display_name
	var by_name := "you" if by == _watch_id else (seeker.display_name if seeker != null else "")
	var line := "%s caught" % subject

	match how:
		HsGame.CAUGHT_TAG:
			line = "%s tagged by %s" % [subject, by_name] if by_name != "" else line
		HsGame.CAUGHT_SIGHT:
			line = "%s spotted by %s" % [subject, by_name] if by_name != "" else line
		HsGame.CAUGHT_FELL:
			line = "%s caught by a fall" % subject

	chat.say_locally(line, game.side_colour(HsGame.SEEKERS).lightened(0.3))


func _on_taunt(session_id: int, taunt_id: StringName, forced: bool) -> void:
	var who := _player_of(session_id)

	if who == null or game.taunts == null:
		return

	var entry := game.taunts.entry(taunt_id)

	if audio != null and not entry.is_empty():
		var _voice := audio.taunt(who, str(entry["sound"]), game.config.taunt_range)

	if session_id == _watch_id and hud != null:
		hud.shout("%s%s" % ["You stood still: " if forced else "", str(entry.get("title", ""))], 1.5)


func _build_camera() -> void:
	if camera != null or player == null:
		return

	camera = Camera3D.new()
	camera.name = "Eye"
	camera.fov = 90.0
	camera.current = true

	# Other hiders, seekers and stand-ins, handed over (their hulls are off while players pass
	# through each other): hidden at the lens, faded in third person between the camera and
	# you. It rides the camera wherever the camera goes.
	_fade = DotCameraFade.new()
	_fade.name = "Fade"
	_fade.bodies_fn = _other_players
	camera.add_child(_fade)

	if not game.view_rules.changed.is_connected(_on_view_rules_changed):
		game.view_rules.changed.connect(_on_view_rules_changed)
	third_person = game.view_rules.resolve(third_person)
	_place_camera()


## Hangs the camera where the view wants it: at the eyes, or on an arm behind a prop as far
## back as the prop is big.
func _place_camera() -> void:
	if camera == null or player == null:
		return

	if camera.get_parent() != null:
		camera.get_parent().remove_child(camera)

	if _arm != null and is_instance_valid(_arm):
		_arm.queue_free()
		_arm = null

	var eye := player.eye_position() - player.controller.state.position

	if not third_person:
		player.add_child(camera)
		_rig_height = eye.y
		camera.position = Vector3(0.0, eye.y, 0.0)
		camera.rotation = Vector3.ZERO
		if _fade != null:
			_fade.focus = null
		return

	# dot-core's boom, swept from the eye with the height above it added in the world's up:
	# a pivot above the head can be inside a tree's canopy (the play test, 0:33), and the
	# spring arm it replaced cast a ray from there and snapped to whatever it hit.
	_arm = DotCameraBoom.new()
	_arm.name = "Chase"
	_arm.spring_length = CHASE_BACK
	# Against the building and the furniture, never the player's own body.
	_arm.collision_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop") \
		if game.physics != null else 1
	_arm.add_excluded_object(player.get_rid())
	_arm.margin = 0.15
	_arm.lift = CHASE_UP
	_rig_height = eye.y
	player.add_child(_arm)
	_arm.add_child(camera)
	camera.position = Vector3.ZERO
	camera.rotation = Vector3.ZERO
	if _fade != null:
		_fade.focus = _arm


## Swaps the view, where the server's `mp_forceview` allows.
func toggle_view() -> void:
	var wanted := game.view_rules.toggled(third_person)
	if wanted == third_person:
		if hud != null and game.view_rules.refusal() != "":
			hud.shout(game.view_rules.refusal(), 1.6)
		return
	third_person = wanted
	_place_camera()

	if audio != null:
		var _heard := audio.click()


## Everybody but this player, for the camera fade.
func _other_players() -> Array:
	var out: Array = []
	if game == null:
		return out
	for id in game.players:
		var other: Node3D = game.players[id]
		if other != player and is_instance_valid(other):
			out.append(other)
	return out


## The server changed `mp_forceview`: the view it allows now.
func _on_view_rules_changed() -> void:
	var allowed := game.view_rules.resolve(third_person)
	if allowed != third_person:
		third_person = allowed
		if not is_spectating():
			_place_camera()


func _build_hud() -> void:
	hud = HsHud.new()
	hud.name = "Hud"
	hud.key_fn = _key
	add_child(hud)


## The key an action is on, as the player has it bound.
func _key(action: StringName) -> String:
	if settings != null and settings.bindings != null:
		var text := settings.bindings.key_for(action)
		if text != "":
			return text

	var row := HsBindings.make().row_for_action(action)
	return str(row.get("default", action))


## dot-game's chat box and microphone, with this game's channels and voice format.
func _build_chat() -> void:
	chat = DotGameChatClient.new()
	chat.name = "Chat"
	chat.channels = [
		{"id": HsServices.CH_ALL, "label": "All", "colour": Color(0.93, 0.94, 0.96)},
		{"id": HsServices.CH_TEAM, "label": "Team", "colour": Color(0.55, 0.82, 0.95)},
		{"id": HsServices.CH_NEAR, "label": "Near", "colour": Color(0.82, 0.86, 0.72)},
	]
	chat.max_length = HsServices.chat_rules().max_length
	chat.voice_config = HsServices.voice_format()
	add_child(chat)


func _build_audio() -> void:
	audio = HsAudio.new()
	audio.name = "Sound"
	add_child(audio)

	var ready_now := audio.setup()

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "no sound", {"why": ready_now.error.message})
		remove_child(audio)
		audio.queue_free()
		audio = null


func _build_settings() -> void:
	settings = HsSettings.new()
	settings.name = "Settings"
	add_child(settings)
	platform.settings = settings
	# Not handed over: HsHud is a CanvasLayer and the platform's hud is a Control, so it follows
	# the menu's theme itself, below.
	platform.chat = chat
	platform.look_position_fn = _look_position
	platform.board_snapshot_fn = board_snapshot
	# M: the map list. Solo it changes the map at once; connected the server decides by
	# `sv_map_menu_flag` and anybody without it votes (wired in [HsModule]). Its choice goes
	# to the map menu, never to the taunt list's `picked` handler.
	platform.maps_rows_fn = func() -> Array: return game.map_rows() if game != null else []
	platform.maps_change_fn = func(id: StringName) -> DotResult: return game.change_map_now(id)
	DotLog.result(CHANNEL, "the platform", platform.setup())
	# The starter set: the equipped list needs a credential the client does not hold (the server reads it).
	DotLog.result(CHANNEL, "avatar actions", platform.add_avatar_actions(net, _avatar_figure))
	_add_noblock_and_workbench()
	# Walking is off while the cover is up, a menu is open or a line is typed: the sampler polls
	# the keyboard.
	platform.input_blocked_changed.connect(_suspend_input)
	_suspend_input(platform.is_input_blocked())

	settings = platform.settings as HsSettings
	console = platform.console as DotConsoleController

	if settings == null:
		return

	if _sampler != null:
		settings.bind_look(_sampler.tunables)

	if audio != null:
		settings.bind_audio(audio.manager)
		# The server's hs_ambient* drive the quiet layer; the player's sliders multiply on top.
		if audio.ambient != null:
			audio.ambient.follow_settings(settings.settings, game.ambient_rules)

	if settings.menu != null:
		settings.menu.picker_action = HsBindings.TAUNT_MENU
		settings.menu.picked.connect(_on_taunt_picked)
		# The HUD in the menu's theme and at the player's HUD size, live.
		if hud != null:
			hud.follow_menu(settings.menu)
		_bind_bot_console()
		board = platform.board as DotMenuScoreboard
		_dress_board()


func _suspend_input(suspended: bool) -> void:
	if _sampler != null:
		_sampler.suspended = suspended

	if player != null and player.sampler != null:
		player.sampler.suspended = suspended


## Whether the pointer is the game's: captured. A menu frees it and the platform takes it back.
func _pointer_ours() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func ask_taunt(taunt_id: StringName = &"") -> void:
	if bridge != null:
		bridge.ask_taunt(taunt_id)
	elif player != null:
		var _said := game.taunt(player.player_id, taunt_id)


func open_taunts() -> void:
	if settings == null or settings.menu == null or game.taunts == null:
		return

	var items: Array = []

	for id in game.taunt_ids():
		var entry := game.taunts.entry(id)
		items.append({"id": id, "name": str(entry.get("title", id)), "tags": ["%.1f s" % float(entry.get("seconds", 0.0))]})

	settings.menu.open_picker(items, "Taunt")


func _on_taunt_picked(id: StringName) -> void:
	if game.taunts != null and game.taunts.has(id):
		ask_taunt(id)


## True while the load gate covers the screen: no input, no prediction sampling.
func _covered() -> bool:
	return gate != null and not gate.is_open()


## The local world's ids are `local` for this keyboard and `u<session>` for everybody else.
func _session(id: StringName) -> int:
	return _watch_id if id == &"local" else HsNetBridge.session_of(id)


## The figure an avatar action plays on (the drawn person, a DotHumanoidFigure): that peer's player, or the local one offline.
func _avatar_figure(peer_id: int) -> Object:
	var who: HsPlayer = null
	if bridge != null and peer_id != 0:
		who = _player_of(bridge.player_for_peer(peer_id))
	if who == null and player != null and (net == null or peer_id == net.local_peer_id):
		who = player
	return who.figure.body_node() if who != null and who.figure != null else null


func _player_of(session_id: int) -> HsPlayer:
	if session_id == _watch_id and player != null:
		return player
	return game.players.get(HsNetBridge.player_key(session_id))


## dot-team's block rules followed from the server, or, solo, the F9 tuning panel over this process's own config.
func _add_noblock_and_workbench() -> void:
	if link != null:
		DotLog.result(CHANNEL, "noblock", platform.add_noblock(game, Callable(game, "team_of_side")))
		return
	var wb := DotGameWorkbench.new()
	wb.name = "Workbench"
	wb.listen_host_fn = func() -> bool: return true
	workbench = wb
	if game.config_binder != null:
		for set: DotProfileSet in game.config_binder.profile_sets():
			wb.add_set(set, "Game settings: %s" % set.rel_path.trim_prefix("config_"))
	add_child(wb)
	var started := wb.start()
	DotLog.result(CHANNEL, "the workbench", started)
	if started.ok and game.config_binder != null and wb.api != null:
		game.config_binder.attach(wb.api.runtime as DotProfileRuntime)
	platform.add_workbench(wb)


## Solo, `bot_difficulty` and every `bot_*` setting at the console, the names a server has, and
## `-- --bot_difficulty hard` at launch. Connected, the server's console holds them and a local
## copy would shadow it.
func _bind_bot_console() -> void:
	if not _offline or console == null or game == null:
		return
	var sources: Array = console.sources()
	if sources.is_empty() or not (sources[0] is DotConsoleLocal):
		return
	var _bound := DotBotSettings.of(game).bind_console(sources[0])
	var args := OS.get_cmdline_user_args()
	var index := args.find("--bot_difficulty")
	if index >= 0 and index + 1 < args.size():
		DotLog.result(CHANNEL, "bot difficulty from the command line", DotBotSettings.of(game).set_difficulty(args[index + 1]))


func is_spectating() -> bool:
	return player != null and game != null and game.spectate != null \
		and game.spectate.is_spectating(player.player_id)


## Where a roster row's player stands, for dot-game's look-to-gag key (G, K).
func _look_position(row: Dictionary) -> Variant:
	if game == null:
		return null
	for who: HsPlayer in game.players.values():
		if who != player and who.display_name == row["name"]:
			return who.global_position + Vector3.UP * 1.5
	return null

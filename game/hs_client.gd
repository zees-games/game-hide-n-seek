extends Node

const HsAudio := preload("hs_audio.gd")
const HsBindings := preload("hs_bindings.gd")
const HsFigure := preload("hs_figure.gd")
const HsSettings := preload("hs_settings.gd")
const HsServices := preload("hs_services.gd")
const HsNetBridge := preload("net/hs_net_bridge.gd")

const HsConfig := preload("hs_config.gd")
const HsGame := preload("hs_game.gd")
const HsHud := preload("hs_hud.gd")
const HsPaths := preload("hs_paths.gd")
const HsPlayer := preload("hs_player.gd")

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

const CHANNEL := "hs.client"

const LINK_SERVICE := &"dot_client_link"

## How far behind a player the camera hangs in third person.
const CHASE_BACK := 3.0
const CHASE_UP := 0.8

@export var config_file: String = "user://cfg/hideseek.json"
@export var force_offline: bool = false

## How many stand-ins an offline round gets.
@export_range(0, 12, 1) var offline_bots: int = 6

var game: HsGame = null
var player: HsPlayer = null
var camera: Camera3D = null
var hud: HsHud = null
var board: DotMenuScoreboard = null
var chat: DotGameChatClient = null
var audio: HsAudio = null
var settings: HsSettings = null

## The player's console. See [method DotConsoleKit.build].
var console: DotConsoleController = null

var net: DotNetManager = null
var bridge: HsNetBridge = null
var link: Node = null

## Whether the camera hangs behind the player. F5 swaps it.
var third_person: bool = false

var _offline: bool = true
var _sampler: DotFpsSampler = null
var _watch_id: int = -1
var _captured: bool = false
var _arm: DotCameraBoom = null
var _fade: DotCameraFade = null
var _rig_height: float = 0.0
var _started_msec: int = Time.get_ticks_msec()

## The last whole second of the hide a beep was played for.
var _beeped: int = -1



func _ready() -> void:
	var config := HsConfig.new()
	var loaded := config.load_layered(config_file)

	if not loaded.ok:
		DotLog.warn(CHANNEL, "falling back to defaults", {"why": loaded.error.message})

	link = DotRegistry.get_node_service(LINK_SERVICE)
	_offline = force_offline or link == null or OS.get_cmdline_user_args().has("--offline")

	game = HsGame.new()
	game.name = "World"
	game.config = config
	game.authoritative = _offline
	game.register_service = _offline
	game.tick_rate = int(ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 64))
	game.draw_world = true
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
		DotLog.result(CHANNEL, "the netcode", _build_netcode())

	if not DotPlatform.is_web():
		_capture()


# --- Offline ---------------------------------------------------------------

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


# --- Connected -------------------------------------------------------------

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
	# The server's sv_ragdoll* set: this end draws the bodies.
	var _dead := game.ragdoll_rules.follow_cvars(link)
	# And sv_toys*: a client hides the toys a server took away.
	var _toys := game.toy_rules.follow_cvars(link)
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
	_build_camera()

	if settings != null:
		settings.bind_camera(camera)
		if player.sampler != null:
			settings.bind_look(player.sampler.tunables)

	if hud != null:
		hud.bind(game, player)


# --- What the world, or the server, says --------------------------------------

## Offline: the world is the authority, so its own signals are what happened. A connected
## client hears the same from the bridge and calls the same functions with the same arguments,
## so the two can only differ in where a fact came from.
func _hear_the_world() -> void:
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


## The local world's ids are `local` for this keyboard and `u<session>` for everybody else.
func _session(id: StringName) -> int:
	return _watch_id if id == &"local" else HsNetBridge.session_of(id)


func _player_of(session_id: int) -> HsPlayer:
	if session_id == _watch_id and player != null:
		return player
	return game.players.get(HsNetBridge.player_key(session_id))


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


# --- Dead bodies -----------------------------------------------------------

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
## figure this client draws; the figure itself stays hidden while they are dead
## ([method HsPlayer.present_body]). Nobody's figure, nothing: a first-person player who never
## had one drawn here. Called from [method _on_death], solo and connected alike.
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


# --- The camera ------------------------------------------------------------

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


# --- The Tab board ---------------------------------------------------------

## M: the map list (dot-menu's map menu). Solo a choice changes the map here at once;
## connected the server decides, by the owner's `sv_map_menu_flag`, and anybody without it
## gets a vote instead (dot-vote's map menu, wired in [HsModule]). Its choice goes to the map
## menu, never to the taunt list's `picked` handler. By name, so a client shell older than
## the map menu still runs the game without it.
func _wire_maps() -> void:
	if not settings.has_method(&"use_maps"):
		return
	var _maps: Variant = settings.call(&"use_maps",
		func() -> Array: return game.map_rows() if game != null else [],
		func(id: StringName) -> DotResult: return game.change_map_now(id))


func _wire_board() -> void:
	if settings == null or settings.menu == null:
		return

	board = settings.menu.scoreboard
	board.title_text = "Hide & Seek"
	board.columns = [
		{"key": &"avatar", "kind": DotMenuScoreboard.KIND_AVATAR, "width": 0.0},
		{"key": &"name", "title": "Player", "width": 3.0},
		{"key": &"points", "title": "Points", "kind": DotMenuScoreboard.KIND_NUMBER},
		{"key": &"seconds", "title": "Time", "kind": DotMenuScoreboard.KIND_DURATION},
		{"key": &"ping", "title": "Ping", "kind": DotMenuScoreboard.KIND_PING},
	]
	board.sort_by = &"points"
	board.decorate = _decorate_row
	board.prepare = _prepare_board

	if not _offline and link != null:
		board.feed_from(link)
	else:
		board.source = board_snapshot


func _show_board(on: bool) -> void:
	if board == null:
		return
	if on:
		board.open()
	else:
		board.close()


func _decorate_row(row: Dictionary) -> void:
	if game == null:
		return
	var id := HsNetBridge.player_key(int(row.get("id", 0)))
	if not game.players.has(id):
		id = StringName(str(row.get("id", "")))
	var who: HsPlayer = game.players.get(id)
	if who == null:
		return
	row["avatar"] = _face(who)
	row["points"] = who.points
	row["team"] = game.team_of(id)
	if int(row.get("ping", -1)) < 0 and who.ping_ms >= 0:
		row["ping"] = who.ping_ms
	if who == player:
		row["you"] = true


## The map in the header, and the two sides as the teams, hiders first.
func _prepare_board(snap: Dictionary) -> void:
	if game == null:
		return
	snap["header"] = {"Map": str(game.map_doc.get("name", "")), "Round": str(game.round_number)}
	snap["teams"] = [
		{"id": HsGame.HIDERS, "name": game.side_name(HsGame.HIDERS), "color": game.side_colour(HsGame.HIDERS)},
		{"id": HsGame.SEEKERS, "name": game.side_name(HsGame.SEEKERS), "color": game.side_colour(HsGame.SEEKERS)},
	]


## The board offline: every player in the local world. Public so a suite can read it.
func board_snapshot() -> Dictionary:
	var rows: Array = []
	if game != null:
		for id in game.players:
			var who: HsPlayer = game.players[id]
			rows.append({"id": String(id), "name": who.display_name, "seconds": _seconds_here(), "ping": -1, "bot": who.is_bot})
	return {"server": {"name": "Hide & Seek", "game": "offline"}, "players": rows}


func _seconds_here() -> int:
	return int((Time.get_ticks_msec() - _started_msec) / 1000)


var _portraits: Dictionary = {}


func _face(who: HsPlayer) -> Texture2D:
	return _portrait(str(who.call("_atlas")))


## A player's face for the board: their figure's head, rendered once per skin. See
## mg-deathrun, where this came from.
func _portrait(atlas: String) -> Texture2D:
	if _portraits.has(atlas):
		return _portraits[atlas]

	var view := SubViewport.new()
	view.name = "Portrait%d" % _portraits.size()
	view.size = Vector2i(64, 64)
	view.own_world_3d = true
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(view)

	var figure := HsFigure.new()
	view.add_child(figure)
	figure.build(1.8, atlas, Color.WHITE)
	figure.global_position = Vector3.ZERO

	var eye := Camera3D.new()
	eye.fov = 30.0
	view.add_child(eye)
	# The people's heads are big: the face is about 1.35 m up a 1.8 m person.
	eye.look_at_from_position(Vector3(0.0, 1.45, -2.0), Vector3(0.0, 1.35, 0.0), Vector3.UP)
	eye.current = true

	var texture := view.get_texture()
	_portraits[atlas] = texture
	return texture


# --- Chat, sound, settings ---------------------------------------------------

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

	# Typing is not moving: the sampler polls the keyboard.
	chat.typing_changed.connect(func(typing: bool) -> void:
		_suspend_input(typing or (settings != null and settings.is_open())))


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
	add_child(settings)

	var built: DotResult = settings.setup()

	if not built.ok:
		DotLog.warn(CHANNEL, "no settings; everything is at its default", {"why": built.error.message})
		remove_child(settings)
		settings.free()
		settings = null
		return

	if _sampler != null:
		settings.bind_look(_sampler.tunables)

	if audio != null:
		settings.bind_audio(audio.manager)

	if settings.menu != null:
		settings.menu.picker_action = HsBindings.TAUNT_MENU
		settings.menu.scoreboard_action = HsBindings.SCOREBOARD
		settings.menu.picked.connect(_on_taunt_picked)
		settings.menu_state_changed.connect(func(any_open: bool) -> void:
			_suspend_input(any_open or (chat != null and chat.is_typing()))
			if any_open:
				_release()
			elif not DotPlatform.is_web():
				_capture())
		settings.menu.busy = func() -> bool: return chat != null and chat.is_typing()
		# The console (the key under Escape): net_stat and every other setting by name, and
		# the server's console when one runs in this process. One of the menu's overlays, so
		# opening it stops the player and frees the pointer exactly as the menu does.
		console = DotConsoleKit.build(self, settings.settings, settings.menu)
		# The HUD in the menu's theme and at the player's HUD size, live.
		if hud != null:
			hud.follow_menu(settings.menu)
		_bind_bot_console()
		_wire_board()
		_wire_maps()


func _suspend_input(suspended: bool) -> void:
	if _sampler != null:
		_sampler.suspended = suspended

	if player != null and player.sampler != null:
		player.sampler.suspended = suspended


func _capture() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	_captured = true


func _release() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_captured = false


# --- Asking ----------------------------------------------------------------

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


# --- The frame -------------------------------------------------------------

func _physics_process(delta: float) -> void:
	# The use key, held: the game makes the press from the edge, on the server or here.
	var use := _captured and InputMap.has_action(HsBindings.USE) and Input.is_action_pressed(HsBindings.USE)

	if _offline:
		if player != null:
			player.wants_use = use
		return

	if net == null or not net.is_running() or bridge == null:
		return

	var move := _sampler.sample(delta) if _sampler != null else DotFpsCommand.new()
	move.set_button(HsPlayer.USE_BUTTON, use)

	var ticks := net.clock.advance(delta)

	for i in range(ticks):
		if not net.clock.is_synced():
			continue

		bridge.client_tick(net.clock.input_tick() - (ticks - 1 - i), move)


func _process(delta: float) -> void:
	var _shown := present_frame(net, game, player, not third_person, delta, -1.0, _watched_through_eyes())
	_present_hide()

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


# --- Watching, once out -----------------------------------------------------

func is_spectating() -> bool:
	return player != null and game != null and game.spectate != null \
		and game.spectate.is_spectating(player.player_id)


func _watched_through_eyes() -> HsPlayer:
	if not is_spectating():
		return null

	var mode := game.spectate.mode_of(player.player_id)

	if mode != DotSpectatorView.Mode.FIRST_PERSON and mode != DotSpectatorView.Mode.FREEZE_CAM:
		return null

	return game.players.get(game.spectate.watching(player.player_id))


func _drive_spectator_camera() -> bool:
	if not is_spectating():
		if camera.get_parent() == self:
			_place_camera()

		if hud != null:
			hud.set_watching("")

		return false

	if camera.get_parent() != self:
		camera.get_parent().remove_child(camera)
		add_child(camera)
		camera.current = true

		if _arm != null and is_instance_valid(_arm):
			_arm.queue_free()
			_arm = null

	# Chase and death cameras pulled out of the house by dot-spectate, given the level.
	var manager: DotSpectatorManager = game.spectate.manager
	if manager != null and manager.camera_world == null and game.physics != null:
		manager.camera_world = camera.get_world_3d()
		manager.camera_mask = game.physics.layer_mask(&"world") | game.physics.layer_mask(&"prop")

	var where := game.spectate.camera_for(player.player_id)

	if where != Transform3D.IDENTITY:
		camera.global_transform = where

	if hud != null:
		hud.set_watching(game.spectate.line_for(player.player_id))

	return true


func spectate_step(direction: int) -> void:
	if audio != null:
		var _heard := audio.click()

	if bridge != null:
		bridge.ask_spectate(direction)
		return

	if game == null or game.spectate == null or player == null:
		return

	var moved := game.spectate.step(player.player_id, direction)

	if not moved.ok and chat != null:
		chat.notice(moved.error.message)


## Everything a frame draws that a tick does not, in this order: the netcode's interpolation,
## then every player in their side's colour, then every beacon. Returns how many are
## shown. Static so the net suite drives exactly this and not a copy of it.
##
## [param first_person] is whether [param own]'s camera is behind their eyes, which hides their
## own body.
static func present_frame(
	p_net: DotNetManager,
	p_game: HsGame,
	own: HsPlayer,
	first_person: bool,
	delta: float,
	alpha: float = -1.0,
	watched: HsPlayer = null
) -> int:
	var networked := p_net != null and p_net.is_running()

	if networked:
		p_net.interpolate_frame(alpha)

	# Your own player is drawn at the clock's render alpha, not the engine's fraction: the
	# clock stretches and shrinks its ticks while it settles on the server, so a physics frame
	# now and then runs no tick or two, and drawn at the engine's fraction the eye stood still
	# on one frame and moved double on the next. `DotFpsController.render_state` reads it from
	# `render_clock` (dot-player-controller); by name both ways, so a shell older than either
	# draws as before. Null offline, where every physics frame is one tick.
	if own != null and own.controller != null:
		own.controller.set(&"render_clock", p_net.clock if networked else null)

	if p_game == null:
		return 0

	var shown := 0
	var period := p_game.config.beacon_period if p_game.config != null else 2.0

	for key: StringName in p_game.players:
		var body: HsPlayer = p_game.players[key]

		if body == null or not is_instance_valid(body) or not body.is_inside_tree():
			continue

		var mine := body == own
		var at := drawn_position(body, networked and not mine)
		var colour := p_game.side_colour(p_game.team_of(key))
		var hidden := (mine and first_person) or body == watched

		if body.present_body(hidden, at, colour):
			shown += 1

		var _pinged := body.present_beacon(delta, at, mine and first_person, period)

	return shown


static func drawn_position(body: HsPlayer, remote: bool) -> Vector3:
	if remote or body.controller == null:
		return body.global_position

	return body.controller.render_state().position


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and not _captured:
		_capture()
		return

	if event.is_action_pressed("ui_cancel"):
		_release()
		if settings != null:
			settings.open()
		return

	if event.is_action(HsBindings.SCOREBOARD) and not event.is_echo():
		_show_board(event.is_pressed())
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

	if event is InputEventMouseMotion and _captured:
		if _offline and player.sampler != null:
			player.sampler.handle_event(event)
		elif _sampler != null:
			_sampler.handle_event(event)


## The game's own keys, from the bindings. True when one was used.
func _key_pressed(event: InputEvent) -> bool:
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

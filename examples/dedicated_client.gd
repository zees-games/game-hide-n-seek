extends "dedicated_vote.gd"


## A reload keeps the maps the server names: `hs_reload` reads the map directory again, which
## forgets everything read before. A pack "mounted" on the disk and a descriptor naming it
## stand in for dot-cloud and the deployment's map config, which a suite has neither of.
func _test_a_reload_keeps_delivered_maps() -> void:
	_section("a reload keeps the maps the server names")
	var key := "dot-test/hs-delivered@1.0.0"
	var mount := DotGameContent.mount_of(key)
	var dir := mount.path_join("maps")
	var id := &"hs_delivered_check"
	DirAccess.make_dir_recursive_absolute(dir)
	var doc: Dictionary = game.catalogue.practice()
	doc["id"] = String(id)
	var file := FileAccess.open(dir.path_join("delivered_check.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(doc))
	file.close()

	# The manager's running descriptor, named the way a deployment names it. Restored below:
	# `_current` is the manager's own, and nothing else in this suite should see the pack.
	var manager: Object = server.games
	var was: Variant = manager.get("_current")
	var named := DotGameDescriptor.new()
	named.maps = PackedStringArray([key])
	manager.set("_current", named)

	var _first := _run_command("hs_reload")
	for _i in range(3):
		await get_tree().process_frame
	_check(game.catalogue.maps.has(id), "a map the server names is in the catalogue after hs_reload",
		str(game.catalogue.maps.keys()))
	_check(game.catalogue.maps.has(&"hs_practice"),
		"beside the built-in one")

	await _delivered_on_boot_ballot(id)

	manager.set("_current", was)
	var _second := _run_command("hs_reload")
	for _i in range(3):
		await get_tree().process_frame
	_check(not game.catalogue.maps.has(id), "and it came from the server's list: unnamed, a reload drops it")

	DirAccess.remove_absolute(dir.path_join("delivered_check.json"))
	var path := dir
	while path != "res://dot_cloud":
		DirAccess.remove_absolute(path)
		path = path.get_base_dir()
	DirAccess.remove_absolute("res://dot_cloud")
	_finished()


## The ballot sees delivered maps from boot, not only after a reload: a module unloaded and
## loaded with the pack named is a boot, and the catalogue is read as a boot finds it.
func _delivered_on_boot_ballot(id: StringName) -> void:
	var only := game.config.map_ids
	game.config.map_ids = PackedStringArray()
	var _builtin := game.catalogue.load_from(game.config.map_directory)
	var reloaded := _run_command("module_unload hideseek")
	reloaded.append_array(_run_command("module_load res://game/hs_module.gd"))
	for _i in range(60):
		await get_tree().process_frame

		if _module() != null and _module().get("vote") != null:
			break
	var booted_vote: Node = _module().get("vote") if _module() != null else null
	var booted_ids: Array = []

	if booted_vote != null:
		for choice: DotVoteChoice in (booted_vote.get("source") as DotVoteListSource).entries:
			booted_ids.append(String(choice.id))

	_check(booted_ids.has(String(id)), "and on the ballot of a module that boots with it named, unrefreshed",
		"%s %s" % [reloaded, booted_ids])
	game.config.map_ids = only


## A hider behind its loading cover is not caught, and is once the cover lifts. A real
## [DotClientLink] joins over the server's socket and says nothing, as a client still loading
## its level does; the seek is set by hand with a stand-in seeker on top of it.
func _test_loading_cover() -> void:
	_section("a client behind its loading cover is not caught")

	var module := _module()
	var roster: DotGameRoster = module.get("roster") if module != null else null

	var known: Dictionary = {}
	for each in server.playing_sessions():
		known[each.userid] = true

	var client := _cover_client()
	var side: Node = client[0]
	var link: DotClientLink = client[1]
	var seat: Variant = await _cover_seat(known)
	_check(seat != null and roster != null, "a real client joins over the socket", str(link.last_error))

	var seeker: HsPlayer = null
	for id: StringName in game.players:
		if (game.players[id] as HsPlayer).is_bot:
			seeker = game.players[id]
			break

	if seat == null or roster == null or seeker == null:
		for what in ["held as loading", "the touch", "the sight meter", "the seeker draw", "an operator's catch",
				"the cover report", "the touch after", "bots and strangers", "leaving"]:
			_check(false, "%s (no runner joined)" % what)
		link.disconnect_from_server("done")
		side.queue_free()
		_finished()
		return

	var userid: int = seat.userid
	var key := StringName("u%d" % userid)
	var hider: HsPlayer = game.players[key]
	_check(roster.is_loading(userid), "the server holds the seat as loading from its spawn", str(roster.describe()))

	_cover_blocks_the_catch(key, hider, seeker)
	await _cover_lifts(link, roster, userid)
	_cover_then_catches(key, hider, seeker)

	_check(not bool(game.loading_fn.call(&"bot7")) and not bool(game.loading_fn.call(&"u99999")),
		"a bot, or a seat the roster does not hold, is never loading")

	link.disconnect_from_server("done")
	var gone := false
	for _i in 900:
		await get_tree().physics_frame
		if not game.players.has(key):
			gone = true
			break
	_check(gone and not roster.is_loading(userid), "it leaves and the roster forgets it")
	side.queue_free()
	_finished()


## A client link in a multiplayer tree of its own, as [side, link].
func _cover_client() -> Array:
	var side := Node.new()
	side.name = "CoverClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	# Under a node named like this suite's own, so the RPC path the server sends resolves in the
	# client's separate multiplayer tree too.
	var mirror := Node.new()
	mirror.name = name
	side.add_child(mirror)
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Cover"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	mirror.add_child(link)
	# A real client has its game's link under `Server`, which DotClientLink drops as the
	# connection phase changes, so it is re-added then.
	var attach := func(_a: Variant = null, _b: Variant = null) -> void:
		if link.get_node_or_null(NodePath(String(HsNetLink.NODE_NAME))) == null:
			link.add_child(HsNetLink.attached_to(link, null, false))
	attach.call()
	link.phase_changed.connect(attach)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	return [side, link]


## The session that joined since [param known], or null when none did.
func _cover_seat(known: Dictionary) -> Variant:
	var seat: Variant = null
	for _i in 1800:
		await get_tree().physics_frame
		for each in server.playing_sessions():
			if not known.has(each.userid) and game.players.has(StringName("u%d" % each.userid)):
				seat = each
		if seat != null:
			break
	return seat


## The setup and the attempt are one run with no await, so nothing ticks between.
func _cover_blocks_the_catch(key: StringName, hider: HsPlayer, seeker: HsPlayer) -> void:
	var was_phase: int = game.phase
	game.phase = HsGame.Phase.SEEK
	game._set_side(key, HsGame.HIDERS)
	game._set_side(seeker.player_id, HsGame.SEEKERS)
	hider.caught = false
	hider.sight_meter = 0.0
	seeker.held_until = -1.0
	seeker.place_at(hider.controller.state.position, 0.0)
	var was_mode: int = game.config.catch_mode
	game.config.catch_mode = HsConfig.Catch.TOUCH
	game._advance_catching(0.05)
	_check(not hider.caught, "a seeker's touch does not catch it", "caught=%s" % hider.caught)

	game.config.catch_mode = HsConfig.Catch.SIGHT
	game._advance_catching(0.05)
	_check(not hider.caught and hider.sight_meter == 0.0, "and the sight meter does not fill", "%s" % hider.sight_meter)
	game.config.catch_mode = was_mode

	# The draw leaves a covered seat on the hiders' side while somebody else can seek.
	var drawn_covered := 0
	for _i in 12:
		game._round_seed = _i
		game.seeker_history.clear()
		game._draw_sides()
		if game.team_of(key) == HsGame.SEEKERS:
			drawn_covered += 1
	_check(drawn_covered == 0, "a covered seat is not drawn to seek", "%d of 12 draws" % drawn_covered)

	game.phase = HsGame.Phase.SEEK
	game._set_side(key, HsGame.HIDERS)
	game._set_side(seeker.player_id, HsGame.SEEKERS)
	hider.caught = false
	_check(game.catch(key, &"", HsGame.CAUGHT_TAG), "an operator's catch still lands")
	game.phase = was_phase


func _cover_lifts(link: DotClientLink, roster: DotGameRoster, userid: int) -> void:
	DotGameClient.report_cover(link, false)
	var lifted := false
	for _i in 900:
		await get_tree().physics_frame
		if not roster.is_loading(userid):
			lifted = true
			break
	_check(lifted, "its cover report crosses the wire and ends the loading state")


func _cover_then_catches(key: StringName, hider: HsPlayer, seeker: HsPlayer) -> void:
	var was_phase: int = game.phase
	var was_mode: int = game.config.catch_mode
	game.phase = HsGame.Phase.SEEK
	game._set_side(key, HsGame.HIDERS)
	game._set_side(seeker.player_id, HsGame.SEEKERS)
	hider.caught = false
	seeker.held_until = -1.0
	seeker.place_at(hider.controller.state.position, 0.0)
	game.config.catch_mode = HsConfig.Catch.TOUCH
	game._advance_catching(0.05)
	_check(hider.caught, "and the same touch now catches it", "caught=%s" % hider.caught)
	game.config.catch_mode = was_mode
	game.phase = was_phase


## A module reload must leave ONE link under the server, still named for the client's route:
## two left the live one renamed `@Node@n` and every RPC to a real client was lost silently.
func _test_a_module_reload() -> void:
	_section("a module reload leaves one live link")

	for _i in range(2):
		_check(server.modules.unload_module("hideseek").ok, "the module unloads")
		var back: DotResult = await server.modules.load_module("res://game/hs_module.gd")
		_check(back.ok, "and loads again", back.error.message if not back.ok else "")
	for _i in range(5):
		await get_tree().process_frame

	var links := 0
	for child in server.get_children():
		if child.get_script() == HsNetLink:
			links += 1
	_check(links == 1 and server.has_node(NodePath(String(HsNetLink.NODE_NAME))),
		"exactly one link, under the name the client routes to", "%d" % links)

	var side := Node.new()
	side.name = "ReloadClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Reloaded"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	var mirror := Node.new()
	mirror.name = name
	side.add_child(mirror)
	mirror.add_child(link)
	# The client's sink shares the server link's name so the RPC path resolves.
	var attach := func(_a: Variant = null, _b: Variant = null) -> void:
		if link.get_node_or_null(NodePath(String(HsNetLink.NODE_NAME))) == null:
			link.add_child(HsNetLink.attached_to(link, null, false))
	attach.call()
	link.phase_changed.connect(attach)
	var spawned := [false]
	link.spawned.connect(func() -> void: spawned[0] = true)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var joined := await _until(func() -> bool:
		return spawned[0] or link.phase == DotClientLink.Phase.FAILED, 30.0)
	_check(joined and spawned[0], "a real client still hears the server's events after two reloads")
	link.disconnect_from_server("done")
	for _i in range(10):
		await get_tree().process_frame
	side.queue_free()
	_finished()


## [b]`hs_ambient*` on a client.[/b] The server's ambience intent rides the replicated cvars over a real socket, and a
## director that follows the game's rules (as [HsClient] wires it) has it in its layer's config.
func _test_ambient_cvars_reach_the_client() -> void:
	_section("the server's hs_ambient* reaches a client's ambience director, live")
	var side := Node.new()
	side.name = "AmbientClient"
	add_child(side)
	get_tree().set_multiplayer(MultiplayerAPI.create_default_interface(), side.get_path())
	var mirror := Node.new()
	mirror.name = name
	side.add_child(mirror)
	var link := DotClientLink.new()
	link.name = "Server"
	link.player_name = "Ambient"
	link.transport_preference = "udp"
	link.udp_address = "127.0.0.1:%d" % PORT
	mirror.add_child(link)
	var attach := func(_a: Variant = null, _b: Variant = null) -> void:
		if link.get_node_or_null(NodePath(String(HsNetLink.NODE_NAME))) == null:
			link.add_child(HsNetLink.attached_to(link, null, false))
	attach.call()
	link.phase_changed.connect(attach)
	link.connect_to_server("127.0.0.1:%d" % PORT)
	var rules := HsAmbience.make_rules()
	var _followed := rules.follow_cvars(link)
	var director := DotAmbienceDirector.new()
	director.ambient = DotAmbience.new()
	director.follow_settings(null, rules)
	var joined := false
	for _i in 1800:
		await get_tree().physics_frame
		if link.replicated_cvar("hs_ambient_volume", "") != "":
			joined = true
			break
	_check(joined and link.replicated_cvar("hs_ambient_dir", "x") == "x",
		"the join carried hs_ambient_volume, and the machine-local hs_ambient_dir stayed home", str(link.replicated_cvars))
	var _vol := server.console.set_cvar("hs_ambient_volume", "0.8")
	var _mood := server.console.set_cvar("hs_ambient_mood", "swamp")
	var _off := server.console.set_cvar("hs_ambient", "0")
	var arrived := false
	for _i in 900:
		await get_tree().physics_frame
		if is_equal_approx(director.ambient.config.volume, 0.8) and director.ambient.config.mood == "swamp" \
				and not director.ambient.config.enabled:
			arrived = true
			break
	_check(arrived, "a change of volume, mood and the switch reaches the director live", str(rules.describe()))
	var _back_vol := server.console.set_cvar("hs_ambient_volume", "0.3")
	var _back_mood := server.console.set_cvar("hs_ambient_mood", "")
	var _back_on := server.console.set_cvar("hs_ambient", "1")
	var back := false
	for _i in 900:
		await get_tree().physics_frame
		if rules.is_on() and rules.mood == "":
			back = true
			break
	_check(back, "and back", str(rules.describe()))
	director.ambient.free()
	director.free()
	link.disconnect_from_server("done")
	for _i in 120:
		await get_tree().physics_frame
	side.queue_free()
	_finished()

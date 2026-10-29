extends "dedicated_world.gd"


## The players' vote decides the next map: a ballot over the server's maps, one vote cast,
## and the round's end puts the winner on the next round. Driven by hand rather than by
## the clock, because stand-ins are not voters and a server of stand-ins never opens one.
func _test_the_map_vote() -> void:
	_section("the map vote")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	_check(vote != null, "the module built a map vote")

	if vote == null:
		_finished()
		return

	_check(server.console.find_command("vote") != null if server.console.has_method("find_command") else true,
		"and registered dot-vote's vote command")
	_vote_hibernation(vote)
	_vote_offers_maps(vote)
	await _vote_map_menu(vote)
	var director: DotVoteDirector = vote.get("director")
	var choice := _vote_ballot(vote, director)
	_vote_next_map(vote, director, choice)
	_vote_rock_the_vote(vote, director)
	_finished()


## DotGameModule hands the director the server; the ballot's timer waits with it, and waking
## starts both again from the top.
func _vote_hibernation(vote: Node) -> void:
	var sleeper: DotVoteDirector = vote.get("director")
	_check(server.hibernation_changed.is_connected(sleeper.set_hibernating),
		"the vote follows the server's hibernation without a line of this game's")
	vote.set("_opened_this_map", true)
	server.console.execute("sv_hibernate_when_empty 1")
	_check(server.is_hibernating() and sleeper.hibernating, "an empty server sleeps, and the vote with it",
		server.state_name())
	var on_map: float = vote.get("_on_map_sec")
	vote.call("advance", 600.0)
	_check(is_equal_approx(vote.get("_on_map_sec"), on_map), "ten minutes asleep do not count towards the ballot")
	server.console.execute("sv_hibernate_when_empty 0")
	_check(not sleeper.hibernating, "waking wakes the vote")
	_check(is_zero_approx(vote.get("_on_map_sec")) and not vote.get("_opened_this_map"),
		"and the map ballot is owed again from the top")


## Every map in the directory, not only this suite's practice house.
func _vote_offers_maps(vote: Node) -> void:
	game.config.map_ids = PackedStringArray()
	vote.call("refresh_maps")
	var ids: Array = []

	for choice: DotVoteChoice in (vote.get("source") as DotVoteListSource).entries:
		ids.append(String(choice.id))

	_check(ids.has("hs_apartments") and ids.has("hs_manor"), "it offers the delivered maps", str(ids))


## The map menu's server half (M): the owner's flag changes the map now, anybody else gets a
## nomination and a rock-the-vote. Contexts as dot-server makes them for a chat line.
func _vote_map_menu(vote: Node) -> void:
	var menu_half: Object = vote.get("commands").get("map_menu")
	_check(menu_half != null and server.console.find_command("mapmenu") != null
		and server.console.find_cvar("sv_map_menu_flag").get_string() == "generic"
		and (menu_half.get("change_fn") as Callable).is_valid(),
		"the map menu is there, staff-only by default, changing the map now")
	var staff := DotCmdContext.new()
	staff.source = DotCmdContext.Source.CHAT
	staff.permissions = PackedStringArray(["generic"])
	var player := DotCmdContext.new()
	player.source = DotCmdContext.Source.CHAT
	var menu_offer: Dictionary = menu_half.call("offer", player)
	_check((menu_offer["maps"] as Array).size() > 1 and not bool(menu_offer["allowed"]) and bool(menu_offer["vote"]),
		"a player is offered every map, as a vote")
	var target: StringName = &""
	for row: Dictionary in menu_offer["maps"]:
		if not bool(row["current"]):
			target = StringName(str(row["id"]))
			break
	var menu_changed: Dictionary = await menu_half.call("choose", staff, target)
	_check(bool(menu_changed["ok"]) and StringName(str(game.map_doc.get("id", ""))) == target, "staff choosing one changes the map on the spot",
		"%s: %s" % [target, menu_changed.get("text", "")])


## Opens a ballot, casts the one vote and returns the map it was cast for.
func _vote_ballot(vote: Node, director: DotVoteDirector) -> StringName:
	vote.set("voters_fn", func() -> Array: return [&"7"])
	var opened := director.open_vote(DotVoteClock.REASON_MANUAL)
	_check(opened.ok and director.is_voting(), "a ballot opens", opened.error.message if not opened.ok else "")

	# A fixed id is on the ballot some runs and not others: it draws a handful from the maps.
	var offered := director.ballot.option_ids() if director.ballot != null else []
	var maps_offered := offered.filter(func(id: StringName) -> bool: return String(id).begins_with("hs_"))
	var choice: StringName = &"hs_manor" if offered.has(&"hs_manor") or maps_offered.is_empty() else StringName(maps_offered[0])
	var cast := director.cast_one(&"7", choice)
	# Everybody has voted; the director closes on its next advance, which is the server's tick.
	director.advance(0.05)
	_check(cast.ok and director.pending_id() == choice, "one vote decides it, waiting for the round's end",
		"%s %s of %s" % [cast.ok, director.pending_id(), offered])
	return choice


func _vote_next_map(vote: Node, director: DotVoteDirector, choice: StringName) -> void:
	# No frame between these: a stand-in round starting in between would lay the map itself.
	vote.call("note_round_end")
	_check(game.next_map_id == choice, "the round's end hands it to the world", str(game.next_map_id))

	game.call("_lay_out_map")
	_check(StringName(str(game.map_doc.get("id", ""))) == choice and game.next_map_id == &"",
		"and the next map laid is the one voted for, once", "%s / %s" % [game.map_doc.get("id", ""), game.next_map_id])
	var laid := StringName(str(game.map_doc.get("id", "")))
	_check(director.current_id() == laid and not director.is_voting(),
		"the new map starts the vote over", "%s / %s" % [director.current_id(), laid])


## Typed at the console as a player's !rtv reaches it. Past dot-vote's cooldown, on the
## director alone so the map's own ballot timer does not open one first.
func _vote_rock_the_vote(vote: Node, director: DotVoteDirector) -> void:
	vote.set("voters_fn", func() -> Array: return [&"console"])
	director.rules.rtv_delay_sec = 0.0
	director.rules.min_players_to_vote = 1
	director.rules.rtv_min_players = 1
	director.rules.allow_single_voter_auto = true
	director.advance(director.rules.vote_cooldown_sec + 0.1)
	var opened_count := [0]
	var counter := func(_options: Array, _seconds: float) -> void: opened_count[0] += 1
	director.vote_opened.connect(counter)
	var rocked := _run_command("rtv")
	vote.call("advance", 0.05)
	_check(director.is_voting(), "and a passing rock-the-vote opens a ballot", str(rocked))
	_check(opened_count[0] == 1, "and opens exactly one rtv ballot, not a second from the game", str(opened_count[0]))
	director.vote_opened.disconnect(counter)


## The config as cvars and a workbench set, the old cvar names as aliases, and dot-team's block rules through dot-game.
func _test_config_and_noblock() -> void:
	_section("config and noblock")
	var console := server.console
	var binder := game.config_binder
	_check(binder != null and console.has_name("hs_hide_seconds") and console.has_name("hs_config_diff"), "the config is bound to cvars and commands")
	var _set := _run_command("hs_tag_range 2.0")
	_check(is_equal_approx(game.config.tag_range, 2.0) and binder.source_of("tag_range") == "cvar", "an hs_<field> cvar writes the field")
	var _doors := _run_command("hs_doors 0")
	_check(not game.config.doors_enabled and console.get_string("hs_doors_enabled", "") == "0", "the old hs_doors alias writes the field and its cvar")
	var _back := _run_command("hs_doors_enabled 1")
	_check(game.config.doors_enabled and console.get_string("hs_doors", "") == "1", "and the field's cvar moves the alias")
	var module := _module()
	var wb: DotGameWorkbench = module.get("workbench") if module != null else null
	_check(wb != null and wb.api != null, "the module hosts a workbench")
	if wb == null or wb.api == null:
		return
	var rel := "config_catching"
	var res: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": rel, "id": binder.profile_id, "key": "auto_taunt_seconds", "value": 33.0})
	_check(res.ok and is_equal_approx(game.config.auto_taunt_seconds, 33.0) and console.get_float("hs_auto_taunt_seconds") == 33.0,
		"a workbench edit changes the field and the live cvar", "" if res.ok else res.error.message)
	_check(game.taunts != null and is_equal_approx(game.taunts.auto_after, 33.0), "and the taunt timer the world cached")
	var amb: DotResult = wb.api.handle(DotGameWorkbench.LOCAL_ACTOR, {"op": "set", "kind": "ambience", "id": DotGameWorkbench.CVAR_SET_ID, "key": "hs_ambient_volume", "value": 0.2})
	_check(amb.ok and is_equal_approx(console.get_float("hs_ambient_volume"), 0.2), "the hs_ambient* cvars are a workbench set and an edit moves the cvar", "" if amb.ok else amb.error.message)
	var teamblock := console.find_cvar("mp_teamblock")
	var enemyblock := console.find_cvar("mp_enemyblock")
	_check(teamblock != null and teamblock.get_string() == "0" and enemyblock != null and enemyblock.get_string() == "1", "mp_teamblock is 0 and mp_enemyblock is 1 by default")
	_check(game.block_rules != null and not game.body_rules.solid, "block rules are wired and players stay non-solid")
	_check(game.team_of_side(&"nobody") == "", "a player with no side has no block side")
	var _reset := _run_command("hs_tag_range 1.2")
	_finished()


## maps.yml on the live module: a map outside the active rotation stays installed and loadable
## by `hs_map` but is never drawn, balloted or nominated; a switch takes effect, `commands:`
## renames commands, and no file changes nothing.
func _test_map_rotation_file() -> void:
	_section("maps.yml")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	_check(game != null and game.catalogue != null and vote != null and vote.get("director") != null,
		"the game has maps and a vote")

	if game == null or game.catalogue == null or vote == null or vote.get("director") == null:
		return

	var director: DotVoteDirector = vote.get("director")
	game.config.map_ids = PackedStringArray()
	var built := DotMapRotationFile.from_trees([{"defaults": {
		"rotation": "main",
		"rotations": {
			"main": {"mode": "cycle", "maps": ["hs_apartments", "hs_manor"]},
			"alt": {"maps": ["hs_manor"]},
		},
		"commands": {"names": {"rtv": "rockthevote", "hs_map": "setnextis", "hs_maps": "maplist"}},
	}}], "game-hide-n-seek")
	_check(built.ok, "a maps.yml with two rotations and renamed commands parses",
		"" if built.ok else built.error.message)
	if not built.ok:
		return

	var kept_file: DotMapRotationFile = game.rotation_file
	_rotation_installed(vote, director, built.value, kept_file)
	_rotation_commands(vote, director)
	_rotation_switch(vote)
	_rotation_cleared(vote)

	game.rotation_file = kept_file
	game.apply_rotation()
	vote.call("refresh_maps")
	_finished()


func _rotation_installed(vote: Node, director: DotVoteDirector, file: DotMapRotationFile, kept_file: DotMapRotationFile) -> void:
	var catalogue := game.catalogue
	var all_ids: Array[StringName] = catalogue.playable(PackedStringArray())
	_check(all_ids.size() > 2 and catalogue.in_rotation_fn.is_valid() == (kept_file != null and kept_file.has_rotations()),
		"the catalogue holds more maps than the rotation will", str(all_ids.size()))
	game.rotation_file = file
	game.apply_rotation()
	vote.call("refresh_maps")

	_check(game.in_rotation(&"hs_apartments") and game.in_rotation(&"hs_manor"), "the listed maps are in rotation")
	_check(not game.in_rotation(&"hs_camp") and catalogue.playable(PackedStringArray()).has(&"hs_camp"),
		"an unlisted map is out of rotation and still installed")
	_check(not game.shuffles_maps(), "a cycle rotation does not shuffle the draw")

	var drawn: Array = []
	var previous: StringName = &""
	for _i in 6:
		var doc := catalogue.next_map(PackedStringArray(), game.shuffles_maps(), game.random.stream(&"map"), previous)
		previous = StringName(str(doc["id"]))
		drawn.append(String(previous))
	_check(drawn == ["hs_apartments", "hs_manor", "hs_apartments", "hs_manor", "hs_apartments", "hs_manor"],
		"six draws cycle the written order and never leave it", str(drawn))

	var ids := (vote.get("source") as DotVoteListSource).choices().map(func(c: DotVoteChoice) -> StringName: return c.id)
	_check(ids.has(&"hs_manor") and ids.has(&"hs_apartments") and not ids.has(&"hs_camp"),
		"a map outside the rotation is not on the ballot, one inside is", str(ids))
	var nominated := director.nominate(&"u77", &"hs_camp")
	_check(not nominated.ok, "nominate refuses a map outside the rotation")
	_check(not director.nominated_ids().has(&"hs_camp"), "and nothing was recorded")


func _rotation_commands(vote: Node, director: DotVoteDirector) -> void:
	var catalogue := game.catalogue
	var queued := _run_command("hs_map hs_camp")
	_check(_said(queued, "hs_camp is next") and game.next_map_id == &"hs_camp",
		"an operator can still queue it with hs_map", str(queued))
	game.next_map_id = &""

	_check(server.console.find_command("hs_map") != null and server.console.find_command("hs_maps") != null,
		"with no file at load the game's own commands keep their names")
	_check(game.command_name("hs_map", "hs_map") == "setnextis" and game.command_name("hs_maps", "hs_maps") == "maplist"
		and game.command_name("hs_reload", "hs_reload") == "hs_reload",
		"the game's own command names come from maps.yml's commands, others keep theirs")
	var rows := game.map_rows().filter(func(r: Dictionary) -> bool: return r["id"] == "hs_camp")
	_check(rows.size() == 1 and str(rows[0]["detail"]).contains("not in rotation"),
		"the map menu marks a map that is not in rotation")
	_check(_said(PackedStringArray(catalogue.describe_lines()), "not in rotation"),
		"and so does the hs_maps list")

	var rtv := DotVoteCommands.new()
	rtv.director = director
	rtv.spec_fn = game.rotation_commands
	var bound := rtv.bind(server.console)
	_check(bound.ok and rtv.command_name("rtv") == "rockthevote" and server.console.find_command("rockthevote") != null,
		"a renamed rtv command is registered from maps.yml's commands")
	var vote_commands: DotVoteCommands = vote.get("commands")
	_check(vote_commands != null and vote_commands.spec_fn.is_valid(), "and the game's vote hands its commands the file")


func _rotation_switch(vote: Node) -> void:
	var switched := game.rotation_file.switch(game._rot, "alt")
	game.apply_rotation()
	vote.call("refresh_maps")
	_check(switched.ok and game.in_rotation(&"hs_manor") and not game.in_rotation(&"hs_apartments"),
		"switching to the alt rotation takes effect")
	var ids := (vote.get("source") as DotVoteListSource).choices().map(func(c: DotVoteChoice) -> StringName: return c.id)
	_check(not ids.has(&"hs_apartments") and ids.has(&"hs_manor"), "and the ballot follows it")
	_check(not game.rotation_file.switch(game._rot, "nope").ok, "an unknown rotation is refused")


## No file again: everything back in, as before maps.yml.
func _rotation_cleared(vote: Node) -> void:
	game.rotation_file = null
	game.apply_rotation()
	vote.call("refresh_maps")
	var all_in := true
	for id in game.catalogue.playable(PackedStringArray()):
		all_in = all_in and game.in_rotation(id)
	_check(all_in and game.shuffles_maps() == game.config.shuffle_maps, "with no file every map is in rotation and the draw is as configured")
	_check(game.rotation_commands().is_empty() and game.command_name("hs_map", "hs_map") == "hs_map",
		"and no command is renamed")


## `time_up: finish_round` waits for a round being played, never for warmup: the game hands
## dot-vote its match's answer (`round_in_progress_fn`). Run on a director of its own, so the
## real vote's clock is untouched; the match's state is set by hand and put back.
func _test_finish_round_waits_for_a_live_round() -> void:
	_section("finish_round waits for a live round, not warmup")
	var module := _module()
	var vote: Node = module.get("vote") if module != null else null
	var director: DotVoteDirector = vote.get("director") if vote != null else null
	var hook: Variant = director.get("round_in_progress_fn") if director != null else null
	_check(hook is Callable and (hook as Callable).is_valid(), "the game tells its vote whether a round is live")

	if not (hook is Callable and (hook as Callable).is_valid()) or game == null or game.match_node == null:
		_finished()
		return

	var match_node: DotMatch = game.match_node
	var was := match_node.state
	match_node.state = DotMatch.State.WARMUP
	var warm_applied := []
	var warm := _finish_round_probe(hook, warm_applied)
	_check(warm_applied == [&"b"] and not warm.is_finishing_round(),
		"in warmup a time limit with finish_round changes at once", str(warm_applied))

	match_node.state = DotMatch.State.LIVE
	var live_applied := []
	var live := _finish_round_probe(hook, live_applied)
	_check(live_applied.is_empty() and live.is_finishing_round(),
		"during a live round it waits for the round", str(live_applied))

	match_node.state = DotMatch.State.INTERMISSION
	live.advance(0.1)
	_check(live_applied == [&"b"], "and the round ending is the change", str(live_applied))

	match_node.state = was
	warm.queue_free()
	live.queue_free()
	_finished()


## A director under `time_up: finish_round` carrying [param hook], its clock run out with a
## winner already decided: what dot-vote's own suite builds, with the game's answer in it.
func _finish_round_probe(hook: Callable, applied: Array) -> DotVoteDirector:
	var source := DotVoteListSource.new()
	var _a := source.add(DotVoteChoice.of(&"a", "A"))
	var _b := source.add(DotVoteChoice.of(&"b", "B"))
	source.apply_fn = func(id: StringName) -> DotResult:
		applied.append(id)
		return DotResult.success(id)

	var rules := DotVoteRules.new()
	rules.apply_delay_sec = 0.0
	rules.duration_sec = 100.0
	rules.vote_lead_sec = 40.0
	rules.vote_duration_sec = 5.0
	rules.include_extend = false
	rules.apply = DotVoteRules.Apply.END_OF_TIME
	rules.cooldown = 0
	rules.time_up = DotVoteRules.TimeUp.FINISH_ROUND
	# For ever: only the hook may release it.
	rules.finish_round_max_sec = 0.0

	var probe := DotVoteDirector.new()
	probe.rules = rules
	probe.source = source
	probe.register_service = false
	probe.self_advance = false
	probe.round_based = true
	probe.player_count_fn = func() -> int: return 4
	probe.set(&"round_in_progress_fn", hook)
	add_child(probe)
	probe.begin(&"a")
	source.current = &"a"

	for i in range(61):
		probe.advance(1.0)

	probe.cast_one(&"p1", &"b")

	# The ballot closes, then the limit (100 s) runs out with the winner decided.
	for i in range(46):
		probe.advance(1.0)

	return probe

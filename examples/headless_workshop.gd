extends Node

const HsCatalogue := preload("../game/hs_catalogue.gd")
const HsConfig := preload("../game/hs_config.gd")
const HsGame := preload("../game/hs_game.gd")
const HsVote := preload("../game/hs_vote.gd")

## Workshop maps: a subscribed pack's map is offered in solo, is not offered online, and a kind
## the game does not accept is left out; and the one chosen in solo is the one that is built.
##
## The fixture is a pack on disk under user:// registered in dot-core's shared content index as a
## solo pack, the way the client shell's Workshop sync registers a mounted one. A map here is a
## hide-and-seek DOCUMENT, so the entry's `scene` is that JSON file (see hs_catalogue.gd).
## [b]Armed by the "surf" entry[/b]: the same file under a kind this game does not accept, which
## must be in neither list.

const ROOT := "user://hs_ws_fixture/"
const CHECKS := 18

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures: Array[String] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("hideseek workshop")
	await _test()
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != 1 or _sections_finished != 1 or _passed + _failed != CHECKS:
		print("ERROR: %d sections, %d checks ran; 1 and %d expected." % [_sections_finished, _passed + _failed, CHECKS])
		code = 1

	get_tree().quit(code)


func _write_pack() -> void:
	DirAccess.make_dir_recursive_absolute(ROOT + "maps")

	for id in ["ws_house", "ws_surf"]:
		var doc := HsCatalogue.practice()
		doc["id"] = id
		doc["name"] = "Fixture %s" % id
		var file := FileAccess.open(ROOT + "maps/%s.json" % id, FileAccess.WRITE)
		file.store_string(JSON.stringify(doc))
		file.close()


func _test() -> void:
	_sections_entered += 1
	_write_pack()

	var index := DotContentIndex.shared()
	index.set_session(DotContentIndex.SESSION_SOLO)
	var added := index.add_pack({
		"content_id": "tester/ws-maps", "version": "1.0.0", "prefix": ROOT,
		"session": "solo", "source": "subscription",
		"provides": {"title": "Workshop Test", "kinds": ["map"], "entries": [
			{"kind": "map", "id": "ws_house", "name": "Fixture House",
				"scene": "maps/ws_house.json", "map_kind": HsCatalogue.CONTENT_KIND},
			{"kind": "map", "id": "ws_surf", "name": "Fixture Surf",
				"scene": "maps/ws_surf.json", "map_kind": "surf"},
		]},
	})
	_check(added.ok and (added.value as Array).size() == 2, "the fixture pack is in the index")

	# The world follows the shared index when it builds its catalogue, as a client shell's solo.
	var config := HsConfig.new()
	config.warmup_seconds = 0.0
	config.minimum_players = 0
	config.keep_progress = false
	var game := HsGame.new()
	game.config = config
	game.tick_rate = 60
	game.authoritative = true
	game.draw_world = false
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	await get_tree().physics_frame

	var vote := HsVote.new()
	vote.maps_fn = func() -> Array:
		var out: Array = []

		for id in game.catalogue.playable(game.config.map_ids):
			if not game.catalogue.is_content(id):
				out.append([id, id])

		return out
	add_child(vote)
	_check(vote.setup().ok, "the vote is built")

	# An own map: the practice house alone, or any delivered one (it drops out beside others).
	var own := &""

	for id in game.catalogue.playable(PackedStringArray()):
		if not game.catalogue.is_content(id):
			own = id
			break

	_check(own != &"", "the game has a map of its own to keep")

	var solo := _ids(game.catalogue.playable(PackedStringArray()))
	_check(solo.has("ws_house"), "solo: the map menu's catalogue offers the pack map")
	_check(not solo.has("ws_surf"), "solo: a kind the game does not accept is not in the catalogue")
	_check(solo.has(String(own)), "solo: the game's own map is still there")

	var rows := game.map_rows()
	var named := false

	for row: Dictionary in rows:
		named = named or str(row["id"]) == "ws_house"

	_check(named, "solo: the M menu lists the pack map")

	var ballot := vote.source.choices()
	var labels := {}

	for choice in ballot:
		labels[String(choice.id)] = choice.label()

	_check(labels.has("ws_house"), "solo: the ballot offers the pack map")
	_check(labels.get("ws_house", "") == "Fixture House [Workshop Test]", "solo: it is labelled with its pack", str(labels.get("ws_house")))
	_check(not labels.has("ws_surf"), "solo: the ballot leaves out a kind the game does not accept")
	_check(labels.has(String(own)), "solo: the game's own map is on the ballot")

	var changed := game.change_map_now(&"ws_house")
	_check(changed.ok, "solo: the pack map can be chosen", "" if changed.ok else changed.error.message)
	_check(str(game.map_doc.get("id", "")) == "ws_house", "solo: the chosen pack map is the one built", str(game.map_doc.get("id", "")))

	index.set_session(DotContentIndex.SESSION_ONLINE)
	var online := _ids(game.catalogue.playable(PackedStringArray()))
	_check(not online.has("ws_house"), "online: the catalogue does not offer the solo map")
	_check(not vote.source.choices().any(func(c: DotVoteChoice) -> bool: return c.id == &"ws_house"), "online: the ballot does not offer the solo map")
	_check(not game.change_map_now(&"ws_house").ok, "online: the solo map cannot be chosen")
	_check(online.has(String(own)), "online: the game's own map is still offered")

	index.set_session(DotContentIndex.SESSION_SOLO)
	_check(_ids(game.catalogue.playable(PackedStringArray())).has("ws_house"), "back in solo: the pack map returns")

	remove_child(vote)
	vote.free()
	remove_child(game)
	game.free()
	_sections_finished += 1


func _ids(list: Array) -> PackedStringArray:
	var out := PackedStringArray()

	for id: Variant in list:
		out.append(String(id))

	return out


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s" % what)
		return

	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)

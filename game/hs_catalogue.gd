extends RefCounted

const HsMapDoc := preload("hs_map_doc.gd")
const HsPaths := preload("hs_paths.gd")

## Every map this server can play, and which one is next.
##
## [b]Two sources, and the built-in one is a floor rather than a feature.[/b] The maps are
## documents read from [member HsConfig.map_directory] — `maps/`, a link to hide-n-seek-maps,
## in a checkout; a directory in a delivered pack. A server whose directory is missing or empty
## still has [method practice], so it plays rather than refusing to start.
##
## [b]A server reads documents; a client never does.[/b] The map travels in its own event (see
## [HsMapDoc]), so nothing here runs on a connected client.

const CHANNEL := "hs.catalogue"

const PRACTICE := &"hs_practice"

## id -> normalised document.
var maps: Dictionary = {}

## Files that were refused, with why. What `hs_maps` prints, so a mapper can see it.
var refused: Dictionary = {}

var _order: Array[StringName] = []

## The map kind this game declares in provides.json's `accepts.map_kinds`, and so the only kind
## of subscribed map it reads. A pack's `map` entry carries a hide-and-seek DOCUMENT in its
## `scene` field (a map here is a document, not a scene; see hs_map_doc.gd).
const CONTENT_KIND := "hideseek"

var _index: DotContentIndex = null
var _kinds := PackedStringArray()
## Parsed documents by entry key, so a pack's file is read once, not on every menu draw.
var _content_docs: Dictionary = {}
## The ids [method sync_content] added last time, so a session change can take them out.
var _content_ids: Dictionary = {}
var _content_titles: Dictionary = {}
var _next: int = 0

## `(StringName) -> bool`: whether maps.yml's active rotation plays this id. Unset, every map
## does. Read by the draw ([method next_map]) only: an operator's `hs_map`, the map menu and the
## ballot's own list ask [method playable], so an unlisted map stays installed and loadable.
var in_rotation_fn: Callable = Callable()

## The active rotation's written order, used by the draw when not shuffling. Empty is the
## catalogue's own (alphabetical) order.
var rotation_order: Array[StringName] = []

## The pack ref (`owner/map`) of each subscribed or delivered map, so maps.yml can name it.
var _content_refs: Dictionary = {}


## Reads every document under [param directory] (relative to this game's root), and adds the
## one built in. Forgets anything read before.
func load_from(directory: String) -> int:
	maps.clear()
	refused.clear()

	_add(practice(), "built-in")

	var root := HsPaths.rebase("res://" + directory.trim_prefix("res://").trim_prefix("/"))
	var loaded := _read_directory(root)
	_rebuild_order()

	DotLog.info(CHANNEL, "maps loaded", {"maps": maps.size(), "refused": refused.size()})
	return loaded


## Adds every document under [param root], an absolute `res://` path: a maps pack mounted
## beside the game, at its OWN prefix, which this game's rebasing would put somewhere else.
func add_directory(root: String) -> int:
	var loaded := _read_directory(root)
	_rebuild_order()
	DotLog.info(CHANNEL, "maps added", {"from": root, "read": loaded, "maps": maps.size()})
	return loaded


## Follows a [DotContentIndex]: subscribed (solo) and delivered (online) map entries of an
## accepted kind become maps here, for the index's CURRENT session only. Empty kinds is none and
## "*" every kind, as for dot-map. The game's own and an operator's maps always win an id.
func follow_content(index: DotContentIndex, accepted_kinds: PackedStringArray) -> void:
	_index = index
	_kinds = accepted_kinds
	sync_content()


## Re-reads the index into [member maps]. Called from [method playable] rather than on a signal:
## [method DotContentIndex.tag_pack] adds a session without announcing it, and a stale list is
## worse than a cheap loop over a handful of entries.
func sync_content() -> void:
	var wanted: Dictionary = {}

	if _index != null:
		for entry in _index.entries(&"map"):
			var kind := str(entry.raw.get("map_kind", ""))

			if kind == "" or not (_kinds.has("*") or _kinds.has(kind)):
				continue

			var doc := _content_doc(entry)

			if doc.is_empty():
				continue

			var id := StringName(str(doc["id"]))

			if not wanted.has(id):
				wanted[id] = doc
				_content_titles[id] = entry.pack_title
				_content_refs[id] = str(entry.content_id)

	var changed := false

	# Only a map this follower added is taken out: load_from may since have put the game's own
	# under the id.
	for id: StringName in _content_ids:
		if maps.has(id) and is_same(maps[id], _content_ids[id]) \
				and not (wanted.has(id) and is_same(wanted[id], _content_ids[id])):
			maps.erase(id)
			changed = true

	_content_ids.clear()

	for id: StringName in wanted:
		if maps.has(id):
			# Either the game's own (it wins) or the one added on an earlier call.
			if is_same(maps[id], wanted[id]):
				_content_ids[id] = wanted[id]
			continue

		maps[id] = wanted[id]
		_content_ids[id] = wanted[id]
		changed = true

	if changed:
		_rebuild_order()


## Whether [param id] is a subscribed or delivered pack map rather than one of the game's own.
func is_content(id: StringName) -> bool:
	return _content_ids.has(id)


## The pack a subscribed or delivered map came from, "" for the game's own.
func pack_title(id: StringName) -> String:
	return str(_content_titles.get(id, ""))


func _content_doc(entry: DotContentEntry) -> Dictionary:
	if _content_docs.has(entry.key):
		return _content_docs[entry.key]

	var file := entry.path("scene")
	var doc: Dictionary = {}
	var text := FileAccess.get_file_as_string(file) if file != "" else ""

	if text.is_empty():
		refused[entry.key] = "empty or unreadable: %s" % file
	else:
		var parsed := HsMapDoc.parse_json(text, file)

		if parsed.ok and str(parsed.value["id"]) != entry.id:
			# The ballot names the entry's id and the map menu the document's: two names for one
			# map would offer a choice the catalogue cannot find.
			refused[entry.key] = "entry id %s but document id %s" % [entry.id, parsed.value["id"]]
		elif parsed.ok:
			doc = parsed.value
		else:
			refused[entry.key] = parsed.error.message
			DotLog.warn(CHANNEL, "a subscribed map was refused", {
				"key": entry.key, "why": parsed.error.message,
			})

	_content_docs[entry.key] = doc
	return doc


func _read_directory(root: String) -> int:
	var dir := DirAccess.open(root)

	if dir == null:
		DotLog.info(CHANNEL, "no map directory here", {"looked_at": root})
		return 0

	var files := PackedStringArray()

	for file in dir.get_files():
		if file.ends_with(".json"):
			files.append(file)

	files.sort()
	var loaded := 0

	for file in files:
		var text := FileAccess.get_file_as_string(root.path_join(file))

		if text.is_empty():
			refused[file] = "empty or unreadable"
			continue

		var parsed := HsMapDoc.parse_json(text, file)

		if not parsed.ok:
			refused[file] = parsed.error.message
			DotLog.warn(CHANNEL, "a map was refused", {
				"file": file, "why": parsed.error.message, "detail": parsed.error.detail,
			})
			continue

		if _add(parsed.value, file):
			loaded += 1

	return loaded


func _add(doc: Dictionary, origin: String) -> bool:
	var id := StringName(str(doc["id"]))

	if maps.has(id) and origin != "built-in" and id != PRACTICE:
		refused[origin] = "a second map with id %s" % id
		return false

	maps[id] = doc
	return true


func _rebuild_order() -> void:
	_order.clear()

	for id: StringName in maps:
		_order.append(id)

	_order.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	_next = 0


## The ids a server may draw from, after [param allowed] (empty is all). The built-in practice
## map drops out once there is anything else.
func playable(allowed: PackedStringArray) -> Array[StringName]:
	sync_content()
	var out: Array[StringName] = []

	for id in _order:
		if allowed.is_empty() or allowed.has(String(id)):
			out.append(id)

	if allowed.is_empty() and out.size() > 1:
		out.erase(PRACTICE)

	return out


## The pack ref of a subscribed or delivered map, "" for the game's own.
func content_ref(id: StringName) -> String:
	return str(_content_refs.get(id, ""))


## Whether maps.yml's active rotation plays [param id]; true with no rotation file.
func in_rotation(id: StringName) -> bool:
	return not in_rotation_fn.is_valid() or bool(in_rotation_fn.call(id))


## [method playable] less the maps outside the active rotation: what a draw may choose. When
## the rotation leaves nothing installed, every playable map: a rotation must never strand the
## server.
func drawable(allowed: PackedStringArray) -> Array[StringName]:
	var all := playable(allowed)
	var out: Array[StringName] = []

	for id in all:
		if in_rotation(id):
			out.append(id)

	if out.is_empty():
		return all

	if not rotation_order.is_empty():
		var ordered: Array[StringName] = []

		for id in rotation_order:
			if out.has(id):
				ordered.append(id)

		for id in out:
			if not ordered.has(id):
				ordered.append(id)

		return ordered

	return out


## The next map: drawn from [param stream] when shuffling, in order otherwise, and never the
## same one twice running when there is a choice.
func next_map(allowed: PackedStringArray, shuffle: bool, stream: DotRandomStream,
		previous: StringName) -> Dictionary:
	var ids := drawable(allowed)

	if ids.is_empty():
		DotLog.warn(CHANNEL, "no map matches the allowed list; playing practice", {
			"allowed": ",".join(allowed),
		})
		return maps.get(PRACTICE, practice())

	var pick: StringName

	if shuffle and stream != null:
		pick = ids[stream.next_range_i(0, ids.size() - 1)]

		if pick == previous and ids.size() > 1:
			pick = ids[(ids.find(pick) + 1 + stream.next_range_i(0, ids.size() - 2)) % ids.size()]
	else:
		pick = ids[_next % ids.size()]
		_next += 1

	return maps[pick]


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["maps (%d)" % maps.size()])

	for id in _order:
		var doc: Dictionary = maps[id]
		lines.append("  %-22s %-28s %4d props  %s%s" % [
			id, str(doc["name"]), (doc["props"] as Array).size(), str(doc["author"]),
			"" if in_rotation(id) else "  (not in rotation)",
		])

	if not refused.is_empty():
		lines.append("refused (%d)" % refused.size())

		for file: String in refused:
			lines.append("  %-22s %s" % [file, refused[file]])

	return lines


# --- The one built in -------------------------------------------------------

## A two-room house with a garden: enough furniture to hide among and a door between the rooms.
##
## [b]Written here rather than shipped as a file,[/b] so a server with no map directory at all
## — a fresh clone, a suite — has something to play, and the suites have a map whose every
## number is in front of them. They lean on these: the floor is x -10..10, z -8..8 at y 0; the
## wall between the rooms is at x 0 with a 1.8 m door at z -1..0.8; the seekers start in the
## east room, the hiders in the west; the garden is x 10..22, with its toys.
static func practice() -> Dictionary:
	var boxes: Array = []
	var height := 3.2

	# Floors and ceiling.
	boxes.append({"at": [-5.0, -0.1, 0.0], "size": [10.0, 0.2, 16.0], "mat": "wood_floor"})
	boxes.append({"at": [5.0, -0.1, 0.0], "size": [10.0, 0.2, 16.0], "mat": "carpet"})
	boxes.append({"at": [0.0, height + 0.1, 0.0], "size": [20.0, 0.2, 16.0], "mat": "ceiling"})
	# Outer walls: north, south, west, and the east wall with a door to the garden.
	boxes.append({"at": [0.0, height * 0.5, -8.1], "size": [20.4, height, 0.2], "mat": "paint"})
	boxes.append({"at": [0.0, height * 0.5, 8.1], "size": [20.4, height, 0.2], "mat": "paint"})
	boxes.append({"at": [-10.1, height * 0.5, 0.0], "size": [0.2, height, 16.0], "mat": "paint", "tint": [0.95, 0.9, 0.8]})
	boxes.append({"at": [10.1, height * 0.5, -4.6], "size": [0.2, height, 6.8], "mat": "brick"})
	boxes.append({"at": [10.1, height * 0.5, 4.6], "size": [0.2, height, 6.8], "mat": "brick"})
	boxes.append({"at": [10.1, 2.7, 0.0], "size": [0.2, 1.0, 2.4], "mat": "brick"})
	# The wall between the rooms, with its door at z -1..0.8.
	boxes.append({"at": [0.0, height * 0.5, -4.5], "size": [0.2, height, 7.0], "mat": "paint"})
	boxes.append({"at": [0.0, height * 0.5, 4.4], "size": [0.2, height, 7.2], "mat": "paint"})
	boxes.append({"at": [0.0, 2.7, -0.1], "size": [0.2, 1.0, 1.8], "mat": "paint"})
	# The garden: grass, a fence round it and a path.
	boxes.append({"at": [16.0, -0.1, 0.0], "size": [12.0, 0.2, 16.0], "mat": "grass"})
	boxes.append({"at": [13.0, 0.01, 0.0], "size": [6.0, 0.02, 1.6], "mat": "sidewalk", "solid": false})
	boxes.append({"at": [22.1, 1.0, 0.0], "size": [0.2, 2.0, 16.4], "mat": "wood"})
	boxes.append({"at": [16.0, 1.0, -8.1], "size": [12.0, 2.0, 0.2], "mat": "wood"})
	boxes.append({"at": [16.0, 1.0, 8.1], "size": [12.0, 2.0, 0.2], "mat": "wood"})

	var props: Array = [
		# West room: a living room.
		{"id": "furniture_lounge_sofa", "at": [-7.0, 0.0, -6.8], "yaw": 0.0},
		{"id": "furniture_table_coffee", "at": [-7.0, 0.0, -4.6]},
		{"id": "furniture_lounge_chair", "at": [-9.0, 0.0, -3.0], "yaw": 90.0},
		{"id": "furniture_television_modern", "at": [-7.0, 0.0, -1.0], "yaw": 180.0},
		{"id": "furniture_potted_plant", "at": [-9.3, 0.0, 7.2]},
		{"id": "furniture_bookcase_closed", "at": [-4.0, 0.0, 7.6], "yaw": 180.0},
		{"id": "furniture_lamp_round_floor", "at": [-9.3, 0.0, -7.3]},
		{"id": "furniture_cardboard_box_closed", "at": [-2.0, 0.0, 6.8]},
		{"id": "furniture_cardboard_box_closed", "at": [-2.6, 0.0, 6.2], "yaw": 20.0},
		{"id": "furniture_trashcan", "at": [-1.0, 0.0, -7.4]},
		{"id": "furniture_rug_rectangle", "at": [-7.0, 0.0, -4.2]},
		# East room: a kitchen.
		{"id": "furniture_kitchen_cabinet", "at": [3.0, 0.0, -7.4]},
		{"id": "furniture_kitchen_stove", "at": [4.0, 0.0, -7.4]},
		{"id": "furniture_kitchen_sink", "at": [5.0, 0.0, -7.4]},
		{"id": "furniture_kitchen_fridge", "at": [6.2, 0.0, -7.5]},
		{"id": "furniture_table", "at": [4.5, 0.0, 2.0]},
		{"id": "furniture_chair", "at": [3.6, 0.0, 1.2]},
		{"id": "furniture_chair", "at": [5.4, 0.0, 1.2]},
		{"id": "furniture_chair", "at": [3.6, 0.0, 2.8], "yaw": 180.0},
		{"id": "furniture_chair", "at": [5.4, 0.0, 2.8], "yaw": 180.0},
		{"id": "furniture_kitchen_microwave", "at": [3.0, 1.03, -7.4]},
		{"id": "furniture_washer", "at": [9.3, 0.0, 6.5], "yaw": -90.0},
		{"id": "furniture_dryer", "at": [9.3, 0.0, 5.4], "yaw": -90.0},
		# The garden.
		{"id": "nature_tree_oak", "at": [19.0, 0.0, -5.0]},
		{"id": "nature_plant_bush", "at": [20.5, 0.0, 3.0]},
		{"id": "nature_plant_bush_detailed", "at": [14.0, 0.0, 6.0]},
		{"id": "nature_rock_small_a", "at": [17.0, 0.0, 1.5]},
		{"id": "nature_stump_round", "at": [15.0, 0.0, -6.0]},
		{"id": "nature_crop_pumpkin", "at": [20.8, 0.0, 6.8]},
		{"id": "nature_flower_red_a", "at": [12.0, 0.0, -7.0]},
	]

	# Toys in the garden (dot-props'): balls to kick about, a tyre, and a lamp on a switch by the
	# door. The suites lean on these too: headless_net pushes the beach ball and presses the
	# switch, and checks a client sees both.
	var toys: Array = [
		{"toy": "beach_ball", "at": [16.5, 0.0, -2.5]},
		{"toy": "football", "at": [14.0, 0.0, 3.0]},
		{"toy": "tyre", "at": [18.5, 0.0, 4.5], "yaw": 30.0},
		{"toy": "lamp_post", "at": [13.5, 0.0, -5.0]},
		{"toy": "light_switch", "at": [12.0, 0.0, -3.0], "links": [3]},
	]

	var source := {
		"format": HsMapDoc.FORMAT,
		"kind": HsMapDoc.KIND,
		"id": String(PRACTICE),
		"name": "Practice House",
		"author": "game-hide-n-seek",
		"blurb": "Two rooms and a garden.",
		"boxes": boxes,
		"props": props,
		"toys": toys,
		"lights": [
			{"at": [-5.0, 2.8, 0.0], "range": 9.0, "energy": 0.9},
			{"at": [5.0, 2.8, 0.0], "range": 9.0, "energy": 0.9},
		],
		# The door between the rooms stands open and the garden door is shut: the one a hider
		# shuts behind them, and the one a bot has to open to get out.
		"doors": [
			{"at": [0.0, 1.1, -0.1], "size": [1.77, 2.18, 0.06], "yaw": 90.0, "hinge": "right",
				"angle": 100.0, "open": true, "name": "kitchen door"},
			{"at": [10.1, 1.1, 0.0], "size": [2.37, 2.18, 0.06], "yaw": 90.0, "hinge": "right",
				"angle": 100.0, "name": "garden door", "tint": [0.3, 0.42, 0.32]},
		],
		"spawns": {
			"hiders": [
				{"at": [-5.0, 0.1, 0.0], "yaw": 90.0}, {"at": [-6.0, 0.1, 2.0], "yaw": 90.0},
				{"at": [-4.0, 0.1, -2.0], "yaw": 90.0}, {"at": [-6.0, 0.1, 4.0], "yaw": 90.0},
				{"at": [-4.0, 0.1, 2.0], "yaw": 90.0}, {"at": [-6.0, 0.1, -2.0], "yaw": 90.0},
			],
			"seekers": [
				{"at": [7.0, 0.1, 0.0], "yaw": 90.0}, {"at": [7.0, 0.1, -2.0], "yaw": 90.0},
				{"at": [7.0, 0.1, 2.0], "yaw": 90.0},
			],
		},
	}

	var normalised := HsMapDoc.validate(source)
	return normalised.value if normalised.ok else {}

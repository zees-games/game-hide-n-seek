extends RefCounted

const HsMaterials := preload("hs_materials.gd")

## What a map IS: a JSON document, checked here before anything is built.
## A document, not a scene: a few tens of kilobytes the server reads off disk and SENDS to each client, so a client needs no map files, a new map is a dropped file, and the two ends cannot disagree about a wall. Contents: boxes, props (by catalogue id), lights, doors (see HsDoors), optional `terrain`, the two sides' spawns, and the sky and sun. Metres and degrees; a box's `at` is its CENTRE, a prop's the middle of its footprint ON the floor.
## Normalised into plain arrays, never vectors, rounded to the millimetre once: float32 components come back out of JSON as `0.300000011920929`, doubling the bytes and moving the digest. `maps/README.md` in hide-n-seek-maps is the mapper's copy.


## The format this build reads. A document written for a later one is refused rather than
## half-built.
const FORMAT := 1

const KIND := "hideseek_map"

const CHANNEL := "hs.map"

## The most one MAP message carries, compressed. A WebSocket's outbound buffer is sixty-four kilobytes and a message past it is never sent (mg-look-at-me's finding), so a larger map goes
## as MAP_PART messages of at most this many bytes each (the bridge's `_map_messages`). Not a limit on a map: a document of any size is sent.
const PART_BYTES := 60000

## How many of each thing a document may hold, 0 for no limit (the default for every one). Settings, not constants: `HsConfig.max_map_*` (`max_map_boxes` ... in config_maps/game.yml), applied by
## [method apply_limits] when the game starts. A document over a set limit is refused with the count, never cut down. What a big map costs to draw and send is its author's choice.
static var max_boxes: int = 0
static var max_props: int = 0
static var max_lights: int = 0
static var max_spawns: int = 0
static var max_doors: int = 0
static var max_toys: int = 0
## Past this many lights a document is still read, with a warning in the log: every light is
## drawn, and the Compatibility renderer lights a mesh with at most eight. 0 is no warning.
static var lights_warn: int = 128

## What a map's building surfaces are drawn as: the pastel grid (the default) or photographic PBR.
const LOOKS := ["pastel", "pbr"]

## How a door moves: about a hinge at one edge, sideways into the wall, or up like a shutter.
const DOOR_MOTIONS := ["swing", "slide", "lift"]

## Every top-level field, and what a missing one becomes.
const DEFAULT_ENV := {
	"sky_top": [0.32, 0.52, 0.82],
	"sky_horizon": [0.72, 0.82, 0.92],
	"ground": [0.35, 0.33, 0.30],
	"sun_pitch": -55.0,
	"sun_yaw": 30.0,
	"sun_energy": 1.1,
	"sun_colour": [1.0, 0.96, 0.88],
	"ambient": [0.62, 0.66, 0.72],
	"ambient_energy": 0.55,
	"fog": 0.0,
}


## Reads a document from JSON text, and checks it.
static func parse_json(text: String, origin: String = "") -> GSResult:
	var json := JSON.new()

	if json.parse(text) != OK:
		return GSResult.fail(
			GSError.CODE_PARSE, "The map is not JSON.",
			"%s line %d: %s" % [origin, json.get_error_line(), json.get_error_message()]
		)

	if typeof(json.data) != TYPE_DICTIONARY:
		return GSResult.fail(GSError.CODE_PARSE, "The map is not a JSON object.", origin)

	return validate(json.data as Dictionary)


## Checks a document and returns a normalised copy of it: every optional field present, every
## position three numbers.
static func validate(source: Dictionary) -> GSResult:
	if int(source.get("format", 0)) != FORMAT:
		return _refuse("format is %s; this build reads %d" % [str(source.get("format")), FORMAT], source)

	if str(source.get("kind", "")) != KIND:
		return _refuse("kind is '%s', not '%s'" % [str(source.get("kind", "")), KIND], source)

	var id := str(source.get("id", ""))

	if not _is_id(id):
		return _refuse("id '%s' is not lower-case letters, digits and underscores" % id, source)

	var doc := {
		"format": FORMAT,
		"kind": KIND,
		"id": id,
		"name": str(source.get("name", id)),
		"author": str(source.get("author", "")),
		"blurb": str(source.get("blurb", "")),
		"round_seconds": maxf(float(source.get("round_seconds", 0.0)), 0.0),
		"hide_seconds": maxf(float(source.get("hide_seconds", 0.0)), 0.0),
		"seeker_pace": clampf(float(source.get("seeker_pace", 0.0)), 0.0, 1.0),
		"players_per_seeker": maxf(float(source.get("players_per_seeker", 0.0)), 0.0),
		"kill_y": float(source.get("kill_y", -30.0)),
	}

	var env := DEFAULT_ENV.duplicate(true)
	var given: Variant = source.get("environment", {})

	if given is Dictionary:
		for key: String in DEFAULT_ENV:
			if (given as Dictionary).has(key):
				var value: Variant = (given as Dictionary)[key]
				env[key] = _floats(value, 3) if DEFAULT_ENV[key] is Array else float(value)

	doc["environment"] = env

	var boxes: Array = []
	for raw: Variant in source.get("boxes", []):
		var box := _box(raw)
		if box.is_empty():
			return _refuse("box %d is not {at, size, mat}" % boxes.size(), source)
		boxes.append(box)

	if _over(boxes.size(), max_boxes):
		return _refuse("%d boxes; this server takes at most %d (max_map_boxes, 0 = no limit)" % [boxes.size(), max_boxes], source)

	doc["boxes"] = boxes

	# A converted map's displacement ground (dot-map's heightfield), which the boxes cannot be: a
	# stepped field stops a walker at the first hill. `tint` is the colour it is drawn in.
	if source.has("terrain"):
		if not (source["terrain"] is Dictionary):
			return _refuse("terrain is not a dictionary", source)
		var ground := GSMapTerrain.from_dict(source["terrain"])
		if not ground.ok:
			return _refuse("terrain: %s" % str(ground), source)
		var raw_ground: Dictionary = (source["terrain"] as Dictionary).duplicate()
		raw_ground["tint"] = _floats(raw_ground.get("tint", [1.0, 1.0, 1.0]), 3)
		doc["terrain"] = raw_ground

	# "pbr" draws the building surfaces with dot-map's photographic kinds (HsMaterials.PBR_KINDS) instead of the pastel grid.
	if source.has("look"):
		if not (str(source["look"]) in LOOKS):
			return _refuse("look is not one of %s" % [LOOKS], source)
		doc["look"] = str(source["look"])

	# The converted world pack a client may draw in place of the boxes (HsMap.load_world): never collision, so a server ignores it.
	if source.has("world"):
		var w: Variant = source["world"]
		if not (w is Dictionary) or not _is_id(str((w as Dictionary).get("pack", ""))) \
				or float((w as Dictionary).get("metres_per_unit", 0.0)) <= 0.0:
			return _refuse("world is not {pack, metres_per_unit, offset}", source)
		doc["world"] = {
			"pack": str(w["pack"]),
			"metres_per_unit": float(w["metres_per_unit"]),
			"offset": _floats((w as Dictionary).get("offset", [0, 0, 0]), 3),
		}

	var props: Array = []
	for raw: Variant in source.get("props", []):
		var prop := _prop(raw)
		if prop.is_empty():
			return _refuse("prop %d is not {id, at}" % props.size(), source)
		props.append(prop)

	if _over(props.size(), max_props):
		return _refuse("%d props; this server takes at most %d (max_map_props, 0 = no limit)" % [props.size(), max_props], source)

	doc["props"] = props

	var bad := _lights(source, doc)

	if bad != "":
		return _refuse(bad, source)

	var doors: Array = []
	for raw: Variant in source.get("doors", []):
		var door := _door(raw)
		if door.is_empty():
			return _refuse("door %d is not {at, size} with a known motion" % doors.size(), source)
		doors.append(door)

	if _over(doors.size(), max_doors):
		return _refuse("%d doors; this server takes at most %d (max_map_doors, 0 = no limit)" % [doors.size(), max_doors], source)

	doc["doors"] = doors

	bad = _toys(source, doc)

	if bad != "":
		return _refuse(bad, source)

	bad = _spawns(source, doc)

	if bad != "":
		return _refuse(bad, source)

	return GSResult.success(doc)


static func _lights(source: Dictionary, out: Dictionary) -> String:
	var lights: Array = []
	for raw: Variant in source.get("lights", []):
		if not (raw is Dictionary) or not (raw as Dictionary).has("at"):
			return "light %d has no 'at'" % lights.size()
		var light := raw as Dictionary
		lights.append({
			"at": _floats(light["at"], 3),
			"range": clampf(float(light.get("range", 8.0)), 0.5, 80.0),
			"energy": clampf(float(light.get("energy", 1.0)), 0.0, 16.0),
			"colour": _floats(light.get("colour", [1.0, 0.95, 0.85]), 3),
		})

	if _over(lights.size(), max_lights):
		return "%d lights; this server takes at most %d (max_map_lights, 0 = no limit)" % [lights.size(), max_lights]

	if _over(lights.size(), lights_warn):
		GSLog.warn(CHANNEL, "a map has more lights than the warning level; each one costs every frame", {
			"map": str(source.get("id", "?")), "lights": lights.size(), "warn_at": lights_warn,
		})

	out["lights"] = lights
	return ""


static func _toys(source: Dictionary, out: Dictionary) -> String:
	# Toys: dot-props' GSPropBodyBox placements, `{toy, at, yaw, links?, on?}`. Which ids exist
	# is the catalogue's to say when the map is built (an unknown one is left out and listed),
	# so a map with a toy a newer dot-props has still plays on an older server.
	var toys: Array = []
	for raw: Variant in source.get("toys", []):
		var toy := GSPropBodyBox.normal_placement(raw)
		if toy.is_empty():
			return "toy %d is not {toy, at}" % toys.size()
		toys.append(toy)

	if _over(toys.size(), max_toys):
		return "%d toys; this server takes at most %d (max_map_toys, 0 = no limit)" % [toys.size(), max_toys]

	for toy: Dictionary in toys:
		for link: int in toy.get("links", []):
			if link < 0 or link >= toys.size():
				return "a %s links to toy %d, and there are %d" % [toy["toy"], link, toys.size()]

	out["toys"] = toys
	return ""


static func _spawns(source: Dictionary, out: Dictionary) -> String:
	var spawns: Variant = source.get("spawns", {})
	if not (spawns is Dictionary):
		return "'spawns' is not {hiders, seekers}"

	var out_spawns := {}
	for side in ["hiders", "seekers"]:
		var list: Array = []
		for raw: Variant in (spawns as Dictionary).get(side, []):
			if not (raw is Dictionary) or not (raw as Dictionary).has("at"):
				return "a %s spawn has no 'at'" % side
			list.append({"at": _floats((raw as Dictionary)["at"], 3), "yaw": _r(float((raw as Dictionary).get("yaw", 0.0)))})
		if list.is_empty():
			return "no spawns for the %s" % side
		if _over(list.size(), max_spawns):
			return "%d %s spawns; this server takes at most %d (max_map_spawns, 0 = no limit)" % [list.size(), side, max_spawns]
		out_spawns[side] = list

	out["spawns"] = out_spawns
	return ""


static func _box(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}

	var b := raw as Dictionary

	if not b.has("at") or not b.has("size"):
		return {}

	var size := _floats(b["size"], 3)

	if size[0] <= 0.0 or size[1] <= 0.0 or size[2] <= 0.0:
		return {}

	var mat := str(b.get("mat", "flat"))

	if not HsMaterials.has(mat):
		mat = "flat"

	var out := {"at": _floats(b["at"], 3), "size": size, "mat": mat}

	if float(b.get("yaw", 0.0)) != 0.0:
		out["yaw"] = _r(float(b["yaw"]))

	if b.has("tint"):
		out["tint"] = _floats(_colour_list(b["tint"]), 3)

	# Solid unless the map says not: water, a light's glow, a line painted on a floor.
	if b.has("solid") and not bool(b["solid"]):
		out["solid"] = false

	# Drawn unless the map says not: an invisible wall that keeps people in the map.
	if b.has("visible") and not bool(b["visible"]):
		out["visible"] = false

	return out


static func _prop(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}

	var p := raw as Dictionary

	if not p.has("id") or not p.has("at"):
		return {}

	var out := {"id": str(p["id"]), "at": _floats(p["at"], 3)}

	for angle in ["yaw", "pitch", "roll"]:
		if float(p.get(angle, 0.0)) != 0.0:
			out[angle] = _r(float(p[angle]))

	return out


## A door: a panel a player opens and shuts with the use key. `at` is the middle of the panel SHUT, `size` its width, height and thickness, turned by `yaw`.
## It swings about its `hinge` edge by `angle` degrees (the sign is the side it opens to), slides by its width, or lifts by its height. Every field but `at` and `size` has a default.
static func _door(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		return {}

	var d := raw as Dictionary

	if not d.has("at") or not d.has("size"):
		return {}

	var size := _floats(d["size"], 3)

	if size[0] <= 0.0 or size[1] <= 0.0 or size[2] <= 0.0:
		return {}

	var motion := str(d.get("motion", "swing"))

	if not DOOR_MOTIONS.has(motion):
		return {}

	var hinge := str(d.get("hinge", "left"))
	var mat := str(d.get("mat", "wood"))

	if not HsMaterials.has(mat):
		mat = "wood"

	var out := {
		"at": _floats(d["at"], 3),
		"size": size,
		"yaw": _r(float(d.get("yaw", 0.0))),
		"motion": motion,
		"hinge": "right" if hinge == "right" else "left",
		"angle": _r(clampf(float(d.get("angle", 100.0)), -170.0, 170.0)),
		"seconds": _r(clampf(float(d.get("seconds", 0.6)), 0.1, 5.0)),
		# How far a slide or a lift goes, in metres; 0 is all the way (its width, its height).
		"travel": _r(clampf(float(d.get("travel", 0.0)), 0.0, 50.0)),
		"open": bool(d.get("open", false)),
		# A swinging door opens away from whoever opens it, unless the map pins its way.
		"away": bool(d.get("away", true)),
		"mat": mat,
		"tint": _floats(_colour_list(d.get("tint", [1.0, 1.0, 1.0])), 3),
		"name": str(d.get("name", "")),
		# A secret door has no handle and is drawn in the wall's own material, so it reads as
		# wall until somebody tries it.
		"secret": bool(d.get("secret", false)),
	}

	return out


## A normalised document as bytes: JSON, deflated, behind both its lengths.
static func encode(doc: Dictionary) -> PackedByteArray:
	return GSWireDoc.encode(doc)


static func decode(bytes: PackedByteArray) -> GSResult:
	var text := GSWireDoc.decode_text(bytes, "map")
	if not text.ok:
		return text
	return parse_json(text.value, "wire")


## A short fingerprint of a document, for a log line and for two ends to compare.
static func digest(doc: Dictionary) -> String:
	return GSWireDoc.digest(doc)



static func v3(value: Variant) -> Vector3:
	if value is Vector3:
		return value

	if typeof(value) == TYPE_ARRAY and (value as Array).size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))

	return Vector3.ZERO


static func colour(value: Variant, fallback: Color = Color.WHITE) -> Color:
	if typeof(value) == TYPE_ARRAY and (value as Array).size() >= 3:
		return Color(float(value[0]), float(value[1]), float(value[2]))

	return fallback


static func _floats(value: Variant, count: int) -> Array:
	var out: Array = []

	if value is Vector3:
		value = [value.x, value.y, value.z]

	if typeof(value) == TYPE_ARRAY:
		for i in range(count):
			out.append(_r(float((value as Array)[i]) if i < (value as Array).size() else 0.0))
	else:
		for i in range(count):
			out.append(0.0)

	return out


static func _colour_list(value: Variant) -> Array:
	if typeof(value) == TYPE_STRING and Color.html_is_valid(str(value)):
		var c := Color.html(str(value))
		return [c.r, c.g, c.b]

	return value if typeof(value) == TYPE_ARRAY else [1.0, 1.0, 1.0]


## Millimetres, as a double JSON prints short.
static func _r(value: float) -> float:
	return snappedf(value, 0.001)


static func _is_id(id: String) -> bool:
	if id.is_empty() or id.length() > 48:
		return false

	for character in id:
		if not (character >= "a" and character <= "z") and not (character >= "0" and character <= "9") \
				and character != "_":
			return false

	return true


## Whether [param count] is past [param limit], where a limit of 0 or less is none.
static func _over(count: int, limit: int) -> bool:
	return limit > 0 and count > limit


## Sets the document limits from a config's `max_map_*` fields (0 = no limit). Static, so every
## document read in this process after it (catalogue, wire, tests) is held to the same.
static func apply_limits(config: Object) -> void:
	max_boxes = int(config.get("max_map_boxes"))
	max_props = int(config.get("max_map_props"))
	max_lights = int(config.get("max_map_lights"))
	max_spawns = int(config.get("max_map_spawns"))
	max_doors = int(config.get("max_map_doors"))
	max_toys = int(config.get("max_map_toys"))
	lights_warn = int(config.get("map_lights_warn"))


static func _refuse(why: String, doc: Dictionary) -> GSResult:
	return GSResult.fail(
		GSError.CODE_INVALID, "The map is refused: %s." % why, str(doc.get("id", "?"))
	)

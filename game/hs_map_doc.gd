extends RefCounted

const HsMaterials := preload("hs_materials.gd")

## What a map IS: a JSON document, checked here before anything is built.
##
## [b]A map is a document, not a scene[/b], for mg-wipeout's reason, which every map-driven game
## in this family has taken since: a scene per map is content to import, to rebase inside a
## mounted pack and to keep in step across a server and every client; a document is a few tens
## of kilobytes the server reads off disk and SENDS to each client when the map changes. A
## client needs no map files, a server gets a new map by having a file dropped in a directory,
## and the two ends cannot disagree about where a wall or a chair is, because there is one copy
## and it travelled.
##
## [b]What is in one:[/b] boxes (the building: floors, walls, ceilings, glass, a pool), props
## (the furniture a player hides among and as, by catalogue id), lights, the two sides' spawns,
## and how the sky and the sun look. Every length is metres, every angle degrees. A box's `at`
## is its CENTRE; a prop's `at` is the middle of its footprint ON the floor, so a mapper places
## a chair by where it stands.
##
## [b]Normalised into plain arrays, never vectors.[/b] What a server encodes is what this
## returned, and a vector's float32 components come back out of JSON as `0.300000011920929`:
## twice the bytes for a map of a thousand boxes and a document whose digest moves when nothing
## did. Rounded to the millimetre here, once.
##
## `maps/README.md` in hide-n-seek-maps is the mapper's copy of this.


## The format this build reads. A document written for a later one is refused rather than
## half-built.
const FORMAT := 1

const KIND := "hideseek_map"

## The largest a document may be on the wire, compressed. A WebSocket's outbound buffer is
## sixty-four kilobytes and a message past it is never sent (mg-look-at-me's finding), so a map
## must fit with room for the header.
const WIRE_LIMIT := 60000

const MAX_BOXES := 6000
const MAX_PROPS := 2000
const MAX_LIGHTS := 128
const MAX_SPAWNS := 64

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
static func parse_json(text: String, origin: String = "") -> DotResult:
	var json := JSON.new()

	if json.parse(text) != OK:
		return DotResult.fail(
			DotError.CODE_PARSE, "The map is not JSON.",
			"%s line %d: %s" % [origin, json.get_error_line(), json.get_error_message()]
		)

	if typeof(json.data) != TYPE_DICTIONARY:
		return DotResult.fail(DotError.CODE_PARSE, "The map is not a JSON object.", origin)

	return validate(json.data as Dictionary)


## Checks a document and returns a normalised copy of it: every optional field present, every
## position three numbers.
static func validate(source: Dictionary) -> DotResult:
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

	if boxes.size() > MAX_BOXES:
		return _refuse("%d boxes; the most is %d" % [boxes.size(), MAX_BOXES], source)

	doc["boxes"] = boxes

	var props: Array = []
	for raw: Variant in source.get("props", []):
		var prop := _prop(raw)
		if prop.is_empty():
			return _refuse("prop %d is not {id, at}" % props.size(), source)
		props.append(prop)

	if props.size() > MAX_PROPS:
		return _refuse("%d props; the most is %d" % [props.size(), MAX_PROPS], source)

	doc["props"] = props

	var lights: Array = []
	for raw: Variant in source.get("lights", []):
		if not (raw is Dictionary) or not (raw as Dictionary).has("at"):
			return _refuse("light %d has no 'at'" % lights.size(), source)
		var light := raw as Dictionary
		lights.append({
			"at": _floats(light["at"], 3),
			"range": clampf(float(light.get("range", 8.0)), 0.5, 80.0),
			"energy": clampf(float(light.get("energy", 1.0)), 0.0, 16.0),
			"colour": _floats(light.get("colour", [1.0, 0.95, 0.85]), 3),
		})

	if lights.size() > MAX_LIGHTS:
		return _refuse("%d lights; the most is %d" % [lights.size(), MAX_LIGHTS], source)

	doc["lights"] = lights

	var spawns: Variant = source.get("spawns", {})
	if not (spawns is Dictionary):
		return _refuse("'spawns' is not {hiders, seekers}", source)

	var out_spawns := {}
	for side in ["hiders", "seekers"]:
		var list: Array = []
		for raw: Variant in (spawns as Dictionary).get(side, []):
			if not (raw is Dictionary) or not (raw as Dictionary).has("at"):
				return _refuse("a %s spawn has no 'at'" % side, source)
			list.append({"at": _floats((raw as Dictionary)["at"], 3), "yaw": _r(float((raw as Dictionary).get("yaw", 0.0)))})
		if list.is_empty():
			return _refuse("no spawns for the %s" % side, source)
		if list.size() > MAX_SPAWNS:
			return _refuse("%d %s spawns; the most is %d" % [list.size(), side, MAX_SPAWNS], source)
		out_spawns[side] = list

	doc["spawns"] = out_spawns
	return DotResult.success(doc)


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


## A normalised document as bytes: JSON, deflated, behind both its lengths.
static func encode(doc: Dictionary) -> PackedByteArray:
	var raw := JSON.stringify(doc, "", false).to_utf8_buffer()
	var packed := raw.compress(FileAccess.COMPRESSION_DEFLATE)

	var out := PackedByteArray()
	out.resize(8)
	out.encode_u32(0, raw.size())
	out.encode_u32(4, packed.size())
	out.append_array(packed)
	return out


static func decode(bytes: PackedByteArray) -> DotResult:
	if bytes.size() < 9:
		return DotResult.fail(DotError.CODE_PARSE, "A map on the wire was empty.")

	var size := bytes.decode_u32(0)

	if bytes.decode_u32(4) != bytes.size() - 8:
		return DotResult.fail(DotError.CODE_PARSE, "A map on the wire is not the length it says.")

	# A size this large is a corrupt header; decompressing it would allocate whatever it says.
	if size <= 0 or size > WIRE_LIMIT * 40:
		return DotResult.fail(DotError.CODE_PARSE, "A map on the wire says it is %d bytes." % size)

	var raw := bytes.slice(8).decompress(size, FileAccess.COMPRESSION_DEFLATE)

	if raw.size() != size:
		return DotResult.fail(DotError.CODE_PARSE, "A map on the wire would not decompress.")

	return parse_json(raw.get_string_from_utf8(), "wire")


## A short fingerprint of a document, for a log line and for two ends to compare.
static func digest(doc: Dictionary) -> String:
	return JSON.stringify(doc, "", true).sha256_text().substr(0, 12)


# --- Small readers ----------------------------------------------------------

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


static func _refuse(why: String, doc: Dictionary) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INVALID, "The map is refused: %s." % why, str(doc.get("id", "?"))
	)

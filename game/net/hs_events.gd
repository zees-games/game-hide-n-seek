extends RefCounted

const HsGame := preload("../hs_game.gd")

## The wire format for everything that is not a snapshot or an input.
## Encoders and decoders in pairs that nothing checks are inverses, so `headless_net` round-trips every one (dot-moderation once wrote `"voice muted"` and read back a warning).
## The map travels whole: `MAP` carries the normalised document deflated (see [HsMapDoc]), so a client needs no map files; after that only sides and taunts change.

enum Kind {
	## Who you are, how fast the server ticks, and how long each part of a round is.
	HELLO,
	## The map, as a document. Build it from this.
	MAP,
	## A player is in the world: net id, name, side, face.
	JOIN,
	LEAVE,
	## A player changed sides: the draw at the top of a round.
	TEAM,
	## The round clock and the numbers a client cannot count for itself.
	CLOCK,
	## A round began or ended, and who won.
	ROUND,
	## The round moved on: hiding, seeking.
	PHASE,
	## Somebody is out, and what did it.
	DEATH,
	## Text for one player.
	NOTICE,
	## One routed chat line.
	CHAT,
	## What this one player's camera is on now that they are out. To its owner only.
	SPECTATE,
	## Somebody taunted: which taunt, and whether it was forced on them.
	TAUNT,
	## A hider was caught: by whom (0 for a fall), and how. The side change follows as a TEAM.
	CAUGHT,
	## A door set off: which, which way, and the tick it went. A joiner is sent one per door
	## that has moved this round.
	DOOR,
	## The map's toys' net ids in toy order, then the map's id (both ends build the toys in the
	## same order from the map). Sent after MAP, and to a joiner after theirs; a client registers
	## them whether it has that map or not, and pairs them when it does.
	TOYS,
}

enum Ask {
	## I have built my world and can receive. Tell me everything in it.
	READY,
	## I typed a line. The server decides what channel it lands on and who hears it.
	SAY,
	## I am out: show me the next person, the previous one, or the other camera.
	SPECTATE,
	## Taunt: one by index, or any.
	TAUNT,
	## I am out: take me into the free camera, or back onto a player from it.
	ROAM,
}

## Every decoder returns an `ok` beside its fields, and every caller checks it.
## A reader past its end returns plausible zeros rather than failing (dot-net's exhaustion was not sticky), so a truncated packet would decode as a valid message about nothing.
const NAME_BYTES := 64
const ID_BYTES := 64
const TEXT_BYTES := 256

## The largest map a reader accepts: [HsMapDoc.WIRE_LIMIT] and its header.
const MAP_BYTES := 65536 + 16

## The most an avatar document may take in a JOIN. One slot is about eighty bytes; the rest
## is room for slots this game does not have yet, and a cap that a hostile document cannot
## talk its way past.
const AVATAR_BYTES := 1024

## Where a body may be, in metres, on the wire.
## Read from [HsGame], not written here: a quantised position decoded against a different range lands somewhere else, not just less precisely.
const WORLD_EXTENT := HsGame.NET_WORLD_EXTENT
const POS_BITS := 24

## The round clock, in seconds. Well past anything the configuration allows, because the
## extra bit is cheaper than the bug of a clock that wraps.
const CLOCK_MAX := 1800.0
const CLOCK_BITS := 15

## A side, which is 1 or 2, in three bits so a third side is not a change to the wire.
const TEAM_BITS := 3

## Phases, three bits: three of them and room for five more.
const PHASE_BITS := 3


static func kind_name(kind: int) -> String:
	var names := Kind.keys()
	return String(names[kind]) if kind >= 0 and kind < names.size() else "?"


static func ask_name(ask: int) -> String:
	var names := Ask.keys()
	return String(names[ask]) if ask >= 0 and ask < names.size() else "?"


static func _w() -> DotNetWriter:
	return DotNetWriter.new()



static func write_hello(
	player_id: int,
	tick_rate: int,
	server_tick: int,
	hide_seconds: float,
	round_seconds: float,
	beacon_period: float,
	taunt_range: float
) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_uint(tick_rate, 9)
	w.write_varint(server_tick)
	w.write_float_range(hide_seconds, 0.0, 300.0, 14)
	w.write_float_range(round_seconds, 0.0, CLOCK_MAX, CLOCK_BITS)
	w.write_float_range(beacon_period, 0.0, 10.0, 10)
	w.write_float_range(taunt_range, 0.0, 400.0, 12)
	return w.to_bytes()


static func read_hello(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var tick_rate := r.read_uint(9)
	var server_tick := r.read_varint()
	var hide_seconds := r.read_float_range(0.0, 300.0, 14)
	var round_seconds := r.read_float_range(0.0, CLOCK_MAX, CLOCK_BITS)
	var beacon_period := r.read_float_range(0.0, 10.0, 10)
	var taunt_range := r.read_float_range(0.0, 400.0, 12)
	return {
		"player_id": player_id,
		"tick_rate": tick_rate,
		"server_tick": server_tick,
		"hide_seconds": hide_seconds,
		"round_seconds": round_seconds,
		"beacon_period": beacon_period,
		"taunt_range": taunt_range,
		"ok": r.ok(),
	}



## The map: [HsMapDoc.encode]'s bytes, as they are.
## Opaque here and validated at the other end, so a document this build cannot read is refused with a sentence rather than half built.
static func write_map(encoded: PackedByteArray) -> PackedByteArray:
	var w := _w()
	w.write_bytes(encoded)
	return w.to_bytes()


static func read_map(r: DotNetReader) -> Dictionary:
	var encoded := r.read_bytes(MAP_BYTES)
	return {"encoded": encoded, "ok": r.ok() and not encoded.is_empty()}



## A join, or a change to who somebody is: their name, their side, their avatar.
## The avatar is the document (JSON, capped at [constant AVATAR_BYTES], empty for the stock person), not a skin index, so a slot added later needs no new wire. Appended, never inserted: a field before it would move the team for every reader of the old layout.
static func write_join(
	player_id: int, net_id: int, display_name: String, team: int,
	avatar: DotAvatar = null
) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(net_id)
	w.write_string(display_name, NAME_BYTES)
	w.write_varint(maxi(team, 0))
	w.write_string(JSON.stringify(avatar.to_dict()) if avatar != null else "", AVATAR_BYTES)
	return w.to_bytes()


static func read_join(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var net_id := r.read_varint()
	var display_name := r.read_string(NAME_BYTES)
	var team := r.read_varint()
	var text := r.read_string(AVATAR_BYTES)
	var avatar: DotAvatar = null

	# A document that does not parse is the stock person, not a refused join: an avatar is
	# cosmetic, and somebody who cannot be drawn as themselves can still be drawn.
	if text != "":
		var parsed: Variant = JSON.parse_string(text)

		if parsed is Dictionary:
			var built := DotAvatar.from_dict(parsed)

			if built.ok:
				avatar = built.value

	return {
		"player_id": player_id,
		"net_id": net_id,
		"name": display_name,
		"team": team,
		"avatar": avatar,
		"ok": r.ok(),
	}


static func write_player(player_id: int) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	return w.to_bytes()


static func read_player(r: DotNetReader) -> int:
	return r.read_varint()


static func write_team(player_id: int, team: int) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(maxi(team, 0))
	return w.to_bytes()


static func read_team(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var team := r.read_varint()
	return {"player_id": player_id, "team": team, "ok": r.ok()}


## [param death] is how the body falls (dot-player-char's [DotPlayerDeath], the server's pick),
## last and optional, so every client draws the same fall and an older one reads the rest.
static func write_death(player_id: int, by: int, why: StringName, death: DotPlayerDeath = null) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(by)
	w.write_string(String(why), ID_BYTES)
	if death != null:
		death.write_to(w)
	return w.to_bytes()


static func read_death(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var by := r.read_varint()
	var why := r.read_string(ID_BYTES)
	var out := {"player_id": player_id, "by": by, "why": StringName(why)}
	# A byte or more left is the fall; less is the padding to the last byte.
	if r.bits_remaining() >= 8:
		out["death"] = DotPlayerDeath.read_from(r)
	out["ok"] = r.ok()
	return out



## The clock, and the numbers a client cannot count for itself.
## `seek_elapsed` is the seekers' clock, which a client shows; the phase's own clock restarts at every phase.
static func write_clock(
	round_number: int,
	elapsed: float,
	seek_elapsed: float,
	phase: int,
	hiders_left: int,
	seekers_left: int,
	playable: bool
) -> PackedByteArray:
	var w := _w()
	w.write_varint(round_number)
	w.write_float_range(clampf(elapsed, 0.0, CLOCK_MAX), 0.0, CLOCK_MAX, CLOCK_BITS)
	w.write_float_range(clampf(seek_elapsed, 0.0, CLOCK_MAX), 0.0, CLOCK_MAX, CLOCK_BITS)
	w.write_uint(clampi(phase, 0, 7), PHASE_BITS)
	w.write_uint(clampi(hiders_left, 0, 255), 8)
	w.write_uint(clampi(seekers_left, 0, 255), 8)
	w.write_bool(playable)
	return w.to_bytes()


static func read_clock(r: DotNetReader) -> Dictionary:
	var round_number := r.read_varint()
	var elapsed := r.read_float_range(0.0, CLOCK_MAX, CLOCK_BITS)
	var seek_elapsed := r.read_float_range(0.0, CLOCK_MAX, CLOCK_BITS)
	var phase := r.read_uint(PHASE_BITS)
	var hiders_left := r.read_uint(8)
	var seekers_left := r.read_uint(8)
	var playable := r.read_bool()
	return {
		"round": round_number,
		"elapsed": elapsed,
		"seek_elapsed": seek_elapsed,
		"phase": phase,
		"hiders": hiders_left,
		"seekers": seekers_left,
		"playable": playable,
		"ok": r.ok(),
	}


## A round began or ended. [param winner] is a side, or 0 for a draw, and [param why] the
## sentence the server decided it with, which is what the HUD prints.
static func write_round(number: int, began: bool, winner: int, why: String = "") -> PackedByteArray:
	var w := _w()
	w.write_varint(number)
	w.write_bool(began)
	w.write_varint(maxi(winner, 0))
	w.write_string(why, TEXT_BYTES)
	return w.to_bytes()


static func read_round(r: DotNetReader) -> Dictionary:
	var number := r.read_varint()
	var began := r.read_bool()
	var winner := r.read_varint()
	var why := r.read_string(TEXT_BYTES)
	return {"round": number, "began": began, "winner": winner, "why": why, "ok": r.ok()}


static func write_phase(phase: int) -> PackedByteArray:
	var w := _w()
	w.write_uint(clampi(phase, 0, 7), PHASE_BITS)
	return w.to_bytes()


static func read_phase(r: DotNetReader) -> Dictionary:
	var phase := r.read_uint(PHASE_BITS)
	return {"phase": phase, "ok": r.ok()}



## A view dot-spectate decided, for the one player it belongs to.
## The death position travels, or a mirror puts every death camera at the world origin, under the floor. The event is bit-packed and keyed by session (zero is nobody), where dot-spectate's is a string-keyed dictionary.
static func write_spectate(
	viewer: int, mode: int, target: int, killer: int, death_at: Vector3
) -> PackedByteArray:
	var w := _w()
	w.write_varint(viewer)
	w.write_uint(clampi(mode, 0, 7), 3)
	w.write_varint(maxi(target, 0))
	w.write_varint(maxi(killer, 0))
	w.write_vector3_range(death_at, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	return w.to_bytes()


static func read_spectate(r: DotNetReader) -> Dictionary:
	var viewer := r.read_varint()
	var mode := r.read_uint(3)
	var target := r.read_varint()
	var killer := r.read_varint()
	var death_at := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	return {
		"viewer": viewer, "mode": mode, "target": target, "killer": killer,
		"death_at": death_at, "ok": r.ok(),
	}


## Next (+1), previous (-1), or the other camera (0).
static func write_ask_spectate(direction: int) -> PackedByteArray:
	var w := _w()
	w.write_uint(clampi(direction, -1, 1) + 1, 2)
	return w.to_bytes()


static func read_ask_spectate(r: DotNetReader) -> Dictionary:
	var raw := r.read_uint(2)
	return {"direction": clampi(raw, 0, 2) - 1, "ok": r.ok()}


## The free-roam key. No payload: the server knows which mode the sender is in.
static func write_ask_roam() -> PackedByteArray:
	return PackedByteArray([0])



## A taunt: who, which (by its id in the taunt list both ends read), and whether forced.
static func write_taunt(player_id: int, taunt_id: StringName, forced: bool) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_string(String(taunt_id), ID_BYTES)
	w.write_bool(forced)
	return w.to_bytes()


static func read_taunt(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var taunt_id := r.read_string(ID_BYTES)
	var forced := r.read_bool()
	return {"player_id": player_id, "taunt_id": StringName(taunt_id), "forced": forced, "ok": r.ok()}


## A catch: who, by whom (0 for a fall), and how ([constant HsGame.CAUGHT_TAG] and the rest).
static func write_caught(player_id: int, by: int, how: StringName) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(maxi(by, 0))
	w.write_string(String(how), ID_BYTES)
	return w.to_bytes()


static func read_caught(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var by := r.read_varint()
	var how := r.read_string(ID_BYTES)
	return {"player_id": player_id, "by": by, "how": StringName(how), "ok": r.ok()}


## A door set off on [param tick], towards open or shut, swinging the map's way or the other.
## The tick is the server's and is the whole of a door's state: see HsDoors.
static func write_door(index: int, open: bool, flip: bool, tick: int) -> PackedByteArray:
	var w := _w()
	w.write_varint(maxi(index, 0))
	w.write_bool(open)
	w.write_bool(flip)
	w.write_varint(maxi(tick, 0))
	return w.to_bytes()


static func read_door(r: DotNetReader) -> Dictionary:
	var index := r.read_varint()
	var open := r.read_bool()
	var flip := r.read_bool()
	var tick := r.read_varint()
	return {"index": index, "open": open, "flip": flip, "tick": tick, "ok": r.ok()}


## The toys' net ids in toy order, then the map's id. The id is what a client pairs by: a
## client whose MAP never arrived (too large for its socket, or a format behind) has another
## map's toys, or none. Appended, so the ids read the same as before it.
static func write_toys(map_id: StringName, net_ids: PackedInt64Array) -> PackedByteArray:
	var w := _w()
	w.write_varint(net_ids.size())
	for id in net_ids:
		w.write_varint(maxi(int(id), 0))
	w.write_string(String(map_id), ID_BYTES)
	return w.to_bytes()


static func read_toys(r: DotNetReader) -> Dictionary:
	var count := r.read_varint()
	var ids := PackedInt64Array()
	if count < 0 or count > 256:
		return {"map_id": &"", "ids": ids, "ok": false}
	for i in count:
		ids.append(r.read_varint())
	var map_id := StringName(r.read_string(ID_BYTES)) if r.has_more() else &""
	return {"map_id": map_id, "ids": ids, "ok": r.ok()}


## A taunt asked for: an id from the list, or empty for any.
static func write_ask_taunt(taunt_id: StringName) -> PackedByteArray:
	var w := _w()
	w.write_string(String(taunt_id), ID_BYTES)
	return w.to_bytes()


static func read_ask_taunt(r: DotNetReader) -> Dictionary:
	var taunt_id := r.read_string(ID_BYTES)
	return {"taunt_id": StringName(taunt_id), "ok": r.ok()}



## A chat line's own field widths. Wider than the rules allow, so a rule can be raised
## without the wire silently truncating what it lets through.
const CHAT_BYTES := 200
const CHAT_CHANNEL_BYTES := 24
const CHAT_KEY_BYTES := 48
const CHAT_KIND_BITS := 4


## Whether every [enum DotChatMessage.Kind] fits in [constant CHAT_KIND_BITS]. dot-chat owns
## that enum, so it can grow under this game; headless_net reads this.
static func chat_kinds_fit() -> bool:
	return DotChatMessage.KIND_NAMES.size() <= (1 << CHAT_KIND_BITS)


## One routed line, in [DotChatMessage]'s own wire shape.
## Field by field rather than `var_to_bytes`, like every message here: a whole dictionary holds whatever the sender put in it, and the widths below are the validation. `x.p` is the speaker's session id.
static func write_chat(wire: Dictionary) -> PackedByteArray:
	var w := _w()
	w.write_varint(int(wire.get("n", 0)))
	w.write_uint(int(wire.get("t", 0)), 32)
	w.write_string(str(wire.get("c", "")), CHAT_CHANNEL_BYTES)
	w.write_uint(
		maxi(0, DotChatMessage.kind_from_name(str(wire.get("k", "say")))), CHAT_KIND_BITS
	)
	w.write_string(str(wire.get("s", "")), CHAT_KEY_BYTES)
	w.write_string(str(wire.get("d", "")), NAME_BYTES)
	w.write_string(str(wire.get("w", "")), CHAT_KEY_BYTES)
	w.write_string(str(wire.get("m", "")), CHAT_BYTES)

	var meta: Variant = wire.get("x")
	var player_id := 0

	if typeof(meta) == TYPE_DICTIONARY:
		player_id = int((meta as Dictionary).get("p", 0))

	w.write_varint(maxi(player_id, 0))
	return w.to_bytes()


static func read_chat(r: DotNetReader) -> Dictionary:
	var out := {
		"n": r.read_varint(),
		"t": r.read_uint(32),
		"c": r.read_string(CHAT_CHANNEL_BYTES),
	}

	var kind := r.read_uint(CHAT_KIND_BITS)
	out["k"] = (
		DotChatMessage.KIND_NAMES[kind] if kind >= 0 and kind < DotChatMessage.KIND_NAMES.size()
		else "say"
	)

	out["s"] = r.read_string(CHAT_KEY_BYTES)
	out["d"] = r.read_string(NAME_BYTES)
	out["w"] = r.read_string(CHAT_KEY_BYTES)
	out["m"] = r.read_string(CHAT_BYTES)

	var player_id := r.read_varint()

	if player_id > 0:
		out["x"] = {"p": player_id}

	out["ok"] = r.ok()
	return out


## What a client sends when somebody presses Enter: a channel and a line, and nothing else.
## No speaker, time or colour: what a line MEANS (who said it, gagged, too fast, which channel, who hears) is decided on the server, or a client could claim it.
static func write_say(channel_id: StringName, text: String) -> PackedByteArray:
	var w := _w()
	w.write_string(String(channel_id), CHAT_CHANNEL_BYTES)
	w.write_string(text, CHAT_BYTES)
	return w.to_bytes()


static func read_say(r: DotNetReader) -> Dictionary:
	var out := {
		"channel": r.read_string(CHAT_CHANNEL_BYTES),
		"text": r.read_string(CHAT_BYTES),
	}
	out["ok"] = r.ok()
	return out


static func write_notice(text: String) -> PackedByteArray:
	var w := _w()
	w.write_string(text, TEXT_BYTES)
	return w.to_bytes()


static func read_notice(r: DotNetReader) -> Dictionary:
	var text := r.read_string(TEXT_BYTES)
	return {"text": text, "ok": r.ok()}

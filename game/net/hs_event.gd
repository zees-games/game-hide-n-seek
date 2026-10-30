extends DotNetMessage

const HsEvents := preload("hs_events.gd")

## Anything the authority tells a client that is not a snapshot. Reliable, to clients.

const NAME := &"hs.event"
const KIND_BITS := 5
## Room for the largest MAP a reader accepts ([constant HsEvents.MAP_BYTES]) and its length.
## A body past the cap is read as EMPTY with no error: at 4096, hs_park with its toys (4100 bytes) delivered a MAP of nothing. headless_net round-trips the largest size.
const MAX_BODY := HsEvents.MAP_BYTES + 8

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


## Built with [code]new(kind, body)[/code]; this file does not preload itself. A script that extends [DotNetMessage] and preloads ITSELF, loaded from a module a running [DotServer] loads at runtime, leaks the whole script graph at exit on Godot 4.7.2. The registry decodes with a bare [code]new()[/code], so both arguments default.
func _init(p_kind: int = 0, p_body: PackedByteArray = PackedByteArray()) -> void:
	kind = p_kind
	body = p_body


func _type_name() -> StringName:
	return NAME


func _write(writer: DotNetWriter) -> void:
	writer.write_uint(kind, KIND_BITS)
	writer.write_bytes(body)


func _read(reader: DotNetReader) -> void:
	kind = reader.read_uint(KIND_BITS)
	body = reader.read_bytes(MAX_BODY)


func _validate() -> DotResult:
	if kind < 0 or kind >= HsEvents.Kind.size():
		return DotResult.fail(DotError.CODE_INVALID, "Unknown event kind %d." % kind)

	return DotResult.success(true)


## Whether every [enum HsEvents.Kind] fits in [constant KIND_BITS]. What a check reads: the writer
## masks a value to its field, so a kind past it goes out as a smaller one and nothing errors.
static func fits() -> bool:
	return int(HsEvents.Kind.values().max()) < (1 << KIND_BITS)


func reader() -> DotNetReader:
	return DotNetReader.new(body)


func _to_string() -> String:
	return "HsEvent(%s, %d bytes)" % [HsEvents.kind_name(kind), body.size()]

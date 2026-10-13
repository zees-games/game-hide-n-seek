extends DotNetMessage

const HsEvents := preload("hs_events.gd")

## Anything the authority tells a client that is not a snapshot. Reliable, to clients.

const NAME := &"hs.event"
const KIND_BITS := 5
## Room for the largest MAP a reader accepts ([constant HsEvents.MAP_BYTES]) and its length.
## It was 4096, and a body past the cap is read as EMPTY with no error: game-hide-n-seek's
## hs_park grew to 4100 bytes with its toys and every delivered client got a MAP of nothing and
## built no map. headless_net round-trips a MAP of the largest size through this message.
const MAX_BODY := HsEvents.MAP_BYTES + 8

var kind: int = 0
var body: PackedByteArray = PackedByteArray()


## [b]Built with [code]new(kind, body)[/code], and this file does not preload itself.[/b]
## It used to, for a typed [code]static func of() -> HsEvent[/code] factory. A script that
## [code]extends DotNetMessage[/code] and preloads ITSELF, first loaded from a module a
## running [DotServer] loads at runtime — which is how every deployed server loads this
## game — leaks the whole script graph at exit on Godot 4.7.2. Measured in
## mg-buses-from-hell (8ed866c) with a two-line reproduction. The registry decodes with a
## bare [code]new()[/code], which is why both arguments default.
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

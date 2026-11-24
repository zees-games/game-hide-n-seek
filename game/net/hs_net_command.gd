extends GSNetInput

const HsNetCommand := preload("hs_net_command.gd")

## One tick of a player's intent, on the wire: a movement command and nothing else.
## Nobody here holds anything: a catch is measured by the server from the bodies, so there is no button to ride on. A game that hands seekers something adds its button in [member GSFpsCommand.buttons].

var move: GSFpsCommand = GSFpsCommand.new()

## Bits of [member view_lag_q]: quarter ticks, so 1023 ticks, past any `max_rewind_sec` a server allows.
const VIEW_LAG_BITS := 12
const MAX_VIEW_LAG_Q := (1 << VIEW_LAG_BITS) - 1
## Bits of [member view_back] and [member view_span]. A view the pair does not fit is sent with no bracket (the lag alone), never clamped.
const VIEW_BACK_BITS := 10
const VIEW_SPAN_BITS := 6

## How far behind this command's tick the sender drew every other player, in quarter ticks; -1 sends none (`mp_solidplayers` or `mp_solidplayers_unlag` off, a client not synced yet).
## The server rewinds the other players' hulls to `tick - view_lag_q / 4` for this tick's move ([GSPlayerHullRewind], through [GSPlayerHullView]); a command with none moves against the present.
var view_lag_q: int = -1

## The snapshot bracket the sender drew between: `tick - view_back` is the older snapshot tick and `+ view_span` the newer, so both ends blend the same two samples. -1: no bracket named.
var view_back: int = -1
var view_span: int = 0


func _write(writer: GSNetWriter) -> void:
	move.write(writer)
	# Appended after the movement, as every addition to this wire is. One bit when there is no view.
	var lagged := view_lag_q >= 0
	writer.write_bool(lagged)
	if lagged:
		writer.write_uint(clampi(view_lag_q, 0, MAX_VIEW_LAG_Q), VIEW_LAG_BITS)
		var bracketed := view_back >= 0
		writer.write_bool(bracketed)
		if bracketed:
			writer.write_uint(clampi(view_back, 0, (1 << VIEW_BACK_BITS) - 1), VIEW_BACK_BITS)
			writer.write_uint(clampi(view_span, 0, (1 << VIEW_SPAN_BITS) - 1), VIEW_SPAN_BITS)


func _read(reader: GSNetReader) -> void:
	move = GSFpsCommand.new()
	move.read(reader)
	view_lag_q = -1
	view_back = -1
	view_span = 0
	if reader.read_bool():
		view_lag_q = reader.read_uint(VIEW_LAG_BITS)
		if reader.read_bool():
			view_back = reader.read_uint(VIEW_BACK_BITS)
			view_span = reader.read_uint(VIEW_SPAN_BITS)


## Not optional. Quantisation bounds each field; it cannot bound the relationship between
## them, and a move vector of (1, 1) is 41% more speed than anybody else — a hider who crosses
## a room before a seeker can turn round.
func _sanitise() -> void:
	move.sanitise()
	view_lag_q = clampi(view_lag_q, -1, MAX_VIEW_LAG_Q)
	view_back = clampi(view_back, -1, (1 << VIEW_BACK_BITS) - 1)
	view_span = clampi(view_span, 0, (1 << VIEW_SPAN_BITS) - 1)


## A silent player lets go: the default neutralises `move`, and the view claim is dropped with it.
func _neutralise() -> void:
	super()
	view_lag_q = -1
	view_back = -1
	view_span = 0


func _equals(other: GSNetInput) -> bool:
	var them := other as HsNetCommand
	return them != null and move.equals(them.move) \
			and view_lag_q == them.view_lag_q and view_back == them.view_back and view_span == them.view_span

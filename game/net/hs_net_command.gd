extends GSNetInput

const HsNetCommand := preload("hs_net_command.gd")

## One tick of a player's intent, on the wire: a movement command and nothing else.
## Nobody here holds anything: a catch is measured by the server from the bodies, so there is no button to ride on. A game that hands seekers something adds its button in [member GSFpsCommand.buttons].

var move: GSFpsCommand = GSFpsCommand.new()


func _write(writer: GSNetWriter) -> void:
	move.write(writer)


func _read(reader: GSNetReader) -> void:
	move = GSFpsCommand.new()
	move.read(reader)


## Not optional. Quantisation bounds each field; it cannot bound the relationship between
## them, and a move vector of (1, 1) is 41% more speed than anybody else — a hider who crosses
## a room before a seeker can turn round.
func _sanitise() -> void:
	move.sanitise()


func _equals(other: GSNetInput) -> bool:
	var them := other as HsNetCommand
	return them != null and move.equals(them.move)

extends DotNetInput

const HsNetCommand := preload("hs_net_command.gd")

## One tick of a player's intent, on the wire: a movement command and nothing else.
##
## [b]Nobody here holds anything.[/b] A seeker catches by touching or by watching, both of which
## the server measures from where it has the bodies, so there is no button a catch could ride
## on and nothing a client could claim with one. A game that hands seekers something later
## adds its button here, in [member DotFpsCommand.buttons], for the reason a jump is there.

var move: DotFpsCommand = DotFpsCommand.new()


func _write(writer: DotNetWriter) -> void:
	move.write(writer)


func _read(reader: DotNetReader) -> void:
	move = DotFpsCommand.new()
	move.read(reader)


## Not optional. Quantisation bounds each field; it cannot bound the relationship between
## them, and a move vector of (1, 1) is 41% more speed than anybody else — a hider who crosses
## a room before a seeker can turn round.
func _sanitise() -> void:
	move.sanitise()


func _equals(other: DotNetInput) -> bool:
	var them := other as HsNetCommand
	return them != null and move.equals(them.move)

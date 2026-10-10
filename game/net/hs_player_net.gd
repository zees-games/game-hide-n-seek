extends DotNetBehaviour

const HsNetCommand := preload("hs_net_command.gd")
const HsPlayer := preload("../hs_player.gd")
const HsController := preload("../hs_controller.gd")

## What a networked player replicates: the movement state, their health, and the numbers a
## hider needs about itself.
##
## [b]The movement half is dot-player-controller's own table and is not written here.[/b]
## [DotFpsNetSync.state_specs] is what the controller says its state is, in the
## quantisation it says it wants; a game that listed the fields itself would be a second
## copy to drift — and the type names in that table are STRINGS precisely so the addon can
## describe a dot-net layout without naming dot-net.
##
## [b]The game fields are not derivable from the movement.[/b] Health decides whether a body
## is drawn at all; sitting a round out and being given away by the beacon are the server's
## decisions about a player, and a client that worked them out for itself would be running a
## second copy of the rules.
##
## [b]Which side somebody is on is deliberately NOT here.[/b] It changes once a round at
## most, and a per-tick field for it would send the same three bits sixty-four times a
## second for ever to carry a fact that arrives reliably in a JOIN and a TEAM. The rule this
## game follows: a per-tick property for what changes per tick, an event for what changes on
## a decision.

var player: HsPlayer = null
var bridge: Node = null

var net_position: Vector3 = Vector3.ZERO
var net_velocity: Vector3 = Vector3.ZERO
var net_yaw: float = 0.0
var net_pitch: float = 0.0
var net_crouch: float = 0.0
var net_flags: int = 0
var net_modifiers: int = 0

## Hit points, and the one field with a hard cap on the wire.
##
## [b]Sent against 0..1000 rather than against the player's own maximum.[/b] A server that
## raised `player_health` mid-round would otherwise change what every previously sent number
## MEANT, which is the quantisation version of the map-size bug: the value does not get less
## precise, it becomes a different value.
var net_health: float = 100.0

## What full health is, for the HUD.
var net_max_health: float = 100.0

## Points this match and the server's ping for the player, for everybody's Tab board.
var net_points: int = 0
var net_ping: int = 0

## How full a hider's forced-taunt meter is, 0..1. Owner only: a seeker who could read it
## would know who is about to make a noise.
var net_taunt_meter: float = 0.0

## How full a hider's "being watched" meter is, 0..1, under the sight rule. Owner only, for
## the same reason: a seeker told it would know which way to look.
var net_sight_meter: float = 0.0

## Caught this round, having started it hiding. Everybody's, for the board.
var net_caught: bool = false

## Held still: a seeker blindfolded, or a hider just caught. Owner only, for the HUD; the hold
## itself is a modifier in the movement state.
var net_held: bool = false

## Sitting this round out, having joined after it started.
var net_watching: bool = false

# --- An administrator's marks, from the live tools ---------------------------

## `HsPlayer.blinded`. Owner only: see [method _register_net_vars].
var net_blind: bool = false

## `HsPlayer.beacon`, or the rule's mark on the last props. Everybody's.
var net_beacon: bool = false

## Which of the two the beacon is: true for the rule's mark, false for an admin's.
var net_marked: bool = false

## `HsPlayer.warps`, four bits of it: how many times the server has put this player
## somewhere rather than moved them there. See [method _forget_the_path].
var net_warp: int = 0

## The last [member net_warp] this mirror acted on.
var _seen_warp: int = -1

## Retained, not cleared: a player whose packet was lost keeps moving in a straight line
## rather than stopping dead. The controller says the same of its own command.
var last_move: DotFpsCommand = DotFpsCommand.new()

var last_state_tick: int = -1


func _register_net_vars() -> void:
	for spec in DotFpsNetSync.state_specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			declaration.interpolated()

		if spec["property"] == &"net_crouch":
			declaration.range_of(0.0, 1.0)

	replicate(&"net_health", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 1000.0).bits(12)
	replicate(&"net_max_health", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 1000.0).bits(14)
	replicate(&"net_points", DotNetVar.Type.UINT).bits(16)
	replicate(&"net_ping", DotNetVar.Type.UINT).bits(10)
	replicate(&"net_watching", DotNetVar.Type.BOOL)
	var _meter := replicate(&"net_taunt_meter", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 1.0).bits(7).to_owner_only()
	var _seen := replicate(&"net_sight_meter", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 1.0).bits(7).to_owner_only()
	var _held := replicate(&"net_held", DotNetVar.Type.BOOL).to_owner_only()
	replicate(&"net_caught", DotNetVar.Type.BOOL)

	# [b]Per-player state rather than an event, and that is what makes both of these survive
	# what an event does not.[/b] A client that joins after the admin typed `beacon`, a
	# snapshot lost on the way, a field re-laid at the top of a round: each is a baseline the
	# next snapshot corrects, where an event sent once is simply missed. Two bits, and nothing
	# at all on a tick where neither changed.
	#
	# The blind goes to its owner alone. Nobody else's screen changes, and an opponent who
	# received it would know the moment somebody could not see — the same reason the meters
	# above are the owner's.
	#
	# [b]No relevance change for a beacon, where game-arena makes one.[/b] Every player here
	# is already always relevant (`HsNetBridge`: a map is a few rooms), so a beacon reaches
	# every client however far away they are without asking — and a beacon turned OFF that
	# set `always_relevant` back to false would take the player out of everybody's snapshot.
	var _blind := replicate(&"net_blind", DotNetVar.Type.BOOL).to_owner_only()
	replicate(&"net_beacon", DotNetVar.Type.BOOL)
	replicate(&"net_marked", DotNetVar.Type.BOOL)
	replicate(&"net_warp", DotNetVar.Type.UINT).bits(4)


func _net_apply_input(input: DotNetInput, _tick: int) -> void:
	var command := input as HsNetCommand

	if command != null:
		last_move = command.move


## On the authority the whole game ticks as one — every player moves, then the catches, the
## taunts and the round are decided — so the first behaviour through drives the whole world and
## the rest find it done. On a predicting client there is one predicted player, and simulating
## it is the whole of what a client may compute.
func _net_simulate(tick: int, delta: float) -> void:
	if player == null:
		return

	if identity != null and identity.is_authoritative:
		if bridge != null:
			bridge.ensure_game_ticked(tick)
	else:
		# The prediction: the controller's own tick, with the same hold modifier the server
		# applies, which travels in the movement state.
		player.controller.apply_command(last_move.duplicate_command())
		player.controller.simulate_tick(tick, delta)

	pull()


## Authority only: what the simulation left this player as.
func pull() -> void:
	if player == null:
		return

	DotFpsNetSync.pull(player.controller.state, self)

	if player.health != null:
		net_health = player.health.health
		net_max_health = player.health.max_health

	net_points = clampi(player.points, 0, 65535)
	net_ping = clampi(player.ping_ms, 0, 1023)
	net_watching = player.watching
	net_taunt_meter = player.taunt_meter
	net_sight_meter = player.sight_meter
	net_caught = player.caught
	net_held = player.controller.has_modifier(HsController.HOLD) if player.controller != null else false
	net_blind = player.blinded
	net_beacon = player.beacon or player.marked
	net_marked = player.marked and not player.beacon
	net_warp = player.warps & 0xF


## The server's answer, adopted wholesale. On the owner it is the rewind half of
## reconciliation and the predictor replays every unacknowledged command on top.
func _net_state_applied(tick: int) -> void:
	if player == null:
		return

	last_state_tick = tick
	_forget_the_path()
	DotFpsNetSync.push(self, player.controller.state)
	_adopt()

	# NOT the node, on a predicted entity: `receive_snapshot` calls this BEFORE the
	# predictor reconciles, and reconcile's first act is to read the node as "what the
	# client is showing". Moving it here makes the measured error the whole replay distance,
	# and the correction rate then reads as if every snapshot snapped. Two games in this
	# family shipped that line.
	#
	if identity == null or not identity.is_predicted():
		player.global_position = player.controller.state.position


## A teleport is not a movement, so the interpolator must not draw one.
##
## [b]A round start moves everybody across the map in one tick, and a watcher saw them
## fly there.[/b] mg-smash-copter's finding. The interpolator blends between the two snapshots
## either side of the render time, and when those are "where they were found" and "at the
## start" the blend is a body sweeping across the map for a snapshot interval.
##
## So the server counts the times it PUT this player somewhere (`HsPlayer.place_at`), the
## count replicates, and a mirror that sees it change drops the interpolator's track for this
## entity before the new snapshot is added to it. A track with one sample answers with that
## sample, so the body appears in its corner, one render delay early, rather than crossing
## the sky to get there. Here, before the push, because this hook runs inside the snapshot
## read and the manager adds the snapshot's values to the track just after it.
##
## Not on the predicted entity: nothing interpolates that, and its own camera is moved by
## the prediction's rewind.
func _forget_the_path() -> void:
	if identity == null or identity.is_authoritative or identity.is_predicted():
		_seen_warp = net_warp
		return

	if _seen_warp >= 0 and net_warp != _seen_warp and bridge != null:
		var manager: Variant = bridge.get(&"net")
		if manager is DotNetManager and (manager as DotNetManager).interpolator != null:
			(manager as DotNetManager).interpolator.forget(identity.net_id)

	_seen_warp = net_warp


## Every frame on a remote player. Without this the interpolator's work sits in a property
## nothing reads and a remote player moves in snapshot-sized steps.
func _net_interpolated(_tick: int) -> void:
	if player == null:
		return

	DotFpsNetSync.push(self, player.controller.state)
	player.global_position = player.controller.state.position


## The game half of a snapshot, on a mirror: what the server decided about this player.
func _adopt() -> void:
	if player == null or identity == null or identity.is_authoritative:
		return

	if player.health != null:
		player.health.max_health = maxf(net_max_health, 1.0)
		player.health.health = net_health
		player.health.alive = net_health > 0.0

	player.points = net_points
	player.ping_ms = net_ping
	player.watching = net_watching
	player.taunt_meter = net_taunt_meter
	player.sight_meter = net_sight_meter
	player.caught = net_caught
	player.held_until = 1.0 if net_held else -1.0

	player.blinded = net_blind
	# One flag on the wire for both marks, and which it is beside it: an admin's beacon and the
	# rule's are drawn in different colours.
	player.beacon = net_beacon and not net_marked
	player.marked = net_marked

extends DotSpectatorHost

const HsPlayer := preload("hs_player.gd")

## Where somebody who is out looks, and what the server lets them see: dot-spectate's host with this game's roster and rules. A client runs a MIRROR told each view change in a `SPECTATE` event.
## No delay: every player is always relevant here, so every client already receives every live position and a delayed camera would hide nothing.
## No `class_name`; reached by preload from [HsGame], which it does not preload back.

## How far above the floor a faller's death camera hangs, looking straight down the drop.
## A fall is recorded at the kill height, where nothing is worth seeing, so the camera goes back up over the point they left the field.
const DROP_CAM_RISE := 6.0

## player id -> HsPlayer. The world's own dictionary, shared rather than copied.
var players: Dictionary = {}

## player id -> team id. Also the world's own.
var sides: Dictionary = {}


func _init() -> void:
	death_cam_seconds = 1.5
	freeze_cam_seconds = 1.5
	chase_distance = 4.6
	chase_height = 1.2
	history_seconds = 0.0
	prefer_own_side = true
	name_fn = _name_of


func _channel() -> String:
	return "hs.spectate"


## Dead players stay dead until the next round, so a cycle that included them would be a list of bodies at the kill height.
func _tune_rules(r: DotSpectatorRules) -> DotSpectatorRules:
	r.cycle_includes_dead = false
	r.delay_ticks = 0
	return r


func _participants() -> PackedStringArray:
	var out := PackedStringArray()

	for id: StringName in players:
		out.append(String(id))

	return out


func _team_of(key: String) -> int:
	return int(sides.get(StringName(key), 0))


## Somebody in the gallery is up and is not in the fight; a camera on them is a camera on a wall of other spectators.
func _is_alive(key: String) -> bool:
	var body: HsPlayer = players.get(StringName(key))
	return body != null and is_instance_valid(body) and body.is_alive() and not body.watching


## The drawn position, not the node, on a world that simulates: a node moves once a tick, so a camera hung on it jitters. A mirror's remote players are written once a frame, so there the node is right, and a rider's controller is not simulated.
func _pose_of(key: String) -> Transform3D:
	var body: HsPlayer = players.get(StringName(key))

	if body == null or not is_instance_valid(body) or body.controller == null:
		return Transform3D.IDENTITY

	var at := body.global_position

	if authoritative:
		at = body.controller.render_state().position

	var state := body.controller.state
	var basis := Basis.from_euler(Vector3(deg_to_rad(state.pitch), deg_to_rad(state.yaw), 0.0))
	# From their own eyes, which crouch with them.
	var eye := body.eye_position() - body.controller.state.position
	return Transform3D(basis, at + eye)


func _name_of(key: String) -> String:
	var body: HsPlayer = players.get(StringName(key))
	return body.display_name if body != null else key


## Somebody is out. Starts the death camera; the server's tick hands it over.
## [param at] is where they died; a fall is recorded at the kill height, so the camera is moved back up over it.
func on_died(
	player_id: StringName, by: StringName, fell: bool, at: Vector3, deck_height: float, tick: int
) -> void:
	if manager == null or not authoritative:
		return

	var where := at

	if fell:
		where = Vector3(at.x, deck_height + DROP_CAM_RISE - 2.0, at.z)

	death(String(player_id), where, String(by), tick)


## A mirror is told, not asked; and only somebody who is out can step.
func toggle_roam(key: String) -> DotResult:
	if manager == null:
		return _unset()

	if not authoritative:
		return DotResult.fail(DotError.CODE_STATE, "A mirror is told, not asked.")

	if not manager.is_spectating(key):
		return DotResult.fail(DotError.CODE_STATE, "You are playing, not watching.")

	return super(key)

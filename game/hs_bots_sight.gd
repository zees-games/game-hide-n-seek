extends "hs_bots_move.gd"

## Bodies in sight, natively: dot-sim's DotSimBodySight asks [method _sees], [method _nearest_seen_seeker] and
## [method _visible_prey] over one table of the tick's bodies, each ask one call, every line of sight the same ray as
## `_clear_between`. The table is written once a tick before the bots are driven ([method _sight_bind]); with no library,
## [member sight_mode] "script" or a body moved mid-tick, the script answers. `HS_SIGHT_VERIFY=1` asks the script beside
## every native answer and keeps the script's (`headless_native_sight`).

## "native" (the default; the script when the library lacks the module) or "script".
static var sight_mode := "native"
## Ask the script beside every native answer, count and log every difference, and keep the script's.
static var sight_verify := OS.get_environment("HS_SIGHT_VERIFY") == "1"
## Native asks checked against the script under [member sight_verify], and those that differed.
static var sight_checked := 0
static var sight_mismatches := 0

const SIGHT_ALIVE := 1
const SIGHT_WATCHING := 2
const SIGHT_CAUGHT := 4
const SIGHT_MARKED := 8
## The chest the script looks for: `position + Vector3(0, 0.6, 0)` in [method _sees].
const SIGHT_CHEST := 0.6

var _sight_table: Object = null
var _sight_ray: Object = null
var _sight_tried := false
var _sight_ready := false
var _sight_index: Dictionary = {}
var _sight_bodies: Array[HsPlayer] = []


## The native table and its ray, made once; none without the library.
func _sight_native() -> Object:
	if _sight_tried:
		return _sight_table
	_sight_tried = true
	if not DotSim.has(&"body_sight") or not DotSim.has(&"sight"):
		return null
	_sight_ray = ClassDB.instantiate(DotSim.MODULES[&"sight"])
	_sight_table = ClassDB.instantiate(DotSim.MODULES[&"body_sight"])
	_sight_table.call(&"set_sight", _sight_ray)
	_sight_table.call(&"set_rules", FELT_WITHIN, STILL_LOW_SIGHT, SIGHT_CHEST)
	return _sight_table


## Writes the tick's bodies, in the players' order, before the bots are driven. Nothing a bot does in [method drive]
## moves a body but [method _sight_stale]'s callers.
func _sight_bind(players: Dictionary) -> void:
	_sight_ready = false
	if sight_mode != "native" or _sight_native() == null:
		return
	var world: World3D = game.call("get_world_3d")
	var layout: DotPhysicsLayout = game.get("physics")
	var mask := 1
	if layout != null:
		mask = layout.layer_mask(&"world") | layout.layer_mask(&"prop") | layout.layer_mask(&"toy")
	_sight_ray.call(&"bind", world.direct_space_state if world != null else null, mask, [] as Array[RID], null, null, 0, Vector3.ZERO, 0.0, 0.0)
	var n := players.size()
	var at := PackedVector3Array()
	var eyes := PackedVector3Array()
	var forwards := PackedVector3Array()
	var velocities := PackedVector3Array()
	var crouch := PackedFloat64Array()
	var flags := PackedInt32Array()
	var sides := PackedInt32Array()
	at.resize(n)
	eyes.resize(n)
	forwards.resize(n)
	velocities.resize(n)
	crouch.resize(n)
	flags.resize(n)
	sides.resize(n)
	_sight_index.clear()
	_sight_bodies.resize(n)
	var i := 0
	for id: StringName in players:
		var p: HsPlayer = players[id]
		if p.controller == null:
			return
		var s := p.controller.state
		at[i] = s.position
		eyes[i] = p.eye_position()
		forwards[i] = DotBotAim.direction(s.yaw, s.pitch)
		velocities[i] = s.velocity
		crouch[i] = s.crouch_fraction
		flags[i] = (SIGHT_ALIVE if p.is_alive() else 0) | (SIGHT_WATCHING if p.watching else 0) \
			| (SIGHT_CAUGHT if p.caught else 0) | (SIGHT_MARKED if p.marked else 0)
		sides[i] = int(game.call("team_of", id))
		_sight_index[p] = i
		_sight_bodies[i] = p
		i += 1
	_sight_ready = bool(_sight_table.call(&"set_bodies", at, eyes, forwards, velocities, crouch, flags, sides))


## A body moved mid-tick: the script answers until the next [method _sight_bind].
func _sight_stale() -> void:
	_sight_ready = false


func _sight_slot(player: HsPlayer) -> int:
	return int(_sight_index.get(player, -1)) if _sight_ready else -1


## [method _sees], natively when the table has both.
func _sight_sees(player: HsPlayer, other: HsPlayer) -> bool:
	var w := _sight_slot(player)
	var o := _sight_slot(other)
	if w < 0 or o < 0:
		return _sees(player, other)
	var profile := settings().profile
	var seen := bool(_sight_table.call(&"sees", w, o, profile.fov, profile.sight))
	if sight_verify:
		sight_checked += 1
		var want := _sees(player, other)
		if want != seen:
			sight_mismatches += 1
			push_error("HsBots._sight_sees: native %s, script %s (%s sees %s)" % [seen, want, player.player_id, other.player_id])
			return want
	return seen


## The nearest on [param side] from [param at] that [param player] has in sight, natively: [param prey] false is
## [method _nearest_seen_seeker] (nearer than [param within]), true [method _visible_prey]. [code]false[/code] when the
## table cannot answer (the caller asks the script), else the body or [code]null[/code].
func _sight_nearest(player: HsPlayer, at: Vector3, side: int, within: float, prey: bool) -> Variant:
	var w := _sight_slot(player)
	if w < 0:
		return false
	var profile := settings().profile
	var found := int(_sight_table.call(&"nearest_seen", w, at, side, profile.fov, profile.sight, within, prey))
	return _sight_bodies[found] if found >= 0 else null


## Holds a native nearest to the script's under [member sight_verify]; returns the answer to keep.
func _sight_checked_nearest(native: HsPlayer, script: HsPlayer, what: String, player: HsPlayer) -> HsPlayer:
	sight_checked += 1
	if native != script:
		sight_mismatches += 1
		push_error("HsBots.%s: native %s, script %s (for %s)" % [what, native.player_id if native != null else &"none",
			script.player_id if script != null else &"none", player.player_id])
	return script

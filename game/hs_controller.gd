extends DotFpsController

## The first-person controller, with the one modifier this game adds: somebody held still — a
## seeker while the hiders hide, and a hider just caught while they become a seeker.
##
## [b]A modifier, not a check in the game's loop.[/b] A modifier is part of the movement
## state, so it travels in the snapshot and a predicting client applies it to its own seeker
## on exactly the ticks the server does; a rule the game applied around the controller would be
## skipped by every replayed tick, and a blindfolded seeker's client would predict them walking
## off while the server held them. Registered in [method _register_extensions], on every
## player on every machine and in the same order, because the id is what travels.

## Held still and unable to jump or crouch.
const HOLD := &"hs_hold"


func _register_extensions() -> void:
	var held := DotFpsModifier.make(HOLD)
	held.deny_move = true
	held.deny_jump = true
	held.deny_crouch = true
	held.max_speed_scale = 0.0
	var _id := motor.register_modifier(held)


## A person thrown by a toy (a trampoline, a bounce pad): which one, by its index in the map's
## toy box. Not during a replay, which is a tick already heard.
signal bounced(index: int)

## `func(feet: Vector3, velocity: Vector3) -> Dictionary`: the velocity a toy under the feet
## throws this person at, `{velocity, index}`, or empty. The game's ([method HsGame._launch]).
var launcher: Callable = Callable()


## The trampolines and pads, before the move: a pure function of where the toys stand, on
## every end that simulates this person, so a predicting client is thrown on the very tick the
## server throws it. AIR at once, as a jump leaves the ground, or the motor snaps them back.
func _on_pre_simulate(_tick: int, _delta: float) -> void:
	if not launcher.is_valid() or state.mode != DotFpsState.Mode.GROUND:
		return
	var thrown: Dictionary = launcher.call(state.position, state.velocity)
	if thrown.is_empty():
		return
	state.velocity = thrown["velocity"]
	state.mode = DotFpsState.Mode.AIR
	state.time_since_grounded = 1000.0
	if not is_replaying():
		bounced.emit(int(thrown["index"]))

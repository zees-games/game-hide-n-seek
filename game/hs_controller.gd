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

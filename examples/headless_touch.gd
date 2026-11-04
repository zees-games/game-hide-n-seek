extends DotGameCheckSuite

const HsBindings := preload("../game/hs_bindings.gd")
const HsTouch := preload("../game/hs_touch.gd")

## The touch layout: every button presses an action the bindings or the controller define, no two overlap, a finger on a button is not a look drag, and it exists only where there is touch.
##
## [codeblock]
## godot --headless --path . res://examples/headless_touch.tscn
## [/codeblock]

const SECTIONS := 4
const EXPECTED_CHECKS := 19


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-hide-n-seek: touch buttons")
	var ids := HsTouch.actions()

	_section("the layout names real actions")
	var rows := PackedStringArray()
	for row in HsBindings.make().rows:
		rows.append(String(row.action))
	_check(ids.size() == HsTouch.LAYOUT.size() and ids.size() >= 5, "the layout has jump, run, duck, door and taunt")
	for id in ids:
		_check(rows.has(String(id)) or String(id) == "dot_fps_jump", "%s is an action in the bindings" % id)
	_check(ids.has(&"dot_fps_jump") and ids.has(&"dot_fps_sprint") and ids.has(&"dot_fps_crouch"), "jump, run and duck are on it")
	_check(ids.has(HsBindings.USE) and ids.has(HsBindings.TAUNT), "the door and the taunt are on it")
	_finished()

	_section("the sampler follows touch")
	DotPlatform.touch_override = 0
	_check(not HsTouch.new_sampler(DotFpsTunables.new()) is DotFpsTouchSampler, "no touch: the plain sampler")
	DotPlatform.touch_override = 1
	_check(HsTouch.new_sampler(DotFpsTunables.new()) is DotFpsTouchSampler, "touch: the touch sampler")
	_finished()

	_section("the buttons show, apart and on screen")
	var buttons := HsTouch.new()
	buttons.size = Vector2(844, 390)
	add_child(buttons)
	_check(buttons.visible, "touch: the buttons show")
	var seen := _overlaps(buttons, ids)
	_check(seen == "", "no two buttons overlap", seen)
	var foot := buttons.footprint()
	_check(Rect2(Vector2.ZERO, buttons.size).encloses(foot) and foot.position.y >= 66.0, "the cluster is on a phone screen and clear of the Menu button", str(foot))
	_check(not buttons.is_held(&"dot_fps_jump"), "nothing is held at the start")
	# The headless viewport is 64 wide, so the move side is x < 32.
	# A finger on a button is the game's, anywhere else on the look side it drags the view.
	var sampler := HsTouch.new_sampler(DotFpsTunables.new()) as DotFpsTouchSampler
	var on_button := buttons.centre_of(&"dot_fps_jump")
	_check(buttons.contains_point(on_button), "a button's centre is on a button")
	buttons.feed(_touch(0, on_button), sampler)
	_check(sampler._look_finger == -1 and sampler._move_finger == -1, "the sampler ignores a touch over a button")
	buttons.feed(_touch(1, Vector2(600, 40)), sampler)
	_check(sampler._look_finger == 1, "a touch on the look side clear of the buttons drags the view")
	buttons.feed(_touch(2, Vector2(8, 200)), sampler)
	_check(sampler._move_finger == 2, "a touch on the move side plants the stick")
	buttons.free()
	_finished()

	_section("no touch: hidden")
	DotPlatform.touch_override = 0
	var off := HsTouch.new()
	add_child(off)
	_check(not off.visible, "no touch: the buttons are hidden")
	off.free()
	_finished()

	DotPlatform.touch_override = -1
	_report_sections(_sections_entered, _sections_finished, SECTIONS, EXPECTED_CHECKS)


var _sections_entered := 0
var _sections_finished := 0


func _section(title: String) -> void:
	_sections_entered += 1
	print(title)


func _finished() -> void:
	_sections_finished += 1


func _touch(index: int, pos: Vector2) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = pos
	event.pressed = true
	return event


func _overlaps(buttons: Control, ids: Array[StringName]) -> String:
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var gap: float = buttons.centre_of(ids[i]).distance_to(buttons.centre_of(ids[j])) - buttons.radius_of(ids[i]) - buttons.radius_of(ids[j])
			if gap < 4.0:
				return "%s and %s" % [ids[i], ids[j]]
	return ""

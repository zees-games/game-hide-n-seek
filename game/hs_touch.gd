extends DotTouchButtons

const HsBindings := preload("hs_bindings.gd")

## The player's actions as on-screen buttons, placed by dot-game's platformer preset.
## A button presses the action its key is bound to, so the client's one key path, the door use and the rebinding stay as they are.

const TAUNT := &"taunt"

## Layout id to the input action it presses.
const ACTIONS := {
	DotGameTouchLayout.JUMP: &"dot_fps_jump",
	DotGameTouchLayout.SPRINT: &"dot_fps_sprint",
	DotGameTouchLayout.CROUCH: &"dot_fps_crouch",
	DotGameTouchLayout.USE: HsBindings.USE,
	TAUNT: HsBindings.TAUNT,
}


## The platformer preset less the scoreboard and chat, with use as the door and the taunt in the corner slot.
static func touch_layout() -> DotGameTouchLayout:
	var res := DotGameTouchLayout.build(DotGameTouchLayout.PLATFORMER, {
		DotGameTouchLayout.BOARD: null,
		DotGameTouchLayout.CHAT: null,
		DotGameTouchLayout.USE: {"label": "DOOR"},
		TAUNT: {"slot": &"corner", "label": "TAUNT"},
	})
	if not res.ok:
		DotLog.error("hs.touch", "touch layout refused", {"error": str(res.error)})
		return DotGameTouchLayout.custom()
	return res.value


func _init() -> void:
	name = "TouchButtons"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_buttons(touch_layout().buttons())
	button_down.connect(_send.bind(true))
	button_up.connect(_send.bind(false))


## The layout ids, in order.
static func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for b in touch_layout().buttons():
		out.append(b["id"])
	return out


## A touch sampler on a touch device (it still reads keys), else the plain one.
static func new_sampler(tunables: DotFpsTunables) -> DotFpsSampler:
	if not DotPlatform.has_touch():
		return DotFpsSampler.new(tunables)
	return DotFpsTouchSampler.new(tunables)


## Sends a screen touch or drag to the sampler, which leaves the buttons' fingers alone.
func feed(event: InputEvent, sampler: DotFpsSampler) -> void:
	if not sampler is DotFpsTouchSampler:
		return
	var touch := sampler as DotFpsTouchSampler
	if touch.ignore_fn.is_null():
		touch.set_screen_width(get_viewport().get_visible_rect().size.x)
		touch.ignore_fn = contains_point
	touch.handle_event(event)


func _send(id: StringName, down: bool) -> void:
	var event := InputEventAction.new()
	event.action = ACTIONS.get(id, id)
	event.pressed = down
	Input.parse_input_event(event)

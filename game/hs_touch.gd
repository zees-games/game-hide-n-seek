extends DotTouchButtons

const HsBindings := preload("hs_bindings.gd")

## The player's actions as on-screen buttons: jump large, the rest in a compact cluster at the bottom right.
## A button presses the action its key is bound to, so the client's one key path, the door use and the rebinding stay as they are.

## Offsets from the bottom-right corner (see [DotTouchButtons]); the cluster's top stays under the menu button.
const LAYOUT: Array[Dictionary] = [
	{"id": &"dot_fps_jump", "label": "JUMP", "offset": Vector2(96, 100), "radius": 54.0},
	{"id": &"dot_fps_sprint", "label": "RUN", "offset": Vector2(216, 84), "radius": 42.0},
	{"id": &"dot_fps_crouch", "label": "DUCK", "offset": Vector2(50, 200), "radius": 28.0},
	{"id": HsBindings.USE, "label": "DOOR", "offset": Vector2(124, 200), "radius": 28.0},
	{"id": HsBindings.TAUNT, "label": "TAUNT", "offset": Vector2(198, 200), "radius": 28.0},
]


func _init() -> void:
	name = "TouchButtons"
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_buttons(LAYOUT)
	button_down.connect(_send.bind(true))
	button_up.connect(_send.bind(false))


## The action ids on the layout, in order.
static func actions() -> Array[StringName]:
	var ids: Array[StringName] = []
	for b in LAYOUT:
		ids.append(b["id"])
	return ids


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
	event.action = id
	event.pressed = down
	Input.parse_input_event(event)

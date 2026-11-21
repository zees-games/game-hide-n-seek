extends RefCounted

const HsBindings := preload("hs_bindings.gd")
const SelfScript := preload("hs_touch.gd")

## The player's actions as on-screen buttons: dot-mobile's stick, drag-look and buttons over the HUD, driving the client's own [GSFpsTouchSampler].
## The buttons are dot-game's platformer preset. Jump, run and duck are held on the sampler as the keys are; the door and the taunt press the action
## their key is bound to, so the client's one key path, the door use and the rebinding stay as they are. Nothing here aims or fires: a hider has no weapon.

const TAUNT := &"taunt"

## Layout id to the input action it presses.
const ACTIONS := {
	GSGameTouchLayout.JUMP: &"dot_fps_jump",
	GSGameTouchLayout.SPRINT: &"dot_fps_sprint",
	GSGameTouchLayout.CROUCH: &"dot_fps_crouch",
	GSGameTouchLayout.USE: HsBindings.USE,
	TAUNT: HsBindings.TAUNT,
}

## Layout id to the command bit the overlay holds on the sampler while the button is down.
const HOLDS := {
	GSGameTouchLayout.JUMP: GSFpsCommand.BUTTON_JUMP,
	GSGameTouchLayout.SPRINT: GSFpsCommand.BUTTON_SPRINT,
	GSGameTouchLayout.CROUCH: GSFpsCommand.BUTTON_CROUCH,
}

var controls: GSMobileControls = null
## dot-ui's buttons inside the overlay, for the shell's DPI fit.
var buttons: GSTouchButtons:
	get:
		return controls.buttons if controls != null else null

var _client: Node = null


## The platformer preset less the scoreboard and chat, with use as the door and the taunt in the corner slot.
static func touch_layout() -> GSGameTouchLayout:
	var res := GSGameTouchLayout.build(GSGameTouchLayout.PLATFORMER, {
		GSGameTouchLayout.BOARD: null,
		GSGameTouchLayout.CHAT: null,
		GSGameTouchLayout.USE: {"label": "DOOR"},
		TAUNT: {"slot": &"corner", "label": "TAUNT"},
	})
	if not res.ok:
		GSLog.error("hs.touch", "touch layout refused", {"error": str(res.error)})
		return GSGameTouchLayout.custom()
	return res.value


## The layout's rows with the held command bits, as dot-mobile takes them.
static func layout() -> Array[Dictionary]:
	var rows := touch_layout().buttons()
	for row in rows:
		if HOLDS.has(row["id"]):
			row["hold"] = HOLDS[row["id"]]
	return rows


## The layout ids, in order.
static func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for b in touch_layout().buttons():
		out.append(b["id"])
	return out


## A touch sampler on a touch device (it still reads keys), else the plain one.
static func new_sampler(tunables: GSFpsTunables) -> GSFpsSampler:
	if not GSPlatform.has_touch():
		return GSFpsSampler.new(tunables)
	return GSFpsTouchSampler.new(tunables)


## Builds the overlay under [param host] (the HUD), following [param rules] (the server's). [param menu_fn] gives the Menu button, which keeps its touches. Never null.
static func build(client: Node, host: Node, sampler: GSFpsSampler, rules: GSMobileRules, menu_fn: Callable = Callable()) -> RefCounted:
	var made: RefCounted = (SelfScript as GDScript).new()
	made.call(&"_setup", client, host, sampler, rules, menu_fn)
	return made


func _setup(client: Node, host: Node, sampler: GSFpsSampler, rules: GSMobileRules, menu_fn: Callable) -> void:
	_client = client
	controls = GSMobileControls.new()
	controls.name = "TouchControls"
	controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if rules != null:
		controls.rules = rules
	if menu_fn.is_valid():
		controls.ignore_fn = func(at: Vector2) -> bool:
			var menu_button: Button = menu_fn.call()
			return menu_button != null and menu_button.is_visible_in_tree() and menu_button.get_global_rect().has_point(at)
	controls.setup(sampler, layout())
	controls.live_fn = _client_bool.bind(&"touch_live")
	controls.button_pressed.connect(_send.bind(true))
	controls.button_released.connect(_send.bind(false))
	host.add_child(controls)


## A declared button held by a thumb.
func is_held(id: StringName) -> bool:
	return controls != null and controls.is_held(id)


## True when the overlay is up and forwards [param event] itself, or [param event] is the mouse Godot emulates
## from a touch, which would turn the view a second time.
func takes(event: InputEvent) -> bool:
	if controls == null or not controls.touch:
		return false
	return controls.takes(event) or (event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION)


func active() -> bool:
	return controls != null and controls.touch


## Follows the sampler the keys drive now (the player's own offline, the netcode's online) and pauses under a menu, the console, chat or the cover.
func sync(sampler: GSFpsSampler, busy: bool) -> void:
	if controls == null:
		return
	if sampler != null and sampler != controls.sampler:
		controls.setup(sampler, layout())
	controls.paused = busy


func describe() -> Dictionary:
	return controls.describe() if controls != null else {"built": false}


## The door and the taunt are actions; jump, run and duck already ride the sampler's bits, and the action is not sent twice.
func _send(id: StringName, down: bool) -> void:
	if HOLDS.has(id) or not ACTIONS.has(id):
		return
	var event := InputEventAction.new()
	event.action = ACTIONS[id]
	event.pressed = down
	Input.parse_input_event(event)


func _client_bool(method: StringName) -> bool:
	return is_instance_valid(_client) and _client.has_method(method) and bool(_client.call(method))

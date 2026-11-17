extends DotGameCheckSuite

const HsBindings := preload("../game/hs_bindings.gd")
const HsTouch := preload("../game/hs_touch.gd")

## The touch controls: every button presses an action the bindings or the controller define, no two overlap on a phone, and dot-mobile's overlay
## drives the client's own sampler (a finger on a button is not a look drag, the mouse a touch emulates is dropped, a menu pauses it).
## Run: [code]./game.sh --no-parse test headless_touch[/code].

const EXPECTED_CHECKS := 41


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("game-hide-n-seek: touch controls")
	var ids := HsTouch.ids()

	var rows := PackedStringArray()
	for row in HsBindings.make().rows:
		rows.append(String(row.action))
	_check(ids.size() == 5, "the layout has jump, run, duck, door and taunt")
	for id in ids:
		var action: StringName = HsTouch.ACTIONS.get(id, &"")
		_check(rows.has(String(action)) or action == &"dot_fps_jump" or action == &"dot_fps_sprint" or action == &"dot_fps_crouch", "%s presses an action the bindings or controller define" % id)
	_check(ids.has(&"jump") and ids.has(&"sprint") and ids.has(&"crouch"), "jump, run and crouch are on it, under their canonical ids")
	_check(ids.has(&"use") and ids.has(HsTouch.TAUNT), "the door and the taunt are on it")
	var held_ids := 0
	for row in HsTouch.layout():
		if row.has("hold"):
			held_ids += 1
	_check(held_ids == 3, "jump, run and duck are held on the sampler as bits")

	DotPlatform.touch_override = 0
	_check(not HsTouch.new_sampler(DotFpsTunables.new()) is DotFpsTouchSampler, "no touch: the plain sampler")
	DotPlatform.touch_override = 1
	_check(HsTouch.new_sampler(DotFpsTunables.new()) is DotFpsTouchSampler, "touch: the touch sampler")

	# The overlay, on a phone-sized host.
	var rules := DotMobileRules.new()
	var client := Node.new()
	add_child(client)
	var host := Control.new()
	host.size = Vector2(844, 390)
	add_child(host)
	var sampler := HsTouch.new_sampler(DotFpsTunables.new()) as DotFpsTouchSampler
	var menu_button := Button.new()
	menu_button.position = Vector2(700, 10)
	menu_button.size = Vector2(120, 50)
	host.add_child(menu_button)
	var touch: HsTouch = HsTouch.build(client, host, sampler, rules, func() -> Button: return menu_button)
	var controls := touch.controls
	_check(controls != null and controls.touch and controls.sampler == sampler, "the overlay drives the client's own sampler", str(touch.describe()))
	_check(controls.crosshair_fn.is_null() and controls.targets_fn.is_null(), "no crosshair or aim assist: a hider has no weapon")
	_check(not rules.resolve(DotMobilePrefs.new(), true).autofire, "auto-fire is off")
	_check(touch.active() and touch.buttons != null and touch.buttons.visible, "the buttons show")
	var seen := _overlaps(touch.buttons, ids)
	_check(seen == "", "no two buttons overlap", seen)
	var foot := touch.buttons.footprint()
	_check(Rect2(Vector2.ZERO, host.size).encloses(foot) and foot.position.y >= 66.0, "the cluster is on a phone screen and clear of the Menu button", str(foot))
	_check(not touch.is_held(&"jump"), "nothing is held at the start")

	_finger_checks(touch, controls, sampler, menu_button)

	_door_and_menu_checks(touch, controls, sampler)

	_narrow_phones(ids)
	host.free()

	_no_touch_and_wiring(client)

	DotPlatform.touch_override = -1
	_report(EXPECTED_CHECKS)


# A finger on a button is the game's; anywhere else on the look side it drags the view.
func _finger_checks(touch: HsTouch, controls: DotMobileControls, sampler: DotFpsTouchSampler, menu_button: Button) -> void:
	var on_jump := touch.buttons.centre_of(&"jump")
	_check(touch.buttons.contains_point(on_jump), "a button's centre is on a button")
	_tap(controls, 0, on_jump, true)
	_check(sampler._look_finger == -1 and sampler._move_finger == -1, "the sampler ignores a touch over a button")
	_check(touch.is_held(&"jump") and sampler._held & DotFpsCommand.BUTTON_JUMP != 0, "jump held on the sampler as its bit")
	_tap(controls, 0, on_jump, false)
	_check(not touch.is_held(&"jump") and sampler._held & DotFpsCommand.BUTTON_JUMP == 0, "and let go with the thumb")
	# The headless viewport is 64 wide, so the move side is x < 32.
	_tap(controls, 1, Vector2(600, 40), true)
	_check(sampler._look_finger == 1, "a touch on the look side clear of the buttons drags the view")
	_tap(controls, 2, Vector2(8, 200), true)
	_check(sampler._move_finger == 2, "a touch on the move side plants the stick")
	_check(_ignored(menu_button.global_position + Vector2(5, 5), controls), "the Menu button keeps its touches")
	_tap(controls, 1, Vector2(600, 40), false)
	_tap(controls, 2, Vector2(8, 200), false)


# The door and the taunt press the actions the key path reads; a menu pauses the overlay.
func _door_and_menu_checks(touch: HsTouch, controls: DotMobileControls, sampler: DotFpsTouchSampler) -> void:
	var use_action: StringName = HsTouch.ACTIONS[&"use"]
	if not InputMap.has_action(use_action):
		InputMap.add_action(use_action)
	_check(not Input.is_action_pressed(use_action), "the door is not pressed to begin with")
	_tap(controls, 3, touch.buttons.centre_of(&"use"), true)
	Input.flush_buffered_events()
	_check(Input.is_action_pressed(use_action), "the door button presses the use action")
	_tap(controls, 3, touch.buttons.centre_of(&"use"), false)
	Input.flush_buffered_events()
	_check(not Input.is_action_pressed(use_action), "and lets it go")

	var tapped := InputEventScreenTouch.new()
	tapped.pressed = true
	var fake := InputEventMouseMotion.new()
	fake.device = InputEvent.DEVICE_ID_EMULATION
	_check(touch.takes(tapped) and touch.takes(fake), "it takes touches and the mouse emulated from them")
	var real := InputEventMouseMotion.new()
	_check(not touch.takes(real), "a real mouse is the game's")

	touch.sync(sampler, true)
	_check(not controls.visible and not touch.active(), "a menu pauses it")
	_check(not touch.takes(tapped), "and a touch is the menu's")
	touch.sync(sampler, false)
	_check(touch.active(), "closing the menu brings it back")

	# The offline player's own sampler replaces the client's.
	var other := HsTouch.new_sampler(DotFpsTunables.new()) as DotFpsTouchSampler
	touch.sync(other, false)
	_check(controls.sampler == other, "it follows the sampler the keys drive now")
	touch.sync(sampler, false)


# Another phone, narrower.
func _narrow_phones(ids: Array[StringName]) -> void:
	for size: Vector2 in [Vector2(667, 375), Vector2(932, 430)]:
		var narrow := DotTouchButtons.new()
		narrow.size = size
		narrow.set_buttons(HsTouch.touch_layout().buttons())
		add_child(narrow)
		_check(Rect2(Vector2.ZERO, size).encloses(narrow.footprint()), "the cluster fits %dx%d" % [size.x, size.y], str(narrow.footprint()))
		var clash := _overlaps(narrow, ids)
		_check(clash == "", "no two buttons overlap at %dx%d" % [size.x, size.y], clash)
		narrow.free()


# No touch: nothing shows and the sampler is left alone; the client carries the wiring.
func _no_touch_and_wiring(client: Node) -> void:
	DotPlatform.touch_override = 0
	var off_host := CanvasLayer.new()
	add_child(off_host)
	var off: HsTouch = HsTouch.build(client, off_host, HsTouch.new_sampler(DotFpsTunables.new()), DotMobileRules.new())
	_check(not off.active() and not off.controls.visible, "no touch: the overlay is hidden")
	off_host.free()
	client.free()

	# The client carries the wiring, and the server's rules ride on the game.
	var state: Object = (load("res://game/hs_game_state.gd") as GDScript)
	var members: Array = []
	for p: Dictionary in state.get_script_property_list():
		members.append(p["name"])
	_check("mobile_rules" in members, "the game holds the sv_mobile_* rules the module binds and the client follows")
	var methods: Array = []
	for m: Dictionary in (load("res://game/hs_client_build.gd") as GDScript).get_script_method_list():
		methods.append(m["name"])
	_check("touch_live" in methods and "_touch_sampler" in methods, "the client carries the touch wiring")


func _tap(controls: DotMobileControls, index: int, pos: Vector2, pressed: bool) -> void:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.position = pos
	event.pressed = pressed
	# The buttons see it first (and handle it), then the overlay, as the tree would hand it on.
	controls.buttons._input(event)
	controls._input(event)


func _ignored(at: Vector2, controls: DotMobileControls) -> bool:
	return controls.ignore_fn.is_valid() and bool(controls.ignore_fn.call(at))


func _overlaps(buttons: Control, ids: Array[StringName]) -> String:
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var gap: float = buttons.centre_of(ids[i]).distance_to(buttons.centre_of(ids[j])) - buttons.radius_of(ids[i]) - buttons.radius_of(ids[j])
			if gap < 4.0:
				return "%s and %s" % [ids[i], ids[j]]
	return ""

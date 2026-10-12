extends CanvasLayer

const HsGame := preload("hs_game.gd")
const HsPlayer := preload("hs_player.gd")
const HsBindings := preload("hs_bindings.gd")
const HsController := preload("hs_controller.gd")

## What a player needs on screen: the clock and who it is counting for, which side they are on,
## how close they are to being caught, and — while the hiders hide — a blindfold for the
## seekers.
##
## [b]The blindfold is a screen, and the HUD is drawn over it.[/b] Seekers cannot see the map,
## the hiders or each other while the hiders hide, but they can still see their HUD and use
## the menus. So it is a black rect UNDER every widget here, with its own line saying how long
## is left; the world behind it is not drawn at all. It does not depend on the client being
## honest about drawing: a blindfolded seeker is also held still by a movement modifier the
## server owns (see [HsController]), and the server tells them nothing about where anybody
## went (see [HsInterest]).
##
## [b]The clock and the door prompt are dot-ui's glance pieces.[/b] The clock is a
## [DotScoreStrip] with the hiders still hidden and the seekers as its two side plates, in the
## sides' colours; the door prompt is a [DotKeyPrompt] under the crosshair with the use key
## drawn as a key. The disc stays: it says which side you are on with a letter, and nobody in
## this game has health.
##
## [b]The keys are read from the bindings, not written here.[/b] The hints in the corner say
## the key each action is on NOW, from the same table the menu's Controls page edits, so a
## rebound key is never a hint that lies.

const BLIND_FADE_SEC := 0.25
const BLIND_COLOUR := Color(0.01, 0.01, 0.015)

## The blindfold is not quite black: a seeker should be able to tell it from a client that
## stopped drawing.
const BLINDFOLD_COLOUR := Color(0.03, 0.025, 0.04)

## Seconds left at which the clock turns red.
const LOW_CLOCK_SEC := 10.0

## The map name's pale blue, which is also the glance pieces' highlight.
const MAP_COLOUR := Color(0.80, 0.88, 0.98)


## This game's accent over whichever theme the player picked in the menu (its highlight and
## the plates' edge). The plates, the words and their outline are the theme's, dark by default,
## so a light or high-contrast theme can change them. Static so a render tool can use it.
static func piece_theme() -> Theme:
	var t := Theme.new()
	var type := DotHudPiece.THEME_TYPE
	t.set_color(&"plate_edge", type, Color(MAP_COLOUR, 0.3))
	t.set_color(&"highlight", type, MAP_COLOUR)
	return t


## The Escape menu, whose theme this HUD follows (dot-menu's `follow_hud`): the menu sets the
## theme on the HUD's root now and at every theme change, and applies the player's HUD size.
## Christian's first play test (2026-10-11) asked for a darker HUD a player can restyle in
## the menu. Duck-typed and called by name, for a client shell older than dot-menu 7.
var _menu: Object = null


func follow_menu(menu: Object) -> void:
	_menu = menu
	_follow()


func _follow() -> void:
	if _root != null and _menu != null and _menu.has_method(&"follow_hud"):
		_menu.call(&"follow_hud", _root, piece_theme())


var game: HsGame = null
var player: HsPlayer = null

## `func(action: StringName) -> String`: the key an action is on, from the bindings.
var key_fn: Callable = Callable()

## What a player who is out is looking at, and the keys that change it. Empty while playing.
var watching_label: Label = null

## An administrator's `blind`, over the world and under the HUD.
var blind_overlay: ColorRect = null

## The seekers' blindfold while the hiders hide, under the HUD's widgets.
var blindfold: ColorRect = null

var _root: Control = null
## The clock, the hiders hidden and the seekers either side of it, and the caption and map
## name under it.
var strip: DotScoreStrip = null
## "Open the pantry door" with the use key drawn as a key, while one is in reach.
var prompt: DotKeyPrompt = null
var _shout: Label = null
var _hints: Label = null
var _disc: Panel = null
var _disc_label: Label = null
var _as: Label = null
var _lock: Label = null
var _seen_back: ColorRect = null
var _seen_fill: ColorRect = null
var _seen_label: Label = null
var _meter_back: ColorRect = null
var _meter_fill: ColorRect = null
var _meter_label: Label = null
var _blindfold_label: Label = null
var _crosshair: ColorRect = null
var _shout_for: float = 0.0


func bind(p_game: HsGame, p_player: HsPlayer) -> void:
	game = p_game
	player = p_player

	if _root == null:
		_build()


func _build() -> void:
	# A full-rect Control between the CanvasLayer and the labels: a CanvasLayer does not lay its
	# children out, so anchors on a Label parented straight to one resolve against nothing.
	_root = Control.new()
	_root.name = "Screen"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	blindfold = _cover("Blindfold", BLINDFOLD_COLOUR)
	blind_overlay = _cover("Blind", BLIND_COLOUR)

	_blindfold_label = _label(30)
	_blindfold_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_blindfold_label.offset_left = -520.0
	_blindfold_label.offset_right = 520.0
	_blindfold_label.offset_top = -40.0
	_blindfold_label.offset_bottom = 40.0
	_blindfold_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_blindfold_label.add_theme_color_override("font_color", Color(0.98, 0.78, 0.45))

	# The glance pieces read their colours from the theme on the type DotHudPiece; set on
	# the root, every piece under it inherits them. See [method piece_theme].
	_root.theme = piece_theme()
	_follow()

	# Top centre, full width because the strip centres itself on its own middle. Its plates
	# span 388 pixels round the middle, clear of the key hints top left at 1280 x 720.
	strip = DotScoreStrip.new()
	strip.name = "Clock"
	strip.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	strip.offset_top = 14.0
	strip.offset_bottom = 94.0
	_root.add_child(strip)

	# Top left: the keys this side has, as the player has them bound.
	_hints = _label(15)
	_hints.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	_hints.offset_left = 22.0
	_hints.offset_top = 18.0
	_hints.offset_right = 420.0
	_hints.offset_bottom = 260.0

	_shout = _label(40)
	_shout.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_shout.offset_top = 170.0
	_shout.offset_bottom = 240.0
	_shout.offset_left = -600.0
	_shout.offset_right = 600.0
	_shout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_shout.add_theme_color_override("font_color", Color(0.99, 0.86, 0.40))

	# Bottom left: a disc in the side's colour with a letter on it, what you are, and what is
	# happening to you.
	# Above the chat box, which also draws bottom-left.
	_disc = Panel.new()
	_disc.name = "Disc"
	_disc.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_disc.offset_left = 22.0
	_disc.offset_right = 102.0
	_disc.offset_top = -300.0
	_disc.offset_bottom = -220.0
	_disc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_disc)

	_disc_label = Label.new()
	_disc_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_disc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_disc_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_disc_label.add_theme_font_size_override("font_size", 26)
	_disc_label.add_theme_color_override("font_color", Color.WHITE)
	_disc_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	_disc_label.add_theme_constant_override("outline_size", 4)
	_disc.add_child(_disc_label)

	_as = _label(17)
	_as.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_as.offset_left = 112.0
	_as.offset_right = 600.0
	_as.offset_top = -296.0
	_as.offset_bottom = -266.0

	_lock = _label(15)
	_lock.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_lock.offset_left = 112.0
	_lock.offset_right = 600.0
	_lock.offset_top = -264.0
	_lock.offset_bottom = -240.0
	_lock.add_theme_color_override("font_color", Color(0.85, 0.92, 1.0))

	# The forced-taunt meter, under the disc's words: how long a hider has before they give
	# themselves away for standing still.
	_meter_back = _bar(Color(0.0, 0.0, 0.0, 0.45))
	_meter_fill = _bar(Color(0.98, 0.62, 0.20, 0.95))

	# The sight meter, in the middle of the screen where a hider is looking: it fills while a
	# seeker is watching them, and a full one is caught. Only under the sight rule.
	_seen_back = _centre_bar(Color(0.0, 0.0, 0.0, 0.5))
	_seen_fill = _centre_bar(Color(0.98, 0.42, 0.12, 0.95))
	_seen_label = _label(16)
	_seen_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_seen_label.offset_left = -200.0
	_seen_label.offset_right = 200.0
	_seen_label.offset_top = 68.0
	_seen_label.offset_bottom = 90.0
	_seen_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_seen_label.add_theme_color_override("font_color", Color(1.0, 0.72, 0.5))
	_meter_label = _label(15)
	_meter_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_meter_label.offset_left = 112.0
	_meter_label.offset_right = 420.0
	_meter_label.offset_top = -256.0
	_meter_label.offset_bottom = -236.0

	watching_label = _label(20)
	watching_label.name = "Watching"
	watching_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	watching_label.offset_left = -520.0
	watching_label.offset_right = 520.0
	watching_label.offset_top = -140.0
	watching_label.offset_bottom = -104.0
	watching_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	watching_label.add_theme_color_override("font_color", Color(0.80, 0.90, 1.0))

	# What the use key would do, under the crosshair while a door is in reach.
	prompt = DotKeyPrompt.new()
	prompt.name = "DoorPrompt"
	prompt.font_size = 15
	prompt.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	prompt.offset_left = -240.0
	prompt.offset_right = 240.0
	prompt.offset_top = 14.0
	prompt.offset_bottom = 46.0
	prompt.visible = false
	_root.add_child(prompt)

	_crosshair = ColorRect.new()
	_crosshair.name = "Crosshair"
	_crosshair.color = Color(1.0, 1.0, 1.0, 0.75)
	_crosshair.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_crosshair.offset_left = -3.0
	_crosshair.offset_top = -3.0
	_crosshair.offset_right = 3.0
	_crosshair.offset_bottom = 3.0
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_crosshair)


func _cover(cover_name: String, colour: Color) -> ColorRect:
	var rect := ColorRect.new()
	rect.name = cover_name
	rect.color = colour
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.modulate.a = 0.0
	rect.visible = false
	_root.add_child(rect)
	return rect


func _bar(colour: Color) -> ColorRect:
	var rect := ColorRect.new()
	rect.color = colour
	rect.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	rect.offset_left = 112.0
	rect.offset_right = 312.0
	rect.offset_top = -234.0
	rect.offset_bottom = -226.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.visible = false
	_root.add_child(rect)
	return rect


func _centre_bar(colour: Color) -> ColorRect:
	var rect := ColorRect.new()
	rect.color = colour
	rect.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	rect.offset_left = -120.0
	rect.offset_right = 120.0
	# Under the door prompt's plate (14 to 46), which a hider can have up at the same time.
	rect.offset_top = 54.0
	rect.offset_bottom = 64.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.visible = false
	_root.add_child(rect)
	return rect


func _label(size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_constant_override("outline_size", 6)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(label)
	return label


func set_watching(text: String) -> void:
	if watching_label != null:
		watching_label.text = text


## One line in the middle of the screen, for a few seconds.
func shout(text: String, seconds: float = 3.5) -> void:
	if _shout == null:
		return

	_shout.text = text
	_shout_for = seconds


func _process(delta: float) -> void:
	present_blind(delta)

	if game == null or game.config == null or _root == null:
		return

	var side := game.team_of(player.player_id) if player != null else 0
	var left := game.seconds_left()

	var caption := ""
	match game.phase:
		HsGame.Phase.HIDE:
			caption = "Seekers released in"
		HsGame.Phase.SEEK:
			caption = "Hiders win in" if game.config.timeout_winner == HsGame.HIDERS else "Time left"
		_:
			caption = "waiting for players" if not game.sides_are_playable() else "between rounds"

	# The caption under the clock rather than over it, as the strip draws every game's: it
	# reads "Hiders win in · Pinecrest Park".
	var running := game.phase != HsGame.Phase.IDLE
	strip.show_clock(
		DotScoreStrip.clock_text(left) if running else "", running and left <= LOW_CLOCK_SEC,
		caption, str(game.map_doc.get("name", ""))
	)
	if running:
		strip.show_scores(
			game.alive_on(HsGame.HIDERS), game.alive_on(HsGame.SEEKERS), "HIDDEN", "SEEKERS",
			game.side_colour(HsGame.HIDERS), game.side_colour(HsGame.SEEKERS)
		)
	else:
		strip.hide_scores()

	_draw_disc(side)
	_draw_hints(side)
	_draw_meter(side)
	_draw_seen(side)
	_draw_door_prompt()
	_crosshair.visible = player != null and player.is_alive() and not is_blindfolded()

	if _shout_for > 0.0:
		_shout_for -= delta
		if _shout_for <= 0.0:
			_shout.text = ""


func _draw_disc(side: int) -> void:
	var shown := player != null and player.is_alive() and not player.watching and side != 0
	_disc.visible = shown
	_as.text = ""
	_lock.text = ""

	if not shown:
		return

	var style := StyleBoxFlat.new()
	style.bg_color = game.side_colour(side)
	style.set_corner_radius_all(40)
	style.border_color = Color(1, 1, 1, 0.85)
	style.set_border_width_all(3)
	_disc.add_theme_stylebox_override("panel", style)
	_disc_label.text = "S" if side == HsGame.SEEKERS else "H"

	if side == HsGame.SEEKERS:
		_as.text = "SEEKER"
		if player.held_until >= 0.0 and game.phase == HsGame.Phase.SEEK:
			_lock.text = "caught — you can move in a moment"
		elif game.config.catches_by_touch() and game.config.catches_by_sight():
			_lock.text = "touch them, or keep them in sight"
		elif game.config.catches_by_sight():
			_lock.text = "keep them in sight to catch them"
		else:
			_lock.text = "touch them to catch them"
		return

	# Nothing under it: the taunt meter is drawn there, and the hints already say what to do.
	_as.text = "HIDER"


func _draw_hints(side: int) -> void:
	if player == null or not player.is_alive() or player.watching or side == 0 or is_blindfolded():
		_hints.text = ""
		return

	var lines := PackedStringArray()

	var moving := "Shift  Sprint    Ctrl  Crouch    %s  Doors" % _key(HsBindings.USE)

	if side == HsGame.HIDERS:
		lines.append("Hide. Don't get caught.")
		lines.append(moving)
		lines.append("%s / %s  Taunt / pick one" % [_key(HsBindings.TAUNT), _key(HsBindings.TAUNT_MENU)])
	else:
		lines.append("Find the hiders and %s them." % ("tag" if game.config.catches_by_touch() else "watch"))
		lines.append(moving)

	_hints.text = "\n".join(lines)


func _draw_meter(side: int) -> void:
	var shown := side == HsGame.HIDERS and player != null and player.is_alive() \
		and game.phase == HsGame.Phase.SEEK and game.config.show_taunt_meter and player.taunt_meter > 0.02
	_meter_back.visible = shown
	_meter_fill.visible = shown
	_meter_label.text = ""

	if not shown:
		return

	_meter_fill.offset_right = 112.0 + 200.0 * clampf(player.taunt_meter, 0.0, 1.0)
	var until := (1.0 - player.taunt_meter) * game.config.auto_taunt_seconds
	_meter_label.text = "Move, or you taunt in %d s" % int(ceilf(until))


## The sight rule's meter, while somebody is watching a hider.
func _draw_seen(side: int) -> void:
	var shown := side == HsGame.HIDERS and player != null and player.is_alive() \
		and game.phase == HsGame.Phase.SEEK and game.config.catches_by_sight() and player.sight_meter > 0.01
	_seen_back.visible = shown
	_seen_fill.visible = shown
	_seen_label.text = ""

	if not shown:
		return

	_seen_fill.offset_right = -120.0 + 240.0 * clampf(player.sight_meter, 0.0, 1.0)
	_seen_label.text = "YOU'RE BEING WATCHED"


## "Open the pantry door  [E]", while one is in reach and the key would do something.
func _draw_door_prompt() -> void:
	var words := _door_words()

	if words == "":
		prompt.clear()
	else:
		prompt.show_prompt(words, _key(HsBindings.USE))


## "Open the pantry door", "Kick the beach ball", or empty while nothing in reach would do
## anything. A toy looked at first, as the use key takes it first (`HsGame._advance_use`).
func _door_words() -> String:
	if player == null or not player.is_alive() or player.watching or is_blindfolded() \
			or game.map == null or player.controller.has_modifier(HsController.HOLD):
		return ""

	var toy := game.toy_aimed(player)

	if toy >= 0:
		return game.map.toys.toy(toy).prompt()

	if game.map.doors == null or not game.config.doors_enabled:
		return ""

	var doors := game.map.doors
	var index := doors.door_for(player.eye_position(), player.aim_direction())

	if index < 0:
		return ""

	var name := str((doors.doors[index]["spec"] as Dictionary)["name"])
	var what := "Shut" if doors.is_open(index) else "Open"
	return "%s%s" % [what, " the " + name if name != "" else ""]


func _key(action: StringName) -> String:
	return str(key_fn.call(action)) if key_fn.is_valid() else String(action)


func present_blind(delta: float) -> void:
	if blind_overlay == null:
		return

	var step := maxf(delta, 0.0) / BLIND_FADE_SEC
	blind_overlay.modulate.a = move_toward(blind_overlay.modulate.a, 1.0 if is_blind() else 0.0, step)
	blind_overlay.visible = blind_overlay.modulate.a > 0.0

	var folded := is_blindfolded()
	blindfold.modulate.a = move_toward(blindfold.modulate.a, 1.0 if folded else 0.0, step)
	blindfold.visible = blindfold.modulate.a > 0.0

	if _blindfold_label != null:
		_blindfold_label.visible = folded

		if folded and game != null:
			var left := game.seconds_left()
			# The strip's own words, so the two clocks on a seeker's screen never disagree by
			# the second one rounds down and the other up.
			_blindfold_label.text = "Counting while they hide\n%s" % DotScoreStrip.clock_text(left)


func is_blind() -> bool:
	return player != null and is_instance_valid(player) and player.blinded


## Whether this player is a seeker while the hiders hide.
func is_blindfolded() -> bool:
	return player != null and is_instance_valid(player) and game != null \
		and game.phase == HsGame.Phase.HIDE and game.team_of(player.player_id) == HsGame.SEEKERS \
		and player.is_alive()

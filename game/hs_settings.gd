extends DotMenuGameSettings

const HsBindings := preload("hs_bindings.gd")

## A player's own settings and the menu that changes them: view turn rate and width, volumes, the window, and the look of the menu. Use: `add_child(settings)`, `setup()` (loads, pushes every value), `bind_look/camera/audio`, `open()` (Escape does this in the client).
## dot-menu's `DotMenuGameSettings` with this game's spec. The scopes are the family's: `sensitivity` is ACCOUNT, `field_of_view` SERVER_CLAMPED (a wide view is an advantage a server may cap), volumes this machine's.

const SCHEMA_VERSION := 1

## Where this game's own document lives. The shared account document is dot-settings'.
const SETTINGS_DIR := "user://hideseek_settings"

## The app's namespace. ACCOUNT settings are shared under dot-menu's `tmc_account`.
const APP_NAMESPACE := &"hideseek"

## The field of view the camera had before this existed, and still the default.
const DEFAULT_FOV := 92

## Stock keys nothing here applies: every sound is on the SFX bus, the client binds no
## effects, and the chat box has no switch.
const NOT_APPLIED: Array[StringName] = [
	&"ui_volume", &"shake_scale", &"allow_flashes", &"fx_quality", &"chat_window",
]


func _init() -> void:
	super(spec_for())


## The game's settings as data: names, field of view, extra settings, keys and the help screen's goal and rules.
static func spec_for() -> DotMenuGameSpec:
	var s := DotMenuGameSpec.new()
	s.schema_version = SCHEMA_VERSION
	s.brand_name = "Hide & Seek"
	s.settings_dir = SETTINGS_DIR
	s.app_namespace = APP_NAMESPACE
	s.default_fov = DEFAULT_FOV
	s.ambient_text = "Quiet sounds under the map."
	s.not_applied = NOT_APPLIED
	s.bindings_maker = func() -> DotMenuBindings: return HsBindings.make()
	s.help_about = "Most players hide; one or two seekers count with their eyes shut, then go looking. A hider who is caught becomes a seeker where they stand. The hiders win if anybody is still hidden when the clock runs out."
	s.help_cards = [
		["Hiding", "Find somewhere nobody looks: under, behind, inside. Doors open and shut, some walls are not walls, and crouching gets you into small places. Taunt for points if you are brave; near the end the last hiders give themselves away with a beacon."],
		["Seeking", "Catch a hider by touching them, or, on a server set that way, by keeping them in view. Everybody you catch seeks with you."],
	]
	s.help_sections = [["Mouse", [["Left", "Watch the next player while out"], ["Right", "Watch the one before"]], &"keys"]]
	return s

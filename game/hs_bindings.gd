extends RefCounted

## Every key this game reads, as one [DotMenuBindings] table: action, setting, words, default and card. Four things read it: the client's event matching, the settings document, the Controls page and the help screen.
## Short on purpose: moving, crouching and looking are the movement rows. H is help in every game of the family (dot-menu adds the row), so nothing here may default to it.
## Chat is two rows on dot-ui's chat window's own actions (Y to all, U to your side), so the help screen lists them and the Controls page moves them.

const TAUNT := &"hs_taunt"
const TAUNT_MENU := &"hs_taunt_menu"
const VIEW := &"hs_view"
const SCOREBOARD := &"hs_scoreboard"
const USE := &"hs_use"
## The spectator's free camera, on and off (`mp_freeroam`). Its flying keys are the movement keys.
const ROAM := &"hs_roam"
## dot-ui's chat window's actions, which dot-game's chat client leaves at their defaults.
const CHAT := &"chat_open"
const CHAT_TEAM := &"chat_open_team"


static func make() -> DotMenuBindings:
	var keys := DotMenuBindings.new()
	keys.add_movement("Movement", "Ctrl", "Crouch")
	# dot-player-controller's own sprint and walk actions, as rows so the Controls page and the
	# help screen have them.
	keys.add(&"dot_fps_sprint", &"bind_sprint", "Sprint", "Shift", "Movement")
	keys.add(&"dot_fps_walk", &"bind_walk", "Walk quietly", "Alt", "Movement")
	keys.add_wheel_jump("Movement")
	keys.add(USE, &"bind_use", "Open or shut a door", "E", "General")
	keys.add(TAUNT, &"bind_taunt", "Taunt", "T", "Hiders")
	keys.add(TAUNT_MENU, &"bind_taunt_menu", "Pick a taunt", "F3", "Hiders")
	keys.add(CHAT, &"bind_chat", "Chat", "Y", "Communication")
	keys.add(CHAT_TEAM, &"bind_chat_team", "Chat to your side", "U", "Communication")
	keys.add(VIEW, &"bind_view", "First or third person", "F5", "General")
	keys.add(ROAM, &"bind_roam", "Free camera while out (move keys fly, Sprint fast, Walk slow)", "G", "General")
	keys.add(SCOREBOARD, &"bind_scoreboard", "Scoreboard (hold)", "Tab", "General")
	return keys

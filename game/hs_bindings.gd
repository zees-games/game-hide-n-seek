extends RefCounted

## Every key this game reads, as one [DotMenuBindings] table: the action, the setting that
## stores it, the words a player sees, the default, and the card it goes on.
##
## [b]A table, because four things read it:[/b] the client matches events against the actions,
## the settings document stores one binding per row, the menu's Controls page draws a key per
## row, and the help screen lists them with the key each is on now.
##
## [b]Short, on purpose.[/b] Hide-and-seek is moving, crouching and looking, all of which are
## the movement rows; what this game adds is the doors, the taunts, the view and the board.
##
## [b]H is help, in every game of the family[/b] (dot-menu adds the row), so nothing here
## may default to it.
##
## [b]Chat is two rows[/b] on dot-ui's chat window's own actions (Y to all, U to your side), so
## the help screen lists them and the Controls page moves them; until 2026-10-12 they were the
## window's defaults, on no page.

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
	# help screen have them; until 2026-10-11 they were only the sampler's defaults.
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

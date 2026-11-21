extends RefCounted

## Hide and seek's per-map settings: the rules a map may change, for gs-game's [GSGameMapConfig].
##
## `cfg/game/game-hide-n-seek/gs_map/map/<name>.yml` (a glob such as `hs_%.yml` covers a class of maps), overridable from `cfg/server/...`. Only the keys in [constant KEYS] are accepted; the rest are logged and ignored. A value under a key's `min` (or over its `max`) is refused with the key and value in the warning, never clamped. There is no `max` except the real domain limits: `hs_catch_mode` is the 0..2 enum, `hs_doors` and `hs_autobhop` are 0/1 switches, `hs_sight_fov` is an angle (180 degrees at most).

const GAME_ID := "game-hide-n-seek"

## cvar -> its constraint. Round pacing, catching, beacons, doors and the body's gravity; never a command, a vote or a bot setting.
const KEYS := {
	"hs_hide_seconds": {"type": "float", "min": 0.0},
	"hs_round_seconds": {"type": "float", "min": 30.0},
	"hs_catch_mode": {"type": "int", "min": 0, "max": 2},
	"hs_tag_range": {"type": "float", "min": 0.5},
	"hs_sight_seconds": {"type": "float", "min": 0.1},
	"hs_sight_range": {"type": "float", "min": 2.0},
	"hs_sight_fov": {"type": "float", "min": 10.0, "max": 180.0},
	"hs_doors": {"type": "int", "min": 0, "max": 1},
	"hs_beacon_hiders_left": {"type": "int", "min": 0},
	"hs_beacon_seconds_left": {"type": "float", "min": 0.0},
	"hs_beacon_every": {"type": "float", "min": 0.0},
	"hs_beacon_reveal": {"type": "float", "min": 0.25},
	"hs_gravity": {"type": "float", "min": 1.0},
	"hs_autobhop": {"type": "int", "min": 0, "max": 1},
}

## The subset a client predicts with: its own copy of the world's config is what moves the body.
const CLIENT_KEYS := {
	"hs_gravity": KEYS["hs_gravity"],
	"hs_autobhop": KEYS["hs_autobhop"],
}

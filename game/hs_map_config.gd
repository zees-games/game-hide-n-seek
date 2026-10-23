extends RefCounted

## Hide and seek's per-map settings: the rules a map may change, for dot-game's [DotGameMapConfig].
##
## `cfg/game/game-hide-n-seek/dot_map/map/<name>.yml` (a glob such as `hs_%.yml` covers a class of maps), overridable from `cfg/server/...`. Only the keys in [constant KEYS] are accepted; the rest are logged and ignored.

const GAME_ID := "game-hide-n-seek"

## cvar -> its constraint. Round pacing, catching, beacons, doors and the body's gravity; never a command, a vote or a bot setting.
const KEYS := {
	"hs_hide_seconds": {"type": "float", "min": 0.0, "max": 180.0},
	"hs_round_seconds": {"type": "float", "min": 30.0, "max": 1800.0},
	"hs_catch_mode": {"type": "int", "min": 0, "max": 2},
	"hs_tag_range": {"type": "float", "min": 0.5, "max": 4.0},
	"hs_sight_seconds": {"type": "float", "min": 0.1, "max": 30.0},
	"hs_sight_range": {"type": "float", "min": 2.0, "max": 200.0},
	"hs_sight_fov": {"type": "float", "min": 10.0, "max": 180.0},
	"hs_doors": {"type": "int", "min": 0, "max": 1},
	"hs_beacon_hiders_left": {"type": "int", "min": 0, "max": 32},
	"hs_beacon_seconds_left": {"type": "float", "min": 0.0, "max": 600.0},
	"hs_beacon_every": {"type": "float", "min": 0.0, "max": 120.0},
	"hs_beacon_reveal": {"type": "float", "min": 0.25, "max": 30.0},
	"hs_gravity": {"type": "float", "min": 1.0, "max": 60.0},
	"hs_autobhop": {"type": "int", "min": 0, "max": 1},
}

## The subset a client predicts with: its own copy of the world's config is what moves the body.
const CLIENT_KEYS := {
	"hs_gravity": KEYS["hs_gravity"],
	"hs_autobhop": KEYS["hs_autobhop"],
}

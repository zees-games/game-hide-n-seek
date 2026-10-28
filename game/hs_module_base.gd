extends DotGameModule
## The constants and instance state of [HsModule] (its base layer, split off for size); never loaded on its own.

const HsNetBridge := preload("net/hs_net_bridge.gd")
const HsServices := preload("hs_services.gd")
const HsMapConfig := preload("hs_map_config.gd")

const HsGame := preload("hs_game.gd")
const HsPlayer := preload("hs_player.gd")
const HsAvatars := preload("hs_avatars.gd")
const HsVote := preload("hs_vote.gd")
const HsAmbience := preload("hs_ambience.gd")
## The workbench kind of the ambience cvar set (saved to cfg/.../ambience/server.yml).
const AMBIENT_KIND := "ambience"

## Older cvar names kept for shipped server configs and map files: alias -> HsConfig field.
const ALIASES := {
	"hs_caught_seek": "caught_become_seekers",
	"hs_caught_from": "caught_seek_from",
	"hs_caught_freeze": "caught_freeze_seconds",
	"hs_side_choice": "allow_side_choice",
	"hs_doors": "doors_enabled",
	"hs_autobhop": "auto_bunny_hop",
	"hs_min_players": "minimum_players",
	"sv_map_rotation_file": "map_rotation_file",
}

## Seconds between checks of how many people are in the round.
const ROSTER_INTERVAL := 2.0

## The `hs_bots` cvar, held so the tick does not look it up sixty times a second.
var _bots: DotConVar = null

## `mp_forcecamera`, kept so the deprecated `hs_spectate_camera` writes through it.
var _force_camera_cvar: Object = null

## How many stand-ins, from how many people: dot-server's one rule for every game. See
## [method _keep_the_round_full].
var _quota: DotBotQuota = null

var _since_roster_check: float = 0.0

## How many stand-ins this module has put in, so it can take them out again.
var _bot_ids: Array[StringName] = []

## The players' vote for the next map; null when it could not be built.
var vote: HsVote = null

## dot-workbench over the config and the block rules; null before the module loads.
var workbench: DotGameWorkbench = null

## The drawn ballot's notice topic. The client shell draws one menu per topic.
const MAP_BALLOT_TOPIC := &"map_ballot"

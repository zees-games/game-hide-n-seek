extends Node

const HsConfig := preload("hs_config.gd")
const HsGame := preload("hs_game.gd")

## What a [DotServer] loads as its game scene. Never a client. Small on purpose: everything a dedicated server does is in `hs_module.gd`;
## dot-server loads a SCENE, and the world must be in the tree (registered under [constant HsGame.SERVICE]) before the module looks for it.
## It lives in `game/` not `scenes/`: a game is vendored as `game/` plus only the `.tscn` files, so a script under `scenes/` never reaches the build.

const CHANNEL := "hs.server"

## The world this server is running. What the module will find in the registry.
var game: HsGame = null


func _ready() -> void:
	var config := HsConfig.new()

	# The family's `defaults < JSON < environment < argv` chain, through DotGameConfigBinder (cfg/game and cfg/server yml too, strict on a
	# dedicated server): how an operator sets `HS_HIDE_SECONDS` or `--hs-round-seconds` without editing anything.
	var binder := HsConfig.make_binder(config, "user://cfg/hideseek.json")
	var loaded := binder.load_layers()

	if not loaded.ok:
		DotGameConfigBinder.fail_boot(get_tree(), loaded)
		return

	game = HsGame.new()
	game.name = "World"
	game.config = config
	game.config_binder = binder
	# The engine's rate, which the server has already set from `sv_tickrate`: read rather than chosen, since this scene loads after the boot,
	# and a game that picked its own would simulate at one rate inside a process ticking at another.
	game.tick_rate = Engine.physics_ticks_per_second
	add_child(game)

	DotLog.info(CHANNEL, "the world is up", {
		"tick_rate": game.tick_rate,
		"maps": config.map_directory,
		"round": config.round_seconds,
	})

	# Not started here: `start()` builds the map and nothing is listening yet (the module builds the bridge that answers `world_rebuilt`),
	# so a map built now is one no client is sent. The module starts it, on the last line of its own load.

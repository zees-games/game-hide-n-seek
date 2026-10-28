extends Node3D
## The constants, signals and exported state of [HsGame] (its base layer, split off for size); never used on its own.

const HsAmbience := preload("hs_ambience.gd")
const HsCatalogue := preload("hs_catalogue.gd")
const HsConfig := preload("hs_config.gd")
const HsMap := preload("hs_map.gd")
const HsMapDoc := preload("hs_map_doc.gd")
const HsPaths := preload("hs_paths.gd")
const HsPlayer := preload("hs_player.gd")
const HsProgress := preload("hs_progress.gd")
const HsProps := preload("hs_props.gd")
const HsRules := preload("hs_rules.gd")
const HsSpectate := preload("hs_spectate.gd")
const HsController := preload("hs_controller.gd")
const HsBots := preload("hs_bots.gd")

const CHANNEL := "hs.game"

## Where this world publishes itself, so a module can find it. A registry name and not an
## autoload: a server and a client in one process are two of these.
const SERVICE := &"hs_game"

## Where a host that runs this game with no server (the client shell's Solo play) publishes
## the map packs it mounted for it. See [method solo_map_dirs].
const SOLO_SERVICE := &"dot_solo"

## Snapshots a second. What a seeker reads continuously is somebody running across a room.
const NET_SNAPSHOT_RATE := 30

## How far a position may be from the origin, in metres, on the wire. Both ends read it here.
const NET_WORLD_EXTENT := 512.0

## The two sides. Fixed ids, because the whole game is about which of the two somebody is.
const HIDERS := 1
const SEEKERS := 2

## The brief: hiders in blue. Seekers in an orange that cannot be mistaken for it in any light.
const TEAM_COLOURS: Array[Color] = [
	Color(0.22, 0.52, 1.0),
	Color(0.98, 0.42, 0.12),
]

const TEAM_NAMES: Array[String] = ["Hiders", "Seekers"]

## Which part of the round it is.
enum Phase {
	## Between rounds, or waiting for enough people.
	IDLE,
	## The hiders hide; the seekers are blindfolded and held still.
	HIDE,
	## The seekers are let go.
	SEEK,
}

## Why somebody's health ran out: below the map, or an administrator.
const DIED_FELL := &"fell"
const DIED_SLAIN := &"slain"

## How a hider was caught.
const CAUGHT_TAG := &"tag"
const CAUGHT_SIGHT := &"sight"
const CAUGHT_FELL := &"fell"

## How far apart two bodies' feet may be in height and still touch, in metres.
const TAG_HEIGHT := 1.6

signal player_added(player_id: StringName)
signal player_removed(player_id: StringName)
signal round_began(number: int, map_id: StringName)
signal world_clearing()
signal world_rebuilt()
signal round_over(number: int, winner: int, winner_name: String)
signal phase_changed(phase: int)
signal side_changed(player_id: StringName, side: int)
signal player_died(player_id: StringName, by: StringName, why: StringName)

## A hider was caught: by a seeker ([param by]), or by a fall (empty), [param how] being one of
## the CAUGHT_ constants.
signal caught(player_id: StringName, by: StringName, how: StringName)

## Somebody taunted: [param taunt_id] from the taunt list, forced or chosen.
signal taunted(player_id: StringName, taunt_id: StringName, forced: bool)

## Somebody used door [param index] on [param tick]: it is on its way to [param open].
signal door_used(index: int, open: bool, flip: bool, tick: int, by: StringName)

## Something a player asked for was refused, and why. Told to them alone.
signal refused(player_id: StringName, why: String)

signal achievement_earned(player_id: StringName, title: String, points: int)

@export var config: HsConfig = null
@export var authoritative: bool = true
@export_range(1, 240, 1) var tick_rate: int = 64
@export var external_tick: bool = false
@export var register_service: bool = true

## Whether the map is drawn. A client sets it.
@export var draw_world: bool = false

var map: HsMap = null
var catalogue: HsCatalogue = null
var props_catalogue: HsProps = null
var combat: DotCombatManager = null
var match_node: DotMatch = null
var random: DotRandomManager = null
var physics: DotPhysicsLayout = null

## What a dead body does, and which death reactions the server allows: dot-player-char's
## `sv_ragdoll*` cvars, bound by the module (REPLICATED) and followed by a client through its
## link, because the client draws the bodies.
var ragdoll_rules: DotPlayerRagdollRules = DotPlayerRagdollRules.new()

## dot-props' `sv_toys*` (whether a map's toys are there, how many simulate at once, how hard a
## walk pushes one). Bound by the module (REPLICATED) and followed by a client, which draws them.
var toy_rules: DotPropToyRules = DotPropToyRules.new()

## What a person weighs on a see-saw, kg.
const PERSON_MASS := 70.0
var effects: DotFxManager = null
var spectate: HsSpectate = null
var progress: HsProgress = null
var taunts: DotPropTaunts = null

## player id -> HsPlayer.
var players: Dictionary = {}

## dot-player-controller's `mp_forceview` (may a player switch to third person) and
## `mp_solidplayers` (do players and stand-ins block each other). Bound by the module
## (REPLICATED) and followed by a client through its link.
var view_rules: DotPlayerViewRules = DotPlayerViewRules.new()
## Who a spectator may watch and whether they may fly a free camera: dot-spectate's `mp_forcecamera`,
## `mp_freeroam` and `mp_freeroam_speed`. Shared with [HsSpectate]'s manager, bound by the module
## (REPLICATED) and followed by a client, which is the end that flies the camera.
var spectate_rules: DotSpectatorRules = DotSpectatorRules.new()
var body_rules: DotPlayerBodyRules = DotPlayerBodyRules.new()

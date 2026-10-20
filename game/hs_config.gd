extends DotConfig

## Every number this game has, layered like every other [DotConfig] in the family:
## [code]exported defaults < JSON file < environment < command line[/code].
##
## [b]Metres and seconds.[/b] The maps are documents in the same units (see [HsMapDoc]), so a
## length a mapper writes and a length this file tunes against are the same number.
##
## [b]Every rule the brief named is here, and its default is the brief's.[/b] How a hider is
## caught (a touch, by default; being watched, or either, as a setting), whether a caught hider
## joins the seekers, how many seekers a round starts with, how long the hide is, when a taunt
## is forced, when the last hiders are given away: a server owner changes any of them in
## `user://cfg/hideseek.json`, an environment variable (`HS_HIDE_SECONDS`) or a flag
## (`--hs-hide-seconds`), and the commonly turned ones are cvars as well (see
## `HsModule._add_tunables`).

## How a seeker catches a hider. See [member catch_mode].
enum Catch {
	## By touching them: a seeker's body within [member tag_range] of theirs.
	TOUCH,
	## By watching them: a hider in a seeker's sight fills a meter, and a full meter is caught.
	SIGHT,
	## Whichever happens first.
	EITHER,
}

## How the first seekers of a round are chosen. See [member seeker_pick].
enum Pick {
	## A random draw that skips last round's seekers ([DotTeamRotation]'s RANDOM).
	RANDOM,
	## Everybody an equal share of turns over time (QUEUE).
	QUEUE,
	## Last round's hiders seek (SWAP).
	SWAP,
	## Whoever was caught first last round seeks, and the draw fills the rest.
	FIRST_CAUGHT,
}

# --- The round -------------------------------------------------------------

@export_group("The round")

## Seconds the hiders have to hide while the seekers are blindfolded and held still.
@export_range(0.0, 180.0, 1.0) var hide_seconds: float = 40.0

## Seconds the seekers have to catch everybody once they are let go. A map may ask for less.
@export_range(30.0, 1800.0, 5.0) var round_seconds: float = 240.0

## Seconds between rounds.
@export_range(0.0, 60.0, 1.0) var intermission_seconds: float = 8.0

## Seconds of warmup before the first round. 0 starts immediately.
@export_range(0.0, 300.0, 1.0) var warmup_seconds: float = 8.0

## Who wins a round the clock ends: 1 the hiders, 2 the seekers, 0 nobody.
##
## [b]The hiders, because staying hidden until the clock runs out is their whole objective.[/b]
@export_enum("draw", "hiders", "seekers") var timeout_winner: int = 1

# --- The sides -------------------------------------------------------------

@export_group("The sides")

## One seeker for every this many players, rounded up, at least [member min_seekers] and at
## most [member max_seekers] — and never everybody.
##
## [b]Few, by design.[/b] Unlike a game where the sides are even, a round starts with one or two
## seekers and grows them out of the hiders they catch; eight players start with one.
@export_range(1.0, 64.0, 0.5) var players_per_seeker: float = 8.0
@export_range(1, 16, 1) var min_seekers: int = 1
@export_range(1, 32, 1) var max_seekers: int = 3

## How the first seekers are chosen each round: [enum Pick].
@export_enum("random", "queue", "swap", "first caught") var seeker_pick: int = Pick.FIRST_CAUGHT

## Whether a player's own wish (`!seek`, `!hide`, `!any`) counts in the draw.
@export var allow_side_choice: bool = true

# --- Catching --------------------------------------------------------------

@export_group("Catching")

## How a hider is caught: 0 a touch, 1 being watched, 2 either. See [enum Catch].
@export_enum("touch", "sight", "either") var catch_mode: int = Catch.TOUCH

## How close a seeker's body must come to a hider's to tag them, centre to centre, in metres.
## Two bodies touching are 0.7 apart; the rest is reach.
@export_range(0.5, 4.0, 0.05) var tag_range: float = 1.2

## Whether a caught hider becomes a seeker where they stand. Off, a caught hider is out and
## watches the rest of the round.
@export var caught_become_seekers: bool = true

## Seconds a newly made seeker is held still before they may chase, so a hider caught beside
## another one does not hand the second over in the same breath.
@export_range(0.0, 15.0, 0.5) var caught_freeze_seconds: float = 3.0

## Where a caught hider starts seeking: 0 where they were caught, 1 at the seekers' start.
## [b]0 hands the catch on[/b]: a hider caught knows where their friends hid, and stands up
## seeking beside the next one. 1 sends them back to where the seekers counted, so each catch is
## a seeker more without a free second one.
@export_range(0, 1, 1) var caught_seek_from: int = CAUGHT_SEEK_HERE

const CAUGHT_SEEK_HERE := 0
const CAUGHT_SEEK_START := 1

## How far a seeker can see a hider for the sight rule, in metres.
@export_range(2.0, 200.0, 1.0) var sight_range: float = 25.0

## How wide a seeker's sight is for the sight rule: the whole angle of the cone, in degrees.
@export_range(10.0, 180.0, 1.0) var sight_fov: float = 70.0

## Seconds of being watched that fill a hider's meter.
@export_range(0.1, 30.0, 0.1) var sight_seconds: float = 2.0

## How fast the meter drains when nobody is watching, in meters a second (1 empties a full one
## in one second).
@export_range(0.0, 10.0, 0.05) var sight_decay: float = 0.35

# --- Taunts ----------------------------------------------------------------

@export_group("Taunts")

## Where the taunt list is read from, relative to this game's root. A list of
## `{"id", "title", "seconds", "sound"}`; see `taunts/taunts.json`.
@export var taunt_file: String = "taunts/taunts.json"

## Seconds a hider may stand within [member auto_taunt_radius] before a taunt is forced. 0 never.
@export_range(0.0, 600.0, 1.0) var auto_taunt_seconds: float = 60.0
@export_range(0.1, 20.0, 0.1) var auto_taunt_radius: float = 1.5

## Whether a hider sees the meter filling toward a forced taunt.
@export var show_taunt_meter: bool = true

## Whether the use key opens and shuts a map's doors. Off, every door stays as the map has
## it: a server that wants the maps' layouts without the doors' noise.
@export var doors_enabled: bool = true

## Seconds between taunts, on top of the last one's length.
@export_range(0.0, 60.0, 0.5) var taunt_cooldown: float = 2.0

## Points for a taunt a hider chose, and for one forced on them.
@export_range(0, 100, 1) var taunt_points: int = 2
@export_range(0, 100, 1) var forced_taunt_points: int = 0

## Metres a taunt carries.
@export_range(5.0, 300.0, 1.0) var taunt_range: float = 60.0

# --- Giving the last hiders away --------------------------------------------

@export_group("The beacon")

## Every hider still hidden is beaconed once this few are left. 0 never.
@export_range(0, 32, 1) var beacon_hiders_left: int = 1

## Every hider still hidden is beaconed once this few seconds are left. 0 never, the default:
## with it at 30 the bots' hiders won 6 rounds in 24 at medium instead of 10, because every
## seeker there is by then walks to every hider still in, and a round the hiders had held for
## three and a half minutes was lost in the last half minute. The last hider's beacon
## ([member beacon_hiders_left]) is what ends a round nobody can find anybody in.
@export_range(0.0, 600.0, 1.0) var beacon_seconds_left: float = 0.0

## Seconds between a beacon's pings.
@export_range(0.25, 10.0, 0.25) var beacon_period: float = 2.0

## Seconds between the beacon showing the last hiders, and for how long each time. 0 shows them
## the whole time.
##
## [b]A reveal now and then, not a marker held on them.[/b] Held, the last hider was walked to by
## every seeker at once from anywhere on the map, and a round with one left was a round lost: at
## medium the bots' hiders won 2 rounds in 24. Shown for two seconds in ten, the seekers learn
## where and go, and the hider has eight seconds to be somewhere else: a chase, not a sentence.
@export_range(0.0, 120.0, 0.5) var beacon_every: float = 10.0
@export_range(0.25, 30.0, 0.25) var beacon_reveal: float = 2.0

# --- Points ----------------------------------------------------------------

@export_group("Points")

## Points to everybody on the winning side.
@export_range(0, 100, 1) var winner_points: int = 10

## Points to a seeker for each hider they catch.
@export_range(0, 100, 1) var catch_points: int = 5

## Points to every hider still hidden when the round ends.
@export_range(0, 100, 1) var survive_points: int = 5

# --- The players -----------------------------------------------------------

@export_group("The players")

@export_range(1.0, 400.0, 1.0) var player_health: float = 100.0

@export_range(1.0, 20.0, 0.1) var run_speed: float = 6.0

## How much faster sprinting is than running (Shift). 1 turns sprinting off.
@export_range(1.0, 3.0, 0.05) var sprint_scale: float = 1.35

## How fast a seeker runs against a hider: 1 the same. A server that finds its seekers never
## catch anybody raises it a little.
@export_range(0.5, 2.0, 0.01) var seeker_speed_scale: float = 1.0

@export_range(0.1, 5.0, 0.05) var jump_height: float = 1.15
@export_range(1.0, 60.0, 0.5) var gravity: float = 20.0
@export var auto_bunny_hop: bool = false
@export_range(0.0, 200.0, 1.0) var air_accelerate: float = 20.0

# --- The maps --------------------------------------------------------------

@export_group("The maps")

## Which maps this server may play, by id. Empty means every one it has.
@export var map_ids: PackedStringArray = PackedStringArray()

## Whether the next map is drawn at random (seeded) rather than taken in order.
@export var shuffle_maps: bool = true

## Rounds played on a map before the next one, unless the players vote first.
@export_range(1, 50, 1) var rounds_per_map: int = 4

## Where map documents are read from, relative to this game's root.
@export var map_directory: String = "maps"

## The file that says which maps a server ROTATES: `cfg/maps.yml`, layered over the game's own
## shipped `res://maps.yml` (dot-map's `DotMapRotationFile`: named rotations, `random` or
## `cycle`, wildcards, command names). Empty, or no such file, rotates every map. A map the
## active rotation leaves out stays installed (`hs_map <id>` queues it); it is only never drawn
## or balloted. `sv_map_rotation_file`.
@export var map_rotation_file: String = "cfg/maps.yml"

## Seed every random choice is drawn from: the map, the seekers, the bots.
@export var seed_value: int = 20261010

# --- Bots ------------------------------------------------------------------

@export_group("Bots")

## How many players the server keeps in the round by adding stand-ins.
@export_range(0, 24, 1) var minimum_players: int = 5

# How far a stand-in sees and hears, how fast it turns and notices, and how well it knows a
# map are dot-bot's `bot_*` settings, shared by every game (`bot_difficulty`, `bot_sight`,
# `bot_fov`, `bot_hearing`, `bot_reaction`, `bot_map_knowledge`, ...).

# --- Watching --------------------------------------------------------------

@export_group("Watching")

## Who somebody who is out may watch: 0 anybody, 1 their own side, 2 nobody.
@export_enum("anybody", "own side", "nobody") var spectate_camera: int = 0

# --- Progress --------------------------------------------------------------

@export_group("Progress")

@export var keep_progress: bool = true
@export var progress_directory: String = ""
@export var report_progress: bool = false


func env_prefix() -> String:
	return "HS_"


func cli_prefix() -> String:
	return "--hs-"


## How many seekers a round with [param players] in it starts with.
func seekers_for(players: int) -> int:
	return DotTeamRotation.count_for(players, players_per_seeker, min_seekers, max_seekers)


func catches_by_touch() -> bool:
	return catch_mode == Catch.TOUCH or catch_mode == Catch.EITHER


func catches_by_sight() -> bool:
	return catch_mode == Catch.SIGHT or catch_mode == Catch.EITHER


func validate() -> DotResult:
	if round_seconds <= 0.0:
		return DotResult.fail(DotError.CODE_INVALID, "A round has to last some time.")

	if min_seekers > max_seekers:
		return DotResult.fail(DotError.CODE_INVALID, "min_seekers is over max_seekers.")

	if timeout_winner < 0 or timeout_winner > 2:
		return DotResult.fail(DotError.CODE_INVALID,
			"timeout_winner is %d; it is 0 (draw), 1 (hiders) or 2 (seekers)." % timeout_winner)

	if seeker_pick < 0 or seeker_pick > Pick.FIRST_CAUGHT:
		return DotResult.fail(DotError.CODE_INVALID,
			"seeker_pick is %d; it is 0 (random), 1 (queue), 2 (swap) or 3 (first caught)." % seeker_pick)

	if catch_mode < 0 or catch_mode > Catch.EITHER:
		return DotResult.fail(DotError.CODE_INVALID,
			"catch_mode is %d; it is 0 (touch), 1 (sight) or 2 (either)." % catch_mode)

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"round": "%.0f s hide, %.0f s seek" % [hide_seconds, round_seconds],
		"seekers": "1 per %.1f, %d..%d, %s" % [players_per_seeker, min_seekers, max_seekers,
			["random", "queue", "swap", "first caught"][seeker_pick]],
		"catch": ["touch (%.2f m)" % tag_range, "sight (%.1f s)" % sight_seconds, "either"][catch_mode],
		"caught": ("join the seekers " + ("where caught" if caught_seek_from == CAUGHT_SEEK_HERE else "at their start")) if caught_become_seekers else "are out",
		"timeout": ["draw", "hiders", "seekers"][timeout_winner],
		"taunts": "forced after %.0f s within %.1f m" % [auto_taunt_seconds, auto_taunt_radius]
			if auto_taunt_seconds > 0.0 else "never forced",
		"beacon": "%d left or %.0f s, %s" % [beacon_hiders_left, beacon_seconds_left,
			"held" if beacon_every <= 0.0 else "%.1f s in %.0f" % [beacon_reveal, beacon_every]],
		"maps": "all" if map_ids.is_empty() else ",".join(map_ids),
		"bots": minimum_players,
	}


func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("hideseek configuration")
	var facts := describe()
	for key: String in facts:
		lines.append("  %-10s %s" % [key, facts[key]])
	return lines

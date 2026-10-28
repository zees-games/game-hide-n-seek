extends RefCounted
## The constants and state of [HsBots] (its base layer, split off for size); never used on its own.

const HsPlayer := preload("hs_player.gd")

const CHANNEL := "hs.bots"

## How loud moving is, as a share of `bot_hearing`: sprinting, running, crouched.
const LOUD_SPRINT := 0.45
const LOUD_RUN := 0.28
const LOUD_CROUCH := 0.06

## A taunt is a shout.
const LOUD_TAUNT := 1.0

## Places surveyed: points across the walkable floor, and beside the props.
const SURVEY_POINTS := 260
const SURVEY_PROPS := 160
const WATCHERS := 80

## Annotator slices stepped each tick while it runs: fixed, so a seeded round starts the hide at
## the same tick wherever the frames fall.
const ANNOTATE_STEPS_PER_TICK := 6

const DROP_MAX := 2.0

## Metres between two links along one stretch of edge (the annotator's default is 2).
const LINK_SPACING := 6.0

## A corner a bot gave up on is shunned for [constant SHUN_FOR] seconds, so it does not go straight back
## through the doorway it could not pass.
const SHUN_COST := 200.0
const SHUN_FOR := 30.0
const SHUN_RADIUS := 0.8
## The seeker's sweep places beside the annotator's hiding spots: a few random points on the
## mesh so the open floor is looked at too, after the tour.
const SWEEP_POINTS := 120

## What a hider thinks of a spot beyond its exposure: how tucked in it is (the share of sixteen
## directions blocked within 2 m) is worth this much exposure, and cover from the seekers' start
## (crouched behind something from every one of them) this much more.
const ENCLOSED_BONUS := 0.30
const COVER_BONUS := 0.25

## The seeker's tour before it sweeps: this many of the best hiding spots, at knowledge 1 (and
## [constant TOUR_MIN] at 0), and every chokepoint up to [constant TOUR_CHOKES], nearest next.
const TOUR_SPOTS := 12
const TOUR_MIN := 4
const TOUR_CHOKES := 4

## A tour stop within this of where another seeker is going is left to that seeker.
const TOUR_APART := 6.0

## Eye heights the quality measure's watchers stand at come from the player; this many of them.
const QUALITY_WATCHERS := 120

## A seeker this near, walking straight at the hider without having seen it, is coming to its
## place. Out of the hider's sight line it slips away low; in it, the hider keeps still, because
## moving is what the seeker would see. One passing any other way is let pass.
const COMING_FROM := 12.0
const COMING_CONE := 30.0

## Where a running hider goes: out of the seeker's sight, at least this far from it, at most
## this far from where it was.
const FLEE_CLEAR := 12.0
const FLEE_WITHIN := 30.0
## A place being run to is kept while it is this much farther from the threat than the runner.
const FLEE_KEEP := 2.0

## A seeker that can see a hidden hider from nearer than this is waited out, not run from.
const FREEZE_WITHIN := 9.0

## A seeker this close is about to walk into the hider whatever it has seen: run.
const BUMP_FROM := 2.4

## How far ahead of a walking bot an open door's panel counts as in the way, and how long it
## may spend going round one before it tries the plain path again.
const DETOUR_LOOK := 1.6
const DETOUR_SECONDS := 4.0
const DETOUR_AGAIN := 10.0

## How long a bot may make no headway before it counts as stuck, and how far it must get from
## where it was first stuck before that stops counting: stepping aside and back again, or a hop
## that lands where it took off, is not headway.
const STUCK_SECONDS := 0.6
const STUCK_LEFT := 1.5

## How near a corner a bot comes before it turns for the next one whatever is in the way.
const CORNER_CLOSE := 0.15

## How far past a doorway a body is clear of the panel's swing (a door is at most about a
## metre wide), before it turns to shut it.
const DOOR_CLEAR := 1.4

## How long a walking bot stays within [constant STUCK_LEFT] of one spot beside an open door's
## panel before it shuts that door (`_linger_by_door`). `headless_bots` holds the worst to 9.0 s.
const LINGER_SHUT := 5.0

## Still there this long after it first came (door would not shut, or the walk returned to the same spot): somewhere else, once.
## Else a seeker stayed in the corner behind its open door.
const LINGER_GIVE_UP := 8.0
## Seconds round one spot before a goal under an open panel is dropped (`_linger_by_door`).
const LINGER_POCKET := 2.5

## How long a door that would not shut is left alone.
const SHUT_FAILED_FOR := 10.0

## A place a bot lingered at is left out of its flee goals this far around, for this long.
## How long a seeker that gave up a goal at a door ignores the hider it was chasing.
const CHASE_OFF_FOR := 4.0
const AVOID_RADIUS := 4.0
const AVOID_FOR := 20.0


## How far off, as a share of `bot_sight`, somebody still and crouched is made out, and only whole (head and chest).
## Tuned against `headless_bots` hider win rates; not monotonic (0.08 was worse than 0.10), so re-measure before moving it.
const STILL_LOW_SIGHT := 0.10

## Metres from the eye within which somebody is felt whichever way the bot faces: an arm's
## length, about, past the touch's reach.
const FELT_WITHIN := 2.0

## How fast a seeker searches, as a share of a run (1.7 m/s); chasing is a sprint. At a run the seekers
## searched a house in a minute. Tuned with STILL_LOW_SIGHT against `headless_bots` hider win rates.
const SEARCH_PACE := 0.28

## Seconds a hider waits after a move before it may move again for the same seeker.
const SETTLE := 2.5

## The same for a hider the beacon is giving away, which keeps moving.
const MARKED_SETTLE := 1.0

var game: Node = null

var nav: DotBotNav = DotBotNav.new()

## `[{at, exposure, ...}]`, the annotator's hiding spots for the map built (the random survey
## when the map has no annotations), or empty.
var spots: Array[Dictionary] = []

## A few random places beside [member spots] that the seekers' sweep looks at too.
var sweep: Array[Dictionary] = []

## The map's annotations ([DotNpcAiNavAnnotator]): links, spots, chokepoints. Null until made.
var annotations: DotNpcAiNavAnnotations = null

## How long the annotation took (or was loaded), milliseconds, and whether it came from the cache.
var annotate_ms: float = 0.0
var annotate_cached: bool = false

## Drop and jump-up links handed to the mesh.
var links_used: int = 0

var _annotator: DotNpcAiNavAnnotator = null
var _cached: DotNpcAiNavAnnotations = null
var _job: DotJob = null
var _job_done: bool = false
var _job_steps: int = 0

## Where each jump-up link starts: a bot near one with its next corner above it hops.
var _jump_feet: PackedVector3Array = PackedVector3Array()

## Hiders' pool for this round, from [method _hider_pool]; cleared by [method reset].
var _pool: Array[Dictionary] = []
var _pool_threats: PackedVector3Array = PackedVector3Array()
var _watch_eyes: PackedVector3Array = PackedVector3Array()

## Which map the survey is of, and which the mesh was baked for.
var _surveyed: String = ""
var _baked: String = ""
## The agent radius the mesh was baked with; narrowed to one cell when a doorway closes the spawns off from each other.
var _nav_radius := HsPlayer.BODY_RADIUS
var _narrowing := false
var _survey_at: int = 0

## player id -> the bot's own state.
var _state: Dictionary = {}

## Sounds this tick and the last second: `[{at, loud, by, side, t}]`.
var _sounds: Array[Dictionary] = []

## Doors stand-ins have shut behind them this round, for the suite.
var doors_shut: int = 0

## The longest any stand-in has spent this round walking and still within [constant STUCK_LEFT]
## of one spot beside an open door's panel (seconds), who, and where: `headless_bots` holds it
## down, which covers every door the rounds walk through.
var longest_stuck: float = 0.0
var _door_rid_list: Array[RID] = []
var _door_rid_doors: Object = null
var longest_stuck_at: Vector3 = Vector3.ZERO
var longest_stuck_who: StringName = &""

## How long the last survey took, milliseconds.
var survey_ms: float = 0.0

## The stand-ins as Christian's review saw them (hiders stood where they spawned, the seeker walked
## a straight line), kept so `headless_bots` can arm its checks: each must fail with this on, or it
## measures nothing. Never set by the game itself.
var legacy: bool = false

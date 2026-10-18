extends CharacterBody3D

const HsConfig := preload("hs_config.gd")
const HsController := preload("hs_controller.gd")
const HsFigure := preload("hs_figure.gd")
const HsAvatars := preload("hs_avatars.gd")

## One person: how they move, which side they are on, and how close they are to being caught.
##
## [b]Everybody is themselves.[/b] A hider is their own avatar with the hiders' blue on the
## torso, a seeker the same with the seekers' orange; nobody turns into anything. What changes
## when a hider is caught is the side, and the body stays where it was.
##
## [b]No hitboxes and no weapons.[/b] Nothing here is shot: a seeker catches by touching, or by
## watching (see [member HsConfig.catch_mode]), and both are distances and rays the server
## measures between bodies. Health is kept for the two things that still take it away — a
## fall below the map, and an administrator's slay — so dot-moderation's god, buddha and slap
## mean what they mean everywhere else.

## Metres above a player's feet that their eyes are.
const EYE_HEIGHT := 1.6

## A player's body hull, in metres: the family's.
const BODY_RADIUS := 0.35
const BODY_HEIGHT := 1.8
const BODY_CROUCH := 0.95
const BODY_STEP := 0.4

## The use key, in the movement command's buttons: one dot-player-controller leaves to games,
## so it rides in every input packet with the movement and needs no field of its own.
const USE_BUTTON := DotFpsCommand.BUTTON_USER_0

@export var player_id: StringName = &"local"
@export var display_name: String = "Player"
@export var samples_input: bool = false
@export var is_bot: bool = false

## What this player looks like, as a dot-user-avatar document; null is the stock person.
var avatar: DotAvatar = null

var config: HsConfig = null

var controller: HsController = null
var sampler: DotFpsSampler = null
var health: DotHealth = null

## Which side they are on now: [constant HsGame.HIDERS] or [constant HsGame.SEEKERS].
var team: int = 0

## Which side they asked for: 0 either, or a side. Server side; read by the draw.
var side_wish: int = 0

var points: int = 0
var ping_ms: int = -1
var entity_id: int = 0

## How many times the server has PUT this player somewhere. Replicated, so a watcher's
## interpolator draws a teleport as one rather than as a flight across the map.
var warps: int = 0

## Sitting this round out: they joined while it could not take them, or they were caught on a
## server where the caught are out.
var watching: bool = false

## Whether they started this round hiding and were caught. Server side, and replicated so the
## board can say who was found.
var caught: bool = false

## How full the "you are being watched" meter is, 0..1, under the sight rule. Server side,
## replicated to the owner.
var sight_meter: float = 0.0

## Who is filling it: the seeker who watched them last. Server side.
var watched_by: StringName = &""

## Simulated second a newly made seeker may move again. Server side; the hold itself is the
## controller's [constant HsController.HOLD] modifier, which travels.
var held_until: float = -1.0

## Whether the use key is held this tick: the game makes the press from the edge. Set by the
## bridge from the player's input on a server, by the client offline, by the game for a bot.
var wants_use: bool = false

## What [member wants_use] was last tick. The game's, for the edge.
var use_was_held: bool = false

## How full the forced-taunt meter is, 0..1. Server side, replicated to the owner.
var taunt_meter: float = 0.0

## Whether a taunt is playing from them now, which one. For the HUD.
var taunting_id: StringName = &""

## Whether the rule that gives the last hiders away has marked them. Server side; replicated
## with an admin's beacon as one flag.
var marked: bool = false

## An administrator's `blind` and `beacon`.
var blinded: bool = false
var beacon: bool = false

var beacon_marker: DotFxBeacon = null

## What other people see this player as. Client side.
var figure: HsFigure = null

## How this player's body falls on their death: the server's pick ([method HsGame.decide_death]),
## carried on DEATH and set here before anybody hears of it. Null before a first death.
var death: DotPlayerDeath = null

var tick_rate: int = 64:
	set(value):
		tick_rate = value
		if controller != null:
			controller.tick_rate = value


func _ready() -> void:
	controller = HsController.new()
	controller.name = "Controller"
	controller.tick_rate = tick_rate
	# EXTERNAL even offline: the world owns the tick, which is the shape a dedicated server
	# needs and the one a predicting client replays.
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller.tunables = tunables_for(config)
	controller.admin_abilities = true
	add_child(controller)

	if samples_input:
		sampler = DotFpsSampler.new(controller.tunables)
		register_actions(sampler)


## How a player moves. Static: a connected client builds a sampler before it has a player, and
## the two must agree. The same for both sides, so a predicting client never has to know which
## side somebody is on to move them.
static func tunables_for(config: HsConfig) -> DotFpsTunables:
	var t := DotFpsTunables.new()
	t.max_speed = config.run_speed if config != null else 6.0
	t.gravity = config.gravity if config != null else 20.0
	t.jump_height = config.jump_height if config != null else 1.15
	t.auto_hop = config.auto_bunny_hop if config != null else false
	var sprint := config.sprint_scale if config != null else 1.35
	t.can_sprint = sprint > 1.001
	t.sprint_speed_scale = maxf(sprint, 1.0)
	t.can_walk = true
	t.walk_speed_scale = 0.45
	t.can_crouch = true
	t.crouch_speed_scale = 0.45
	t.accelerate = 10.0
	t.friction = 6.0
	t.stop_speed = 2.5
	t.air_accelerate = config.air_accelerate if config != null else 20.0
	t.max_air_wish_speed = 1.2
	t.coyote_time = 0.1
	t.jump_buffer_time = 0.12
	t.max_slope_angle = 46.0
	t.radius = BODY_RADIUS
	t.stand_height = BODY_HEIGHT
	t.crouch_height = BODY_CROUCH
	t.step_height = BODY_STEP
	return t


## The movement actions. Shift sprints here (the controller's own default), because a chase is
## the game; the slow walk stays on its own key.
static func register_actions(p_sampler: DotFpsSampler = null) -> void:
	var _added := DotFpsSampler.register_default_actions(p_sampler)


## One simulated tick. On the server and offline; a client predicts through its behaviour.
func simulate(tick: int, delta: float) -> void:
	# The world calls this by name, so a body the load gate froze is skipped here.
	if is_inside_tree() and not can_process():
		return

	if sampler != null:
		# Settling under the cover runs the body with its input off (falls, lands, no keys).
		var gate := DotLoadGate.of(self) if is_inside_tree() else null
		controller.apply_command(
			sampler.sample(delta) if gate == null or gate.is_open() else DotFpsCommand.new())

	controller.simulate_tick(tick, delta)
	global_position = controller.state.position


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


## The hull's height now.
func hull_height() -> float:
	return controller.tunables.stand_height if controller != null else BODY_HEIGHT


## Where this player's eyes are.
func eye_position() -> Vector3:
	var height := EYE_HEIGHT

	if controller != null and controller.state.crouch_fraction > 0.0:
		height = lerpf(EYE_HEIGHT, BODY_CROUCH - 0.15, controller.state.crouch_fraction)

	return controller.state.position + Vector3(0.0, height, 0.0)


## Which way they are looking, as a unit vector. From yaw and pitch, never a camera.
func aim_direction() -> Vector3:
	var view := Basis.from_euler(Vector3(
		deg_to_rad(controller.state.pitch), deg_to_rad(controller.state.yaw), 0.0
	))
	return -view.z


## The duck-typed lookup other addons ask a carrier for.
func component(type_name: StringName) -> Object:
	match String(type_name):
		"DotPlayerController", "DotFpsController":
			return controller
		"DotHealth":
			return health
		_:
			return null


## Puts a player somewhere, facing somewhere, with nothing carried over.
func place_at(at: Vector3, yaw_degrees: float) -> void:
	warps += 1
	global_position = at
	controller.teleport(at, yaw_degrees, 0.0)

	if sampler != null:
		sampler.look_at_angles(yaw_degrees, 0.0)

	var facing := DotFpsCommand.new()
	facing.yaw = yaw_degrees
	controller.apply_command(facing)


## Back to the start of a round: nothing caught, nothing watched, nothing marked, not held.
func reset_round() -> void:
	watching = false
	caught = false
	sight_meter = 0.0
	watched_by = &""
	held_until = -1.0
	taunt_meter = 0.0
	taunting_id = &""
	marked = false

	if controller != null:
		var _let_go := controller.remove_modifier(HsController.HOLD)


func retune() -> void:
	if controller == null:
		return

	controller.tunables = tunables_for(config)

	if sampler != null:
		sampler.tunables = controller.tunables


func is_alive() -> bool:
	return health == null or health.alive


# --- Drawing (client side) --------------------------------------------------

## Draws the beacon at [param at], from the admin's flag or the rule's. Returns whether it
## pinged.
func present_beacon(delta: float, at: Vector3, local_view: bool, period: float) -> bool:
	if not (beacon or marked) or not is_alive():
		if beacon_marker != null:
			beacon_marker.queue_free()
			beacon_marker = null
		return false

	if beacon_marker == null:
		beacon_marker = DotFxBeacon.new()
		beacon_marker.name = "Beacon"
		beacon_marker.period = period
		# The rule's marker is the hiders' blue, so it reads as "a hider is here" and not as an
		# admin's punishment; an admin's is the family's magenta.
		beacon_marker.colour = Color(0.98, 0.22, 0.86) if beacon else Color(0.35, 0.7, 1.0)
		beacon_marker.column_base = hull_height() + 0.4
		add_child(beacon_marker)

	beacon_marker.local_view = local_view
	beacon_marker.global_position = at
	return beacon_marker.advance(delta)


## Draws this player for one frame at [param at], in [param team_colour]. Returns whether
## anything was shown.
##
## [b]A side change rebuilds the figure[/b], because the colour is painted into its torso: a
## hider caught in front of somebody turns orange on the next frame.
func present_body(hidden: bool, at: Vector3, team_colour: Color) -> bool:
	var shown := not hidden and is_alive() and not watching

	if figure == null:
		if not shown:
			return false
		figure = HsFigure.new()
		figure.name = "Figure"
		add_child(figure)

	var atlas := _atlas()

	if figure.atlas != atlas or not figure.team_colour.is_equal_approx(team_colour):
		figure.build(BODY_HEIGHT, atlas, team_colour)

	figure.visible = shown

	if shown:
		var velocity := controller.state.velocity
		figure.set_motion({
			"on_floor": controller.state.mode == DotFpsState.Mode.GROUND,
			"vertical": velocity.y,
			"crouched": controller.state.crouch_fraction > 0.5,
			# The view's pitch: the upper body and the head follow it.
			"aim": deg_to_rad(controller.state.pitch),
		})
		figure.pose(at, deg_to_rad(controller.state.yaw), Vector2(velocity.x, velocity.z).length())

	return shown


func _atlas() -> String:
	var index := HsAvatars.skin_index(avatar)

	if index < 0 or index >= HsFigure.ATLASES.size():
		index = HsAvatars.stock_index(player_id)

	return str(HsFigure.ATLASES[index])


func describe() -> Dictionary:
	return {
		"id": String(player_id),
		"side": team,
		"alive": is_alive(),
		"caught": caught,
		"seen": snappedf(sight_meter, 0.01),
		"watching": watching,
		"marked": marked,
		"blinded": blinded,
		"beacon": beacon,
		"points": points,
	}

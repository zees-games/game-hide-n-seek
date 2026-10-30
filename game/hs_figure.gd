extends Node3D

const HsPaths := preload("hs_paths.gd")

## What somebody ELSE looks like: a family humanoid figure scaled to the player's hull, with their side's colour as the shirt, turned to where they look. Client side only. See `HsPlayer.present_body` for when one is shown.
## Top level, placed by its caller every frame: the player node moves once a TICK on a simulated player, and a body hung off it would step while the camera is blended. `HsClient.present_frame` hands it the position this frame draws.
## Which person comes from the blocky kit's atlas the avatar names (`HsAvatars`, [constant ATLASES]; `DotHumanoidLook.from_letter`), so older documents dress the same person. The side is the shirt, the first thing anybody needs to read off a body.

const CHANNEL := "hs.figure"

## The six people a player can be, by the blocky kit's atlas letters (the avatar documents name
## them). Only the letter is read: the people are coloured, not textured.
static var ATLASES: Array[String] = [
	HsPaths.rebase("res://assets/kenney/characters/Textures/texture-a.png"),
	HsPaths.rebase("res://assets/kenney/characters/Textures/texture-b.png"),
	HsPaths.rebase("res://assets/kenney/characters/Textures/texture-c.png"),
	HsPaths.rebase("res://assets/kenney/characters/Textures/texture-e.png"),
	HsPaths.rebase("res://assets/kenney/characters/Textures/texture-f.png"),
	HsPaths.rebase("res://assets/kenney/characters/Textures/texture-k.png"),
]

## How much of the side's colour goes on the top: all of it (a tint over a teal shirt read as
## teal, a red one as muddy purple).
const TEAM_TINT := 1.0

## Which atlas this figure wears, and the side colour on it. Read by the suite.
var atlas: String = ""
var team_colour: Color = Color.WHITE

## Whether the people's art loaded, or a capsule stands in.
var from_art: bool = false

## The clip playing, for the suite and for `describe()`.
var clip: StringName = &""

## The person, under this node.
var person: DotHumanoidFigure = null

## dot-player-char API level that has DotHumanoidFigure.frame_delta.
const FRAME_DELTA_LEVEL := 11

var _posed_at_usec: int = -1


func _init() -> void:
	# The caller places it; see the class note.
	top_level = true


## Builds the figure to stand [param height] metres tall, feet at this node's origin, as the
## person [param atlas_path]'s letter is, wearing [param colour] on the top.
func build(height: float, atlas_path: String, colour: Color) -> void:
	atlas = atlas_path
	team_colour = colour
	clip = &""
	_posed_at_usec = -1
	var look := DotHumanoidLook.from_letter(atlas_path)
	if look == null:
		DotLog.debug(CHANNEL, "no person for this atlas letter, a stock look", {"atlas": atlas_path})
		look = DotHumanoidLook.stock(hash(atlas_path))
	if colour != Color.WHITE:
		look = look.with_side(colour, TEAM_TINT)
	if person == null:
		person = DotHumanoidFigure.new()
		person.name = "Person"
		add_child(person)
	person.build(look, height)
	from_art = person.from_art


## The drawn model, for a death that breaks it apart or falls. Null before [method build].
func body_node() -> Node3D:
	return person


## How the player moves besides its ground speed: `on_floor`, `vertical`, `crouched` and the
## rest [DotHumanoidFigure.set_motion] reads.
func set_motion(motion: Dictionary) -> void:
	if person != null:
		person.set_motion(motion)


## Puts the figure where this frame draws its player, facing [param yaw_radians], moving at
## [param speed] metres a second over the ground.
func pose(at: Vector3, yaw_radians: float, speed: float) -> void:
	global_position = at
	rotation = Vector3(0.0, yaw_radians, 0.0)
	if person == null:
		return
	# Game time, as the body moves: a wall-clock step skated the feet (slow motion, fixed-rate frames).
	if DotAddonApi.build_level("dot_player_char") >= FRAME_DELTA_LEVEL:
		person.animate(speed, person.frame_delta())
	else:
		var now := Time.get_ticks_usec()
		var delta := 0.0 if _posed_at_usec < 0 else clampf((now - _posed_at_usec) / 1e6, 0.0, 0.1)
		_posed_at_usec = now
		person.animate(speed, delta)
	clip = person.clip


func describe() -> Dictionary:
	return {
		"art": from_art,
		"atlas": atlas.get_file(),
		"visible": visible,
		"clip": String(clip),
		"at": str(global_position.snapped(Vector3.ONE * 0.01)) if is_inside_tree() else "-",
	}

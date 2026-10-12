extends Node3D

const HsPaths := preload("hs_paths.gd")

## What somebody ELSE looks like: a Kenney blocky character, scaled to the player's hull,
## wearing their side's colour on the torso and turned to where they are looking. Client
## side only; a server never builds one.
##
## [b]This game drew no person at all until 2026-09-24.[/b] Every player's own view was
## first person, and third person showed the platform rather than the player — so nobody had
## needed a body until a networked client, whose other players were drawn as nothing. Their
## node moved, their beacon marked them, and a platform leaned toward a patch of empty deck.
## See `HsPlayer.present_body` for when one is shown.
##
## [b]Top level, and placed by its caller every frame.[/b] The player node is the
## simulation's: on a remote player it is written by the interpolator once a frame, but on
## the local player and on every offline stand-in it moves once a TICK, and a body hung off
## it would step at the tick rate while the camera beside it is blended between ticks. So
## `HsClient.present_frame` hands every body the position this frame draws — the node for a
## remote player, `render_state()` for one this process simulates — and nothing here
## computes one.
##
## [b]One of the family's people[/b] (dot-player-char's `DotHumanoidFigure`: animated, on the
## rig every game's players, bots and NPCs share), because a seeker is somebody to see coming and
## a capsule does not say which way somebody is facing from forty metres. Which person a player
## is still comes from the blocky kit's atlas their avatar names (`HsAvatars`, [constant ATLASES]):
## the atlas letter is a look (`DotHumanoidLook.from_letter`), so every document written before
## the people arrived dresses the same person on every client. [b]The side is the shirt[/b]: the
## top is the side's colour outright, and the face, hair and legs stay the player's own. The first
## thing anybody needs to read off a body is whether to run from it.

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
	var now := Time.get_ticks_usec()
	# A figure that was hidden for a minute is not a minute behind: clamped.
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

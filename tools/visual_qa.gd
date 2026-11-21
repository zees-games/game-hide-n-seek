extends GSGameVisualQaCapture

## Visual QA capture for the six people a player can be, as a hider (blue) and as a seeker (orange): idle, walk, run, sprint, crouch walk and a jump, three cameras, every frame at 60 fps.
## Renders, so it runs on a GPU box through tools/visual_qa_shot.sh, never in the headless suites (addons/gs_game/docs/visual-qa.md).

const HsFigure := preload("res://game/hs_figure.gd")
const HsGameBase := preload("res://game/hs_game_base.gd")

const ITEM_LETTERS := {"person_a": 0, "person_b": 1, "person_c": 2, "person_e": 3, "person_f": 4, "person_k": 5}
const SEEKER_ITEM := "seeker_a"

## Ground speed per clip, m/s: the config's run speed, its 0.45 walk scale and 1.35 sprint scale.
const RUN := 6.0
const SPEEDS := {"idle": 0.0, "walk": RUN * 0.45, "run": RUN, "sprint": RUN * 1.35, "crouch_walk": RUN * 0.45 * 0.6, "jump": RUN}
const JUMP_HEIGHT := 1.15
const GRAVITY := 20.0

var _figure: Node3D = null
var _built_for: String = ""


func _items() -> PackedStringArray:
	var out := PackedStringArray(ITEM_LETTERS.keys())
	out.append(SEEKER_ITEM)
	return out


func _clips(_item: String) -> PackedStringArray:
	return PackedStringArray(["idle", "walk", "run", "sprint", "crouch_walk", "jump"])


func _build() -> void:
	if limits_path == "":
		limits_path = "res://tools/visual_qa_thresholds.json"
	build_stage()


func _stage(item: String, clip: String) -> GSResult:
	if not SPEEDS.has(clip):
		return GSResult.fail(GSError.CODE_INVALID, "no %s clip" % clip)
	if _figure == null:
		_figure = HsFigure.new()
		root.add_child(_figure)
		# Layer 19: the outside cameras draw it, the first-person camera (your own body) does not.
		first_person.cull_mask &= ~(1 << 18)
	if _built_for != item:
		var letter: int = 0 if item == SEEKER_ITEM else int(ITEM_LETTERS[item])
		var side: int = 1 if item == SEEKER_ITEM else 0
		_figure.build(1.8, HsFigure.ATLASES[letter], HsGameBase.TEAM_COLOURS[side])
		GSGameVisualQaViews.tag_layers(_figure, 1 << 18)
		_built_for = item
	_figure.global_position = Vector3(0.0, 0.0, 6.0 if clip != "idle" else 0.0)
	_figure.rotation = Vector3.ZERO
	_figure.set_motion({"on_floor": true, "crouched": clip == "crouch_walk", "aim": 0.0})
	return GSResult.success(clip)


func _subject(_item: String) -> Node3D:
	return _figure


func _skeleton(_item: String) -> Skeleton3D:
	return _figure.person.skeleton() if _figure != null and _figure.person != null else null


func _grounded(_item: String, clip: String, t: float) -> bool:
	return clip != "jump" or _jump_height(t) < 0.02


func _jump_height(t: float) -> float:
	var air := 2.0 * sqrt(2.0 * JUMP_HEIGHT / GRAVITY)
	var u := fposmod(t, air + 0.4)
	if u > air:
		return 0.0
	var v := sqrt(2.0 * GRAVITY * JUMP_HEIGHT)
	return maxf(v * u - 0.5 * GRAVITY * u * u, 0.0)


func _drive(_item: String, clip: String, t: float, _frame: int) -> void:
	var speed: float = SPEEDS[clip]
	var dt := 1.0 / 60.0
	var pos: Vector3 = _figure.global_position
	pos.z -= speed * dt
	var vertical := 0.0
	if clip == "jump":
		pos.y = _jump_height(t)
		vertical = (_jump_height(t + dt) - pos.y) / dt
	_figure.global_position = pos
	# The same keys HsPlayer.present_body gives the figure (no velocity, no sprinting), or the clips differ from the game's.
	_figure.set_motion({"on_floor": pos.y < 0.02, "vertical": vertical, "crouched": clip == "crouch_walk", "aim": 0.0})
	_figure.person.animate(speed, dt)

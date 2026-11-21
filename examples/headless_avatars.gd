extends DotGameCheckSuite

const HsFigure := preload("../game/hs_figure.gd")
const HsConfig := preload("../game/hs_config.gd")
const HsGame := preload("../game/hs_game.gd")
const HsPlayer := preload("../game/hs_player.gd")

## Every player always has a visible body: with no avatar art available (a native build that never imported or shipped the people, a failed load) a figure falls back to the next stock person, and to a coloured capsule only when none loads (dot-player-char's `DotHumanoidAssets.available_body`).
## Run: [code]./game.sh --no-parse test headless_avatars[/code].

const SECTIONS := 3
const CHECKS := 7

var _entered := 0
var _finished := 0


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("hideseek avatar fallback")
	await _empty_set()
	await _one_body_left()
	await _players_in_a_world()
	_report_sections(_entered, _finished, SECTIONS, CHECKS)


## Every stock body's model unavailable: the figure is a capsule, drawn.
func _empty_set() -> void:
	_entered += 1
	print("no avatar art at all")
	_remove_bodies([])
	var all_drawn := true
	for atlas in HsFigure.ATLASES:
		var fig := HsFigure.new()
		add_child(fig)
		fig.build(1.8, atlas, Color.BLUE)
		fig.pose(Vector3.ZERO, 0.0, 0.0)
		all_drawn = all_drawn and _drawn(fig)
		fig.queue_free()
	_check(all_drawn, "all %d people are a visible body with the stock art gone" % HsFigure.ATLASES.size())
	var fig := HsFigure.new()
	add_child(fig)
	fig.build(1.8, HsFigure.ATLASES[0], Color.BLUE)
	_check(not fig.from_art and fig.person.get_child_count() > 0, "the last resort is a capsule, not nothing")
	_check(DotHumanoidAssets.available_body(&"matt") == &"", "no body is reported available")
	fig.queue_free()
	_finished += 1


## Only one of the four people loads: everybody is drawn as that person, with the art.
func _one_body_left() -> void:
	_entered += 1
	print("one stock person left")
	_remove_bodies([&"sam"])
	_check(DotHumanoidAssets.available_body(&"matt") == &"sam", "a missing body is replaced by the next that loads")
	var all_art := true
	for atlas in HsFigure.ATLASES:
		var fig := HsFigure.new()
		add_child(fig)
		fig.build(1.8, atlas, Color.ORANGE)
		fig.pose(Vector3.ZERO, 0.0, 0.0)
		all_art = all_art and _drawn(fig) and fig.from_art
		fig.queue_free()
	_check(all_art, "all six people are drawn with art, as the one body")
	_finished += 1


## The game's own players, the way the client draws them: each has a visible figure with the art set empty.
func _players_in_a_world() -> void:
	_entered += 1
	print("the game's players")
	_remove_bodies([])
	var config := HsConfig.new()
	config.minimum_players = 0
	config.map_ids = PackedStringArray(["hs_practice"])
	var game := HsGame.new()
	game.config = config
	game.tick_rate = 30
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	await get_tree().physics_frame
	var seekers := 0
	var drawn := 0
	for i in 4:
		var player := game.add_player(StringName("u%d" % (500 + i)), "P%d" % i)
		var seeker := i == 0
		game.wish_side(player.player_id, HsGame.SEEKERS if seeker else HsGame.HIDERS)
		seekers += int(seeker)
	game.start()
	for i in 4:
		await get_tree().physics_frame
	for id: StringName in game.players:
		var p: HsPlayer = game.players[id]
		var shown := p.present_body(false, Vector3(float(drawn), 0.0, 0.0), Color.ORANGE if p.team == HsGame.SEEKERS else Color.BLUE)
		if shown and p.figure != null and _drawn(p.figure):
			drawn += 1
	_check(game.players.size() == 4 and drawn == 4, "every one of %d players has a visible body" % game.players.size(), str(drawn))
	_check(seekers == 1, "a seeker among them")
	_remove_bodies(["matt", "lis", "sam", "shaun"].map(func(s: String) -> StringName: return StringName(s)))
	game.queue_free()
	_finished += 1


## Whether [param fig] is shown with something in it to see.
func _drawn(fig: HsFigure) -> bool:
	return fig.visible and fig.person != null and fig.person.visible \
		and (fig.person.find_children("*", "MeshInstance3D", true, false).size() > 0)


## Makes every stock body's model unavailable except [param keep] (the import cache missing it, as a native pack without the people).
func _remove_bodies(keep: Array) -> void:
	for id in DotHumanoidLook.BODIES:
		if not keep.has(id):
			DotHumanoidAssets._scenes[DotHumanoidAssets.body_path(id)] = null
	if keep.is_empty():
		return
	for id in keep:
		DotHumanoidAssets._scenes.erase(DotHumanoidAssets.body_path(id))

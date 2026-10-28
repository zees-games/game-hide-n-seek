extends Node
## The constants, state and Tab board of [HsClient] (its base layer, split off for size); never used on its own.

const HsAudio := preload("hs_audio.gd")
const HsBindings := preload("hs_bindings.gd")
const HsFigure := preload("hs_figure.gd")
const HsSettings := preload("hs_settings.gd")
const HsServices := preload("hs_services.gd")
const HsNetBridge := preload("net/hs_net_bridge.gd")

const HsConfig := preload("hs_config.gd")
const HsMapConfig := preload("hs_map_config.gd")
const HsGame := preload("hs_game.gd")
const HsHud := preload("hs_hud.gd")
const HsPaths := preload("hs_paths.gd")
const HsPlayer := preload("hs_player.gd")

const CHANNEL := "hs.client"

## How far behind a player the camera hangs in third person.
const CHASE_BACK := 3.0
const CHASE_UP := 0.8

@export var config_file: String = "user://cfg/hideseek.json"
@export var force_offline: bool = false

## How many stand-ins an offline round gets.
@export_range(0, 12, 1) var offline_bots: int = 6

var game: HsGame = null
var player: HsPlayer = null
var camera: Camera3D = null

## Keeps the screen covered, and the local body and the input still, until the level, the
## player and the camera are all in. It is [member DotGameClient.gate].
var gate: DotLoadGate = null

## dot-game's client platform: the cover, settings and menu, console, HUD theme, Tab, M, the
## pointer and the input block. See [DotGameClient].
var platform: DotGameClient = null
var hud: HsHud = null
var board: DotMenuScoreboard = null
var chat: DotGameChatClient = null
var audio: HsAudio = null
var settings: HsSettings = null

## The player's console (the platform's).
var console: DotConsoleController = null

var net: DotNetManager = null
var bridge: HsNetBridge = null
var link: Node = null
## Asks a server whether this player may edit it (sv_workbench_remote); null offline.
var workbench_remote: DotGameWorkbenchRemoteClient = null
## The tuning panel's host: F9 solo or hosting, the admin's remote panel on a server that allows it.
var workbench: DotGameWorkbench = null

## Whether the camera hangs behind the player. F5 swaps it.
var third_person: bool = false

var _offline: bool = true
var _sampler: DotFpsSampler = null

## The spectator's free camera while roaming, and the mouse motion not yet turned into a look.
var _free_cam: DotSpectatorFreeCam = null
var _roam_look: Vector2 = Vector2.ZERO
var _watch_id: int = -1
var _arm: DotCameraBoom = null
var _fade: DotCameraFade = null
var _rig_height: float = 0.0
var _started_msec: int = Time.get_ticks_msec()

## The last whole second of the hide a beep was played for.
var _beeped: int = -1


func _dress_board() -> void:
	if board == null:
		return

	board.title_text = "Hide & Seek"
	board.columns = [
		{"key": &"avatar", "kind": DotMenuScoreboard.KIND_AVATAR, "width": 0.0},
		{"key": &"name", "title": "Player", "width": 3.0},
		{"key": &"points", "title": "Points", "kind": DotMenuScoreboard.KIND_NUMBER},
		{"key": &"seconds", "title": "Time", "kind": DotMenuScoreboard.KIND_DURATION},
		{"key": &"ping", "title": "Ping", "kind": DotMenuScoreboard.KIND_PING},
	]
	board.sort_by = &"points"
	board.decorate = _decorate_row
	board.prepare = _prepare_board



func _decorate_row(row: Dictionary) -> void:
	if game == null:
		return
	var id := HsNetBridge.player_key(int(row.get("id", 0)))
	if not game.players.has(id):
		id = StringName(str(row.get("id", "")))
	var who: HsPlayer = game.players.get(id)
	if who == null:
		return
	row["avatar"] = _face(who)
	row["points"] = who.points
	row["team"] = game.team_of(id)
	if int(row.get("ping", -1)) < 0 and who.ping_ms >= 0:
		row["ping"] = who.ping_ms
	if who == player:
		row["you"] = true


## The map in the header, and the two sides as the teams, hiders first.
func _prepare_board(snap: Dictionary) -> void:
	if game == null:
		return
	snap["header"] = {"Map": str(game.map_doc.get("name", "")), "Round": str(game.round_number)}
	if game.map != null and game.map.world_credits != "":
		snap["header"]["Credits"] = game.map.world_credits
	snap["teams"] = [
		{"id": HsGame.HIDERS, "name": game.side_name(HsGame.HIDERS), "color": game.side_colour(HsGame.HIDERS)},
		{"id": HsGame.SEEKERS, "name": game.side_name(HsGame.SEEKERS), "color": game.side_colour(HsGame.SEEKERS)},
	]
	add_bot_rows(snap, game)


## Online the board is dot-server's roster, which lists sessions only, not stand-ins. Adds a row for
## each bot the roster lacks, keyed as `board_snapshot()` keys it so `_decorate_row` finds its team.
## Static so a suite can run it on a world.
static func add_bot_rows(snap: Dictionary, world: HsGame) -> void:
	var rows: Array = snap.get("players", []) as Array
	var listed := {}
	for raw in rows:
		if raw is Dictionary:
			listed[str((raw as Dictionary).get("id", ""))] = true
			listed[String(HsNetBridge.player_key(int((raw as Dictionary).get("id", 0))))] = true
	for id in world.players:
		var who: HsPlayer = world.players[id]
		if not (who.is_bot or HsNetBridge.is_bot_key(id)) or listed.has(String(id)):
			continue
		listed[String(id)] = true
		rows.append({"id": String(id), "name": who.display_name, "seconds": 0, "ping": -1, "bot": true})
	snap["players"] = rows


## The board offline: every player in the local world. Public so a suite can read it.
func board_snapshot() -> Dictionary:
	var rows: Array = []
	if game != null:
		for id in game.players:
			var who: HsPlayer = game.players[id]
			rows.append({"id": String(id), "name": who.display_name, "seconds": _seconds_here(), "ping": -1, "bot": who.is_bot})
	return {"server": {"name": "Hide & Seek", "game": "offline"}, "players": rows}


func _seconds_here() -> int:
	return int((Time.get_ticks_msec() - _started_msec) / 1000)


var _portraits: Dictionary = {}


func _face(who: HsPlayer) -> Texture2D:
	return _portrait(str(who.call("_atlas")))


## A player's face for the board: their figure's head, rendered once per skin. See
## mg-deathrun, where this came from.
func _portrait(atlas: String) -> Texture2D:
	if _portraits.has(atlas):
		return _portraits[atlas]

	var view := SubViewport.new()
	view.name = "Portrait%d" % _portraits.size()
	view.size = Vector2i(64, 64)
	view.own_world_3d = true
	view.transparent_bg = true
	view.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(view)

	var figure := HsFigure.new()
	view.add_child(figure)
	figure.build(1.8, atlas, Color.WHITE)
	figure.global_position = Vector3.ZERO

	var eye := Camera3D.new()
	eye.fov = 30.0
	view.add_child(eye)
	# The people's heads are big: the face is about 1.35 m up a 1.8 m person.
	eye.look_at_from_position(Vector3(0.0, 1.45, -2.0), Vector3(0.0, 1.35, 0.0), Vector3.UP)
	eye.current = true

	var texture := view.get_texture()
	_portraits[atlas] = texture
	return texture

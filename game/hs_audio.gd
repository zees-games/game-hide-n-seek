extends Node

const HsPaths := preload("hs_paths.gd")

## What this game makes a noise about, and the noise, on the client.
##
## [b]In a hiding game the sounds ARE the game.[/b] A taunt is the loudest thing a hider can
## do, so it is heard where the hider is, as loud as the server allows and no further; a catch
## has a noise of its own, so a hider in the next room knows the seekers just grew by one; the
## seekers' release is a horn every hider hears wherever they are.
##
## [b]A catalogue of ids and a table of stand-ins, which is the family's shape.[/b] dot-audio
## decides what is audible, how many at once and how far; [method sound_catalogue] is those
## decisions, naming paths under `audio/`, and [method sound_recipes] says which synthesised
## voice stands in for each until a real `.ogg` is dropped in — [DotAudioSinkGodot] consults
## the file before the stand-in.
##
## [b]Taunts are files, and they are played from the hider.[/b] They are CC0 voice lines and
## jingles in `taunts/` (see its README), listed in `taunts/taunts.json`; a taunt is an
## [AudioStreamPlayer3D] parented to the player who made it, so it moves with a hider that
## runs.
##
## [b]Never on a server, and never deciding anything.[/b]

const CHANNEL := "hs.audio"

static var SOUND_DIR := HsPaths.rebase("res://audio")

## A round begins and the hiders scatter.
const HIDE := &"hide"
## The seekers are let go.
const SEEK := &"seek"
## The last seconds of hiding.
const COUNTDOWN := &"countdown"
## A hider caught, somewhere. Positional.
const CAUGHT := &"caught"
## You, caught. Flat.
const YOU_ARE_CAUGHT := &"you_are_caught"
const ROUND_WON := &"round_won"
const ROUND_LOST := &"round_lost"
const UI_CLICK := &"ui_click"
const UI_DENY := &"ui_deny"

var manager: DotAudioManager = null

## path -> AudioStream, the taunts loaded so far.
var _taunts: Dictionary = {}


static func ids() -> Array[StringName]:
	return [
		HIDE, SEEK, COUNTDOWN, CAUGHT, YOU_ARE_CAUGHT, ROUND_WON, ROUND_LOST, UI_CLICK, UI_DENY,
	]


static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()

	c.add(_flat(HIDE, &"UI", 1, 85))
	c.add(_flat(SEEK, &"UI", 1, 90))
	var beep := _flat(COUNTDOWN, &"UI", 1, 70)
	beep.cooldown_ms = 400
	c.add(beep)
	c.add(_placed(CAUGHT, 60.0, 10.0, 3, 70, 0.95, 1.05))
	c.add(_flat(YOU_ARE_CAUGHT, &"SFX", 1, 100))
	c.add(_flat(ROUND_WON, &"UI", 1, 80))
	c.add(_flat(ROUND_LOST, &"UI", 1, 80))

	var click := _flat(UI_CLICK, &"UI", 2, 60)
	click.cooldown_ms = 60
	c.add(click)
	var deny := _flat(UI_DENY, &"UI", 1, 60)
	deny.cooldown_ms = 250
	c.add(deny)
	return c


static func sound_recipes() -> Dictionary:
	return {
		HIDE: DotAudioSynth.Voice.SPAWN,
		SEEK: DotAudioSynth.Voice.SHOT_HEAVY,
		COUNTDOWN: DotAudioSynth.Voice.BLIP,
		CAUGHT: DotAudioSynth.Voice.HURT,
		YOU_ARE_CAUGHT: DotAudioSynth.Voice.DIE,
		ROUND_WON: DotAudioSynth.Voice.PICKUP,
		ROUND_LOST: DotAudioSynth.Voice.DENY,
		UI_CLICK: DotAudioSynth.Voice.CLICK,
		UI_DENY: DotAudioSynth.Voice.DENY,
	}


static func _placed(
	id: StringName, max_distance: float, unit_size: float, concurrent: int, priority: int,
	pitch_min: float, pitch_max: float
) -> DotAudioDef:
	var def := DotAudioDef.new()
	def.id = id
	def.path = "%s/%s.ogg" % [SOUND_DIR, String(id)]
	def.kind = DotAudioDef.Kind.POSITIONAL_3D
	def.bus = &"SFX"
	def.max_distance = max_distance
	def.unit_size = unit_size
	def.max_concurrent = concurrent
	def.priority = priority
	def.pitch_min = pitch_min
	def.pitch_max = pitch_max
	return def


static func _flat(id: StringName, bus: StringName, concurrent: int, priority: int) -> DotAudioDef:
	var def := DotAudioDef.new()
	def.id = id
	def.path = "%s/%s.ogg" % [SOUND_DIR, String(id)]
	def.bus = bus
	def.max_concurrent = concurrent
	def.priority = priority
	return def


func setup() -> DotResult:
	manager = DotAudioManager.new()
	manager.name = "Audio"
	manager.catalogue = sound_catalogue()
	manager.mixer = DotAudioMixer.new()
	manager.register_as_service = false
	manager.voices = 24
	add_child(manager)

	var ready_now := manager.setup()

	if not ready_now.ok:
		return ready_now.wrap("hideseek audio")

	var godot_sink := manager.sink as DotAudioSinkGodot

	if godot_sink != null:
		godot_sink.bank = DotAudioSynth.bank(manager.catalogue, sound_recipes())
		DotLog.info(CHANNEL, "no audio files; synthesised stand-ins are in use", {
			"ids": sound_recipes().size(), "dir": SOUND_DIR,
		})

	return DotResult.success(null)


func listen_from(at: Vector3) -> void:
	if manager != null:
		manager.listener_position = at


## A taunt from [param from], which it follows. [param sound] is the path in the taunt list,
## relative to this game's root; [param range_metres] is how far it carries. Returns the player
## made, or null when there was nothing to play.
func taunt(from: Node3D, sound: String, range_metres: float) -> AudioStreamPlayer3D:
	if from == null or sound == "":
		return null

	var stream := _taunt_stream(sound)

	if stream == null:
		return null

	var voice := AudioStreamPlayer3D.new()
	voice.name = "Taunt"
	voice.stream = stream
	voice.bus = &"SFX"
	voice.max_distance = range_metres
	voice.unit_size = range_metres * 0.18
	voice.position = Vector3(0.0, 0.6, 0.0)
	from.add_child(voice)
	voice.finished.connect(voice.queue_free)

	if voice.is_inside_tree():
		voice.play()

	return voice


func _taunt_stream(sound: String) -> AudioStream:
	if _taunts.has(sound):
		return _taunts[sound]

	var path := HsPaths.rebase("res://" + sound.trim_prefix("res://"))
	var stream: AudioStream = load(path) as AudioStream if ResourceLoader.exists(path) else null

	if stream == null:
		DotLog.warn(CHANNEL, "a taunt's sound is missing", {"path": path})

	_taunts[sound] = stream
	return stream


func on_hide() -> bool:
	return _flat_play(HIDE)


func on_seek() -> bool:
	return _flat_play(SEEK)


func on_countdown() -> bool:
	return _flat_play(COUNTDOWN)


func on_caught(at: Vector3, mine: bool) -> bool:
	if mine:
		return _flat_play(YOU_ARE_CAUGHT)

	return _at(CAUGHT, at)


func on_round_end(won: bool) -> bool:
	return _flat_play(ROUND_WON if won else ROUND_LOST)


func click() -> bool:
	return _flat_play(UI_CLICK)


func deny() -> bool:
	return _flat_play(UI_DENY)


func _at(id: StringName, at: Vector3, volume: float = 1.0) -> bool:
	return manager != null and manager.play_at(id, at, volume) != 0


func _flat_play(id: StringName) -> bool:
	return manager != null and manager.play(id) != 0


func describe() -> Dictionary:
	return {
		"ids": ids().size(),
		"taunts_loaded": _taunts.size(),
		"device": manager != null and manager.sink is DotAudioSinkGodot,
	}

extends Node

## Under xvfb-run (never --headless, whose audio driver is Dummy): does the game make a noise?
## Bakes the bank as a client does, plays the round's cues beside the listener, then plays a
## taunt file the way a prop does, from a node three metres away.
##   xvfb-run -a godot --path . res://tools/audio_probe.tscn

const HsAudio := preload("res://game/hs_audio.gd")


func _ready() -> void:
	var audio := HsAudio.new()
	add_child(audio)
	var ready_now := audio.setup()
	var sink := audio.manager.sink as DotAudioSinkGodot
	var ok := ready_now.ok and sink != null
	print("driver=%s sink=%s" % [AudioServer.get_driver_name(), sink != null])

	for id: StringName in [HsAudio.HIDE, HsAudio.SEEK, HsAudio.CAUGHT, HsAudio.YOU_ARE_CAUGHT, HsAudio.COUNTDOWN]:
		var stream: Variant = sink.bank.get(id) if sink != null else null
		var length := (stream as AudioStream).get_length() if stream is AudioStream else 0.0
		var voice := audio.manager.play_at(id, Vector3(0, 0, -3))
		await get_tree().process_frame
		print("%s baked=%.2f s voice=%d" % [id, length, voice])
		ok = ok and length > 0.05 and voice != 0

	var source := Node3D.new()
	add_child(source)
	source.position = Vector3(0, 0, -3)
	var taunt := audio.taunt(source, "taunts/you_lose.ogg", 60.0)
	await get_tree().process_frame
	var playing := taunt != null and taunt.playing and taunt.stream != null
	print("taunt playing=%s length=%.2f s" % [playing, taunt.stream.get_length() if playing else 0.0])
	ok = ok and playing

	get_tree().quit(0 if ok else 1)

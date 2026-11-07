extends DotAudioProbe

const HsAudio := preload("res://game/hs_audio.gd")

## Under xvfb-run (never --headless, whose audio driver is Dummy): does the game make a noise? Bakes the bank as a client does, plays the round's cues, then a taunt file from a node three metres away.
##   xvfb-run -a godot --path . res://tools/audio_probe.tscn


func _make_audio() -> Node:
	return HsAudio.new()


func _cue_ids() -> Array[StringName]:
	return [HsAudio.HIDE, HsAudio.SEEK, HsAudio.CAUGHT, HsAudio.YOU_ARE_CAUGHT, HsAudio.COUNTDOWN]


func _after_cues(_sink: Object) -> bool:
	var source := Node3D.new()
	add_child(source)
	source.position = Vector3(0, 0, -3)
	var taunt: Variant = audio.call("taunt", source, "taunts/you_lose.ogg", 60.0)
	await get_tree().process_frame
	var playing: bool = taunt != null and taunt.playing and taunt.stream != null
	report("taunt playing=%s length=%.2f s" % [playing, taunt.stream.get_length() if playing else 0.0])
	return playing

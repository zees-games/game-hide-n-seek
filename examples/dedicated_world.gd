extends "dedicated_base.gd"

const HsAmbience := preload("../game/hs_ambience.gd")
const HsConfig := preload("../game/hs_config.gd")
const HsGame := preload("../game/hs_game.gd")
const HsPlayer := preload("../game/hs_player.gd")
const HsNetLink := preload("../game/net/hs_net_link.gd")

const SERVER_DIR := "user://hs_dedicated"
const PORT := 28931
const QUERY_PORT := 28932
const TICK_RATE := 60

var server: DotServer = null
var game: HsGame = null


func _until(condition: Callable, seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().physics_frame
	return bool(condition.call())


func _module() -> DotModule:
	return server.modules.get_module("hideseek") if server != null and server.modules != null else null


func _run_command(line: String) -> PackedStringArray:
	var captured: Array[String] = []
	var context := DotCmdContext.console("", PackedStringArray())
	context.reply_sink = func(text: String) -> void: captured.append(text)
	server.console.execute(line, context)
	return PackedStringArray(captured)


func _said(lines: PackedStringArray, text: String) -> bool:
	for line in lines:
		if line.findn(text) >= 0:
			return true

	return false

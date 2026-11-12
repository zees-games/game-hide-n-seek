extends DotGameClientBench

const HsModule := preload("../game/hs_module.gd")

## Client prediction bench (dot-game's DotGameClientBench): see that class for the flags.
## The server's seekers and hiders are real players, so `--bots` is ignored.


func _configure() -> void:
	client_scene = "res://game/hs.tscn"


func _boot_server(_bots_wanted: int, data_dir: String) -> DotNetManager:
	var dir := ProjectSettings.globalize_path(data_dir)
	var config := make_server_config(data_dir)
	config.max_players = 16
	var server := DotServer.new()
	server.name = "Server"
	server.config = config
	add_child(server)
	for _i in 60:
		await get_tree().process_frame
		if server.state == DotServer.State.RUNNING:
			break
	var scene: Node = (load("res://scenes/hs_server.tscn") as PackedScene).instantiate()
	add_child(scene)
	await get_tree().process_frame
	(HsModule as GDScript).set("punishments_file", "%s/punishments.json" % dir)
	var loaded: DotResult = await server.modules.load_module("res://game/hs_module.gd")
	if not loaded.ok:
		printerr("client_bench server: ", loaded.error)
		return null
	for n in server.modules.loaded_names():
		var m: Object = server.modules.get_module(n)
		if m != null and m.get("net") != null:
			return m.get("net")
	return null


var _snap_next := 0.0
var _snap_last: Dictionary = {}


## `--snaplog`: every 2 s the client's snapshot, reconcile and skipped-reconcile counts, so a quiet
## `replays` column can be told from a stalled link (a matching prediction skips, it does not replay).
func _process(_delta: float) -> void:
	if _client == null or "--snaplog" not in OS.get_cmdline_user_args():
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now < _snap_next:
		return
	_snap_next = now + 2.0
	var net = _client.get("net")
	if net == null:
		return
	var pc: Dictionary = net.perf_counters()
	if not _snap_last.is_empty():
		print("  snaplog snapshots +", int(pc[&"snapshots"]) - int(_snap_last[&"snapshots"]),
			" reconciles +", int(pc[&"reconciles"]) - int(_snap_last[&"reconciles"]),
			" skipped +", int(pc[&"skipped"]) - int(_snap_last[&"skipped"]),
			" received_tick ", net.clock.received_tick())
	_snap_last = pc

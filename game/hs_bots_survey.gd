extends "hs_bots_base.gd"
## The survey, the nav mesh and the per-bot bookkeeping of [HsBots] (a middle layer, split off for size); never loaded on its own.


func settings() -> DotBotSettings:
	return DotBotSettings.of(game)


func now() -> float:
	return float(int(game.get("_tick"))) / float(maxi(int(game.get("tick_rate")), 1))


func dt() -> float:
	return 1.0 / float(maxi(int(game.get("tick_rate")), 1))


## A new round or map: every bot forgets what it was doing.
func reset() -> void:
	_state.clear()
	_sounds.clear()
	_pool.clear()
	doors_shut = 0
	longest_stuck = 0.0


func forget(player_id: StringName) -> void:
	_state.erase(player_id)


## Somebody was caught: the shout, and the new seeker standing where they were, is a sound every
## hider within earshot hears and moves away from.
func on_caught(player_id: StringName) -> void:
	var players: Dictionary = game.get("players")
	if not players.has(player_id):
		return
	var who: HsPlayer = players[player_id]
	_sounds.append({"at": who.controller.state.position, "loud": LOUD_TAUNT, "by": player_id, "t": now(), "caught": true})


## A taunt was played: a shout every bot within earshot hears.
func on_taunted(player_id: StringName) -> void:
	var players: Dictionary = game.get("players")
	if not players.has(player_id):
		return
	var who: HsPlayer = players[player_id]
	_sounds.append({"at": who.controller.state.position, "loud": LOUD_TAUNT, "by": player_id, "t": now()})


## Bakes and surveys the map now built, once per map. Only where bots run (the server, or solo).
func _prepare() -> void:
	var map: Node3D = game.get("map")
	var doc: Dictionary = game.get("map_doc")
	var key := "%s|%d" % [str(doc.get("id", "")), map.get_instance_id() if map != null else 0]

	if map == null or key == _surveyed:
		return

	if key != _baked:
		_bake_map(map, doc, key)
		return

	if int(game.get("_tick")) < _survey_at or not nav.is_ready():
		return

	# A doorway a body walks through but the mesh does not (the baker rounds the radius up and erodes both jambs) cuts the hiders'
	# spawn off from the seekers', so nobody has a spot. Bake once more with a one-cell radius.
	if _nav_radius > DotBotNav.CELL and not _spawns_joined(map):
		_nav_radius = DotBotNav.CELL
		DotLog.info(CHANNEL, "the spawns are not joined on the mesh; baking narrower", {"map": str(doc.get("id", ""))})
		_baked = ""
		_narrowing = true
		_prepare()
		return

	# The annotation is a job: stepped a fixed number of slices each tick (never by the clock, so
	# a seeded round plays the same), and the hiders wait for it as they waited for the bake.
	if _job == null and not _job_done:
		_job = _begin_annotation(map, doc)
		_job_steps = 0
	if _job != null:
		var stepped := Time.get_ticks_usec()
		for _i in range(ANNOTATE_STEPS_PER_TICK):
			_job_steps += 1
			if not _job.step():
				break
		annotate_ms += (Time.get_ticks_usec() - stepped) / 1000.0
		if _job.state == DotJob.State.RUNNING or _job.state == DotJob.State.PENDING:
			return

	_finish_survey(key, map, doc)


## Bakes the navigation mesh for the map, and sets when to survey it (the server takes the mesh in on a later frame).
func _bake_map(map: Node3D, doc: Dictionary, key: String) -> void:
	_baked = key
	_baked = key
	if not _narrowing:
		_nav_radius = HsPlayer.BODY_RADIUS
	_narrowing = false
	spots.clear()
	sweep.clear()
	annotations = null
	_job = null
	_job_done = false
	_pool.clear()
	# The walls, floors and furniture, never the doors: a door baked shut is a doorway the
	# mesh does not go through.
	var still: Array = [map.get("_solid"), map.get("_furniture")]
	# And round every toy that stands in the way (a swing's sweep, a see-saw, a trampoline):
	# a bot never paths across one. The loose toys are not in it; a bot walks through a
	# ball and pushes it, as anybody does.
	var toys: Variant = map.get("toys")
	if toys is DotPropToyBox:
		still.append_array((toys as DotPropToyBox).nav_bodies())
	var baked := nav.bake(map, {"radius": _nav_radius, "height": HsPlayer.BODY_CROUCH, "climb": HsPlayer.BODY_STEP}, 0, still)
	if not baked.ok:
		_surveyed = key
		DotLog.warn(CHANNEL, "no walkable mesh for the bots; they walk straight", {"map": str(doc.get("id", "")), "why": baked.error.message})
	# The navigation server takes the mesh in on a later frame; survey a quarter of a second
	# of game time on, always the same tick, so a round plays the same however the frames
	# fall (and later still only when the server is that slow).
	_survey_at = int(game.get("_tick")) + maxi(int(game.get("tick_rate")) / 4, 1)
	return


## Keeps the annotated spots and the sweep (or the random survey when nothing annotated) and logs what it cost.
func _finish_survey(key: String, map: Node3D, doc: Dictionary) -> void:
	_surveyed = key
	var started := Time.get_ticks_usec()
	var random: DotRandomManager = game.get("random")
	var stream := random.stream_for(&"bot_survey", hash(str(doc.get("id", ""))) % 65536)

	annotations = _finish_annotation(doc)
	if annotations != null and not annotations.hiding.is_empty():
		spots = _walkable_spots(annotations.hiding_spots(), map)
		sweep = _random_survey(map, stream, SWEEP_POINTS, SURVEY_PROPS / 3)
	else:
		# Nothing annotated (no mesh, or a map with no walls to hide by): the old random survey.
		spots = _random_survey(map, stream, SURVEY_POINTS, SURVEY_PROPS)
		sweep = []
	survey_ms = (Time.get_ticks_usec() - started) / 1000.0 + nav.bake_ms + annotate_ms
	DotLog.debug(CHANNEL, "surveyed the map for the bots", {
		"map": str(doc.get("id", "")), "spots": spots.size(), "nav_ms": snappedf(nav.bake_ms, 0.1), "ms": snappedf(survey_ms, 0.1),
		"links": links_used, "chokepoints": annotations.chokepoints.size() if annotations != null else 0, "cached": annotate_cached,
		"steps": _job_steps,
	})


## The old survey (random points and points beside props, scored by random watchers): the sweep's open-floor places, the fallback without
## annotations, and the yardstick `headless_bots` measures hiding against ([method legacy_picks]).
## Spots a seeker can walk to from its spawn: unjoined places (a slab above the roof) filled the shortlist; all of them when none is joined.
func _walkable_spots(all: Array[Dictionary], map: Node3D) -> Array[Dictionary]:
	if not nav.is_ready():
		return all
	var from := nav.closest((map.call("spawn", "seekers", 0) as Array)[0])
	var joined: Array[Dictionary] = []
	for spot in all:
		if nav.joined(from, spot["at"]):
			joined.append(spot)
	return joined if not joined.is_empty() else all


## Whether the first hiders' spawn can walk to the first seekers' on the mesh.
func _spawns_joined(map: Node3D) -> bool:
	var hider: Vector3 = (map.call("spawn", "hiders", 0) as Array)[0]
	var seeker: Vector3 = (map.call("spawn", "seekers", 0) as Array)[0]
	return nav.joined(hider, seeker)


func _random_survey(map: Node3D, stream: DotRandomStream, points: int, prop_count: int) -> Array[Dictionary]:
	var candidates := PackedVector3Array()

	for _i in range(points):
		candidates.append(nav.random_point(stream))

	# Beside furniture, where people hide: a point a little out from a side of the prop, put
	# on the walkable mesh.
	var props: Array = map.get("props")
	var step := maxi(1, props.size() / maxi(prop_count, 1))
	for i in range(0, props.size(), step):
		var prop: Dictionary = props[i]
		var frame: Transform3D = prop["transform"]
		var size: Vector3 = prop["size"]
		var side := Vector3(1.0, 0.0, 0.0).rotated(Vector3.UP, stream.next_range_f(0.0, TAU))
		var beside := frame.origin + side * (maxf(size.x, size.z) * 0.5 + 0.5)
		var on := nav.closest(beside)
		if on.distance_to(beside) < 0.8:
			candidates.append(on)

	var watchers := PackedVector3Array()
	for _i in range(WATCHERS):
		watchers.append(nav.random_point(stream) + Vector3(0.0, HsPlayer.EYE_HEIGHT, 0.0))

	return DotBotHiding.survey(candidates, watchers, _los)


## What the map means to somebody walking it: [DotNpcAiNavAnnotator] over the baked mesh, seeded with every spawn, doors left out, cached under `user://nav`.
## Returns the job to step, or null on a cache hit; [method _finish_annotation] then adds drop and jump-up links as ride edges.
func _begin_annotation(map: Node3D, doc: Dictionary) -> DotJob:
	annotate_cached = false
	annotate_ms = 0.0
	links_used = 0
	_annotator = null
	_cached = null
	_job_done = true
	if nav.mesh == null or not nav.is_ready():
		return null

	var annotator := DotNpcAiNavAnnotator.new(nav.mesh, map.get_world_3d())
	annotator.agent_radius = HsPlayer.BODY_RADIUS
	annotator.stand_height = HsPlayer.BODY_HEIGHT
	annotator.crouch_height = HsPlayer.BODY_CROUCH
	annotator.eye_height = HsPlayer.EYE_HEIGHT
	annotator.climb = HsPlayer.BODY_STEP
	annotator.random_seed = hash(str(doc.get("id", ""))) % 65536 + 1
	annotator.exclude = _door_rids()
	# Fewer links than the default two metres apart: a camp's cabins on stilts gave four hundred,
	# and a way down every metre is not a hiding place anybody uses.
	annotator.link_spacing = LINK_SPACING
	# A way down of two metres at most: a four-metre drop off a landing was a rail the bot stood
	# at for twenty seconds (the ray at knee height does not see a rail), and nobody drops that
	# far to hide.
	annotator.drop_max = DROP_MAX
	var physics: Object = game.get("physics")
	if physics != null:
		annotator.collision_mask = int(physics.call("layer_mask", &"world")) | int(physics.call("layer_mask", &"prop"))
	var seeds := PackedVector3Array()
	for side in ["hiders", "seekers"]:
		for i in range(((doc.get("spawns", {}) as Dictionary).get(side, []) as Array).size()):
			seeds.append(nav.closest((map.call("spawn", side, i) as Array)[0]))
	annotator.seeds = seeds
	_annotator = annotator

	var loaded := DotNpcAiNavAnnotations.load_file(_cache_path(), annotator.cache_key())
	if loaded.ok:
		_cached = loaded.value
		annotate_cached = true
		return null
	return annotator


func _cache_path() -> String:
	return "user://nav/%s.json" % _annotator.cache_key()


func _finish_annotation(doc: Dictionary) -> DotNpcAiNavAnnotations:
	if _annotator == null:
		return null
	var found: DotNpcAiNavAnnotations = _cached
	if found == null:
		if _annotator.state != DotJob.State.DONE or _annotator.result == null or not _annotator.result.ok:
			DotLog.warn(CHANNEL, "the map could not be annotated; the bots use a random survey", {"map": str(doc.get("id", ""))})
			return null
		found = _annotator.annotations
		var _saved := found.save(_cache_path())

	# Drops and short jumps up: the mesh does not join a table top to the floor, the bot can.
	# A gap is a running jump the stand-ins do not make.
	var ride := 0
	_jump_feet.clear()
	for link in found.links:
		var kind := int(link["kind"])
		if kind == DotNpcAiNavAnnotations.LINK_DROP or kind == DotNpcAiNavAnnotations.LINK_JUMP_UP:
			# Both ends on the mesh itself: a link end off it made the engine's path query fail.
			if nav.closest(link["from"]).distance_to(link["from"]) > 0.3 or nav.closest(link["to"]).distance_to(link["to"]) > 0.3:
				continue
			nav.add_ride(link["from"], link["to"], ride, 1.5)
			ride += 1
			if kind == DotNpcAiNavAnnotations.LINK_JUMP_UP:
				_jump_feet.append(link["from"])
	links_used = ride
	return found


func _los(a: Vector3, b: Vector3) -> bool:
	return bool(game.call("_clear_between", a, b, true))


## The doors' bodies, for a ray that looks past them; gathered once for each map.
func _door_rids() -> Array[RID]:
	var map: Node3D = game.get("map")
	var doors: Object = map.get("doors") if map != null else null
	if doors == null:
		return []
	var specs: Array = doors.get("doors")
	if _door_rid_list.size() != specs.size() or _door_rid_doors != doors:
		_door_rid_list.clear()
		_door_rid_doors = doors
		for door: Dictionary in specs:
			var body: Variant = door.get("body")
			if body is CollisionObject3D:
				_door_rid_list.append((body as CollisionObject3D).get_rid())
	return _door_rid_list

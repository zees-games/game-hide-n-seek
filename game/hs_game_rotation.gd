extends "hs_game_base.gd"
## The maps.yml rotation of [HsGame] (a middle layer, split off for size); never used on its own.


## The server's maps.yml, or null when there is none (every map rotates, as it always did).
var rotation_file: DotMapRotationFile = null

# dot-map's rotation file marks and orders [DotMapDef]s in a [DotMapCatalogue]; this game keeps
# its maps as documents, so a def per map id is mirrored here and the file applied to those.
var _rot_catalogue: DotMapCatalogue = null
var _rot: DotMapRotation = null


## Reads maps.yml (the game's shipped `res://maps.yml` under the server's
## [member HsConfig.map_rotation_file], looked for in the `--config` directory too) and applies
## it. A file that is present and unreadable is an ERROR and changes nothing: rotating every map
## is a better failure than rotating none.
func load_rotation() -> DotResult:
	var stem := config.map_rotation_file if config != null else ""
	var dir := DotMapRotationFile.config_dir_arg()
	var found := DotMapRotationFile.find(stem, dir)

	if found == "" and stem != "" and (dir != "" or stem != HsConfig.new().map_rotation_file):
		# The default name being absent is an install with no maps.yml; a name or a directory
		# somebody chose that finds nothing is a typo they would otherwise never hear about.
		DotLog.warn(CHANNEL, "the map rotation file was not found; every map rotates", {
			"file": stem, "config_dir": dir,
		})

	var paths := PackedStringArray()
	for candidate in ["res://maps.yml", found]:
		if candidate != "" and not paths.has(candidate) and FileAccess.file_exists(candidate):
			paths.append(candidate)

	var read := DotMapRotationFile.load_files(paths, "game-hide-n-seek")

	if not read.ok:
		DotLog.error(CHANNEL, "the map rotation file could not be read; every map rotates", {
			"why": read.error.message,
		})
		rotation_file = null
		apply_rotation()
		return read

	rotation_file = read.value
	if rotation_file.has_rotations():
		DotLog.info(CHANNEL, "the map rotation file", {
			"paths": ", ".join(rotation_file.sources), "active": rotation_file.active_name(),
		})

	apply_rotation()
	return read


## Marks every catalogue map in or out of rotation from the file. With no file, or one with no
## rotations, every map is in: what this game did before maps.yml.
func apply_rotation() -> void:
	if catalogue == null:
		return

	catalogue.in_rotation_fn = Callable()
	catalogue.rotation_order = []

	if rotation_file == null or not rotation_file.has_rotations():
		_rot = null
		_rot_catalogue = null
		return

	_rot_catalogue = DotMapCatalogue.new()

	for id in catalogue.playable(PackedStringArray()):
		var def := DotMapDef.new()
		def.id = id
		def.display_name = str(catalogue.maps[id].get("name", id))
		def.scene_path = "doc:%s" % id
		def.content_id = StringName(catalogue.content_ref(id))
		var _added := _rot_catalogue.add(def)

	_rot = DotMapRotation.of(_rot_catalogue)
	# An empty rotation plays every installed map: the same set as having no file.
	rotation_file.fallback_in = func(_map: DotMapDef) -> bool: return true
	var _applied := rotation_file.apply(_rot)
	var marks := {}

	for def in _rot_catalogue.maps:
		marks[def.id] = def.in_rotation

	# Ids the mirror has not seen (a pack map subscribed since) are out of a file's rotation
	# unless it matches them, which needs a re-apply; the next apply_rotation does that.
	catalogue.in_rotation_fn = func(id: StringName) -> bool: return bool(marks.get(id, true))
	catalogue.rotation_order = _rot.order.duplicate()


## Whether maps.yml's active rotation plays [param id]. A map the catalogue lacks is not.
func in_rotation(id: StringName) -> bool:
	return catalogue != null and catalogue.maps.has(id) and catalogue.in_rotation(id)


## Whether the next map is drawn at random: the rotation's mode when a file is in force,
## [member HsConfig.shuffle_maps] otherwise.
func shuffles_maps() -> bool:
	if _rot != null:
		return _rot.mode == DotMapRotation.Mode.RANDOM

	return config.shuffle_maps


## maps.yml's `commands:` block (prefix and names), or empty with no file.
func rotation_commands() -> Dictionary:
	return rotation_file.commands() if rotation_file != null else {}


## The name a game-specific command answers to: maps.yml's `commands: names:` role (and prefix)
## over [param default]. The first name is the one registered; see [method command_aliases].
func command_name(role: String, default: String) -> String:
	return command_aliases(role, default)[0]


## Every name [param role] answers to, primary first.
func command_aliases(role: String, default: String) -> PackedStringArray:
	var target := DotCommandNamesHolder.new()
	DotCommandNames.apply(target, rotation_commands())
	return DotCommandNames.all_of(target.prefix, target.names, {role: default}, role)


class DotCommandNamesHolder extends RefCounted:
	var prefix: String = ""
	var names: Dictionary = {}

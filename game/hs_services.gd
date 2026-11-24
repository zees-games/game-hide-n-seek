extends GSPlayerGameServices

const HsGame := preload("hs_game.gd")

## Chat, voice and moderation, wired to this game's sides; [GSGameServices] holds the rest.
## The team channel must not leak: a hider who could read the seekers' channel would know where not to stand.

# No `const CHANNEL`: [GSGameServices] declares one and GDScript refuses a redeclaration,
# which is the right refusal — one layer, one channel an operator can turn up.

const CH_ALL := &"all"
const CH_TEAM := &"team"
const CH_NEAR := &"near"
const CH_ADMIN := &"admin"
const CH_WHISPER := &"whisper"

## Metres a shout carries: about two rooms.
const PROXIMITY_RANGE := 20.0

func _services_name() -> String:
	return "hideseek"


func _chat_rules() -> Object:
	return chat_rules()


## The same rules, as a static a CLIENT can ask for without building a services layer.
## Static because `new()` on a services layer builds a moderation store and a router, leaks them, and inside a delivered pack fails to compile (a script whose base class is in the HOST build cannot hand its return type to a script in the mount).
static func chat_rules() -> GSChatRules:
	var rules := GSChatRules.new()
	rules.max_length = 140
	rules.refuse_over_length = false
	rules.allow_newlines = false
	rules.escape_markup = true
	rules.strip_invisible = true
	rules.collapse_whitespace = true
	rules.rate_per_minute = 22
	rules.burst = 4.0
	rules.flood_penalty_sec = 10.0
	rules.duplicate_window_sec = 8.0
	rules.duplicate_depth = 3
	rules.command_prefixes = PackedStringArray(["!", "/"])
	# An unclaimed `!command` is not broadcast: a player typing `!ban` at a server with no
	# such command would otherwise say "!ban" to everybody, which is worse than nothing
	# happening.
	rules.broadcast_unknown_commands = false
	rules.history_limit = 300
	return rules


func _chat_channels() -> Array:
	return chat_channels()


static func chat_channels() -> Array[GSChatChannel]:
	var out: Array[GSChatChannel] = []

	var everyone := GSChatChannel.make(CH_ALL, "All", GSChatChannel.Scope.EVERYONE)
	everyone.colour = Color(0.93, 0.94, 0.96)
	# Short, because a round is a few minutes: a backlog longer than the round is a
	# conversation from a game the new player was not in.
	everyone.backlog = 10
	everyone.history_limit = 200
	out.append(everyone)

	var team := GSChatChannel.make(CH_TEAM, "Team", GSChatChannel.Scope.TEAM)
	team.prefix = "[team]"
	team.colour = Color(0.55, 0.82, 0.95)
	# [b]No backlog, and the draw is what makes that matter.[/b] A backlog is handed to whoever
	# joins, and the sides change every round: a replayed team line is last round's seekers'
	# plan handed to whoever is seeking now — or to a hider who was seeking then.
	team.backlog = 0
	team.history_limit = 120
	out.append(team)

	var near := GSChatChannel.make(CH_NEAR, "Near", GSChatChannel.Scope.RADIUS)
	near.prefix = "[near]"
	near.colour = Color(0.82, 0.86, 0.72)
	near.radius = PROXIMITY_RANGE
	near.backlog = 0
	near.history_limit = 80
	out.append(near)

	var admin := GSChatChannel.make(CH_ADMIN, "Admin", GSChatChannel.Scope.EVERYONE)
	admin.prefix = "[ADMIN]"
	admin.colour = Color(0.98, 0.72, 0.35)
	admin.admin_only = true
	# A gag is about a player's speech; an admin who has been gagged has a bigger problem
	# than chat.
	admin.ignores_gag = true
	admin.backlog = 0
	out.append(admin)

	var whisper := GSChatChannel.make(CH_WHISPER, "Whisper", GSChatChannel.Scope.DIRECT)
	whisper.prefix = "[w]"
	whisper.colour = Color(0.78, 0.71, 0.93)
	whisper.backlog = 0
	out.append(whisper)

	return out


## The voice format, which both ends must agree on exactly.
## Static because the client builds one too, and a differing sample rate makes the router refuse every packet as the wrong length, counted and said to nobody ([method GSVoiceConfig.format_fingerprint]).
static func voice_format() -> GSVoiceConfig:
	var config := GSVoiceConfig.new()
	config.sample_rate = 16000
	config.frame_ms = 20.0
	config.codec_id = &"adpcm"
	# [b]Push to talk, because a hider with an open microphone is a hider that taunts for
	# free.[/b] Every breath from a cupboard would give somebody away.
	config.push_to_talk = true
	config.activation_rms = 0.02
	config.hangover_ms = 250.0
	config.jitter_ms = 60.0
	config.jitter_max_ms = 400.0
	config.proximity_range = PROXIMITY_RANGE
	config.max_bytes_per_second = 6144
	return config


func _voice_config() -> Object:
	return voice_format()


## Voice goes to the team, because the two sides are the game.
## A hider saying "I'm behind the fridge" on an open channel is a hider who is caught. Everybody voice is a key away.
func _voice_default_channel() -> int:
	return GSVoiceRouter.Channel.TEAM


## Where a body starts again is the game's; the rest of the admin set is [GSPlayerGameServices]'s.
func _mod_extra_abilities() -> Dictionary:
	return {
		"respawn": func(id: StringName, _args: Dictionary) -> GSResult:
			var p := _mod_player(id)
			var field := game as HsGame
			if p == null or field == null or field.map == null or field.map.doc.is_empty():
				return _mod_absent(id)
			var spot: Array = field.map.spawn(
				"seekers" if field.team_of(p.player_id) == HsGame.SEEKERS else "hiders", 0)
			p.reset_round()
			p.watching = false
			if p.health != null:
				p.health.health = p.health.max_health
				p.health.alive = true
				p.health.invulnerable = false
			p.place_at(spot[0], spot[1])
			if field.spectate != null:
				field.spectate.spawned(String(p.player_id))
			return GSResult.success(spot[0]),
	}


func _mod_unsupported() -> Dictionary:
	return {
		"give": "nobody here carries anything",
		"strip": "nobody here carries anything",
		"burn": "nothing here burns",
	}


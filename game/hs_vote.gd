extends Node

## The players choose the next map: [DotVoteDirector] over a [DotVoteListSource] of this server's maps. This file decides only WHEN: a ballot opens [member open_after_sec] into the LAST round on a map ([member due_fn]) and applies when it ends; everything about the ballot itself is dot-vote's settings.
## `trigger` is MANUAL, not ROUND_END: ROUND_END applies at the NEXT round's end, a round late; opening in the last round with `apply: END_OF_ROUND` puts the choice on the very next round.
## Server side only: a client draws the ballot from the notice [member ballot_fn] sends and never holds a director, or it would be deciding what it plays.

const HsCatalogue := preload("hs_catalogue.gd")

const CHANNEL := "hideseek.vote"

## The key in the running game's descriptor metadata an operator's overrides are read from —
## [code]metadata: map_vote:[/code] in a delivered game's [code]game.yml[/code].
const METADATA_KEY := "map_vote"

## The dot-vote API level at which the director opens a rocked vote itself under MANUAL.
const RTV_OPENS_IN_DIRECTOR_LEVEL := 2

## What the vote command is called: `!vote 2` in chat, `vote 2` in a console.
const COMMAND_NAMES := {"vote": "vote"}

## Seconds into the last round on a map before its ballot opens. Late enough that nobody votes
## while hiding, early enough that a short round still sees it close.
@export var open_after_sec: float = 20.0

## The file a server owner configures the vote in, keyed exactly as [DotVoteRules]. Layered: [code]_rules() < game.yml metadata map_vote: < this file < DOT_VOTE_* < --vote-*[/code].
## Empty skips the file; [code]{"enabled": false}[/code] turns the vote off and the rotation ([code]hs_shuffle_maps[/code]) decides alone.
@export var config_path: String = "user://cfg/hideseek_vote.json"

## [code]func() -> Array[/code] of [code][id, name][/code] pairs: every map a ballot may
## offer. The host's, because which maps a server plays is the world's to say.
var maps_fn: Callable = Callable()

## [code]func() -> bool[/code]: whether this round is the map's last, and owes a ballot. Unset
## is every round.
var due_fn: Callable = Callable()

## [code]func(id: StringName) -> DotResult[/code]: play this map next.
var apply_fn: Callable = Callable()

## [code]func() -> Array[/code] of voter ids (StringName): the people who may vote. Stand-ins
## are not voters — a ballot they could swing is not the players' choice.
var voters_fn: Callable = Callable()

## Says a line to everybody.
var announce_fn: Callable = Callable()

## Whether a voter is an admin, for dot-vote's admin bypasses.
var is_admin_fn: Callable = Callable()

## [code]func(state: Dictionary)[/code]: the ballot as a client draws it, sent when it changes.
var ballot_fn: Callable = Callable()

## [code]func(voter: StringName) -> Dictionary[/code]: a voter's name and avatar, for the ballot.
var people_fn: Callable = Callable()

## [code]func() -> bool[/code]: whether a round is being played right now — not warmup, not
## between rounds. Handed to dot-vote so [code]time_up: finish_round[/code] holds a change
## only for a round in progress. The host's, because only the match knows.
var round_in_progress_fn: Callable = Callable()

var director: DotVoteDirector = null
var source: DotVoteListSource = null
var commands: DotVoteCommands = null

## `() -> Dictionary`: maps.yml's `commands:` block, so an operator renames the vote's commands
## without this game naming any. The module points it at the game's rotation file.
var commands_spec_fn: Callable = Callable()

## `(id) -> bool` and `() -> Array`: maps.yml's active rotation, handed to the source so the pack
## maps dot-vote merges are filtered and ordered like the game's own (dot-vote API level 12).
var in_rotation_fn: Callable = Callable()
var rotation_order_fn: Callable = Callable()
var feed: DotVoteBallotFeed = null

## Seconds since the map in play was built.
var _on_map_sec: float = 0.0

## Whether this map has had its ballot (or been refused one), so it opens once.
var _opened_this_map: bool = false


## Builds the director. Fails when the rules do not validate, never because there are too few
## maps: a server whose catalogue grows on [code]hs_reload[/code] gets a ballot from then on.
func setup() -> DotResult:
	source = DotVoteListSource.new()
	source.label = "maps"
	source.apply_fn = func(id: StringName) -> DotResult:
		return apply_fn.call(id) if apply_fn.is_valid() else DotResult.success(id)
	# Pack maps by dot-vote's own merge, so a choice reads "Name [Pack]". The game's list is
	# handed over as entries_fn as well, so a rebuild before a ballot keeps it; the index is
	# read on every choices() call, so a solo entry never shows online.
	source.entries_fn = _own_maps
	source.follow_content(DotContentIndex.shared(), PackedStringArray([HsCatalogue.CONTENT_KIND]))
	# By name, only where it exists: a delivered pack may run on an older shell dot-vote.
	if "in_rotation_fn" in source:
		source.set(&"in_rotation_fn", in_rotation_fn)
		source.set(&"rotation_order_fn", rotation_order_fn)
	refresh_maps()

	director = DotVoteDirector.new()
	director.name = "VoteDirector"
	director.rules = configured_rules()
	director.source = source
	director.auto_apply = true
	# The host calls begin() whenever a map is built, which a vote's change is one cause of
	# and an operator's hs_reload or a rotation another; both firing would put one play in the
	# history twice. See DotVoteDirector.begin_on_apply.
	director.begin_on_apply = false
	# The server's tick drives it, not the frame clock.
	director.self_advance = false
	director.round_based = true
	# Set by name, and only where it exists: a shell dot-vote older than API 3 has no `round_in_progress_fn`, and naming it would fail the pack's parse.
	# Read through this node's own field, so the order the host sets it in does not matter.
	if "round_in_progress_fn" in director:
		director.set(&"round_in_progress_fn", func() -> bool:
			return not round_in_progress_fn.is_valid() or bool(round_in_progress_fn.call()))

	director.player_count_fn = func() -> int:
		return _voters().size()
	director.voters_fn = _voters
	director.is_admin_fn = func(voter: StringName) -> bool:
		return is_admin_fn.is_valid() and bool(is_admin_fn.call(voter))
	director.announce_fn = func(line: String) -> void:
		if announce_fn.is_valid():
			announce_fn.call(line)

	add_child(director)

	# Rock the vote opens its own ballot from dot-vote API level 2; a second start_vote here would be refused. Below it (an older shell under a delivered pack) MANUAL dropped it and `!rtv` answered "Rocked." and nothing happened.
	# Any round, not only the last on a map (due_fn): rocking is the players asking now.
	if DotAddonApi.build_level("dot_vote") < RTV_OPENS_IN_DIRECTOR_LEVEL:
		director.clock.expired.connect(func(reason: StringName) -> void:
			if reason != DotVoteClock.REASON_RTV or director.is_voting():
				return

			_opened_this_map = true
			var opened := director.start_vote(DotVoteClock.REASON_RTV)

			if not opened.ok:
				DotLog.debug(CHANNEL, "the rocked vote could not open", {"why": opened.error.message})
		)

	director.vote_closed.connect(func(result: DotVoteResult) -> void:
		DotLog.info(CHANNEL, "the map vote closed", {"winner": String(result.winner_id), "votes": result.votes_cast})
	)

	feed = DotVoteBallotFeed.of(director, func(state: Dictionary) -> void:
		if ballot_fn.is_valid():
			ballot_fn.call(state)
	)
	feed.title = "Vote for the next map"
	feed.command = COMMAND_NAMES["vote"]
	feed.people_fn = func(voter: StringName) -> Dictionary:
		return people_fn.call(voter) if people_fn.is_valid() else {}

	return DotResult.success(self)


## [method _rules] under the server owner's layers. A layer that does not validate is refused
## whole, with the reason logged, and the defaults stand.
func configured_rules() -> DotVoteRules:
	var rules := _rules()
	var loaded := rules.layer_over_defaults(
		config_path, DotVoteGameSource.running_game_metadata(METADATA_KEY)
	)
	DotLog.result(CHANNEL, "the map vote's rules", loaded)
	return rules


## What a one-map-per-round game wants from dot-vote by default. Every line is a default an
## operator overrides in [member config_path].
func _rules() -> DotVoteRules:
	var rules := DotVoteRules.new()
	# See the class note: opened here, applied at the round's end.
	rules.trigger = DotVoteRules.Trigger.MANUAL
	rules.apply = DotVoteRules.Apply.END_OF_ROUND
	# A rocked vote changes the map at the round's end too. Immediately would take the
	# furniture out from under every hider in the middle of a round.
	rules.rtv_apply = DotVoteRules.Apply.END_OF_ROUND
	# No time limit: a map lasts a few rounds (`hs_rounds_per_map`), and dot-vote's 45-minute
	# default would expire and change it under a round in progress.
	rules.duration_sec = 0.0
	# There is no clock to extend, and "this map again" is a fair thing to want when a
	# server has two.
	rules.include_extend = false
	# Rock the vote from the first round: dot-vote's two minutes are longer than a round here, and a rocked vote waits for the round's end anyway (rtv_apply).
	rules.rtv_delay_sec = 0.0
	rules.include_current = true
	# Plays, not minutes: two maps with a cooldown of five would offer nothing at all.
	rules.cooldown = 0
	rules.max_options = 5
	rules.vote_duration_sec = 25.0
	rules.method = DotVoteRules.Method.PLURALITY
	rules.tie_break = DotVoteRules.TieBreak.RANDOM
	return rules


## Reads the map list again: on boot, after the delivered maps arrive, and after [code]hs_reload[/code].
## The module calls it after [code]_add_delivered_maps[/code]: built before them the list held one map, and a list of one never opens a ballot.
func refresh_maps() -> void:
	if source == null:
		return

	source.entries.clear()

	for choice in _own_maps():
		var _added := source.add(choice)


## The game's own maps as choices, [member maps_fn] minus the pack maps (which dot-vote merges
## from the index with their pack's name).
func _own_maps() -> Array:
	var out: Array = []

	if not maps_fn.is_valid():
		return out

	for pair: Variant in maps_fn.call():
		var row: Array = pair
		out.append(DotVoteChoice.of(StringName(str(row[0])), str(row[1])))

	return out


## A map was built: the director starts over on it and the ballot timer restarts.
func note_map(id: StringName) -> void:
	if director == null:
		return

	source.current = id
	director.begin(id)
	_on_map_sec = 0.0
	_opened_this_map = false


## The server woke from hibernation: the map ballot is owed again, from the top.
## The director restarts itself ([member DotVoteRules.wake_restart]); this is the seconds into the map at which the ballot opens.
func note_woke() -> void:
	_on_map_sec = 0.0
	_opened_this_map = false


## A round began: the ballot timer starts again, for the round that might be the map's last.
func note_round_start() -> void:
	_on_map_sec = 0.0
	_opened_this_map = false


## A round ended: a decided map is applied now, so the next round starts on it.
func note_round_end() -> void:
	if director != null:
		var _over := director.note_round_end()


## One tick.
func advance(delta: float) -> void:
	if director == null:
		return

	director.advance(delta)

	if feed != null:
		feed.poll()

	# The ballot's own timer waits with the director's clock while the server hibernates; counted on, it ran past open_after_sec over an empty room and the first player in never got a ballot.
	if director.hibernating:
		return

	_on_map_sec += delta

	if _opened_this_map or _on_map_sec < open_after_sec:
		return

	if due_fn.is_valid() and not bool(due_fn.call()):
		return

	_opened_this_map = true

	# Nothing to choose between: one map, or one map and itself.
	if source.entries.size() < 2:
		return

	var opened := director.start_vote(DotVoteClock.REASON_MANUAL)

	if not opened.ok:
		DotLog.debug(CHANNEL, "no map vote this round", {"why": opened.error.message})


func forget_voter(voter: StringName) -> void:
	if director != null:
		director.forget_voter(voter)


func is_voting() -> bool:
	return director != null and director.is_voting()


## dot-vote's commands on [param host]: `vote`, `rtv`, `nominate` and the operator's. Voters
## are the bare session id, the same spelling [member voters_fn] lists — dot-vote's default is
## `u<userid>`, and two spellings of one voter is a player who rocks the vote twice.
func install_commands(host: Object) -> DotResult:
	if director == null:
		return DotResult.fail(DotError.CODE_STATE, "There is no vote to command.")

	commands = DotVoteCommands.new()
	commands.director = director
	commands.names = COMMAND_NAMES
	commands.spec_fn = commands_spec_fn
	commands.voter_fn = func(ctx: Object) -> StringName:
		var session: Variant = ctx.get("session")

		if session is Object and (session as Object).get("userid") != null:
			return StringName(str((session as Object).get("userid")))

		return &"console"

	var bound := commands.bind(host)

	if feed != null:
		feed.command = commands.command_name("vote")

	return bound


func _voters() -> Array:
	return voters_fn.call() if voters_fn.is_valid() else []


func describe() -> Dictionary:
	return {
		"maps": source.entries.size() if source != null else 0,
		"open_after_sec": open_after_sec,
		"on_map_sec": snappedf(_on_map_sec, 0.1),
		"director": director.describe() if director != null else {},
	}


func describe_lines() -> PackedStringArray:
	return director.describe_lines() if director != null else PackedStringArray()

extends GSStatsPlayerProgress

const HsPlayer := preload("hs_player.gd")

## What a player keeps from a round: the numbers this game produces, and what they earn.
## The numbers are the ones only this game has (rounds got through unseen on a map, hiders caught), declared once in [method schema] and reported to gs-stats as a DELTA ("add one"), so two servers reporting one player add up.
## Achievements are rules over those numbers, through [GSAchievementStatsLink] (the differencer between SESSION and lifetime totals). Stand-ins are never counted. Server side and on an offline client. Numbers are filed under the scoped profile key when there is one ([member durable_key_fn]), else the world's id, which lasts a connection. The shared parts are [GSStatsPlayerProgress]'s.

## The published skill figure the site orders by (gs-stats' GSStatsRank).
const RANK_SCORE := &"rank_score"


## Rounds a player was in from the start to the end, and won.
const ROUNDS_PLAYED := &"hs.rounds_played"
const ROUNDS_WON := &"hs.rounds_won"
## Rounds started on each side.
const HIDER_ROUNDS := &"hs.hider_rounds"
const SEEKER_ROUNDS := &"hs.seeker_rounds"
## A round got through hidden, never caught.
const SURVIVED := &"hs.survived"
## A hider caught, by the seeker who caught them, and the most in one round.
const CAUGHT_OTHERS := &"hs.caught"
const BEST_ROUND_CAUGHT := &"hs.best_round_caught"
## Caught, as a hider.
const TIMES_CAUGHT := &"hs.times_caught"
## Caught first in a round, which under the default draw is next round's seeker.
const FIRST_CAUGHT := &"hs.first_caught"
## Caught by being watched rather than touched.
const SPOTTED := &"hs.spotted"
## A taunt chosen, and one forced by standing still.
const TAUNTS := &"hs.taunts"
const FORCED_TAUNTS := &"hs.forced_taunts"
## A fall below the map.
const FALLS := &"hs.falls"
## A door opened or shut.
const DOORS := &"hs.doors"

## The world's own side dictionary, shared. See [HsSpectate] for why not a reference to it.
var sides: Dictionary = {}

## player id -> hiders they caught this round, for [constant BEST_ROUND_CAUGHT].
var _round_found: Dictionary = {}

## Hiders caught so far this round, so the first is known.
var _caught_this_round: int = 0


static func ids() -> Array[StringName]:
	return [
		ROUNDS_PLAYED, ROUNDS_WON, HIDER_ROUNDS, SEEKER_ROUNDS, SURVIVED, CAUGHT_OTHERS,
		BEST_ROUND_CAUGHT, TIMES_CAUGHT, FIRST_CAUGHT, SPOTTED, TAUNTS, FORCED_TAUNTS, FALLS,
	]


## Every number, once. [b]`publish` on the ones a player page would show[/b]; rounds played and
## falls are inputs to a ratio rather than figures anybody reads.
static func schema() -> GSStatsSchema:
	var out := GSStatsSchema.new()
	add_def(out, ROUNDS_PLAYED, GSStatsDef.Kind.COUNTER, "Rounds played", "rounds", false)
	add_def(out, ROUNDS_WON, GSStatsDef.Kind.COUNTER, "Rounds won", "rounds", true)
	add_def(out, HIDER_ROUNDS, GSStatsDef.Kind.COUNTER, "Rounds hiding", "rounds", true)
	add_def(out, SEEKER_ROUNDS, GSStatsDef.Kind.COUNTER, "Rounds seeking first", "rounds", true)
	add_def(out, SURVIVED, GSStatsDef.Kind.COUNTER, "Rounds never found", "rounds", true)
	add_def(out, CAUGHT_OTHERS, GSStatsDef.Kind.COUNTER, "Hiders caught", "hiders", true)
	add_def(out, BEST_ROUND_CAUGHT, GSStatsDef.Kind.BEST, "Most hiders caught in a round", "hiders", true)
	add_def(out, TIMES_CAUGHT, GSStatsDef.Kind.COUNTER, "Times caught", "times", true)
	add_def(out, FIRST_CAUGHT, GSStatsDef.Kind.COUNTER, "Caught first", "times", true)
	add_def(out, SPOTTED, GSStatsDef.Kind.COUNTER, "Caught by being seen", "times", false)
	add_def(out, TAUNTS, GSStatsDef.Kind.COUNTER, "Taunts", "taunts", true)
	add_def(out, FORCED_TAUNTS, GSStatsDef.Kind.COUNTER, "Taunts forced by standing still", "taunts", false)
	add_def(out, FALLS, GSStatsDef.Kind.COUNTER, "Falls", "falls", false)
	add_def(out, DOORS, GSStatsDef.Kind.COUNTER, "Doors opened or shut", "doors", false)
	var _rank := GSStatsRank.declare(out, RANK_SCORE, "Rank score")
	return out


## What a player can earn, as rules over [method schema]'s numbers.
## Every stat read here must be one [method schema] declares and this file records, or the achievement never unlocks and nothing errors; the suite checks both ways.
static func catalogue() -> GSAchievementCatalogue:
	var made: Array[GSAchievement] = []

	made.append(_sum(&"hs.hidden", "Nowhere to Be Seen", SURVIVED, 1.0, 10,
		"Get through a round without being caught.", &"hs.hider", 1))
	made.append(_sum(&"hs.ghost", "Ghost", SURVIVED, 25.0, 30,
		"Get through twenty-five rounds without being caught.", &"hs.hider", 2))
	made.append(_sum(&"hs.tag", "Tag, You're It", CAUGHT_OTHERS, 1.0, 10,
		"Catch a hider.", &"hs.seeker", 1))
	made.append(_sum(&"hs.bloodhound", "Bloodhound", CAUGHT_OTHERS, 50.0, 30,
		"Catch fifty hiders.", &"hs.seeker", 2))
	made.append(_sum(&"hs.loudmouth", "Loudmouth", TAUNTS, 50.0, 15,
		"Taunt the seekers fifty times."))

	# A BEST: four in one round, not four over a career.
	var sweep := GSAchievement.make(&"hs.clean_sweep", "Clean Sweep", [
		GSAchievementRule.make(
			BEST_ROUND_CAUGHT, 4.0, GSAchievementRule.Op.AT_LEAST,
			GSAchievementRule.Merge.HIGHEST
		),
	])
	sweep.description = "Catch four hiders in one round."
	sweep.points = 30
	made.append(sweep)

	# Secret: earned by the thing everybody tries to avoid, and only funny afterwards.
	var first := _sum(&"hs.first_out", "Not It... Oh", FIRST_CAUGHT, 5.0, 10,
		"Be caught first five times.")
	first.secret = true
	made.append(first)

	var out := GSAchievementCatalogue.new()
	out.achievements = made
	return out


static func _sum(
	id: StringName, title: String, stat: StringName, target: float, points: int,
	description: String, series: StringName = &"", tier: int = 0
) -> GSAchievement:
	var out := GSAchievement.make(id, title, [
		GSAchievementRule.make(
			stat, target, GSAchievementRule.Op.AT_LEAST, GSAchievementRule.Merge.SUM
		),
	])
	out.description = description
	out.points = points
	out.series = series
	out.tier = tier
	return out


func _label() -> String:
	return "hideseek"


func _make_schema() -> GSStatsSchema:
	return schema()


func _make_catalogue() -> Object:
	return catalogue()


func _rank_stat() -> StringName:
	return RANK_SCORE


func _rank_terms() -> Array:
	return [
		{"stat": String(ROUNDS_WON), "weight": 3.0},
		{"stat": String(SURVIVED), "weight": 1.0},
		{"stat": String(CAUGHT_OTHERS), "weight": 1.0},
		{"stat": String(TIMES_CAUGHT), "weight": -0.5},
	]


func _setup_feed(target: GSStatsEventFeed) -> void:
	super(target)
	target.is_bot = func(id: Variant) -> bool:
		var body: HsPlayer = players.get(StringName(str(id)))
		return body != null and body.is_bot


## A rank term moved: file the rank on the lifetime baseline plus this session.
func _after_record(player_id: StringName, key_id: StringName, stat: StringName, filed: GSResult) -> void:
	if filed.ok and stat != RANK_SCORE and rank != null and rank.terms.any(func(t: Dictionary) -> bool: return str(t["stat"]) == String(stat)):
		var _s := rank.publish_lifetime(player_id, stats.session_values(key_id), stats.schema)


func _on_leave(player_id: StringName) -> void:
	_round_found.erase(player_id)


func on_round_began() -> void:
	_in_round.clear()
	_round_found.clear()
	_caught_this_round = 0

	for id: StringName in players:
		_in_round[id] = true
		record(id, SEEKER_ROUNDS if int(sides.get(id, 0)) == 2 else HIDER_ROUNDS)


## A round ended. [param winner] is a side, or 0 for a draw.
func on_round_over(winner: int) -> void:
	for id: StringName in _in_round.keys():
		if not players.has(id):
			continue

		record(id, ROUNDS_PLAYED)

		if winner > 0 and int(sides.get(id, 0)) == winner:
			record(id, ROUNDS_WON)

		var found := int(_round_found.get(id, 0))

		if found > 0:
			record(id, BEST_ROUND_CAUGHT, float(found))

	_in_round.clear()
	_round_found.clear()


## A hider never caught, at the end of a round.
func on_survived(player_id: StringName) -> void:
	record(player_id, SURVIVED)


func on_taunted(player_id: StringName, forced: bool) -> void:
	record(player_id, FORCED_TAUNTS if forced else TAUNTS)


## A hider was caught. [param by] is the seeker who caught them, or empty for a fall; [param
## how] is the world's `tag`, `sight` or `fell`.
func on_caught(player_id: StringName, by: StringName, how: StringName) -> void:
	record(player_id, TIMES_CAUGHT)

	if _caught_this_round == 0:
		record(player_id, FIRST_CAUGHT)

	_caught_this_round += 1

	if how == &"sight":
		record(player_id, SPOTTED)

	if by == &"" or by == player_id or not players.has(by):
		return

	report_kill(by, player_id, String(how))
	record(by, CAUGHT_OTHERS)
	_round_found[by] = int(_round_found.get(by, 0)) + 1


func on_fell(player_id: StringName) -> void:
	record(player_id, FALLS)


func on_door(player_id: StringName) -> void:
	record(player_id, DOORS)

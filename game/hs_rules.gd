extends DotMatchRules

## A round ends when the game says so, and the game says who won.
## dot-match's elimination rule nearly fits: a mid-round joiner is benched rather than dead, the hide must never end on a count, and the clock's winner is a server setting. [HsGame] knows all that, and [DotMatchRules] is where a mode dot-match does not ship goes.
## The answer is read, never computed here: a pure function of what the game decided, NONE every tick until it has.

## `func() -> Dictionary`: `{decided: bool, winner: int}`. Set by [HsGame].
var decision_fn: Callable = Callable()


static func make() -> DotMatchRules:
	# Not this class's own name, for dot-match's reason: a script that names itself in an
	# expression cuts Godot 4.7.2's exit teardown short. See docs/gdscript-hazards.md.
	var rules := new()
	rules.id = &"hideseek"
	rules.display_name = "Hide & Seek"
	rules.score_limit = 0
	# The round keeps its own clock; this is the BACKSTOP, set by [HsGame] to the hiding, the seeking and a minute more, so an undecided round ends as a draw rather than running for ever, and dot-match stops warning at every boot.
	rules.time_limit_sec = 600.0
	rules.rounds_to_win = 999
	rules.respawn_disabled = true
	rules.kill_points = 1
	rules.suicide_points = 0
	return rules


func _round_outcome(
	_scoreboard: DotScoreboard,
	_teams: DotTeamManager,
	_elapsed_sec: float
) -> Outcome:
	if not decision_fn.is_valid():
		return Outcome.NONE

	var decision: Dictionary = decision_fn.call()

	if bool(decision.get("decided", false)):
		return Outcome.CUSTOM

	# Only the backstop clock is left to the parent: there is no score limit to reach.
	return super._round_outcome(_scoreboard, _teams, _elapsed_sec)


func _round_winner(_scoreboard: DotScoreboard, _teams: DotTeamManager) -> int:
	if not decision_fn.is_valid():
		return 0

	return int((decision_fn.call() as Dictionary).get("winner", 0))

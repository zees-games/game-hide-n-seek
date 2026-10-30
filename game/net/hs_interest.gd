extends DotNetInterest

const HsGame := preload("../hs_game.gd")
const HsPlayer := preload("../hs_player.gd")

## Who a client is told about: everybody, except that a seeker is told nothing about the hiders while they hide.
## The blindfold made true on the wire: a client never told where somebody is cannot draw them, whatever it does to its renderer. During the hide a seeker's snapshots carry no hider and no toy (a ball rolling from a hider's path is the hider); their mirrors stand where the round put them.
## Evaluated every snapshot, nothing lingers: the default caches for a quarter second and keeps sending a departed entity, which would be a second of where everybody ran. Two dozen players is not worth caching.

## The world whose phase and sides this reads. Set by the bridge.
var game: HsGame = null


func _init() -> void:
	strategy_name = "hideseek"
	evaluation_interval_sec = 0.0


func _is_relevant(observer: DotNetIdentity, entity: DotNetIdentity, _context: Dictionary) -> bool:
	if game == null or observer == null or entity == null:
		return true

	if game.phase != HsGame.Phase.HIDE:
		return true

	var watcher := observer.get_parent() as HsPlayer

	if watcher == null:
		return true

	# A toy: not to a seeker while the hiders hide, or a ball rolling away from where a hider
	# just walked would be that hider on the wire. It is sent as it stands when the seek starts.
	if entity.get_parent() is DotPropToy:
		return game.team_of(watcher.player_id) != HsGame.SEEKERS

	var seen := entity.get_parent() as HsPlayer

	if seen == null:
		return true

	return not (
		game.team_of(watcher.player_id) == HsGame.SEEKERS
		and game.team_of(seen.player_id) == HsGame.HIDERS
	)

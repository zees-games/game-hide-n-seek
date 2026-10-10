extends DotNetInterest

const HsGame := preload("../hs_game.gd")
const HsPlayer := preload("../hs_player.gd")

## Who a client is told about: everybody, except that a seeker is told nothing about the
## hiders while they hide.
##
## [b]The blindfold, made true on the wire.[/b] The HUD draws a seeker's screen black while the
## hiders hide, and a client that skipped drawing it would watch every hider pick its spot. dot-net's
## own note on interest management is the reason this exists: a client that is never told where
## somebody is cannot draw them, whatever it does to its renderer, and every other defence is a
## delaying action. So during the hide a seeker's snapshots carry no hider at all; their mirrors
## stand where the round put them until the seeking starts.
##
## [b]Evaluated every snapshot, and nothing lingers.[/b] The default caches an answer for a
## quarter of a second and keeps sending an entity that has left interest for a while, both to
## save work on big servers; here the answer changes at a phase boundary and a hider that kept
## being sent for a second after the hide began would be a second of where everybody ran.
## Two dozen players is not a set worth caching.

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
	var seen := entity.get_parent() as HsPlayer

	if watcher == null or seen == null:
		return true

	return not (
		game.team_of(watcher.player_id) == HsGame.SEEKERS
		and game.team_of(seen.player_id) == HsGame.HIDERS
	)

# The design

The family's fourth asymmetric game, after buses, deathrun and prop hunt, and the first where **the sides change during a round**: it starts as one or two against everybody and ends as everybody against one or two. Prop hunt's skill is choosing what to be; this one's is choosing where to be, and when to run. So the maps carry the game: every one has a way round (a chase that reaches a dead end is over), a way up, and a crawl space a seeker has to get down on their knees to look into.

Built from mg-prop-hunt, with the disguise, the hull, the hitboxes, the weapons and the decoy charge taken out and catching put in. Where a comment says another game found something, the line was kept because it is still true here.

## A catch is a measurement, and only the server makes one

Nothing is shot and nothing is claimed. Every tick of the seek, `HsGame._advance_catching` looks at where the server has every body:

- **A touch**: a seeker's capsule axis within `tag_range` (1.2 m; two bodies touching are 0.7) of a hider's, feet within 1.6 m of each other, and no wall between their middles.
- **Being watched**: the hider's head or chest inside a seeker's `sight_fov` cone within `sight_range`, nothing solid between (walls and furniture both). It fills a meter over `sight_seconds` that drains at `sight_decay` when nobody is looking.
- `catch_mode` picks touch (the default, as the brief asked), sight, or either.

A client sends movement and nothing else (`HsNetCommand` has no buttons of its own beyond the use key), so there is nothing a client could send to catch anybody.

**People do not collide with people**, as in prop hunt: a hider pinned in a corner by a seeker's body, or one blocking a doorway with their own, would be a different game, and a touch is a distance, so walking through costs nothing.

## A hider caught becomes a seeker, held still, on both ends

`HsGame.catch` moves the hider to the seekers where they stand (`caught_become_seekers`) and holds them for `caught_freeze_seconds` with the controller's `HOLD` modifier, the same one that blindfolds the seekers during the hide. **A modifier, not a timer the game checks**: it travels in the movement state, so the caught player's own client predicts them standing still on exactly the ticks the server holds them. With `caught_become_seekers` off, a caught hider is benched and watches (dot-spectate).

- **A joiner while the seekers are out seeks.** A hider dropped into a half-over round has had no time to hide; a seeker more is a round that ends a little sooner.
- **A fall is a catch.** A hider below `kill_y` during the seek is caught by it (`CAUGHT_FELL`) and stands up at the seekers' start; a seeker who falls is put back there.
- Health stays only for falls and for dot-moderation's slay, slap, god and buddha, which mean what they mean everywhere else. There are no hitboxes. dot-combat's trace is set anyway, or it warns at every boot that shots pass through walls.

## Few seekers, and the first one caught is next

`players_per_seeker` is 8 (one seeker up to eight players, two from nine), at most `max_seekers` 3, because the sides even themselves out as the round goes. `seeker_pick` defaults to `FIRST_CAUGHT`: whoever was caught first last round seeks, and `DotTeamRotation`'s random draw fills the rest. The other modes are dot-team's (RANDOM, QUEUE, SWAP); `!seek` / `!hide` / `!any` are wishes the draw honours, except over the first caught.

## The blindfold is true on the wire

As in prop hunt: the HUD paints a seeker's screen black during the hide, the `HOLD` modifier holds them still, and `net/hs_interest.gd` (`HsInterest`) sends a seeker's snapshots **no hider at all** until the seek starts. **The sight meter is the owner's alone** (`net_sight_meter` is `to_owner_only`), because a seeker told it would know which way to look.

## Everybody is themselves, and the side is the shirt

A hider is their site avatar (dot-platform, `HsAvatars`) with the torso **painted** the side's colour outright: hiders blue, seekers orange. Not tinted: tinting over the atlas made a teal shirt read teal and a red one purple. A side change rebuilds the figure, so a caught hider turns orange on the next frame.

## Taunts, the beacon, points and stats

Taunts are prop hunt's (`DotPropTaunts`): hiders only, from the seek on, forced after `auto_taunt_seconds` (60) within `auto_taunt_radius`. The beacon marks every hidden hider when `beacon_hiders_left` (1) are left or `beacon_seconds_left` (30) remain. Points: winning side 10, a catch 5, surviving 5, taunts. `HsProgress` keeps the stats (doors used among them) and the achievements.

## Bots

A stand-in hider runs to a spot beside a piece of furniture as far from the seekers' start as a seeded draw allows and crouches there, and runs from any seeker within nine metres it can see. A stand-in seeker wanders from prop to prop and sprints at any hider it sees ahead. Bots open a shut door they walk into and leave open ones alone.

## Weapons were taken out

Prop hunt's weapon plumbing (zee-dot-weapons, `ARMED`, the input's slot) was removed rather than left idle. Seeker items found on a map, which the brief anticipates, would copy it back from mg-prop-hunt.

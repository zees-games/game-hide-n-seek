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

## The HUD's glance pieces are dot-ui's

The clock is a `DotScoreStrip` with the hiders still hidden and the seekers as its two side plates, in the sides' colours, and "Hiders win in · <map>" under it (the blindfold's own clock uses `DotScoreStrip.clock_text`, so the two never disagree by a second). The door prompt under the crosshair is a `DotKeyPrompt`, "Open the toilet door" with the use key as bound drawn as a key; the sight meter sits under it, because a hider can have both up at once. The disc with the side's letter stays: nobody here has health, and the letter is the side. Colours from `HsHud.piece_theme()`. `tools/shot.sh --view=door` renders the prompt. Naming these classes makes the pack need a client shell with dot-ui API level 4; the derived `requires.json` asks for it and `headless_run` checks it.

## Props collide as their shape

Christian's first play test (2026-10-11) circled the trees wanting their low branches and met the canopy's box at arm's length all the way to the ground, and a bot pressed against that box looked like it hung in the air beside the tree. A prop now collides as its **pieces**: a few convex hulls measured out of the model by dot-props' `DotPropPieces` in `tools/measure_props.gd` (one decomposition per material, so a leaf clump and the trunk come apart), written to `props/pieces.json` and read by the server and every client alike, as the catalogue's sizes are. A tree is its trunk, its branch stubs and its leaf clumps; a table its top and legs, so a seeker sees under it; a sofa its seat, back and arms. A prop the decomposition cannot improve on (a fridge, a crate, anything under 0.6 m) keeps its box.

What a person can now do with Kenney's trees: walk in under the leaves to the trunk, hide behind it, and jump onto the stubby branches of the commonest tree (1.1 m and 1.5 m up, `headless_climb`). Kenney's clumps sit on their branches and the conifers are stacked cones, so no tree in the kit has a long limb to stand on; that wants a model of its own.

Measured on hs_camp (84 trees): 831 shapes became 2078, a server tick with twelve runners 1.04 ms became 1.05 ms, a ray 4.7 µs became 5.9 µs.

## Bots

A stand-in hider runs to a spot beside a piece of furniture as far from the seekers' start as a seeded draw allows and crouches there, and runs from any seeker within nine metres it can see. A stand-in seeker wanders from prop to prop and sprints at any hider it sees ahead. Bots open a shut door they walk into and leave open ones alone.

## Weapons were taken out

Prop hunt's weapon plumbing (zee-dot-weapons, `ARMED`, the input's slot) was removed rather than left idle. Seeker items found on a map, which the brief anticipates, would copy it back from mg-prop-hunt.

## Colour and light

The family's sunny look (game-arena's built-in maps), carried over from mg-prop-hunt, whose `ph_materials.gd` and `ph_map.gd` these files mirror.

- **Every building surface** (floor, wall, ceiling, roof, the ground outside) is Kenney's light prototype grid, or his tiles on a floor, under a pastel per surface (`HsMaterials.PASTELS`: peach wood, periwinkle carpet, coral brick, mint grass, lavender roof), mapped in world space at 4 m a copy. A map's tint still multiplies it, paled halfway to white, because the tints were chosen against the old darker colours and at full strength turned a pastel to mud. Glass, water, court lines, boards, lockers, metal, fabric and lamps keep their generated look; furniture keeps Kenney's colours, so a hider crouched behind a sofa is beside a coloured thing in a pale room. The two textures load through `HsPaths.rebase` and fall back to the generated look when absent.
- **Light is a dot-lighting document made from the map's `environment`** (`HsMap.light_document`): the map's sun angle and colour, its sky at the zenith and under the horizon, its horizon as fog from 120 m; brightness 380 times the square of `sun_energy`. The fill is a near-neutral pale grey at 1.4 times the map's `ambient_energy`: game-arena's pale cool fill at its flat 1.0 turned every room, which is lit by the fill and its lamps rather than the sun, into a lavender haze with nothing in shadow. Glow starts above white (the lamps), not at dot-lighting's 0.85, where a room of pale walls glowed milky.
- **Compatibility** (this game's and the shell's renderer) divides the sun by 700 instead of 200 and takes the fill at 0.87 times the map's (`HsMap.light_profile`). Shadows stay on in the browser. Check a look change in both renderers.

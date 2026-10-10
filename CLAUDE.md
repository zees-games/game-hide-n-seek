# game-hide-n-seek

Hide and seek. Most players hide, as themselves in the hiders' blue; one or two seekers count blindfolded and then catch them, by a touch (or, on a server set that way, by keeping them in view), and every hider caught becomes a seeker. The hiders win if anybody is still hidden when the clock runs out.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and each addon's own `CLAUDE.md` before working in it. This file is only about what this game decides. The maps are in `maps/`, a link to [hide-n-seek-maps](../hide-n-seek-maps), written by its `tools/build_maps.py`; `maps/README.md` there is the format.

**Built 2026-10-10 from mg-prop-hunt** (module, services, wire, client, HUD, spectate, progress, avatars, figure, vote, map documents, the prop catalogue and the taunts, renamed `ph` → `hs`), with the disguise, the hull, the hitboxes, the weapons and the decoy charge taken out and catching put in. Where a comment says "mg-wipeout found…" or "mg-smash-copter found…", the finding is that game's and the line was kept because it is still true here.

## What this game is, versus the others

The fourth asymmetric one, after buses, deathrun and prop hunt, and the first where **the sides change during a round**: it starts as one or two against everybody and ends as everybody against one or two. Prop hunt's skill is choosing what to be; this one's is choosing where to be, and when to run. So the maps carry the game: every one has a way round (a chase that reaches a dead end is over), a way up, and a crawl space a seeker has to get down on their knees to look into.

## Layout

```
game/
  hs_config.gd       every rule a round is played under (maps are documents)
  hs_map_doc.gd      what a map IS: boxes, props by catalogue id, lights, spawns (hiders, seekers); validated
  hs_map.gd          a document built: solid boxes, furniture shapes, drawn batches, spawns
  hs_props.gd        the prop catalogue (props/catalogue.json): sizes, models, recolour, parts
  hs_materials.gd    the surfaces a box is drawn with, textures made in code
  hs_catalogue.gd    every map the server has, the built-in practice house, which is next
  hs_controller.gd   DotFpsController with the HOLD modifier (blindfolded, or just caught)
  hs_player.gd       one person: their body, health, caught, the sight meter, the hold, the beacon
  hs_game.gd         the simulation: the draw, hide/seek, catching, conversion, taunts, falls, beacons, bots
  hs_rules.gd        a DotMatchRules whose outcome is whatever HsGame decided
  hs_hud.gd          the clock, hints, the side disc, the taunt meter, the sight meter, the blindfold
  hs_audio.gd        the round's cues (made in code) and taunts played from a hider
  hs_client.gd       one local player, alone or against a server; first person, F5 for third
  hs_bindings.gd     every key, as dot-menu bindings; hs_settings.gd the Escape menu
  hs_module.gd       the DotGameModule: cvars, hs_status / hs_maps / hs_catch / hs_map, stand-ins
  hs_services.gd     chat, voice and moderation over dot-game's base
  hs_progress.gd     stats and achievements; hs_vote.gd the map vote; hs_spectate.gd who watches whom
  net/               the codec (MAP, CAUGHT, TAUNT…), the link, the player behaviour, the bridge,
                     and HsInterest (the blindfold on the wire)
props/               kits.json (which Kenney models, at what scale), catalogue.json (measured)
assets/props/        the vendored furniture and nature models (Kenney, CC0)
taunts/              the taunt sounds and taunts.json (Kenney, CC0); edit freely
maps/                link to ../hide-n-seek-maps/maps
examples/            headless_run (84), headless_maps (49), headless_climb (9), headless_net (41), dedicated (42)
tools/               shot.sh/.gd (render a view), measure_props.gd, audio_probe (xvfb only)
```

## Decision 1: a catch is a measurement, and only the server makes one

Nothing is shot and nothing is claimed. Every tick of the seek, `HsGame._advance_catching` looks at where the server has every body: a **touch** is a seeker's capsule axis within `tag_range` (1.2 m; two bodies touching are 0.7) of a hider's, feet within 1.6 m of each other, and no wall between their middles; **being watched** is a seeker's eye with the hider's head or chest inside a `sight_fov` cone within `sight_range` and nothing solid between, walls and furniture both, and it fills a meter over `sight_seconds` that drains at `sight_decay` when nobody is looking. `catch_mode` picks touch (the default, as the brief asked), sight, or either. A client sends movement and nothing else (`HsNetCommand` has no buttons of its own), so there is nothing a client could send to catch anybody. `headless_run` arms both wall tests: with them taken out, nine checks fail.

**People do not collide with people**, as in prop hunt: a hider pinned in a corner by a seeker's body, or one blocking a doorway with their own, would be a different game, and a touch is a distance, so walking through costs nothing.

## Decision 2: a hider caught becomes a seeker, held still, on both ends

`HsGame.catch` moves the hider to the seekers where they stand (`caught_become_seekers`) and holds them for `caught_freeze_seconds` with the controller's `HOLD` modifier, the same one that blindfolds the seekers during the hide. **A modifier, not a timer the game checks**: it travels in the movement state, so the caught player's own client predicts them standing still on exactly the ticks the server holds them. `headless_net` arms this: with the hold as a server-only timer, the caught client predicts itself 0.8 m across the room while the server has it standing. Off, a caught hider is benched and watches (dot-spectate), like a joiner in prop hunt.

**A joiner while the seekers are out seeks.** A hider dropped into a half-over round has had no time to hide, and benching them would be minutes of watching; a seeker more is a round that ends a little sooner.

**A fall is a catch.** A hider below `kill_y` during the seek is caught by it (`CAUGHT_FELL`) and stands up at the seekers' start; a seeker who falls is put back there. Health stays only for this and for dot-moderation's slay, slap, god and buddha, which mean what they mean everywhere else; there are no hitboxes.

## Decision 3: few seekers, and the first one caught is next

`players_per_seeker` is 8 (one seeker for up to eight players, two from nine), at most `max_seekers` 3, because the sides even themselves out as the round goes. `seeker_pick` defaults to `FIRST_CAUGHT`: whoever was caught first last round seeks, and `DotTeamRotation`'s random draw fills the rest. The other three modes are dot-team's (RANDOM, QUEUE, SWAP); `!seek` / `!hide` / `!any` are wishes the draw honours, except over the first caught.

## Decision 4: the blindfold is true on the wire

Unchanged from prop hunt: the HUD paints a seeker's screen black during the hide, the `HOLD` modifier holds them still, and `net/hs_interest.gd` sends a seeker's snapshots no hider at all until the seek starts. `headless_net` moves a hider during the hide and asserts the seeker's copy did not move, then that it is right the tick seeking starts. **The sight meter is the owner's alone** (`net_sight_meter` is `to_owner_only`), because a seeker told it would know which way to look; `headless_net` checks the other hider's copy reads zero while the server's does not.

## Decision 5: everybody is themselves, and the side is the shirt

A hider is their TMC avatar (dot-platform, `HsAvatars`) with the torso painted the side's colour outright: hiders blue, seekers orange. **Painted, not tinted**: prop hunt's figure tinted the torso over the atlas, and a render of the park showed a teal shirt tinted blue reads as teal and a red one as purple. A side change rebuilds the figure, so a caught hider turns orange on the next frame.

## Taunts, the beacon, points and stats

Taunts are prop hunt's (`DotPropTaunts`): hiders only, from the seek on, forced after `auto_taunt_seconds` (60) within `auto_taunt_radius`. The beacon marks every hidden hider with `beacon_hiders_left` (1) left or `beacon_seconds_left` (30) to go. Points: winning side 10, a catch 5, surviving 5, taunts. `HsProgress` keeps thirteen stats and seven achievements (catches, the best round, times caught, caught first, spotted, rounds never found).

## Bots

A stand-in hider runs to a spot beside a piece of furniture as far from the seekers' start as a seeded draw allows and crouches there, and runs from any seeker within nine metres it can see; a stand-in seeker wanders from prop to prop and sprints at any hider it sees in front of it. In `dedicated` the stand-in seekers catch everybody inside the round.

## What running it found

- **A seeker reported in a round that had already redrawn.** `headless_run` checked "everybody ends it seeking" four ticks after the last catch, by which time intermission 0 had started the next round. The check is made before the step now.
- **Teal shirts**: the side tint over the atlas (Decision 5). Found by rendering.
- **"You was caught"**: the local player is "You" offline. Found by rendering.
- **Two HUD lines on top of each other** for a hider (the old disguise line under the taunt meter). Found by rendering.
- **A warehouse washed orange** by fog over a sunset sky, as prop hunt's woods once were. Found by rendering.
- **dot-combat warned at every boot that shots pass through walls**, because nothing here shoots and the trace was left out; it is set anyway. Found by `hideseek_client` in dot-server-deploy.

## Validating

```bash
./game.sh test                                          # parse, then all five suites
python3 ../hide-n-seek-maps/tools/build_maps.py --check
tools/shot.sh --view=overview --hs-map-ids=hs_manor
tools/shot.sh --view=room --hs-map-ids=hs_warehouse --at=-4,1.4,-5 --look=-16,0.6,-9
tools/shot.sh --view=hider --third                      # your own body, in blue
tools/shot.sh --view=seeker --board --name=board
tools/shot.sh --view=blind
tools/shot.sh --view=caught
```

`headless_climb` stands somebody at the foot of every stairway that matters and holds forward, and tries a play tube standing and crouched; its coordinates are the maps repo's, so a map moved there is a climb that fails here. Without `maps/` linked in (CI clones this repository alone) `headless_maps` checks the practice house only and `headless_climb` has nothing to climb, and both say so.

## Delivery

As prop hunt: the maps are their own repository and pack, [hide-n-seek-maps](../hide-n-seek-maps), named by the server owner in their map config (dot-server-deploy's `cfg/content.yml`), fetched by `HsModule._add_delivered_maps` through `DotGameContent.map_dirs`. The game's own pack carries only `hs_practice`. dot-server-deploy has `content/hideseek/`, `content/hideseek_maps/` and `examples/hideseek_client` (22 checks, passing 2026-10-10): the delivered pack boots, a real client joins over a real socket, the maps, prop catalogue and taunts are read from their mounts, and the client builds the server's map with every prop. No `class_name` anywhere in `game/`, because a mounted pack cannot register one.

**Before publishing**: dot-props (API level 2), dot-team (2), dot-fx (2), dot-game (3) and dot-menu must be tagged and in the client shell, as for prop hunt. This game added nothing to any addon.

## Still to do

1. **Put it live.** Create `gamemann/game-hide-n-seek` and `gamemann/hide-n-seek-maps` (the remotes are set), publish the maps pack before the game.
2. **Try it in a browser**, with people: how long the hide is, how far a touch reaches and how fast the sight meter fills are numbers only play settles.
3. **Seeker items** found on a map, as the brief anticipates. The weapon plumbing prop hunt had (zee-dot-weapons, `ARMED`, the input's slot) was taken out rather than left idle; prop hunt is where to copy it back from.
4. **Stamina.** dot-player-controller has none; sprint is a flat `sprint_scale`. A stamina modifier there would serve every game that sprints.
5. **The catching rules as an addon**, once a second game wants them (an infection mode, a tag game): touch and sight are about two hundred lines of `HsGame` and depend on nothing of this game's.

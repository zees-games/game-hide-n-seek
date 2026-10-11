# game-hide-n-seek

Hide and seek. Most players hide, as themselves in the hiders' blue; one or two seekers count blindfolded and then catch them, by a touch (or, on a server set that way, by keeping them in view), and every hider caught becomes a seeker where they stand. The hiders win if anybody is still hidden when the clock runs out. Built from mg-prop-hunt with disguises, hitboxes and weapons taken out and catching and doors put in.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to this game. The maps are in `maps/`, a link to [hide-n-seek-maps](../hide-n-seek-maps), written by its `tools/build_maps.py`; `maps/README.md` there is the format. **The detail is in [docs/](docs/README.md).**

## Read before

| Read | Before |
| --- | --- |
| [docs/README.md](docs/README.md) | the index |
| [docs/design.md](docs/design.md) | catching, conversion, the seeker draw, the blindfold, avatars and shirts, taunts, beacons, bots |
| [docs/doors.md](docs/doors.md) | `hs_doors.gd`, the use key, anything that moves in a map |
| [docs/testing.md](docs/testing.md) | adding a check, believing a green run, rendering |
| [docs/history.md](docs/history.md) | a bug that "cannot be happening" |

## Layout

| Path | What |
| --- | --- |
| `game/hs_game.gd`, `hs_rules.gd` | the simulation: the draw, hide/seek, catching, conversion, taunts, falls, beacons, bots; a `DotMatchRules` whose outcome is whatever `HsGame` decided |
| `game/hs_map_doc.gd`, `hs_map.gd`, `hs_doors.gd`, `hs_catalogue.gd` | what a map is (boxes, props by catalogue id, lights, spawns), validated; a map built; the doors; every map the server has and the built-in practice house |
| `game/hs_props.gd`, `hs_materials.gd` | the prop catalogue (`props/catalogue.json`); surfaces: Kenney's prototype grid under a pastel for every building surface, the rest made in code |
| `game/hs_player.gd`, `hs_controller.gd` | one person (body, caught, sight meter, hold, beacon); `DotFpsController` with the HOLD modifier |
| `game/hs_config.gd`, `hs_paths.gd` | every rule a round is played under; `rebase` for pack delivery |
| `game/hs_module.gd`, `hs_services.gd`, `hs_vote.gd`, `hs_progress.gd`, `hs_spectate.gd`, `hs_server.gd` | the `DotGameModule` (cvars, `hs_status`/`hs_maps`/`hs_catch`/`hs_map`, stand-ins, delivered maps); chat/voice/moderation; the map vote; stats; spectating |
| `game/net/` | the codec (MAP, CAUGHT, TAUNT, DOOR…), link, player behaviour, bridge, and `hs_interest.gd` (the blindfold on the wire) |
| `game/hs_client.gd`, `hs_hud.gd`, `hs_audio.gd`, `hs_figure.gd`, `hs_avatars.gd`, `hs_bindings.gd`, `hs_settings.gd`, `hs.tscn` | the client: first person, F5 for third; keys as dot-menu bindings; the Escape menu |
| `props/`, `assets/props/`, `taunts/` | `kits.json` and the measured `catalogue.json`; vendored Kenney furniture and nature models (CC0); taunt sounds and `taunts.json` (CC0, edit freely) |
| `maps/` | link to `../hide-n-seek-maps/maps` |
| `examples/` | `headless_run`, `headless_maps`, `headless_climb`, `headless_net`, `dedicated` |
| `tools/` | `shot.sh` (render a view; `--doors=open`), `measure_props.gd`, `audio_probe` (xvfb only) |

## Running and testing

- `./game.sh` plays offline; `./game.sh online` runs a local server and browser client; `./game.sh test` parses and runs all five suites. After a map change, `python3 ../hide-n-seek-maps/tools/build_maps.py --check`.
- `headless_maps` swings every door and walks every doorway; `headless_climb` walks every stairway and a tube. Both need `maps/` linked, and say so when it is not. [testing](docs/testing.md)
- **Render after touching what anyone sees** (`tools/shot.sh`); the shirt colour, HUD overlaps, fog and floor striping were only found in a picture.

## Rules

- **A catch is the server's measurement**: touch (`tag_range`, feet close, no wall between) or sight (cone, range, nothing solid between, a meter). A client sends movement and the use key, nothing a catch could come from. [design](docs/design.md#a-catch-is-a-measurement-and-only-the-server-makes-one)
- People do not collide with people.
- **Holding still is the `HOLD` modifier in the movement state**, never a timer the game checks, so the held client predicts it exactly (the blindfold and a new seeker's freeze both).
- A joiner during the seek seeks; a fall during the seek is a catch (`CAUGHT_FELL`).
- The first caught seeks next (`seeker_pick` `FIRST_CAUGHT`); side wishes are honoured except over that.
- **The blindfold is true on the wire**: `HsInterest` sends a seeker no hider during the hide. The sight meter is `to_owner_only`.
- The side colour is painted onto the torso, never tinted over the atlas; a side change rebuilds the figure.
- **Doors** ([doors](docs/doors.md)): state is `(open, since, flip)`; only a `DOOR` use is sent (and replayed to joiners); a client poses doors for its input tick before predicting; doors are static bodies on the world layer moved through `PhysicsServer3D`; a use is refused while anybody is in the panel's sweep; the use key is `BUTTON_USER_0` with the press made from the edge.
- **Rooms are pastel on Kenney's prototype grid; furniture keeps Kenney's colours** (`HsMaterials.PASTELS`, map tint paled halfway on top). Light is a dot-lighting document from the map's `environment` (`HsMap.light_document`), near-neutral fill at the map's `ambient_energy`, glow only above white, turned down under Compatibility. A secret panel is drawn with its wall's surface and tint, so it still matches. [design](docs/design.md#colour-and-light)
- dot-combat's trace is set even though nothing shoots.
- **Delivery**: no `class_name` in `game/`; every own `res://` path through `HsPaths.rebase()` where defined (see [mg-buses-from-hell's delivery.md](../mg-buses-from-hell/docs/delivery.md)). Maps are their own pack, named by the server owner's map config and fetched by `HsModule._add_delivered_maps`; the game's own pack carries only `hs_practice`. dot-server-deploy's `examples/hideseek_client` is the real-client check.
- **The map vote** (`game/hs_vote.gd`, MANUAL, applied at a round's end): under MANUAL `HsVote` opens a passed rock-the-vote itself (dot-vote does not; `rtv_delay_sec` 0), and `_game_load` refreshes the map list after `_add_delivered_maps`. Without either, `!rtv` answers "Rocked. 1 of 1." and nothing opens, or a delivered server's ballot holds only the practice map and never opens. `examples/dedicated` arms both.
- The catching rules depend on nothing of this game's; extract them to an addon once a second game wants them.

## Not yet done

1. **Put it live.** The remotes are set; `zees-games/game-hide-n-seek` and `zees-games/hide-n-seek-maps` are not created on GitHub. Publish the maps pack before the game. Before publishing, the addons it needs (dot-props, dot-team, dot-fx, dot-game at their current API levels, and dot-menu) must be tagged and in the client shell.
2. **Play it in a browser with people**: the hide's length, the touch's reach and the sight meter's speed are numbers only play settles.
3. **Seeker items** found on a map, as the brief anticipates; copy the weapon plumbing back from mg-prop-hunt.
4. **Stamina**: dot-player-controller has none (sprint is a flat `sprint_scale`); a modifier there would serve every game that sprints.

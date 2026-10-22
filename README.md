This is a game to demonstrate the capabilities of the [**Dot collection**](https://moddingcommunity.com/co/4-dot-assets) built on-top of [Godot 4](https://godotengine.org/) and [TMC's gaming platform](https://moddingcommunity.com/play). In this 3D game, most players are **hiders**: they are their own TMC avatars in a blue shirt, and they have a little while to find somewhere on the map nobody will look. One or two players are **seekers**, who count with a black screen while everybody hides and then go looking. A seeker catches a hider by touching them, and every hider caught becomes a seeker too, so the hunt gets bigger as the round goes on. This is inspired by the classic hide and seek game mode!

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## How it plays
Each round starts with the **hide**. The hiders get 40 seconds to run off and find a spot while the seekers stand at their spawn with a black screen (they can still see their HUD and menus, just not the map or anybody on it). Then the seekers are let go and have 4 minutes.

- **Hiders** are themselves, in blue. Get behind the sofa, up on the roof, into the bottom shelf of a warehouse rack, under the footbridge in the pond. **Shift** sprints and **Ctrl** crouches, and some of the best spots on every map are crawl spaces you only fit into crouched.
- **Seekers** are in orange and carry nothing. Run into a hider to tag them. A server can also make seekers catch by **watching**: keep a hider in view for a couple of seconds and they're caught, with a meter on the hider's screen showing how close it is. Or either one.
- **Caught hiders become seekers** where they stand, frozen for a few seconds first so they can't tag whoever was hiding next to them. A server can turn this off, and then the caught just watch the rest of the round.
- **Taunts.** Once the seekers are let go, a hider can press **T** to play a sound from where they are standing (or **F3** to pick one). Every taunt is worth points, but everybody hears where it came from. Stand still for too long and the game taunts for you, with a meter on screen showing how close it is.
- **The beacon.** When only one hider is left, or with 30 seconds to go, every hider still hidden pings out a sound and a ring everybody can see.
- **Doors.** Press **E** at a door to open or shut it: every room, cupboard, toilet stall, gate and shipping container has one, and the loading bays have shutters. A shut door is a wall, to a seeker's eyes and hands as much as to anybody's feet, so shutting yourself in is hiding, and opening every door is seeking. A door swings away from whoever opens it, and never opens into anybody, which can give away who is standing behind it. Somewhere on most maps is a panel of wall that slides.
- **Toys.** Every map has things to play with, picked for the place: beach balls and footballs to kick (walk into one, or press **E** looking at it), swings and punching bags to push, see-saws and wobbly platforms that tip under you, a roundabout to spin, trampolines and bounce pads that throw you, skittles, barrels and tyres, lamps on a switch, a fountain to turn on, a ship's horn and a school bell. Everybody sees the same ball in the same place. Hide behind a barrel or the roundabout; a ball you kicked rolling away from your hiding place is a clue. Every toy goes back to its place at the start of a round.
- **Falling** off the map catches a hider. A seeker who falls is put back at the start.

The hiders win if any of them is still hidden when the clock runs out. The seekers win if they catch everybody. Winning is worth 10 points to everyone on that side, a catch 5 and surviving a round 5. Catches, rounds survived, times caught and the rest go to your stats and the leaderboards on TMC.

Rounds start with few seekers: one for every eight players. By default the first hider caught is next round's seeker. Say **!seek** or **!hide** in chat to ask for a side. Somebody who joins while the seekers are out joins them. After a few rounds on a map, players vote for the next one (`!rtv`, `!nominate hs_manor`).

There are twelve maps: a small practice house built into the game, and eleven from [hide-n-seek-maps](https://github.com/zees-games/hide-n-seek-maps):

| Map | What it is |
| --- | --- |
| **Larkspur Court** | Three floors of flats with a stairwell up to the roof, a fire escape down the side, an alley, a back yard, a corner shop and a street of parked cars. Every flat has its doors, and one wall upstairs is not a wall |
| **Dockside Warehouse** | Racks you can crawl into, a maze of crate stacks, a mezzanine office, and a container yard on the quay at dusk where you can shut yourself into a container |
| **Hollowmere Manor** | A two-storey house with a gallery round the hall, a cupboard under the stairs nobody can see the door of, a hedge maze, a greenhouse, a gazebo and a shed |
| **Thistle Green** | A village of cottages round a square with a market, a barn with a hayloft, a meeting hall with a hollow stage and a pond with a bridge |
| **Brookside School** | Two floors of classrooms and lockers off one long corridor with a stairwell at each end, a cafeteria, a gym with bleachers to crawl under and a balcony, a portable classroom on blocks, and a library with a room behind its wall |
| **Galleria Mall** | Two floors of shops round a glass-roofed atrium, shutters to pull down, changing rooms, a food court, a supermarket, a cinema with a projection booth nobody can see the door of, and service corridors behind every shop |
| **The Marigold** | A ship at her quay: an engine room to crawl through, a deck of cabins, saloons with promenades down both sides, a sun deck with lifeboats to hide in, the bridge and its roof. Two stairwells run the whole height. Over the side is a catch |
| **Ravenhold Castle** | A walled castle over a moat: a walk along the top of the walls, a tower at each corner with a stair to its top, a gatehouse with a portcullis, a keep of three floors over a dungeon of cells, stables with stall gates to crouch behind, and a tunnel from the dungeon to somewhere nobody would look |
| **Pinehollow Camp** | A summer camp by a lake: cabins up on blocks, tents round a fire, a mess hall, a fire lookout twelve metres up, a treehouse with a rope bridge, a dock with boats to lie in, a boathouse, and a cave in the hillside with a chamber behind a rock |
| **Halden Museum** | Two floors of galleries round a rotunda with a whale hung in its skylight: a dinosaur to crouch under, a pyramid to crawl through, a maze of paintings, a rocket and a capsule with a hatch, an armour hall, and a vault behind the library's wall |
| **Pinecrest Park** | A playground of towers and play tubes, a picnic shelter, the toilets with a door on every stall, a tennis court, a pond and the woods all round |

## Controls

| Key | Action |
| --- | --- |
| **WASD** / mouse | Move and look |
| **Shift** | Sprint |
| **Ctrl** | Crouch |
| **Alt** | Walk quietly |
| **Space** | Jump |
| **E** | Open or shut a door; kick, push, spin or press the toy you are looking at |
| **T** / **F3** | Taunt / pick a taunt (hiders) |
| **V** | Talk (voice) |
| **F5** | First or third person |
| **Tab** | Scoreboard (hold) |
| **H** | Help: the goal, the rules and every key as you have it bound |
| **Esc** | Menu: settings (every key above can be rebound), help, and leave |

## Getting started
You need [Godot 4.7](https://godotengine.org/download). The game is built from many Dot addons, each in its own repository, so the easiest way to get everything is [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap). It clones every project and links the addons into each one:

```bash
git clone https://github.com/modcommunity/dot-bootstrap.git
cd dot-bootstrap
./bootstrap.sh
cd projects/game-hide-n-seek
./game.sh
```

On Windows, run `bootstrap.ps1` instead and open the project in Godot.

The maps come from the hide-n-seek-maps checkout, which bootstrap links into `maps/` for you. On a deployed server they come from the server instead: the game ships only its built-in practice map, and the server owner picks the maps pack (`gamemann/hide-n-seek-maps`, or their own) in dot-server-deploy's `cfg/content.yml`.

`game.sh` does everything else:

| Command | What it does |
| --- | --- |
| `./game.sh` | Play offline against bots (they hide when you seek, and seek when you hide) |
| `./game.sh online` | Start a local server and the browser client, and print the link to open |
| `./game.sh online down` | Stop them |
| `./game.sh server` | Start a local dedicated server only |
| `./game.sh test` | Check every script and run every test suite |
| `./game.sh shot` | Save a screenshot to `screenshots/`. `tools/shot.sh` lists the views |
| `./game.sh help` | All of the options |

`online` and `server` use [dot-server-deploy](https://github.com/modcommunity/dot-server-deploy), which bootstrap clones next to this one. Run its `./setup.sh` once first.

## Running a server
Settings are cvars. Set them in the server's config, on the command line, or live from the console. Most of them take effect from the next round.

```
hs_hide_seconds 40             // how long the hiders have to hide (a map may ask for less)
hs_round_seconds 240           // how long the seekers have to catch them (a map may ask for less)
hs_timeout_winner 1            // who wins when the clock runs out: 0 nobody, 1 hiders, 2 seekers
hs_catch_mode 0                // how a hider is caught: 0 a touch, 1 being watched, 2 either
hs_tag_range 1.2               // metres between two bodies that count as a touch
hs_sight_seconds 2             // seconds in a seeker's view that catch a hider (catch mode 1 or 2)
hs_sight_range 25              // how far a seeker can see a hider from (catch mode 1 or 2)
hs_sight_fov 70                // how wide a seeker's view is, in degrees (catch mode 1 or 2)
hs_caught_seek 1               // 1 = a caught hider becomes a seeker, 0 = they are out
hs_caught_freeze 3             // seconds a newly caught hider is frozen before they seek
hs_caught_from 0               // where a caught hider starts seeking: 0 where caught, 1 the seekers' start
hs_players_per_seeker 8        // one seeker at the start for every this many players
hs_min_seekers 1               // never fewer than this many at the start
hs_max_seekers 3               // never more than this many at the start
hs_seeker_pick 3               // 0 random, 1 an equal share, 2 the sides swap, 3 the first caught
hs_side_choice 1               // 1 = !seek and !hide count in the draw
hs_doors 1                     // 1 = E opens and shuts doors, 0 = every door stays as the map has it
hs_auto_taunt_seconds 60       // a hider standing still this long is taunted for (0 never)
hs_auto_taunt_radius 1.5       // metres a hider has to move for it to count as moving
hs_taunt_points 2              // points for a taunt a hider chose
hs_forced_taunt_points 0       // points for one the game forced
hs_beacon_hiders_left 1        // beacon every hider once this few are left (0 never)
hs_beacon_seconds_left 0       // beacon every hider with this many seconds left (0 never)
hs_beacon_every 10             // seconds between the beacon showing them (0 = the whole time)
hs_beacon_reveal 2             // seconds it shows them each time
hs_rounds_per_map 4            // rounds on a map before the next one
hs_spectate_camera 0           // deprecated, sets mp_forcecamera
mp_forcecamera 0               // who somebody who is out may watch: 0 anybody, 1 their own side, 2 nobody (1 and 2 also switch the free camera off)
mp_freeroam 1                  // 1 lets somebody who is out fly a free camera (G), 0 keeps them on players
mp_freeroam_speed 12           // the free camera's speed in metres a second (Sprint faster, Walk slower)
hs_autobhop 0                  // 1 = hold jump to keep hopping
bot_quota 5                    // players a round is kept at with bots; each person who joins replaces one
bot_quota_mode fill            // fill (as above), fixed (that many bots), per_player (that many per person) or off
hs_bots 1                      // 0 = no bots
hs_vote_after 20               // seconds into a map's last round before the vote opens
```

The bot cvars are the family's shared ones: how many is dot-server's `DotBotQuota`, how well they see, hear, turn and know a map is [dot-bot](https://github.com/modcommunity/dot-bot)'s `bot_difficulty` (easy, medium, hard, nightmare) and its `bot_*` settings (`bot_settings` lists them). The same names work at the console in solo, and `./game.sh -- --bot_difficulty hard` sets it at launch. `hs_min_players` still works and sets `bot_quota`; it is deprecated.

The map's toys follow `sv_toys` (0 takes them all away), `sv_toys_awake` (how many may simulate at once; 0 is 24, or 8 on a machine without threads) and `sv_toys_push` (how hard walking into one sends it).

Somebody slain by an administrator (or killed by a fall) drops as a ragdoll ([dot-player-char](https://github.com/modcommunity/dot-player-char)); the server picks how each body goes down and everybody sees the same fall. `sv_ragdoll 0` makes it a quick fall with no physics, `sv_ragdoll_style` picks ragdoll, stiff, topple or hide, `sv_ragdoll_time` and `sv_ragdoll_max` say how long and how many, and `sv_ragdoll_reactions` weights the falls (`limp`, `face_plant`, `crumple`, `headshot_launch`, `power_launch`; 0 turns one off).

`--hs-map-ids=<ids>` limits a server to some maps, and every other setting in `game/hs_config.gd` can be given the same way (`--hs-sprint-scale=1.5`, `--hs-taunt-range=80`). The taunts are listed in `taunts/taunts.json`: edit it to add your own sounds. The vote's settings go in `user://cfg/hideseek_vote.json` (`{"enabled": false}` turns it off); dot-vote's README lists them.

Console commands:

| Command | |
| --- | --- |
| `hs_status` | The round, the map, and who has been caught |
| `hs_maps` | The maps the server has, and any it refused (with the reason) |
| `hs_map <id>` | Play this map next |
| `hs_catch <userid>` | Catch a hider now |
| `hs_taunts` | The taunts |
| `hs_reload` | Read the map folder again, for the next map |
| `hs_net` | What the network code is doing |

### Admin commands
These come from [dot-moderation](https://github.com/modcommunity/dot-moderation): `noclip`, `freeze`, `speed`, `gravity`, `god`, `buddha`, `hp`, `slay`, `slap`, `rename`, the teleports, `blind` and `beacon`. `respawn` puts somebody back at their side's spawn. `give` and `strip` are turned off, because nobody here carries anything.

## Writing a map
A map is a JSON file: the building as boxes, the furniture as props, the doors, the lights, and where each side starts. The maps are in [hide-n-seek-maps](https://github.com/zees-games/hide-n-seek-maps), whose `tools/build_maps.py` writes them (a wall with its doors and windows, a flight of stairs, a crawl space or a whole hedge maze is one line there). [`maps/README.md`](maps/README.md) describes the format. The server sends the map to each player when it changes, so players don't need the map files.

## Testing

```bash
./game.sh test                      # every script parses, then every suite runs
./game.sh test headless_climb       # one suite
```

| Suite | What it covers |
| --- | --- |
| `headless_run` | The game itself: the draw, the hide, tagging, being watched, the caught, taunts, falls, the beacon, doors, toys, ragdolls, bots |
| `headless_maps` | Every map: it fits on the wire, every spawn is clear, every prop stands on something, there is enough to hide behind, every door swings clear and every doorway can be walked through, every toy stands clear and stays put |
| `headless_climb` | Somebody stands on a tree's branch, sees under a table, climbs every stairway that matters and crawls through a play tube |
| `headless_bots` | Bots play whole rounds against each other; how long a hider lasts, how spread out they are, who wins |
| `headless_net` | A server and a client in one process, over the network code: the blindfold, a door, a catch, the sight meter, taunts, the toys |
| `dedicated` | A real server: boots, loads the game, runs its commands, a round of bots, the map vote |

[`CLAUDE.md`](CLAUDE.md) has the design decisions and the reasoning behind them.

## Not done yet
- Seekers have nothing in their hands. Special weapons for seekers, found somewhere on a map, are planned.
- Bot hiders pick hidden places apart from each other and keep still, and bot seekers search the likely places first, but neither plans a route to cut somebody off, and bots never shut a door behind them.
- There is no stamina: sprinting is a flat speed boost for everybody.
- The round sounds (not the taunts) are made in code and are placeholders.
- Not yet tried in a browser.

## Credits
The furniture is Kenney's Furniture Kit (ten of the most-used pieces rebuilt as this game's own by `art-src/build_props.py`: bevelled, repainted, with modelled parts, see `assets/props/furniture/CREDITS.md`), the trees, plants and rocks his Nature Kit (the two climbing trees are this game's own, made in that kit's style by `tools/climb_trees.py`, CC0 like it), the players are the family's people from Quaternius' [Zombie Apocalypse Kit](https://quaternius.com/packs/zombieapocalypsekit.html) (CC0 1.0, credited in dot-player-char), chosen by the blocky kit's skins, and the taunts come from his Voiceover Pack and Music Jingles ([kenney.nl](https://kenney.nl), CC0). The Nature Kit's colours are toned down when the game loads them. Floors, walls and roofs are his Prototype Textures under a pastel; the remaining surfaces (glass, boards, lockers, lines) are drawn in code. Each kit's licence is next to its files. Footsteps are Kenney's Impact Sounds and the ambience beds are generated by dot-audio, both CC0 and shipped in dot-audio (`addons/dot_audio/stock/CREDITS.md`). The toys are [dot-props](https://github.com/modcommunity/dot-props)' (drawn in code; their sounds are Kenney's CC0 Impact, Interface, Foley and Digital Audio sounds plus a horn made for it, listed in `addons/dot_props/toys/sounds/CREDITS.md`), and the death sounds are dot-player-char's (Kenney, CC0).

## License
MIT. See [LICENSE](LICENSE). The Kenney art is CC0, which is public domain.

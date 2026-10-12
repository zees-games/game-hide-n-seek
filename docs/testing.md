# Testing

`./game.sh test` parses every script and runs all five suites; `python3 ../hide-n-seek-maps/tools/build_maps.py --check` confirms the maps are what the builder writes.

| Suite | What it covers |
| --- | --- |
| `examples/headless_run` | the simulation: catching by touch and sight (both wall tests armed), conversion and the hold, the draw, falls, taunts, beacons, doors as walls and the sweep |
| `examples/headless_maps` | every map: validated, built, every door swung, every doorway walked |
| `examples/headless_climb` | a garden first (no maps needed): somebody walks in under a tree's leaves to its trunk, jumps onto its low branch and crouch-jumps onto the one 1.5 m up and stands there, and a line under a table is clear while one through its top is not. Then somebody at the foot of every stairway that matters, holding forward, and a play tube standing and crouched; its coordinates are the maps repository's, so a map moved there is a climb that fails here. `-- --props` runs the garden alone; `HS_CLIMB_SEARCH=<prop id>` tries every approach at a prop and prints the ones that end up on it, which is how the garden's approaches were found |
| `examples/headless_net` | over a loopback: the blindfold on the wire (a seeker's copy of a hider does not move during the hide), the sight meter owner-only, the caught hold predicted, doors posed before prediction |
| `examples/dedicated` | a real server: stand-in seekers catch everybody inside a round |

## Rules

- **Without `maps/` linked** (CI clones this repository alone), `headless_maps` checks the practice house only and `headless_climb` has nothing to climb, and both say so.
- **Check before stepping across a round boundary**: with intermission 0, a check four ticks after the last catch saw the next round.
- **Bound a server round in server ticks**, with the wall clock only as a cap for a server that stopped: a 75 s wall-clock bound failed one run in three with a build running alongside.
- Every behaviour that crosses the wire is armed: the hold as a server-only timer, the door posing taken out, the sweep taken out.

## Renders

`tools/shot.sh --view=overview|room|hider|seeker|blind|caught`, with `--hs-map-ids=<id>`, `--at=x,y,z --look=x,y,z`, `--third`, `--board`, `--doors=open`. Shirt colours, HUD overlaps, wording, fog colour, floor striping and the secret panel's outline were all found by rendering.

## The deployment

dot-server-deploy's `examples/hideseek_client` boots the delivered pack, joins with a real client over a real socket, reads the maps, prop catalogue and taunts from their mounts, and checks the client builds the server's map with every prop.

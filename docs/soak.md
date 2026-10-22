# Bot soak

`./game.sh soak [map] [minutes]` runs `tools/soak.tscn`: seven of the game's stand-ins (`game/hs_bots.gd`) play rounds back to back on one map through dot-bot's `DotBotSoak`, with dot-spawn's `DotSpawnWatch` for stuck and fell-out verdicts. The report is `.godot/test-logs/soak-<map>.json` and one `SOAK {...}` line. A catch is the game working, so the kill check is off; off-nav and unreachable are off too. A mover with no goal is not stuck: everyone between rounds, a seeker through the hide, and a hider that has settled in its spot (`mode` hidden). The world is ticked at 32 Hz with a physics frame after each tick, as `headless_bots` does.

First run, 2026-10-22, 5 simulated minutes per map, 7 bots, all 14 maps: 10 pass, 4 fail, all `stuck` (limit 10 s). Tick cost is not the problem: p95 is 1.5 to 3.2 ms, worst single tick 47 to 750 ms (the map load and the annotation), object growth 0.2% at most, no bot fell out anywhere.

- Fail: hs_apartment (a bot stuck 280 s, the whole run after the hide), hs_frontyard (19.7 s), hs_castle (13.1 s), hs_ship (10.9 s).
- Close to the limit but passing: hs_restaurant 7.1 s, hs_school 6.6 s, hs_warehouse 6.6 s.
- Pass: hs_apartments, hs_camp, hs_mall, hs_manor, hs_museum, hs_park, hs_village, and the three above.
- hs_mall prints "It's not expect to not find the most reachable polygons" from the navigation server throughout the run (23 times); the run still passes.

The findings are nightly items (`hns-soak-stuck-bots`, `hns-soak-mall-nav-errors`); the bots were not changed.

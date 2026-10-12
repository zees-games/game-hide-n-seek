# History

Kept because each could come back.

- **A seeker reported in a round that had already redrawn**: the check ran after intermission 0 started the next round. Checks are made before the step now.
- **Teal shirts**: the side tint over the atlas. Painted outright now. Found by rendering.
- **"You was caught"**: the local player is "You" offline. Found by rendering.
- **Two HUD lines on top of each other** for a hider (the old disguise line under the taunt meter). Found by rendering.
- **A warehouse washed orange** by fog over a sunset sky, as prop hunt's woods once were. Found by rendering.
- **Two doorways nobody could use**, found by `headless_maps` the moment there were doors: a sofa in the manor's lounge doorway, and every village cottage's fence across its back door. Fixed in hide-n-seek-maps.
- **Every building's floor striped with the grass under it**: both tops at y 0. Found by rendering the doors.
- **A secret door's outline** showed with a plain door's 3 cm gap; 6 mm now.
- **`dedicated` failed one run in three once doors were in**: a wall-clock bound, with stand-ins taking most of the seek to open a garden door. Bounded in server ticks now.
- **dot-combat warned at every boot that shots pass through walls**, because nothing shoots and the trace was left out; it is set anyway. Found by dot-server-deploy's `hideseek_client`.
- **A seeker stood on one spot for a whole round and caught nobody** (`headless_bots`, a park round): the place it was searching was inside a bush, so its eye never had it in view, and `DotBotSearch` never crossed it off and handed it back, nearest, every time. A place the seeker has stood on counts as looked at now.
- **A seeker frozen in mid-air beside an open door** (school door 35, `headless_bots` round 23 at medium): it hopped to get unstuck at the door's open panel and stayed at y 0.6 for the rest of the round, mode air, its fall speed growing to -70 m/s and its position never changing. Not fixed; queued as `hns-door-wedge-1`. A suite round with no catch is the first sign.

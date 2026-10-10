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

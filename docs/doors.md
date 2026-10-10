# Doors

The maps' doors (hundreds across the eleven maps, declared as a wall hole's fifth element, plus a sliding secret panel on most maps) are the only thing in a map that moves, so they are built the way mg-deathrun builds a trap. `game/hs_doors.gd` builds them, poses them, finds them by the use key, and sweeps them.

## A door is a pure function of the tick

**A door's state is `(open, since, flip)`**: where it is going, the tick it set off, and which way it swings. Its pose on any tick follows from those and the document (`HsDoors.fraction`, `panel_transform`).

- **The only thing ever sent is a use**: `DOOR` (door, open, flip, tick), broadcast when it happens and sent to a joiner for every door that has moved this round.
- **A client poses the doors for its own input tick before it predicts its player** (`HsNetBridge.client_tick`), so it is predicted into a shut door exactly where the server stops it. Without the posing, the client's panel sat 1.8 m from the server's.
- Every door goes back to its map state at the top of a round. `hs_doors 0` freezes every door as its map has it.

## The use key is a button in the movement command

`DotFpsCommand.BUTTON_USER_0` (`HsPlayer.USE_BUTTON`), held; the game makes the press from the edge, as mg-deathrun makes its button presses. A reliable request would arrive a round trip after the key. Held players (the blindfold, a new seeker's freeze) cannot use a door.

## A shut door is a wall

**A static body on the world layer, moved through the physics server** (`PhysicsServer3D.body_set_state`).

- On the world layer because the touch rule and the sight rule both ask "is there a wall between", and a shut door has to be one: a touch through a shut door is not a touch.
- Static and teleported, never kinematic: a kinematic body's transform lands a physics step late (mg-wipeout's finding).

## A door never moves into anybody

A door swings away from whoever opens it (unless the map pins it with `away: false`), and **a use is refused while any body stands anywhere the panel will pass** (`HsDoors.sweeps`, seven poses along its path). A static panel posed inside a capsule leaves the controller to push its way out, and a seeker slamming a door on a hider in its frame would be the door deciding a catch. The refusal says somebody is in the way, which tells a seeker somebody is behind it: so does a real door, and it is a fair clue.

## What a map must get right

`headless_maps` swings every door and walks every doorway. Doorways blocked by furniture or a fence are map bugs, fixed in hide-n-seek-maps. A secret panel's outline gap is 6 mm (a plain door's 3 cm gap gave it away). A building's floor must not share its top with the grass under it, or it stripes.

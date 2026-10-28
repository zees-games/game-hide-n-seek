# Nature models

Twelve of the models here are this game's own, built from Kenney's Nature Kit by `art-src/build_props.py` (Blender in background mode: `blender -b -P art-src/build_props.py -- <name>`): `tree_default`, `tree_oak`, `tree_tall`, `tree_cone`, `tree_pineTallA`, `tree_pineRoundA`, `tree_detailed`, `tree_fat`, `tree_small`, `plant_bushLarge`, `plant_bushDetailed`, `crop_melon`. The rest of the folder is the kit as Kenney made it.

- **Base**: [Kenney's Nature Kit](https://kenney.nl/assets/nature-kit) by Kenney (CC0 1.0; licence in `LICENSE-kenney-nature-kit.txt`). The unmodified originals are in `art-src/base/nature/`.
- **Changes**: our own bark, a three-tone foliage by height with noise (greens for leaf trees, blue-greens for pines), root flares, a knot and a moss patch on each trunk, blossom, apples, oranges or pine cones scattered on the canopy, berries on the bushes, a soil disc under them, halved melons on the patch.
- **Kept**: node names and tree, origin and bounding box (refitted to the stock box), so `props/catalogue.json` is unchanged. `props/pieces.json` is not re-measured: the added parts are decoration.

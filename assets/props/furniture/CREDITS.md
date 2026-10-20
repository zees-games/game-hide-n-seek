# Furniture models

Ten of the furniture models are this game's own, built from Kenney's Furniture Kit by `art-src/build_props.py` (Blender in background mode: `blender -b -P art-src/build_props.py`). The rest of the folder is the kit as Kenney made it.

- **Base**: [Kenney's Furniture Kit](https://kenney.nl/assets/furniture-kit) (CC0 1.0; licence in `LICENSE-kenney-furniture-kit.txt`). The unmodified originals are kept in `art-src/base/`.
- **Rebuilt** (the ten this game's maps use most): `cardboardBoxClosed`, `cardboardBoxOpen`, `kitchenBar`, `desk`, `chairDesk`, `bench`, `chair`, `table`, `trashcan`, `bookcaseOpen`.
- **Changes**: every sharp edge is bevelled; the kit's pale pine, coral and silver are replaced by honey oak, sage and teal paint, mustard and copper. Modelled onto them: taped, labelled cartons (the open one with packing paper), a tiled top and trim on the kitchen island, a desk pad, notebook and pencil pot on the desk, a teal seat and back pad on the desk chair, a mustard cushion on the bench, painted seat and back pads on the chair, a runner, vase and plate on the table, hoops and a label on the bin, shelved books on the bookcase.
- **Kept**: node names and tree, origin, and the bounding box (each model is refitted to the stock box, so `props/catalogue.json` and the collision in `props/pieces.json` are unchanged).
- Contact sheet (rebuilt on top, stock below; Cycles) is in `reports/models/2026-10-20/props/`. The cartons render black in Blender's importer for both stock and rebuilt; in the game they are kraft board.

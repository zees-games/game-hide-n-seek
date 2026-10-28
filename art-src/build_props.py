"""Rebuilds forty-eight of the furniture and nature models under assets/props/ for game-hide-n-seek.

Pass 4: seven furniture models and seven nature ones (NATURE4: stones, logs, a pumpkin), sheets in reports/models/2026-10-28/props4.
Pass 3 (NATURE below): twelve trees, bushes and a melon patch from Kenney's Nature Kit (CC0, bases in art-src/base/nature/), written to
assets/props/nature/: their own bark and a three-tone foliage by height, knots, moss, fruit, blossom, cones and berries.

Run:  blender -b -P art-src/build_props.py -- [name ...] [--out DIR]
Bases: art-src/base/<name>.glb, the stock Kenney Furniture Kit (CC0, see assets/props/furniture/LICENSE-kenney-furniture-kit.txt).
The ten are the ones this game's maps use most (cardboard boxes, desk, kitchen island, desk chair, bench, chair, table,
bin, open bookcase). Every sharp edge is bevelled and the kit's pale pine and coral are replaced by this game's own
palette: honey oak, sage and teal paint, mustard and copper. Each also gets parts of its own: tape, a label and packing
paper on the boxes, a tiled counter and a trim line on the kitchen island, a desk pad, pencil pot and notebook on the
desk, a teal seat pad on the desk chair, a cushion on the bench, a seat and back pad on the chair, a runner, vase and
fruit plate on the table, hoops on the bin, books on the bookcase.
Node names, the node tree, each model's origin and its bounding box are kept: the whole model is refitted to the
base's box, because pieces.json (the collision) and catalogue.json (the size) are measured from it.
Blender axes: the importer turns glTF (x, y, z) into (x, -z, y), so a model's front (glTF +Z) is Blender -Y.
"""
import bpy, bmesh, sys, os, math, random
from mathutils import Vector, Matrix

here = os.path.dirname(os.path.abspath(__file__))
argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
outdir = os.path.join(here, "..", "assets", "props", "furniture")
if "--out" in argv:
    i = argv.index("--out")
    outdir = argv[i + 1]
    del argv[i:i + 2]
names = argv
NATURE = ["tree_default", "tree_oak", "tree_tall", "tree_cone", "tree_pineTallA", "tree_pineRoundA", "tree_detailed", "tree_fat",
          "tree_small", "plant_bushLarge", "plant_bushDetailed", "crop_melon"]
NATURE4 = ["rock_largeA", "rock_tallA", "rock_smallA", "log", "log_large", "log_stack", "crop_pumpkin"]
naturedir = os.path.join(here, "..", "assets", "props", "nature")

PAL = {}

def mat(name, rgb, metal=0.0, rough=0.6):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = next(n for n in m.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    b.inputs["Base Color"].default_value = (*rgb, 1)
    b.inputs["Metallic"].default_value = metal
    b.inputs["Roughness"].default_value = rough
    return m

def palette():
    PAL.clear()
    PAL["oak"] = mat("oak", (0.42, 0.24, 0.1), 0.0, 0.55)
    PAL["oakDark"] = mat("oakDark", (0.27, 0.14, 0.055), 0.0, 0.6)
    PAL["sage"] = mat("sage", (0.2, 0.34, 0.2), 0.0, 0.6)
    PAL["teal"] = mat("teal", (0.04, 0.26, 0.28), 0.0, 0.7)
    PAL["tealDark"] = mat("tealDark", (0.02, 0.14, 0.16), 0.0, 0.7)
    PAL["mustard"] = mat("mustard", (0.62, 0.38, 0.04), 0.0, 0.6)
    PAL["copper"] = mat("copper", (0.55, 0.22, 0.1), 0.7, 0.35)
    PAL["steel"] = mat("steel", (0.3, 0.33, 0.36), 0.5, 0.4)
    PAL["cream"] = mat("cream", (0.78, 0.7, 0.52), 0.0, 0.8)
    PAL["paper"] = PAL["cream"]
    PAL["tileWhite"] = mat("tileWhite", (0.72, 0.74, 0.72), 0.0, 0.25)
    PAL["ink"] = mat("ink", (0.02, 0.025, 0.04), 0.0, 0.7)
    PAL["kraft"] = mat("kraft", (0.45, 0.28, 0.12), 0.0, 0.8)
    PAL["kraftDark"] = mat("kraftDark", (0.34, 0.2, 0.08), 0.0, 0.8)
    PAL["tape"] = mat("tape", (0.7, 0.55, 0.28), 0.0, 0.3)
    PAL["red"] = mat("red", (0.55, 0.06, 0.04), 0.0, 0.7)
    PAL["plant"] = mat("plant", (0.07, 0.3, 0.09), 0.0, 0.6)
    PAL["linen"] = mat("linen", (0.55, 0.5, 0.4), 0.0, 0.9)
    PAL["terracotta"] = mat("terracotta", (0.46, 0.17, 0.08), 0.0, 0.8)
    PAL["soil"] = mat("soil", (0.025, 0.015, 0.01), 0.0, 1.0)
    PAL["brass"] = PAL["copper"]
    PAL["bark"] = mat("bark", (0.24, 0.15, 0.08), 0.0, 0.9)
    PAL["barkDark"] = mat("barkDark", (0.15, 0.1, 0.07), 0.0, 0.9)
    PAL["moss"] = mat("moss", (0.16, 0.3, 0.1), 0.0, 0.95)
    PAL["leafDark"] = mat("leafDark", (0.06, 0.2, 0.08), 0.0, 0.8)
    PAL["leafMid"] = mat("leafMid", (0.12, 0.31, 0.09), 0.0, 0.8)
    PAL["leafLight"] = mat("leafLight", (0.26, 0.42, 0.1), 0.0, 0.8)
    PAL["pineDark"] = mat("pineDark", (0.03, 0.15, 0.1), 0.0, 0.8)
    PAL["pineMid"] = mat("pineMid", (0.05, 0.23, 0.14), 0.0, 0.8)
    PAL["pineLight"] = mat("pineLight", (0.14, 0.33, 0.16), 0.0, 0.8)
    PAL["grassDark"] = mat("grassDark", (0.1, 0.24, 0.07), 0.0, 0.85)
    PAL["grassLight"] = mat("grassLight", (0.22, 0.38, 0.09), 0.0, 0.85)
    PAL["apple"] = mat("apple", (0.6, 0.05, 0.04), 0.0, 0.4)
    PAL["orange"] = mat("orange", (0.75, 0.32, 0.04), 0.0, 0.4)
    PAL["blossom"] = mat("blossom", (0.8, 0.52, 0.55), 0.0, 0.6)
    PAL["berry"] = mat("berry", (0.12, 0.1, 0.4), 0.0, 0.4)
    PAL["pinecone"] = mat("pinecone", (0.3, 0.17, 0.07), 0.0, 0.8)
    PAL["melonRind"] = mat("melonRind", (0.2, 0.42, 0.12), 0.0, 0.6)
    PAL["stoneDark"] = mat("stoneDark", (0.17, 0.17, 0.18), 0.0, 0.9)
    PAL["stoneMid"] = mat("stoneMid", (0.3, 0.29, 0.28), 0.0, 0.9)
    PAL["stoneLight"] = mat("stoneLight", (0.45, 0.43, 0.4), 0.0, 0.9)
    PAL["lichen"] = mat("lichen", (0.5, 0.52, 0.28), 0.0, 0.95)
    PAL["ring"] = mat("ring", (0.5, 0.34, 0.17), 0.0, 0.8)
    PAL["ringDark"] = mat("ringDark", (0.34, 0.2, 0.09), 0.0, 0.8)
    PAL["pumpkin"] = mat("pumpkin", (0.72, 0.28, 0.03), 0.0, 0.55)
    PAL["pumpkinDark"] = mat("pumpkinDark", (0.5, 0.17, 0.02), 0.0, 0.6)
    PAL["stem"] = mat("stem", (0.2, 0.26, 0.07), 0.0, 0.8)
    PAL["capRed"] = mat("capRed", (0.62, 0.08, 0.06), 0.0, 0.5)
    PAL["melonFlesh"] = mat("melonFlesh", (0.6, 0.12, 0.1), 0.0, 0.5)
    # books() draws from these names.
    PAL["leather"] = PAL["teal"]
    PAL["velvet"] = PAL["tealDark"]
    PAL["walnutDark"] = PAL["oakDark"]
    PAL["blotter"] = PAL["sage"]
    PAL["gunmetal"] = PAL["steel"]

# Kit material name -> ours.
SWAP = {"wood": "oak", "woodDark": "oakDark", "metal": "copper", "metalMedium": "steel",
        "metalDark": "steel", "carpet": "teal", "carpetDarker": "tealDark", "carpetWhite": "linen", "plant": "plant", "_defaultMat": "oak"}

def meshes():
    return [o for o in bpy.data.objects if o.type == "MESH"]

def world_box(objs):
    pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
    return Vector(min(p[i] for p in pts) for i in range(3)), Vector(max(p[i] for p in pts) for i in range(3))

OVERRIDES = {"cardboardBoxClosed": {"wood": "kraft", "woodDark": "kraftDark"}, "cardboardBoxOpen": {"wood": "kraft", "woodDark": "kraftDark"},
             "trashcan": {"metal": "tealDark", "metalDark": "tealDark"}, "kitchenBar": {"wood": "sage", "woodDark": "oakDark"},
             "chair": {"wood": "oak"}, "bench": {"wood": "oakDark"}, "table": {"wood": "oak"},
             "bedSingle": {"carpetWhite": "linen", "carpet": "teal", "wood": "oakDark"},
             "pottedPlant": {"wood": "terracotta", "woodDark": "oakDark"},
             "loungeSofa": {"carpet": "mustard", "wood": "oakDark"}, "kitchenCabinet": {"wood": "sage", "woodDark": "oakDark", "metal": "copper"},
             "bookcaseClosedDoors": {"wood": "oakDark"}, "bookcaseClosedWide": {"wood": "sage"}, "bookcaseClosed": {"wood": "oakDark"},
             "cabinetBedDrawer": {"wood": "sage", "_defaultMat": "oak"}, "sideTableDrawers": {"wood": "oak", "_defaultMat": "sage"},
             "tableRound": {"wood": "oakDark"}, "coatRackStanding": {"wood": "oakDark"},
             "rugRectangle": {"carpet": "mustard", "carpetDarker": "red"},
             "bedDouble": {"carpet": "sage", "carpetWhite": "linen", "wood": "oakDark"},
             "chairRounded": {"wood": "sage"}, "chairCushion": {"wood": "oakDark", "carpet": "mustard"},
             "cabinetTelevision": {"wood": "oakDark"}, "loungeChairRelax": {"carpet": "teal", "wood": "oak", "metal": "copper"},
             "benchCushionLow": {"wood": "oakDark", "carpet": "sage"},
             "kitchenStove": {"metal": "steel", "wood": "oakDark", "metalDark": "ink", "carpetWhite": "tileWhite", "glass": "ink"}}

def reskin(o, overrides=None):
    overrides = overrides or {}
    for i, s in enumerate(o.material_slots):
        k = s.material.name.split(".")[0]
        o.material_slots[i].material = PAL[overrides.get(k, SWAP.get(k, "oak"))]

def bevel(o, width=0.004):
    sc = sum(o.matrix_world.to_scale()) / 3
    bm = bmesh.new()
    bm.from_mesh(o.data)
    edges = [e for e in bm.edges if len(e.link_faces) == 2 and e.calc_face_angle(0) > math.radians(35)]
    bmesh.ops.bevel(bm, geom=edges, offset=width / sc, segments=2, affect="EDGES")
    bm.to_mesh(o.data)
    bm.free()
    o.data.update()

def slot(o, key):
    m = PAL[key]
    for i, s in enumerate(o.material_slots):
        if s.material == m:
            return i
    o.data.materials.append(m)
    return len(o.material_slots) - 1

def add_box(host, lo, hi, key, rot=0.0):
    """A box from world-space corner lo to hi (rotated rot rad about Z through its centre), joined into host."""
    lo, hi = Vector(lo), Vector(hi)
    c = (lo + hi) / 2
    bpy.ops.mesh.primitive_cube_add(size=1, location=c, rotation=(0, 0, rot))
    p = bpy.context.active_object
    p.scale = (hi - lo)
    bpy.ops.object.transform_apply(scale=True)
    join(host, p, key)

def add_cyl(host, c, r, h, key, axis="Z", verts=16, r2=None):
    rot = {"Z": (0, 0, 0), "X": (0, math.pi / 2, 0), "Y": (math.pi / 2, 0, 0)}[axis]
    bpy.ops.mesh.primitive_cone_add(vertices=verts, radius1=r, radius2=r if r2 is None else r2, depth=h, location=c, rotation=rot)
    join(host, bpy.context.active_object, key)

def add_sphere(host, c, r, key, sq=1.0):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=12, ring_count=6, radius=r, location=c)
    p = bpy.context.active_object
    p.scale.z = sq
    bpy.ops.object.transform_apply(scale=True)
    join(host, p, key)

def add_torus(host, c, R, r, key):
    bpy.ops.mesh.primitive_torus_add(major_radius=R, minor_radius=r, major_segments=20, minor_segments=6, location=c)
    join(host, bpy.context.active_object, key)

def join(host, p, key):
    for f in p.data.polygons:
        f.use_smooth = False
    p.data.materials.clear()
    p.data.materials.append(PAL[key])
    # Match the host's slot for this material so joining does not add a duplicate.
    idx = slot(host, key)
    bpy.ops.object.select_all(action="DESELECT")
    p.select_set(True)
    host.select_set(True)
    bpy.context.view_layer.objects.active = host
    bpy.ops.object.join()
    # The joined faces carry the slot index of the parts' own single material (0); remap by material.
    remap_new_faces(host)

def remap_new_faces(host):
    # After a join Blender appends the part's material to the host's slots when it is not there yet and points the
    # part's faces at it, so nothing is needed except dropping duplicate slots, which export merges anyway.
    pass

def top_levels(o, min_area=0.002):
    """z levels (world) of upward faces of o with their areas: shelves and seats."""
    bm = bmesh.new()
    bm.from_mesh(o.data)
    out = {}
    for f in bm.faces:
        n = (o.matrix_world.to_3x3() @ f.normal).normalized()
        if n.z > 0.95:
            z = round((o.matrix_world @ f.calc_center_median()).z, 3)
            out[z] = out.get(z, 0) + f.calc_area()
    bm.free()
    return sorted((z, a) for z, a in out.items() if a > min_area)

def books(host, lo, hi, z, gap, seed):
    rnd = random.Random(seed)
    cols = ["red", "leather", "velvet", "kraft", "paper", "walnutDark", "blotter", "gunmetal"]
    x = lo.x
    while x < hi.x - 0.02:
        w = rnd.uniform(0.012, 0.026)
        h = min(gap * rnd.uniform(0.62, 0.92), gap - 0.012)
        d = (hi.y - lo.y) * rnd.uniform(0.7, 0.9)
        if rnd.random() < 0.12 and x + 0.07 < hi.x:
            add_box(host, (x, lo.y, z), (x + 0.07, lo.y + d, z + 0.014), cols[rnd.randrange(len(cols))])
            x += 0.075
            continue
        add_box(host, (x, lo.y, z), (x + w, lo.y + d, z + h), cols[rnd.randrange(len(cols))])
        x += w + 0.001
        if rnd.random() < 0.1:
            x += rnd.uniform(0.03, 0.06)

def knob(host, c):
    add_sphere(host, c, 0.011, "brass", 0.8)

# ---- per-model parts; each gets the model's meshes by name ------------------------------------------------

def do_cardboardBoxClosed(by):
    o = by["cardboardBoxClosed(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    add_box(o, (c.x - 0.02, lo.y - 0.001, hi.z - 0.002), (c.x + 0.02, hi.y + 0.001, hi.z + 0.002), "tape")
    add_box(o, (c.x - 0.02, lo.y - 0.001, lo.z + 0.02), (c.x + 0.02, lo.y + 0.001, hi.z), "tape")
    add_box(o, (hi.x - 0.1, lo.y - 0.002, hi.z * 0.5), (hi.x - 0.03, lo.y, hi.z * 0.8), "cream")
    add_box(o, (hi.x - 0.09, lo.y - 0.003, hi.z * 0.68), (hi.x - 0.04, lo.y, hi.z * 0.72), "ink")
    add_box(o, (lo.x + 0.03, lo.y - 0.002, lo.z + 0.03), (lo.x + 0.07, lo.y, lo.z + 0.07), "mustard")

def do_cardboardBoxOpen(by):
    o = by["cardboardBoxOpen(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    add_box(o, (c.x - 0.02, lo.y - 0.001, lo.z + 0.03), (c.x + 0.02, lo.y + 0.001, hi.z - 0.05), "tape")
    add_box(o, (lo.x + 0.04, lo.y - 0.002, lo.z + 0.08), (lo.x + 0.11, lo.y, lo.z + 0.15), "cream")
    add_box(o, (lo.x + 0.05, lo.y - 0.003, lo.z + 0.115), (lo.x + 0.1, lo.y, lo.z + 0.12), "ink")
    # Packing paper crumpled in the mouth, kept below the rim so the box does not grow.
    for k, (dx, dy) in enumerate(((-0.05, 0.0), (0.03, 0.02), (0.07, -0.02))):
        add_sphere(o, (c.x + dx, c.y + dy, hi.z - 0.075), 0.05, "cream", 0.8)

def do_kitchenBar(by):
    o = by["kitchenBar(Clone)"]
    lo, hi = world_box([o])
    add_box(o, (lo.x - 0.002, lo.y - 0.003, hi.z - 0.014), (hi.x + 0.002, hi.y + 0.002, hi.z + 0.003), "tileWhite")
    n = 8
    w = (hi.x - lo.x) / n
    for i in range(n):
        add_box(o, (lo.x + i * w + 0.003, lo.y - 0.004, hi.z - 0.012), (lo.x + (i + 1) * w - 0.003, lo.y + 0.01, hi.z + 0.004),
                "tileWhite" if i % 2 else "teal")
    for x in (lo.x + 0.07, hi.x - 0.07):
        add_cyl(o, (x, lo.y, lo.z + (hi.z - lo.z) * 0.55), 0.011, 0.014, "copper", axis="Y")
    add_box(o, (lo.x + 0.03, lo.y - 0.003, lo.z + 0.03), (hi.x - 0.03, lo.y, lo.z + 0.036), "sage")

def do_desk(by):
    o, drawer = by["desk(Clone)"], by["drawer"]
    lo, hi = world_box([o])
    add_box(o, (lo.x + 0.1, lo.y + 0.06, hi.z - 0.002), (lo.x + 0.4, hi.y - 0.06, hi.z + 0.004), "sage")
    add_box(o, (lo.x + 0.13, lo.y + 0.08, hi.z + 0.004), (lo.x + 0.27, lo.y + 0.17, hi.z + 0.012), "cream")
    add_cyl(o, (hi.x - 0.1, hi.y - 0.09, hi.z + 0.006), 0.026, 0.012, "mustard", verts=14)
    for k in range(3):
        add_cyl(o, (hi.x - 0.1 + (k - 1) * 0.012, hi.y - 0.09, hi.z + 0.014), 0.003, 0.012, ("red", "teal", "cream")[k], verts=5)
    dlo, dhi = world_box([drawer])
    c = (dlo + dhi) / 2
    add_cyl(drawer, (c.x, dlo.y, c.z), 0.01, 0.012, "cream", axis="Y")

def do_chairDesk(by):
    base, chair = by["chairDesk(Clone)"], by["chair"]
    lo, hi = world_box([chair])
    lv = [z for z, a in top_levels(chair) if 0.15 < z < hi.z - 0.05]
    seat = min(lv) if lv else lo.z + 0.2
    add_box(chair, (lo.x + 0.03, lo.y + 0.03, seat), (hi.x - 0.03, hi.y - 0.05, seat + 0.022), "teal")
    for dz in (0.0, 0.05):
        add_box(chair, (lo.x + 0.04, hi.y - 0.012, hi.z - 0.12 + dz), (hi.x - 0.04, hi.y, hi.z - 0.09 + dz), "tealDark")
    add_sphere(chair, ((lo.x + hi.x) / 2, hi.y, hi.z - 0.02), 0.012, "copper", 0.6)

def do_bench(by):
    o = by["bench(Clone)"]
    lo, hi = world_box([o])
    add_box(o, (lo.x + 0.015, lo.y + 0.015, hi.z - 0.002), (hi.x - 0.015, hi.y - 0.015, hi.z + 0.02), "mustard")
    add_box(o, (lo.x + 0.012, lo.y + 0.012, hi.z + 0.016), (hi.x - 0.012, lo.y + 0.018, hi.z + 0.022), "cream")
    for x in (lo.x + 0.06, hi.x - 0.06):
        add_sphere(o, (x, (lo.y + hi.y) / 2, hi.z + 0.021), 0.007, "copper", 0.6)

def do_chair(by):
    o = by["chair(Clone)"]
    lo, hi = world_box([o])
    lv = [z for z, a in top_levels(o) if 0.1 < z < hi.z - 0.05]
    seat = max(lv) if lv else 0.23
    add_box(o, (lo.x + 0.018, lo.y + 0.018, seat), (hi.x - 0.018, hi.y - 0.045, seat + 0.014), "sage")
    add_box(o, (lo.x + 0.02, hi.y - 0.012, hi.z - 0.11), (hi.x - 0.02, hi.y, hi.z - 0.06), "sage")
    for x in (lo.x + 0.012, hi.x - 0.012):
        add_sphere(o, (x, hi.y - 0.015, hi.z), 0.012, "copper", 0.8)

def do_table(by):
    o = by["table(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    add_box(o, (lo.x + 0.1, c.y - 0.07, hi.z - 0.002), (hi.x - 0.1, c.y + 0.07, hi.z + 0.004), "teal")
    add_box(o, (lo.x + 0.1, c.y - 0.07, hi.z + 0.004), (hi.x - 0.1, c.y - 0.066, hi.z + 0.006), "cream")
    add_cyl(o, (c.x - 0.15, c.y, hi.z + 0.008), 0.026, 0.016, "cream", r2=0.02)
    add_sphere(o, (c.x - 0.15, c.y, hi.z + 0.016), 0.01, "red", 0.8)
    add_cyl(o, (c.x + 0.12, c.y, hi.z + 0.004), 0.045, 0.008, "mustard", verts=18)

def do_trashcan(by):
    o = by["trashcan(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    r = min(hi.x - lo.x, hi.y - lo.y) / 2 - 0.006
    add_torus(o, (c.x, c.y, hi.z - 0.006), r, 0.007, "copper")
    for f in (0.25, 0.5, 0.75):
        add_torus(o, (c.x, c.y, lo.z + (hi.z - lo.z) * f), r * 0.97, 0.004, "tealDark")
    add_box(o, (c.x - 0.03, c.y - r - 0.003, hi.z * 0.5), (c.x + 0.03, c.y - r + 0.002, hi.z * 0.5 + 0.045), "cream")
    add_cyl(o, (c.x, c.y, lo.z + 0.006), r * 0.9, 0.012, "tealDark")

def do_bookcaseOpen(by):
    o = by["bookcaseOpen(Clone)"]
    lo, hi = world_box([o])
    lv = sorted(z for z, a in top_levels(o) if z < hi.z - 0.05)
    for i, z in enumerate(lv):
        nxt = next((n for n in lv if n > z + 0.05), None)
        under = (nxt - 0.02) if nxt else hi.z - 0.02
        gap = under - z
        if gap > 0.06:
            books(o, Vector((lo.x + 0.022, lo.y + 0.03, 0)), Vector((hi.x - 0.022, hi.y - 0.02, 0)), z, gap, 31 + i)
    # A painted back panel strip and brass-free copper cap along the top edge.
    add_box(o, (lo.x, lo.y, hi.z - 0.008), (hi.x, hi.y, hi.z + 0.004), "sage")

def knob_in(host, c):
    """A knob half sunk in the face, so it does not grow the box the collision is measured from."""
    add_sphere(host, (c.x, c.y + 0.009, c.z), 0.011, "brass", 0.8)

def case_books(o, seed):
    lo, hi = world_box([o])
    lv = sorted(z for z, a in top_levels(o) if z < hi.z - 0.05)
    for i, z in enumerate(lv):
        nxt = next((n for n in lv if n > z + 0.05), None)
        gap = ((nxt - 0.02) if nxt else hi.z - 0.02) - z
        if gap > 0.06:
            books(o, Vector((lo.x + 0.03, lo.y + 0.04, 0)), Vector((hi.x - 0.03, hi.y - 0.03, 0)), z, gap, seed + i)
    return lo, hi

def plinth_and_cap(o, lo, hi, cap="copper"):
    add_box(o, (lo.x, lo.y, lo.z), (hi.x, hi.y, lo.z + 0.03), "oakDark")
    add_box(o, (lo.x + 0.002, lo.y - 0.004, hi.z - 0.018), (hi.x - 0.002, hi.y - 0.002, hi.z - 0.002), cap)

def do_cabinetBedDrawer(by):
    o = by["cabinetBedDrawer(Clone)"]
    lo, hi = world_box([o])
    for k in ("door", "drawer"):
        dlo, dhi = world_box([by[k]])
        knob_in(by[k], Vector(((dlo.x + dhi.x) / 2, dlo.y, (dlo.z + dhi.z) / 2)))
    add_box(o, (lo.x + 0.01, lo.y + 0.01, lo.z), (hi.x - 0.01, hi.y - 0.01, lo.z + 0.02), "oakDark")
    add_box(o, (lo.x + 0.03, lo.y + 0.05, hi.z - 0.002), (lo.x + 0.11, lo.y + 0.13, hi.z + 0.004), "teal")
    add_box(o, (lo.x + 0.04, lo.y + 0.06, hi.z + 0.004), (lo.x + 0.10, lo.y + 0.12, hi.z + 0.006), "cream")
    add_cyl(o, (hi.x - 0.06, hi.y - 0.07, hi.z), 0.03, 0.008, "mustard")

def do_sideTableDrawers(by):
    o = by["sideTableDrawers(Clone)"]
    lo, hi = world_box([o])
    for k in ("drawerLeft", "drawerRight"):
        dlo, dhi = world_box([by[k]])
        c = (dlo + dhi) / 2
        knob_in(by[k], Vector((c.x, dlo.y, c.z)))
        add_box(by[k], (dlo.x + 0.012, dlo.y - 0.001, dhi.z - 0.03), (dhi.x - 0.012, dlo.y + 0.001, dhi.z - 0.026), "mustard")
    add_box(o, (lo.x + 0.01, lo.y + 0.01, lo.z), (hi.x - 0.01, hi.y - 0.01, lo.z + 0.02), "oakDark")
    add_box(o, (lo.x + 0.03, lo.y + 0.06, hi.z - 0.002), (lo.x + 0.15, lo.y + 0.16, hi.z + 0.012), "red", rot=0.15)
    add_cyl(o, (hi.x - 0.1, lo.y + 0.12, hi.z + 0.002), 0.045, 0.006, "cream")

def do_bedSingle(by):
    o, cover, pillow = by["bedSingle(Clone)"], by["cover"], by["pillow"]
    lo, hi = world_box([o])
    clo, chi = world_box([cover])
    plo, phi = world_box([pillow])
    add_box(cover, (clo.x - 0.002, clo.y + 0.30, chi.z - 0.004), (chi.x + 0.002, clo.y + 0.32, chi.z + 0.002), "mustard")
    add_box(cover, (clo.x - 0.002, chi.y - 0.09, chi.z - 0.004), (chi.x + 0.002, chi.y - 0.0, chi.z + 0.003), "linen")
    for x in (lo.x + 0.012, hi.x - 0.012):
        add_sphere(o, (x, hi.y - 0.012, hi.z - 0.012), 0.012, "copper")
    add_box(pillow, (plo.x + 0.03, plo.y + 0.02, phi.z - 0.003), (phi.x - 0.03, phi.y - 0.02, phi.z + 0.0), "cream")

def do_pottedPlant(by):
    pot, plant = by["pottedPlant(Clone)"], by["plant"]
    lo, hi = world_box([pot])
    c = (lo + hi) / 2
    add_cyl(pot, (c.x, c.y, hi.z - 0.012), 0.092, 0.012, "soil")
    add_torus(pot, (c.x, c.y, hi.z - 0.004), 0.092, 0.006, "terracotta")
    add_cyl(pot, (c.x, c.y, lo.z + 0.018), 0.075, 0.012, "oakDark")
    for k in range(4):
        a = k * math.pi / 2 + 0.5
        add_cyl(plant, (c.x + math.cos(a) * 0.05, c.y + math.sin(a) * 0.05, hi.z + 0.1), 0.012, 0.2, "plant", r2=0.0, verts=6)

def do_bookcaseClosedWide(by):
    o = by["bookcaseClosedWide(Clone)"]
    lo, hi = case_books(o, 41)
    plinth_and_cap(o, lo, hi, "mustard")

def do_bookcaseClosed(by):
    o = by["bookcaseClosed(Clone)"]
    lo, hi = case_books(o, 21)
    plinth_and_cap(o, lo, hi, "teal")

def do_bookcaseClosedDoors(by):
    o = by["bookcaseClosedDoors(Clone)"]
    lo, hi = world_box([o])
    for k in ("doorLeft", "doorRight"):
        dlo, dhi = world_box([by[k]])
        c = (dlo + dhi) / 2
        add_box(by[k], (dlo.x + 0.02, dlo.y - 0.001, dlo.z + 0.03), (dhi.x - 0.02, dlo.y + 0.001, dlo.z + 0.034), "sage")
        add_box(by[k], (dlo.x + 0.02, dlo.y - 0.001, dhi.z - 0.034), (dhi.x - 0.02, dlo.y + 0.001, dhi.z - 0.03), "sage")
        knob_in(by[k], Vector((dlo.x + 0.03 if k == "doorRight" else dhi.x - 0.03, dlo.y, c.z)))
    plinth_and_cap(o, lo, hi, "sage")

def do_kitchenCabinet(by):
    o, door = by["kitchenCabinet(Clone)"], by["door"]
    lo, hi = world_box([o])
    dlo, dhi = world_box([door])
    c = (dlo + dhi) / 2
    add_box(o, (lo.x - 0.002, lo.y - 0.003, hi.z - 0.014), (hi.x + 0.002, hi.y + 0.002, hi.z + 0.003), "tileWhite")
    add_box(o, (lo.x + 0.01, lo.y + 0.01, lo.z), (hi.x - 0.01, hi.y - 0.01, lo.z + 0.02), "oakDark")
    add_box(door, (dlo.x + 0.025, dlo.y - 0.002, dlo.z + 0.025), (dhi.x - 0.025, dlo.y + 0.001, dlo.z + 0.03), "oakDark")
    add_box(door, (c.x - 0.03, dlo.y - 0.004, dhi.z - 0.05), (c.x + 0.03, dlo.y + 0.002, dhi.z - 0.042), "copper")

def do_rugRectangle(by):
    o = by["rugRectangle(Clone)"]
    lo, hi = world_box([o])
    z = hi.z
    m = 0.03
    for y in (lo.y + m, hi.y - m):
        add_box(o, (lo.x + m, y - 0.008, z - 0.002), (hi.x - m, y + 0.008, z + 0.0004), "cream")
    for x in (lo.x + m, hi.x - m):
        add_box(o, (x - 0.008, lo.y + m, z - 0.002), (x + 0.008, hi.y - m, z + 0.0004), "cream")
    c = (lo + hi) / 2
    add_box(o, (c.x - 0.12, c.y - 0.12, z - 0.002), (c.x + 0.12, c.y + 0.12, z + 0.0004), "tealDark", rot=math.pi / 4)

def do_loungeSofa(by):
    o = by["loungeSofa(Clone)"]
    lo, hi = world_box([o])
    lv = [(a, z) for z, a in top_levels(o) if 0.08 < z < hi.z * 0.8]
    seat = max(lv)[1] if lv else 0.2
    for x in (lo.x + 0.03, hi.x - 0.03):
        for y in (lo.y + 0.03, hi.y - 0.03):
            add_cyl(o, (x, y, lo.z + 0.006), 0.017, 0.012, "copper", verts=10)
    add_box(o, (lo.x + 0.12, lo.y + 0.12, seat), (lo.x + 0.28, lo.y + 0.27, seat + 0.07), "teal", rot=0.3)
    add_box(o, (hi.x - 0.30, lo.y + 0.14, seat), (hi.x - 0.14, lo.y + 0.28, seat + 0.06), "sage", rot=-0.35)
    add_box(o, (lo.x, hi.y - 0.015, hi.z - 0.012), (hi.x, hi.y, hi.z), "oakDark")

def do_coatRackStanding(by):
    o = by["coatRackStanding(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    add_sphere(o, (c.x, c.y, hi.z - 0.012), 0.022, "copper", 1.0)
    add_torus(o, (c.x, c.y, lo.z + 0.02), 0.1, 0.01, "copper")
    for k in range(4):
        a = k * math.pi / 2 + math.pi / 4
        for h in (hi.z - 0.1, hi.z - 0.17):
            ang = a + (0.0 if h > hi.z - 0.12 else math.pi / 4)
            add_cyl(o, (c.x + math.cos(ang) * 0.045, c.y + math.sin(ang) * 0.045, h), 0.006, 0.07, "copper",
                    axis="X" if abs(math.cos(ang)) > 0.7 else "Y", verts=8)

def do_tableRound(by):
    o = by["tableRound(Clone)"]
    lo, hi = world_box([o])
    c = (lo + hi) / 2
    r = min(hi.x - lo.x, hi.y - lo.y) / 2
    add_cyl(o, (c.x, c.y, hi.z - 0.002), r * 0.55, 0.006, "teal", verts=24)
    add_torus(o, (c.x, c.y, hi.z - 0.002), r * 0.55, 0.003, "cream")
    add_cyl(o, (c.x + 0.08, c.y, hi.z), 0.04, 0.005, "mustard", verts=18)
    add_cyl(o, (c.x + 0.08, c.y, hi.z + 0.002), 0.026, 0.005, "cream", verts=18)


# ---- nature (pass 3) ------------------------------------------------------------------------------------

LEAF_BANDS = {"leafsGreen": ("leafDark", "leafMid", "leafLight"), "leafsDark": ("pineDark", "pineMid", "pineLight"),
              "grass": ("grassDark", "grassLight", "grassLight")}
NSWAP = {"woodBark": "bark", "woodBarkDark": "barkDark", "dirt": "soil", "_defaultMat": "bark"}

def nature_skin(o, seed):
    """Foliage faces get one of three tones by height with a little noise; bark and soil take our colours."""
    rnd = random.Random(seed)
    lo, hi = world_box([o])
    old = [s.material.name.split(".")[0] for s in o.material_slots]
    was = [f.material_index for f in o.data.polygons]
    o.data.materials.clear()
    idx = {}
    def ix(key):
        if key not in idx:
            o.data.materials.append(PAL[key])
            idx[key] = len(o.data.materials) - 1
        return idx[key]
    mw = o.matrix_world
    for f in o.data.polygons:
        k = old[was[f.index]]
        if k in LEAF_BANDS:
            t = ((mw @ f.center).z - lo.z) / max(hi.z - lo.z, 1e-6) + rnd.uniform(-0.12, 0.12)
            b = LEAF_BANDS[k]
            f.material_index = ix(b[0] if t < 0.45 else b[1] if t < 0.75 else b[2])
        elif k == "leafsDark" or k == "dirt" or k in NSWAP:
            f.material_index = ix(NSWAP[k])
        else:
            f.material_index = ix("melonRind" if k == "leafsDark" else "leafMid")
        f.use_smooth = False

def faces_of(o, keys, min_nz=0.3):
    """(world centre, world normal) of upward-ish faces on slots whose material is one of keys."""
    mw = o.matrix_world
    out = []
    for f in o.data.polygons:
        if o.material_slots[f.material_index].material.name.split(".")[0] in [PAL[k].name for k in keys]:
            n = (mw.to_3x3() @ f.normal).normalized()
            if n.z > min_nz:
                out.append((mw @ f.center, n))
    return out

def scatter(host, o, keys, count, r, key, seed, sq=1.0, above=0.25):
    """Fruit, blossom or cones: small spheres half sunk into upward faces of the foliage."""
    rnd = random.Random(seed)
    fs = faces_of(o, keys)
    lo, hi = world_box([o])
    fs = [f for f in fs if (f[0].z - lo.z) / (hi.z - lo.z) > above]
    rnd.shuffle(fs)
    for c, n in fs[:count]:
        add_sphere(host, c + n * (r * 0.3), r, key, sq)

def trunk_radius(o):
    """Radius of the bark near the ground, from bark faces only (a squat tree's canopy is low)."""
    lo, hi = world_box([o])
    bark = [PAL["bark"].name, PAL["barkDark"].name]
    pts = []
    for f in o.data.polygons:
        if o.material_slots[f.material_index].material.name in bark:
            for vi in f.vertices:
                p = o.matrix_world @ o.data.vertices[vi].co
                if p.z < lo.z + (hi.z - lo.z) * 0.3:
                    pts.append(p)
    return min(0.07, max(max(abs(p.x), abs(p.y)) for p in pts)) if pts else 0.04

def tree_parts(by, name, fruit=None, fruit_r=0.016, count=14, moss=True, roots=False, keys=("leafMid", "leafLight"), seed=3):
    o = by[name]
    nature_skin(o, seed)
    lo, hi = world_box([o])
    r = trunk_radius(o)
    h = hi.z - lo.z
    if roots:
        for k in range(5):
            a = k * 2 * math.pi / 5 + 0.4
            add_sphere(o, (math.cos(a) * r * 0.95, math.sin(a) * r * 0.95, 0.0), r * 0.5, "barkDark", 0.3)
    if moss:
        add_box(o, (-r * 0.45, -r * 0.97, 0.09), (r * 0.45, -r * 0.8, 0.09 + h * 0.05), "moss")
    if fruit:
        scatter(o, o, keys, count, fruit_r, fruit, seed + 7)

def do_tree_default(by):
    tree_parts(by, "tree_default", "blossom", 0.014, 16)

def do_tree_oak(by):
    tree_parts(by, "tree_oak", "apple", 0.016, 12, seed=5)

def do_tree_tall(by):
    tree_parts(by, "tree_tall", "orange", 0.014, 10, keys=("leafLight", "leafMid"), seed=7)

def do_tree_cone(by):
    tree_parts(by, "tree_cone", "pinecone", 0.014, 12, keys=("leafMid", "leafLight", "leafDark"), seed=9)

def do_tree_pineTallA(by):
    tree_parts(by, "tree_pineTallA", "pinecone", 0.013, 12, keys=("pineMid", "pineLight", "pineDark"), seed=11)

def do_tree_pineRoundA(by):
    tree_parts(by, "tree_pineRoundA", "pinecone", 0.014, 14, keys=("pineMid", "pineLight", "pineDark"), seed=13)

def do_tree_detailed(by):
    tree_parts(by, "tree_detailed", "apple", 0.014, 14, seed=15)

def do_tree_fat(by):
    tree_parts(by, "tree_fat", "orange", 0.016, 12, seed=17)

def do_tree_small(by):
    tree_parts(by, "tree_small", "blossom", 0.012, 12, seed=19)

def bush_parts(by, name, fruit, count, seed, r=0.014):
    o = by[name]
    nature_skin(o, seed)
    scatter(o, o, ("grassDark", "grassLight"), count, r, fruit, seed + 1, above=0.35)
    lo, hi = world_box([o])
    add_cyl(o, (0, 0, lo.z + 0.056), min(hi.x - lo.x, hi.y - lo.y) * 0.3, 0.012, "soil", verts=12)

def do_plant_bushLarge(by):
    bush_parts(by, "plant_bushLarge", "berry", 12, 21)

def do_plant_bushDetailed(by):
    bush_parts(by, "plant_bushDetailed", "apple", 14, 23, 0.016)

def do_crop_melon(by):
    o = by["crop_melon"]
    nature_skin(o, 25)
    lo, hi = world_box([o])
    for k, (x, y) in enumerate(((0.05, 0.03), (-0.09, -0.05))):
        add_sphere(o, (x, y, 0.045), 0.045, "melonRind", 0.8)
        add_box(o, (x - 0.004, y - 0.046, 0.05), (x + 0.004, y + 0.046, 0.088), "melonFlesh", rot=0.0)

# ---- pass 4: furniture --------------------------------------------------------------------------------

def seat_z(o, lo_f=0.25, hi_f=0.8):
    hi = world_box([o])[1]
    lv = [(a, z) for z, a in top_levels(o, 0.0005) if hi.z * lo_f < z < hi.z * hi_f]
    return max(lv)[1] if lv else hi.z * 0.5

def feet(o, lo, hi, r=0.006, inset=0.01):
    for x in (lo.x + inset, hi.x - inset):
        for y in (lo.y + inset, hi.y - inset):
            add_cyl(o, (x, y, lo.z + 0.002), r, 0.006, "copper", verts=8)

def do_bedDouble(by):
    o, cover = by["bedDouble(Clone)"], by["cover"]
    lo, hi = world_box([o])
    clo, chi = world_box([cover])
    add_box(cover, (clo.x - 0.002, clo.y + 0.30, chi.z - 0.004), (chi.x + 0.002, clo.y + 0.33, chi.z + 0.002), "mustard")
    add_box(cover, (clo.x - 0.002, clo.y + 0.37, chi.z - 0.004), (chi.x + 0.002, clo.y + 0.38, chi.z + 0.0015), "mustard")
    add_box(cover, (clo.x - 0.002, chi.y - 0.10, chi.z - 0.004), (chi.x + 0.002, chi.y, chi.z + 0.004), "linen")
    for k in ("pillowLeft", "pillowRight"):
        plo, phi = world_box([by[k]])
        add_box(by[k], (plo.x + 0.03, plo.y + 0.02, phi.z - 0.003), (phi.x - 0.03, phi.y - 0.02, phi.z + 0.0), "cream")
    for x in (lo.x + 0.012, hi.x - 0.012):
        add_sphere(o, (x, hi.y - 0.012, hi.z - 0.012), 0.014, "copper")
    feet(o, lo, hi, 0.01, 0.014)

def do_chairRounded(by):
    o = by["chairRounded(Clone)"]
    lo, hi = world_box([o])
    z = seat_z(o)
    add_box(o, (lo.x + 0.025, lo.y + 0.025, z - 0.002), (hi.x - 0.025, hi.y - 0.025, z + 0.012), "mustard")
    feet(o, lo, hi, 0.0055, 0.012)

def do_chairCushion(by):
    o = by["chairCushion(Clone)"]
    lo, hi = world_box([o])
    z = seat_z(o)
    c = (lo + hi) / 2
    add_box(o, (lo.x + 0.02, lo.y + 0.02, z - 0.004), (hi.x - 0.02, hi.y - 0.02, z + 0.002), "cream")
    add_box(o, (c.x - 0.003, lo.y + 0.02, z), (c.x + 0.003, hi.y - 0.02, z + 0.004), "tealDark")
    feet(o, lo, hi, 0.0055, 0.012)

def do_cabinetTelevision(by):
    o = by["cabinetTelevision(Clone)"]
    lo, hi = world_box([o])
    add_box(o, (lo.x + 0.01, lo.y + 0.01, lo.z), (hi.x - 0.01, hi.y - 0.01, lo.z + 0.02), "ink")
    add_box(o, (lo.x + 0.1, lo.y + 0.04, hi.z - 0.002), (hi.x - 0.1, hi.y - 0.04, hi.z + 0.003), "teal")
    for x in (lo.x + (hi.x - lo.x) * 0.3, lo.x + (hi.x - lo.x) * 0.7):
        add_box(o, (x - 0.045, lo.y - 0.001, lo.z + 0.1), (x + 0.045, lo.y + 0.002, lo.z + 0.105), "copper")
        add_sphere(o, (x, lo.y + 0.004, lo.z + 0.16), 0.008, "copper", 0.8)
    add_box(o, (hi.x - 0.2, lo.y + 0.06, hi.z - 0.002), (hi.x - 0.14, hi.y - 0.06, hi.z + 0.004), "red")

def do_loungeChairRelax(by):
    o = by["loungeChairRelax(Clone)"]
    lo, hi = world_box([o])
    z = seat_z(o, 0.2, 0.6)
    add_box(o, (lo.x + 0.1, lo.y + 0.12, z), (hi.x - 0.1, lo.y + 0.3, z + 0.012), "mustard")
    add_box(o, (lo.x + 0.1, hi.y - 0.2, hi.z * 0.62), (hi.x - 0.1, hi.y - 0.14, hi.z * 0.62 + 0.012), "mustard")
    add_box(o, (hi.x - 0.17, lo.y + 0.16, z + 0.0), (hi.x - 0.07, lo.y + 0.26, z + 0.05), "cream", rot=0.4)

def do_benchCushionLow(by):
    o = by["benchCushionLow(Clone)"]
    lo, hi = world_box([o])
    z = seat_z(o, 0.4, 1.0)
    for x in (lo.x + (hi.x - lo.x) * 0.33, lo.x + (hi.x - lo.x) * 0.66):
        add_box(o, (x - 0.002, lo.y + 0.012, z - 0.003), (x + 0.002, hi.y - 0.012, z + 0.003), "tealDark")
    add_box(o, (lo.x + 0.012, lo.y + 0.012, z - 0.003), (hi.x - 0.012, lo.y + 0.018, z + 0.003), "cream")
    add_box(o, (lo.x + 0.012, hi.y - 0.018, z - 0.003), (hi.x - 0.012, hi.y - 0.012, z + 0.003), "cream")
    feet(o, lo, hi, 0.007, 0.02)

def do_kitchenStove(by):
    o, door = by["kitchenStove(Clone)"], by["door"]
    lo, hi = world_box([o])
    dlo, dhi = world_box([door])
    for x in (lo.x + (hi.x - lo.x) * 0.28, lo.x + (hi.x - lo.x) * 0.72):
        for y in (lo.y + (hi.y - lo.y) * 0.3, lo.y + (hi.y - lo.y) * 0.72):
            add_torus(o, (x, y, hi.z - 0.002), 0.05, 0.005, "ink")
            add_cyl(o, (x, y, hi.z - 0.004), 0.025, 0.006, "ink", verts=14)
    for k in range(4):
        add_cyl(o, (lo.x + 0.07 + k * 0.1, lo.y + 0.002, hi.z - 0.045), 0.012, 0.012, "copper", axis="Y", verts=10)
    add_cyl(door, ((dlo.x + dhi.x) / 2, dlo.y - 0.001, dhi.z - 0.03), 0.006, dhi.x - dlo.x - 0.07, "copper", axis="X", verts=8)
    feet(o, lo, hi, 0.01, 0.015)


# ---- pass 4: stone, logs, pumpkin -----------------------------------------------------------------------

def stone_skin(o, seed):
    """Rock faces take one of three greys by height and noise, upward grass faces a moss green, lichen blotches on the tops."""
    rnd = random.Random(seed)
    lo, hi = world_box([o])
    old = [s.material.name.split(".")[0] for s in o.material_slots]
    was = [f.material_index for f in o.data.polygons]
    o.data.materials.clear()
    idx = {}
    def ix(key):
        if key not in idx:
            o.data.materials.append(PAL[key])
            idx[key] = len(o.data.materials) - 1
        return idx[key]
    mw = o.matrix_world
    for f in o.data.polygons:
        k = old[was[f.index]]
        t = ((mw @ f.center).z - lo.z) / max(hi.z - lo.z, 1e-6) + rnd.uniform(-0.15, 0.15)
        nz = (mw.to_3x3() @ f.normal).normalized().z
        if k == "grass":
            f.material_index = ix("moss" if rnd.random() < 0.8 else "lichen")
        else:
            f.material_index = ix("stoneDark" if t < 0.3 else "stoneMid" if t < 0.65 else "stoneLight")
            if nz > 0.6 and rnd.random() < 0.12:
                f.material_index = ix("lichen")
        f.use_smooth = False

def pebbles(host, lo, hi, n, seed, rmax=0.04):
    rnd = random.Random(seed)
    cx, cy = (lo.x + hi.x) / 2, (lo.y + hi.y) / 2
    for _ in range(n):
        a = rnd.uniform(0, 2 * math.pi)
        k = rnd.uniform(0.85, 1.0)
        r = rnd.uniform(rmax * 0.4, rmax)
        add_sphere(host, (cx + math.cos(a) * (hi.x - lo.x) / 2 * k, cy + math.sin(a) * (hi.y - lo.y) / 2 * k, lo.z + 0.05 + r * 0.2), r,
                   ["stoneMid", "stoneLight", "stoneDark"][rnd.randrange(3)], 0.6)

def rock_parts(by, name, seed, n_peb, cracks):
    o = by[name]
    stone_skin(o, seed)
    lo, hi = world_box([o])
    top = hi.z
    pebbles(o, Vector((lo.x * 0.7, lo.y * 0.7, lo.z)), Vector((hi.x * 0.7, hi.y * 0.7, hi.z)), n_peb, seed + 1, 0.035)
    add_cyl(o, (0, 0, lo.z + 0.056), min(hi.x - lo.x, hi.y - lo.y) * 0.25, 0.012, "soil", verts=12)

def do_rock_largeA(by):
    rock_parts(by, "rock_largeA", 31, 8, 3)

def do_rock_tallA(by):
    rock_parts(by, "rock_tallA", 33, 6, 4)

def do_rock_smallA(by):
    rock_parts(by, "rock_smallA", 35, 5, 2)

def bark_skin(o, seed):
    rnd = random.Random(seed)
    old = [s.material.name.split(".")[0] for s in o.material_slots]
    was = [f.material_index for f in o.data.polygons]
    o.data.materials.clear()
    idx = {}
    def ix(key):
        if key not in idx:
            o.data.materials.append(PAL[key])
            idx[key] = len(o.data.materials) - 1
        return idx[key]
    for f in o.data.polygons:
        k = old[was[f.index]]
        f.material_index = ix(("bark" if rnd.random() < 0.6 else "barkDark") if k == "woodBark" else "ring")
        f.use_smooth = False

def ring_at(host, c, R, r, key, axis):
    rot = {"X": (0, math.pi / 2, 0), "Y": (math.pi / 2, 0, 0), "Z": (0, 0, 0)}[axis]
    bpy.ops.mesh.primitive_torus_add(major_radius=R, minor_radius=r, major_segments=20, minor_segments=5, location=c, rotation=rot)
    join(host, bpy.context.active_object, key)

def end_caps(o):
    """Cut ends of a log: (centre, radius, axis letter, sign) per group of woodInner faces on one plane."""
    mw = o.matrix_world
    groups = {}
    for f in o.data.polygons:
        if o.material_slots[f.material_index].material.name.split(".")[0] != "ring":
            continue
        n = (mw.to_3x3() @ f.normal).normalized()
        ax = max(range(3), key=lambda i: abs(n[i]))
        if ax == 2:
            continue
        s = 1 if n[ax] > 0 else -1
        c = mw @ f.center
        groups.setdefault((ax, s, round(c[ax], 2)), []).append((c, f.area))
    out = []
    for (ax, s, _), fs in groups.items():
        tot = sum(a for _, a in fs)
        c = sum((c * a for c, a in fs), Vector()) / tot
        lo, hi = world_box([o])
        edge = hi["XYZ".index("XYZ"[ax])] if s > 0 else lo["XYZ".index("XYZ"[ax])]
        if tot > 0.004 and abs(c[ax] - edge) < 0.012:
            out.append((c, math.sqrt(tot / math.pi), "XYZ"[ax], s))
    return out

def log_parts(by, name, seed, moss=True, mushrooms=1):
    o = by[name]
    bark_skin(o, seed)
    lo, hi = world_box([o])
    for c, r, ax, s in end_caps(o):
        off = Vector((0, 0, 0))
        off["XYZ".index(ax)] = 0.002 * s
        for f in (0.35, 0.65, 0.9):
            ring_at(o, c + off, r * f, 0.0035, "ringDark" if f < 0.5 else "ring", ax)
        bpy.ops.mesh.primitive_cone_add(vertices=8, radius1=0.012, radius2=0.012, depth=0.004, location=c + off,
                                        rotation={"X": (0, math.pi / 2, 0), "Y": (math.pi / 2, 0, 0), "Z": (0, 0, 0)}[ax])
        join(o, bpy.context.active_object, "ringDark")
    rnd = random.Random(seed)
    cx, cy = (lo.x + hi.x) / 2, (lo.y + hi.y) / 2
    if moss:
        for _ in range(3):
            x, y = cx + rnd.uniform(-0.25, 0.25) * (hi.x - lo.x), cy + rnd.uniform(-0.3, 0.3) * (hi.y - lo.y)
            add_box(o, (x - 0.03, y - 0.04, hi.z - 0.02), (x + 0.03, y + 0.04, hi.z + 0.0), "moss", rot=rnd.uniform(0, 1))
    for _ in range(2):
        x, y = cx + rnd.uniform(-0.3, 0.3) * (hi.x - lo.x), cy + rnd.uniform(-0.3, 0.3) * (hi.y - lo.y)
        add_sphere(o, (x, y, hi.z - 0.02), 0.014, "barkDark", 0.6)
    for k in range(mushrooms):
        x, y = lo.x + (hi.x - lo.x) * 0.15, cy + rnd.uniform(-0.2, 0.2) * (hi.y - lo.y)
        add_cyl(o, (x, y, lo.z + 0.065), 0.006, 0.03, "cream", verts=6)
        add_sphere(o, (x, y, lo.z + 0.082), 0.017, "capRed", 0.5)

def do_log(by):
    log_parts(by, "log", 41)

def do_log_large(by):
    log_parts(by, "log_large", 43, mushrooms=2)

def do_log_stack(by):
    log_parts(by, "log_stack", 45)

def do_crop_pumpkin(by):
    o = by["crop_pumpkin"]
    rnd = random.Random(47)
    old = [s.material.name.split(".")[0] for s in o.material_slots]
    was = [f.material_index for f in o.data.polygons]
    o.data.materials.clear()
    idx = {}
    def ix(key):
        if key not in idx:
            o.data.materials.append(PAL[key])
            idx[key] = len(o.data.materials) - 1
        return idx[key]
    for f in o.data.polygons:
        k = old[was[f.index]]
        f.material_index = ix(("pumpkin" if rnd.random() < 0.65 else "pumpkinDark") if k == "leafsFall" else "grassLight" if rnd.random() < 0.5 else "grassDark")
        f.use_smooth = False
    lo, hi = world_box([o])
    for k in range(6):
        a = k * math.pi / 3 + 0.2
        add_box(o, (math.cos(a) * 0.12 - 0.003, math.sin(a) * 0.12 - 0.003, lo.z + 0.1), (math.cos(a) * 0.12 + 0.003, math.sin(a) * 0.12 + 0.003, lo.z + 0.25),
                "pumpkinDark", rot=a)
    add_cyl(o, (0.0, 0.0, hi.z - 0.02), 0.014, 0.05, "stem", verts=6, r2=0.008)
    add_cyl(o, (0.14, -0.1, lo.z + 0.1), 0.025, 0.07, "stem", verts=6, r2=0.012, axis="X")
    add_sphere(o, (0.16, -0.12, lo.z + 0.1), 0.06, "pumpkin", 0.8)
    add_cyl(o, (0, 0, lo.z + 0.056), 0.18, 0.012, "soil", verts=12)


def build(name):
    palette()
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o)
    nat = name in NATURE or name in NATURE4
    bpy.ops.import_scene.gltf(filepath=os.path.join(here, "base", "nature" if nat else "", name + ".glb"))
    objs = meshes()
    by = {o.name: o for o in bpy.data.objects}
    # Bounds are taken before anything is added, from the stock model.
    lo0, hi0 = world_box(objs)
    names0 = sorted(o.name for o in bpy.data.objects)
    if not nat:
        for o in objs:
            reskin(o, OVERRIDES.get(name))
            bevel(o)
        for o in objs:
            for f in o.data.polygons:
                f.use_smooth = False
    globals()["do_" + name](by)
    objs = meshes()
    lo, hi = world_box(objs)
    # Refit to the stock box: every axis is scaled about the box's own corner.
    s = Vector(((hi0[i] - lo0[i]) / (hi[i] - lo[i]) if hi[i] - lo[i] > 1e-6 else 1.0) for i in range(3))
    print("refit", name, [round(v, 4) for v in s])
    roots = [o for o in bpy.data.objects if o.parent is None]
    for o in roots:
        o.matrix_world = Matrix.Translation(lo0) @ Matrix.Diagonal((*s, 1)) @ Matrix.Translation(-lo) @ o.matrix_world
    assert names0 == sorted(o.name for o in bpy.data.objects), "node names changed"
    bpy.ops.object.select_all(action="DESELECT")
    od = naturedir if nat else outdir
    os.makedirs(od, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(od, name + ".glb"), export_format="GLB", export_yup=True,
                              export_apply=False, export_cameras=False, export_lights=False)

ALL = ["cardboardBoxClosed", "cardboardBoxOpen", "kitchenBar", "desk", "chairDesk", "bench", "chair", "table", "trashcan", "bookcaseOpen"]
ALL2 = ["cabinetBedDrawer", "bedSingle", "pottedPlant", "bookcaseClosedWide", "loungeSofa", "bookcaseClosedDoors",
        "bookcaseClosed", "kitchenCabinet", "rugRectangle", "coatRackStanding", "tableRound", "sideTableDrawers"]
ALL4 = ["bedDouble", "chairRounded", "chairCushion", "cabinetTelevision", "loungeChairRelax", "benchCushionLow", "kitchenStove"]
for n in (names or ALL + ALL2 + NATURE + ALL4 + NATURE4):
    build(n)

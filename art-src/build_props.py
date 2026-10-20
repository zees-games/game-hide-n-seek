"""Rebuilds ten of the furniture models under assets/props/furniture/ for game-hide-n-seek.

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
    # books() draws from these names.
    PAL["leather"] = PAL["teal"]
    PAL["velvet"] = PAL["tealDark"]
    PAL["walnutDark"] = PAL["oakDark"]
    PAL["blotter"] = PAL["sage"]
    PAL["gunmetal"] = PAL["steel"]

# Kit material name -> ours.
SWAP = {"wood": "oak", "woodDark": "oakDark", "metal": "copper", "metalMedium": "steel",
        "metalDark": "steel", "carpet": "teal", "plant": "plant", "_defaultMat": "oak"}

def meshes():
    return [o for o in bpy.data.objects if o.type == "MESH"]

def world_box(objs):
    pts = [o.matrix_world @ Vector(c) for o in objs for c in o.bound_box]
    return Vector(min(p[i] for p in pts) for i in range(3)), Vector(max(p[i] for p in pts) for i in range(3))

OVERRIDES = {"cardboardBoxClosed": {"wood": "kraft", "woodDark": "kraftDark"}, "cardboardBoxOpen": {"wood": "kraft", "woodDark": "kraftDark"},
             "trashcan": {"metal": "tealDark", "metalDark": "tealDark"}, "kitchenBar": {"wood": "sage", "woodDark": "oakDark"},
             "chair": {"wood": "oak"}, "bench": {"wood": "oakDark"}, "table": {"wood": "oak"}}

def reskin(o, overrides=None):
    overrides = overrides or {}
    for i, s in enumerate(o.material_slots):
        k = s.material.name.split(".")[0]
        o.material_slots[i].material = PAL[overrides.get(k, SWAP.get(k, "walnut"))]

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

def build(name):
    palette()
    for o in list(bpy.data.objects):
        bpy.data.objects.remove(o)
    bpy.ops.import_scene.gltf(filepath=os.path.join(here, "base", name + ".glb"))
    objs = meshes()
    by = {o.name: o for o in bpy.data.objects}
    # Bounds are taken before anything is added, from the stock model.
    lo0, hi0 = world_box(objs)
    names0 = sorted(o.name for o in bpy.data.objects)
    for o in objs:
        for i, s in enumerate(o.material_slots):
            pass
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
    os.makedirs(outdir, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(outdir, name + ".glb"), export_format="GLB", export_yup=True,
                              export_apply=False, export_cameras=False, export_lights=False)

ALL = ["cardboardBoxClosed", "cardboardBoxOpen", "kitchenBar", "desk", "chairDesk", "bench", "chair", "table", "trashcan", "bookcaseOpen"]
for n in (names or ALL):
    build(n)

"""Climbing trees for game-hide-n-seek, in the Kenney Nature Kit's style.

blender -b --factory-startup --python tools/climb_trees.py -- assets/props/nature

Writes climbtree_oak.glb and climbtree_fork.glb, authored in metres (the kit entry gives
them scale 1.0). No tree in the Nature Kit has a limb a person can stand on: its leaf clumps
sit on the branch ends and its conifers are stacked cones. These are made for it: limbs with
flat tops wide enough to land on, at heights a jump (1.2 m) and a crouch-jump (1.75 m) reach,
and nothing solid within 1.9 m over any limb, so a person stands up on one.

Two materials, named as the kit names them (woodBark, leafsGreen), so the game's kit
recolour paints them the same as every other tree; the base colours and the metallic and
roughness factors are the kit's own. Flat shaded, low sided, as the kit is.
"""
import math
import sys

import bpy
import bmesh
from mathutils import Matrix, Vector

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "."

BARK = (0.8862745, 0.5137255, 0.34117648, 1.0)
LEAF = (0.160784319, 0.7882353, 0.670588255, 1.0)


def material(name, colour):
    m = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = colour
    bsdf.inputs["Metallic"].default_value = 1.0
    bsdf.inputs["Roughness"].default_value = 1.0
    return m


def ring(bm, centre, radius, sides, phase=0.0, frame=Matrix.Identity(3)):
    out = []
    for i in range(sides):
        a = phase + 2.0 * math.pi * i / sides
        local = Vector((math.cos(a) * radius, math.sin(a) * radius, 0.0))
        out.append(bm.verts.new(centre + frame @ local))
    return out


def bridge(bm, a, b):
    n = len(a)
    for i in range(n):
        bm.faces.new((a[i], a[(i + 1) % n], b[(i + 1) % n], b[i]))


def trunk(bm, points, radii, sides=6, cap_top=True):
    """A tapered, faceted trunk through [points] (each a Vector), one ring per point."""
    rings = []
    for i, (p, r) in enumerate(zip(points, radii)):
        # Each ring square to the segment it starts, so a bend stays a bend and not a pinch.
        d = (points[min(i + 1, len(points) - 1)] - points[max(i - 1, 0)]).normalized()
        # The first ring lies flat, so the trunk stands on the floor and not a centimetre in it.
        frame = Matrix.Identity(3) if i == 0 else Vector((0, 0, 1)).rotation_difference(d).to_matrix()
        rings.append(ring(bm, p, r, sides, math.pi / sides, frame))
    for a, b in zip(rings, rings[1:]):
        bridge(bm, a, b)
    bm.faces.new(list(reversed(rings[0])))
    if cap_top:
        bm.faces.new(rings[-1])


def limb(bm, yaw_deg, top, length, width=0.46, thick=0.34, tip_width=0.32, tip_thick=0.22, rise=0.12, start=0.0):
    """A limb with a flat top a person lands on: a box tapered from below and at the sides,
    starting at [start] from the trunk's axis (inside the trunk) and rising [rise] to its tip."""
    yaw = math.radians(yaw_deg)
    fwd = Vector((math.cos(yaw), math.sin(yaw), 0.0))
    side = Vector((-math.sin(yaw), math.cos(yaw), 0.0))
    up = Vector((0, 0, 1))

    def section(dist, z_top, w, t):
        c = fwd * dist
        return [
            bm.verts.new(c + side * (w / 2) + up * z_top),
            bm.verts.new(c - side * (w / 2) + up * z_top),
            # The underside is narrower than the top: a limb, not a plank.
            bm.verts.new(c - side * (w * 0.35) + up * (z_top - t)),
            bm.verts.new(c + side * (w * 0.35) + up * (z_top - t)),
        ]

    mid = length * 0.6
    a = section(start, top - 0.02, width * 1.1, thick * 1.3)
    b = section(mid, top + rise * 0.4, (width + tip_width) / 2, (thick + tip_thick) / 2)
    c = section(length, top + rise, tip_width, tip_thick)
    bridge(bm, a, b)
    bridge(bm, b, c)
    bm.faces.new(list(reversed(a)))
    bm.faces.new(c)


def clump(bm, centre, size, yaw_deg=0.0):
    """A leaf clump as the kit draws one: a box with its edges cut off."""
    s = Vector(size) / 2.0
    cut = min(size) * 0.22
    m = Matrix.Rotation(math.radians(yaw_deg), 3, "Z")
    res = bmesh.ops.create_cube(bm, size=1.0)
    verts = res["verts"]
    for v in verts:
        v.co = Vector((v.co.x * 2 * s.x, v.co.y * 2 * s.y, v.co.z * 2 * s.z))
    edges = list({e for v in verts for e in v.link_edges})
    bmesh.ops.bevel(bm, geom=verts + edges, offset=cut, segments=1, affect="EDGES", profile=0.5)
    # Placed after the bevel: rotate and move every vertex the bevel left.
    return m, Vector(centre)


def finish(name, wood, leaves):
    """Two objects (one per material) joined into one mesh, flat shaded, origin on the floor."""
    objs = []
    for part, mat in ((wood, "woodBark"), (leaves, "leafsGreen")):
        me = bpy.data.meshes.new(f"{name}_{mat}")
        part.to_mesh(me)
        part.free()
        ob = bpy.data.objects.new(f"{name}_{mat}", me)
        bpy.context.collection.objects.link(ob)
        me.materials.append(bpy.data.materials[mat])
        objs.append(ob)
    bpy.ops.object.select_all(action="DESELECT")
    for ob in objs:
        ob.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.data.name = name
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.normals_make_consistent(inside=False)
    bpy.ops.object.mode_set(mode="OBJECT")
    for poly in ob.data.polygons:
        poly.use_smooth = False
    return ob


def leaves_into(bm, items):
    for centre, size, yaw in items:
        tmp = bmesh.new()
        m, c = clump(tmp, centre, size, yaw)
        for v in tmp.verts:
            v.co = m @ v.co + c
        me = bpy.data.meshes.new("tmp")
        tmp.to_mesh(me)
        tmp.free()
        bm.from_mesh(me)
        bpy.data.meshes.remove(me)


def oak():
    """Three limbs climbing round the trunk: 1.2 m (a jump), 1.75 m (a crouch-jump, or a step
    up from the first), 2.95 m (a crouch-jump from the second), and a crown above 4.9 m."""
    wood = bmesh.new()
    pts = [Vector((0, 0, 0)), Vector((0.03, 0.02, 1.4)), Vector((-0.04, 0.03, 3.2)), Vector((0.05, -0.02, 5.0)), Vector((0.0, 0.0, 6.4))]
    trunk(wood, pts, [0.5, 0.36, 0.3, 0.24, 0.16], sides=7)
    limb(wood, 0.0, 1.20, 2.35)
    limb(wood, 125.0, 1.75, 2.25)
    limb(wood, 245.0, 2.95, 2.05, width=0.44)
    # Two short stubs up into the crown, so the clumps are held by something.
    limb(wood, 60.0, 5.3, 1.3, width=0.26, thick=0.22, tip_width=0.16, tip_thick=0.14, rise=0.5)
    limb(wood, 190.0, 5.6, 1.2, width=0.26, thick=0.22, tip_width=0.16, tip_thick=0.14, rise=0.5)

    leaves = bmesh.new()
    def at(yaw, dist, z):
        a = math.radians(yaw)
        return (math.cos(a) * dist, math.sin(a) * dist, z)
    leaves_into(leaves, [
        # The crown, its underside at 5.0 m: over 1.9 m clear of the top limb.
        (at(0, 0.0, 6.6), (3.0, 3.0, 2.6), 10.0),
        (at(60, 1.5, 6.0), (1.8, 1.8, 1.7), 25.0),
        (at(190, 1.4, 6.3), (1.7, 1.7, 1.6), -15.0),
        (at(300, 1.4, 6.1), (1.6, 1.6, 1.5), 40.0),
        # A clump past each limb's tip, on its end: something to hide behind up there, and
        # an end to the limb. Never over the limb itself.
        (at(0, 2.75, 1.85), (1.0, 1.1, 1.1), 15.0),
        (at(125, 2.65, 2.35), (0.95, 1.0, 1.0), -20.0),
        (at(245, 2.45, 3.6), (1.0, 1.0, 1.05), 30.0),
    ])
    return finish("climbtree_oak", wood, leaves)


def fork():
    """A low, wide tree whose trunk splits at 1.65 m: a crotch to stand in between the two
    leaders, a long low limb at 1.25 m to jump onto first, and the crown high on the leaders."""
    wood = bmesh.new()
    trunk(wood, [Vector((0, 0, 0)), Vector((0.02, 0, 0.9)), Vector((0, 0, 1.62))], [0.5, 0.44, 0.46], sides=7)
    # Two leaders out of the crotch, leaning apart along X; their bases leave the crotch flat.
    for s in (1, -1):
        trunk(wood, [Vector((s * 0.3, 0, 1.5)), Vector((s * 0.75, 0.05, 2.6)), Vector((s * 1.55, 0.1, 3.9)), Vector((s * 2.0, 0.0, 4.9))],
              [0.24, 0.22, 0.18, 0.13], sides=6)
    limb(wood, 90.0, 1.25, 2.7, width=0.5)
    limb(wood, 215.0, 1.62, 1.6, width=0.42, start=0.0, rise=0.05)

    leaves = bmesh.new()
    leaves_into(leaves, [
        (( 2.0, 0.0, 5.6), (2.4, 2.4, 2.0), 15.0),
        ((-2.0, 0.0, 5.7), (2.5, 2.5, 2.1), -10.0),
        (( 0.0, 0.3, 6.3), (2.0, 2.2, 1.7), 30.0),
        (( 0.1, 3.05, 1.9), (1.1, 1.0, 1.15), 20.0),
        (( 1.3, -1.1, 4.4), (1.2, 1.2, 1.1), 5.0),
    ])
    return finish("climbtree_fork", wood, leaves)


def export(ob, path):
    bpy.ops.object.select_all(action="DESELECT")
    ob.select_set(True)
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_apply=True,
                              export_yup=True, export_texcoords=True, export_normals=True,
                              export_materials="EXPORT", export_animations=False)


bpy.ops.wm.read_factory_settings(use_empty=True)
material("woodBark", BARK)
material("leafsGreen", LEAF)
for make in (oak, fork):
    ob = make()
    export(ob, f"{OUT}/{ob.name}.glb")
    print("wrote", ob.name)

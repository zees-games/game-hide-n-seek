"""One contact sheet of many furniture models: the stock model in the back row, the rebuilt one in front.

Run (GPU box):  ./gpu.sh blender --stage <repo> --pull <outdir> -- -b -P art-src/render_grid.py -- <out.png> <name> [name ...]
Stock models come from art-src/base, rebuilt ones from assets/props/furniture. Three-quarter view from the front-left.
"""
import bpy, sys, os
from mathutils import Vector

here = os.path.dirname(os.path.abspath(__file__))
out, names = sys.argv[sys.argv.index("--") + 1], sys.argv[sys.argv.index("--") + 2:]
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
sc.render.engine = "CYCLES"
try:
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "CUDA"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
    sc.cycles.device = "GPU"
except Exception as e:
    print("no GPU", e)
sc.cycles.samples = 64
w = bpy.data.worlds.new("w")
w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.62, 0.68, 0.76, 1)
sc.world = w
bpy.ops.object.light_add(type="SUN", rotation=(0.9, 0.2, 0.7))
bpy.context.active_object.data.energy = 3.5

def place(path, x, y):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    new = [o for o in bpy.data.objects if o not in before]
    roots = [o for o in new if o.parent is None]
    meshes = [o for o in new if o.type == "MESH"]
    pts = [o.matrix_world @ Vector(c) for o in meshes for c in o.bound_box]
    lo = Vector(min(p[i] for p in pts) for i in range(3))
    hi = Vector(max(p[i] for p in pts) for i in range(3))
    for r in roots:
        r.location += Vector((x - (lo.x + hi.x) / 2, y - (lo.y + hi.y) / 2, -lo.z))

step = 1.0
for i, n in enumerate(names):
    place(os.path.join(here, "base", n + ".glb"), i * step, 1.0)
    place(os.path.join(here, "..", "assets", "props", "furniture", n + ".glb"), i * step, 0.0)
bpy.ops.mesh.primitive_plane_add(size=60, location=(len(names) * step / 2, 0, -0.001))
cx = (len(names) - 1) * step / 2
sc.render.resolution_x = min(4000, 400 * len(names))
sc.render.resolution_y = 760
bpy.ops.object.camera_add(location=(cx - 0.3, -3.2 - len(names) * 0.12, 1.6))
cam = bpy.context.active_object
cam.rotation_euler = (Vector((cx, 0.5, 0.25)) - cam.location).to_track_quat("-Z", "Y").to_euler()
cam.data.angle = 0.5 + 0.0 * len(names)
cam.data.type = "ORTHO"
cam.data.ortho_scale = len(names) * step * 1.0
sc.camera = cam
sc.render.filepath = out
bpy.ops.render.render(write_still=True)

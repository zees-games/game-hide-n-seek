"""One contact image: the rebuilt models in the top row, the stock models under them, three-quarter view.

Run on a box with Cycles on a GPU:  blender -b -P render_contact.py -- <new_dir> <stock_dir> <out.png> [name ...]
"""
import bpy, sys, os
from mathutils import Vector
args = sys.argv[sys.argv.index("--") + 1:]
newd, stockd, out = args[:3]
names = args[3:]
bpy.ops.wm.read_factory_settings(use_empty=True)
sc = bpy.context.scene
sc.render.engine = "CYCLES"
prefs = bpy.context.preferences.addons["cycles"].preferences
prefs.compute_device_type = "CUDA"
prefs.get_devices()
for d in prefs.devices:
    d.use = True
sc.cycles.device = "GPU"
sc.cycles.samples = 64
sc.render.resolution_x = 2000
sc.render.resolution_y = 700
w = bpy.data.worlds.new("w")
w.use_nodes = True
w.node_tree.nodes["Background"].inputs[0].default_value = (0.62, 0.68, 0.76, 1)
sc.world = w
bpy.ops.object.light_add(type="SUN", rotation=(0.9, 0.2, 0.7))
bpy.context.active_object.data.energy = 3.5
bpy.ops.mesh.primitive_plane_add(size=40, location=(0, 0, -0.001))
for i, n in enumerate(names):
    for row, d in enumerate((newd, stockd)):
        before = set(bpy.data.objects)
        bpy.ops.import_scene.gltf(filepath=os.path.join(d, n + ".glb"))
        for o in set(bpy.data.objects) - before:
            if o.parent is None:
                o.location += Vector((i * 0.9, -row * 1.3, 0))
cx = (len(names) - 1) * 0.45
bpy.ops.object.camera_add(location=(cx, -7, 7))
cam = bpy.context.active_object
cam.rotation_euler = (Vector((cx, -0.6, 0.2)) - cam.location).to_track_quat("-Z", "Y").to_euler()
cam.data.type = "ORTHO"
cam.data.ortho_scale = len(names) * 0.98
sc.camera = cam
sc.render.filepath = out
bpy.ops.render.render(write_still=True)

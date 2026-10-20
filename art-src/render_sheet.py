"""Contact sheet of one furniture model: front, side and three-quarter, then the stock model beside it.

Run on a box with Cycles on a GPU (staging02, ~/gpu/blender/blender):
  blender -b -P render_sheet.py -- <new.glb> <stock.glb> <out_prefix>
Renders <out_prefix>_{front,side,threequarter}.png of the new model and <out_prefix>_stock.png of the stock one.
"""
import bpy, sys
from mathutils import Vector

new, stock, prefix = sys.argv[-3:]

def world_box():
    pts = [o.matrix_world @ Vector(c) for o in bpy.data.objects if o.type == "MESH" for c in o.bound_box]
    return Vector(min(p[i] for p in pts) for i in range(3)), Vector(max(p[i] for p in pts) for i in range(3))

def setup():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "CUDA"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
    sc.cycles.device = "GPU"
    sc.cycles.samples = 96
    sc.render.resolution_x = 520
    sc.render.resolution_y = 520
    w = bpy.data.worlds.new("w")
    w.use_nodes = True
    w.node_tree.nodes["Background"].inputs[0].default_value = (0.62, 0.68, 0.76, 1)
    sc.world = w
    bpy.ops.object.light_add(type="SUN", rotation=(0.9, 0.2, 0.7))
    bpy.context.active_object.data.energy = 3.5
    return sc

def shoot(sc, glb, views, prefix):
    bpy.ops.import_scene.gltf(filepath=glb)
    lo, hi = world_box()
    ctr = (lo + hi) / 2
    dist = max(hi - lo) * 2.6
    for name, d in views.items():
        bpy.ops.object.camera_add(location=ctr + Vector(d).normalized() * dist)
        cam = bpy.context.active_object
        cam.rotation_euler = (ctr - cam.location).to_track_quat("-Z", "Y").to_euler()
        cam.data.angle = 0.6
        sc.camera = cam
        sc.render.filepath = "%s_%s.png" % (prefix, name)
        bpy.ops.render.render(write_still=True)

# glTF front (+Z) is Blender -Y.
sc = setup()
shoot(sc, new, {"front": (0, -1, 0.25), "side": (1, 0, 0.25), "threequarter": (-0.8, -0.9, 0.55)}, prefix)
sc = setup()
shoot(sc, stock, {"stock": (-0.8, -0.9, 0.55)}, prefix)

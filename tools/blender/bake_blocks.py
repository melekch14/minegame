"""Bakes the detailed terrain blocks onto low-poly boxes for Godot.

Run from the project root:
    blender -b --python tools/blender/bake_blocks.py

For each block in assets/models/ (the exported high-poly Blender blocks, ~500-2800 triangles):
  * builds a low-poly stand-in: a 2x2x2 m box without its bottom (a wedge for the slope),
    ~10 triangles, UV-unwrapped into a 3x2 atlas (one cell per face),
  * bakes the high-poly block onto it with Cycles ("selected to active"):
        <name>_normal.png  object-space normals, Godot axes (bevels, cracks, grass rim)
        <name>_matao.png   R = material index as (id + 0.5) / 8, G = ambient occlusion
  * exports the box to assets/models/baked/<name>.glb.
The colours are NOT baked: shaders/voxel_ramp.gdshader still builds them procedurally per
instance, it only reads the material index and the normal from these textures.
Nothing is saved back to any .blend.
"""

import os

import bmesh
import bpy
import numpy as np
from mathutils import Vector

PROJECT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC_DIR = os.path.join(PROJECT_DIR, "assets", "models")
OUT_DIR = os.path.join(SRC_DIR, "baked")
BLOCKS = ["01_grass_block", "02_dirt_block", "03_stone_block", "04_sand_block", "06_grass_slope"]

CELL = 128        # texels per face
PAD = 4           # texels kept free around each face (bake margin / mip bleeding)
COLS, ROWS = 3, 2
AO_SAMPLES = 64
AO_DISTANCE = 0.35
SLOPE_LOW = 0.25  # height of the slope's low edge (measured on 06_grass_slope)
# Atlas cell per face direction (Blender axes, Z up).
CELLS = {"+Z": (0, 0), "+X": (1, 0), "-X": (2, 0), "+Y": (0, 1), "-Y": (1, 1)}


def log(msg):
    print("[bake_blocks] " + msg)


def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.device = "CPU"
    scene.world = bpy.data.worlds.new("World")
    scene.world.light_settings.distance = AO_DISTANCE


def import_high(name):
    bpy.ops.import_scene.gltf(filepath=os.path.join(SRC_DIR, name + ".glb"))
    high = next(o for o in bpy.context.scene.objects if o.type == "MESH")
    # Emission = material index read from UV.x (the exporter stored index + 0.5 there).
    mat = bpy.data.materials.new("BakeMatId")
    mat.use_nodes = True
    nt = mat.node_tree
    nt.nodes.clear()
    uv = nt.nodes.new("ShaderNodeUVMap")
    uv.uv_map = high.data.uv_layers[0].name
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    div = nt.nodes.new("ShaderNodeMath")
    div.operation = "DIVIDE"
    div.inputs[1].default_value = 8.0
    emit = nt.nodes.new("ShaderNodeEmission")
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    nt.links.new(uv.outputs["UV"], sep.inputs[0])
    nt.links.new(sep.outputs["X"], div.inputs[0])
    nt.links.new(div.outputs[0], emit.inputs["Color"])
    nt.links.new(emit.outputs[0], out.inputs["Surface"])
    high.data.materials.clear()
    high.data.materials.append(mat)
    return high


def face_uv(co, axis):
    """Maps a vertex of a face pointing along `axis` into its atlas cell (Blender UV space)."""
    x, y, z = (co.x + 1.0) * 0.5, (co.y + 1.0) * 0.5, co.z * 0.5
    a, b = {"Z": (x, y), "X": (y, z), "Y": (x, z)}[axis[1]]
    cx, cy = CELLS[axis]
    inner = (CELL - 2 * PAD) / CELL
    u = (cx + PAD / CELL + a * inner) / COLS
    v = (cy + PAD / CELL + b * inner) / ROWS
    return u, v


def build_low(name, high):
    slope = "slope" in name
    lo = SLOPE_LOW if slope else 2.0
    # Corners: (x, y) -> top height. The slope rises toward +Y (Godot -Z).
    top = {(-1, -1): lo, (1, -1): lo, (1, 1): 2.0, (-1, 1): 2.0}
    faces = [
        ("+Z", [(-1, -1, top[(-1, -1)]), (1, -1, top[(1, -1)]), (1, 1, 2.0), (-1, 1, 2.0)]),
        ("+X", [(1, -1, 0), (1, 1, 0), (1, 1, 2.0), (1, -1, top[(1, -1)])]),
        ("-X", [(-1, 1, 0), (-1, -1, 0), (-1, -1, top[(-1, -1)]), (-1, 1, 2.0)]),
        ("+Y", [(1, 1, 0), (-1, 1, 0), (-1, 1, 2.0), (1, 1, 2.0)]),
        ("-Y", [(-1, -1, 0), (1, -1, 0), (1, -1, lo), (-1, -1, lo)]),
    ]
    me = bpy.data.meshes.new(name + "_low")
    bm = bmesh.new()
    uv_layer = bm.loops.layers.uv.new("UVMap")
    for axis, pts in faces:
        f = bm.faces.new([bm.verts.new(p) for p in pts])
        for loop in f.loops:
            loop[uv_layer].uv = face_uv(loop.vert.co, axis)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    bm.to_mesh(me)
    bm.free()
    low = bpy.data.objects.new(name, me)
    bpy.context.scene.collection.objects.link(low)
    low.matrix_world = high.matrix_world
    # Don't let the box occlude the high-poly block while baking AO.
    low.visible_diffuse = low.visible_glossy = low.visible_shadow = False
    low.visible_transmission = low.visible_volume_scatter = False
    return low


def bake(low, high, kind, samples):
    w, h = COLS * CELL, ROWS * CELL
    img = bpy.data.images.new("bake_" + kind, w, h, alpha=True, float_buffer=True)
    img.colorspace_settings.name = "Non-Color"
    img.generated_color = (0.0, 0.0, 0.0, 0.0)  # alpha stays 0 where no ray hit the block
    mat = bpy.data.materials.new("Bake_" + kind)
    mat.use_nodes = True
    node = mat.node_tree.nodes.new("ShaderNodeTexImage")
    node.image = img
    mat.node_tree.nodes.active = node
    low.data.materials.clear()
    low.data.materials.append(mat)
    bpy.ops.object.select_all(action="DESELECT")
    high.select_set(True)
    low.select_set(True)
    bpy.context.view_layer.objects.active = low
    bpy.context.scene.cycles.samples = samples
    args = dict(type=kind, use_selected_to_active=True, cage_extrusion=0.05, max_ray_distance=0.6,
                margin=PAD, margin_type="EXTEND", use_clear=False)
    if kind == "NORMAL":
        args.update(normal_space="OBJECT", normal_r="POS_X", normal_g="POS_Y", normal_b="POS_Z")
    bpy.ops.object.bake(**args)
    px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
    return px


def fill_missed(px, default):
    missed = px[..., 3] < 0.5
    px[missed, :3] = default
    return int(missed.sum())


def save_png(path, rgb):
    h, w, _ = rgb.shape
    img = bpy.data.images.new(os.path.basename(path), w, h, alpha=False)
    img.colorspace_settings.name = "Non-Color"
    rgba = np.concatenate([np.clip(rgb, 0.0, 1.0), np.ones((h, w, 1), np.float32)], axis=2)
    img.pixels[:] = rgba.ravel()
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()


def process(name):
    reset()
    high = import_high(name)
    low = build_low(name, high)
    for p in low.data.polygons:  # every face must point away from the box centre
        assert p.normal.dot(p.center - Vector((0.0, 0.0, 1.0))) > 0.0, name + ": inward face"
    nrm = bake(low, high, "NORMAL", 1)
    mat = bake(low, high, "EMIT", 1)
    ao = bake(low, high, "AO", AO_SAMPLES)
    # Texels no ray reached (open bottom edge): flat face normal, most common material, no AO.
    missed = 0
    for axis, (cx, cy) in CELLS.items():
        ys = slice(cy * CELL, (cy + 1) * CELL)
        xs = slice(cx * CELL, (cx + 1) * CELL)
        flat = np.zeros(3, np.float32)
        flat["XYZ".index(axis[1])] = 1.0 if axis[0] == "+" else -1.0
        missed += fill_missed(nrm[ys, xs], flat * 0.5 + 0.5)
        ids = mat[ys, xs, 0]
        hit = ids[mat[ys, xs, 3] > 0.5]
        common = np.bincount(np.floor(hit * 8.0).astype(int)).argmax() if hit.size else 0
        fill_missed(mat[ys, xs], (common + 0.5) / 8.0)
        fill_missed(ao[ys, xs], 1.0)
    # Blender object space (Z up) -> Godot object space (Y up): (x, y, z) -> (x, z, -y).
    n = nrm[..., :3] * 2.0 - 1.0
    n = np.stack([n[..., 0], n[..., 2], -n[..., 1]], axis=-1)
    n /= np.maximum(np.linalg.norm(n, axis=-1, keepdims=True), 1e-6)
    # Material index: snap to the texel centre value so 8-bit storage decodes exactly.
    ids = (np.floor(np.clip(mat[..., 0], 0.0, 0.99) * 8.0) + 0.5) / 8.0
    os.makedirs(OUT_DIR, exist_ok=True)
    save_png(os.path.join(OUT_DIR, name + "_normal.png"), n * 0.5 + 0.5)
    save_png(os.path.join(OUT_DIR, name + "_matao.png"),
             np.stack([ids, ao[..., 0], np.zeros_like(ids)], axis=-1))
    low.data.materials.clear()
    bpy.ops.object.select_all(action="DESELECT")
    low.select_set(True)
    bpy.ops.export_scene.gltf(filepath=os.path.join(OUT_DIR, name + ".glb"), export_format="GLB",
                              use_selection=True, export_materials="NONE", export_normals=True,
                              export_texcoords=True)
    log("%s: %d -> %d triangles, %d texels without a hit" % (
        name, sum(len(p.vertices) - 2 for p in high.data.polygons),
        sum(len(p.vertices) - 2 for p in low.data.polygons), missed))


for block in BLOCKS:
    process(block)
log("done -> " + OUT_DIR)

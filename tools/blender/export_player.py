"""Exports ../assets/playerlv0.blend -> assets/characters/player/playerlv0.glb for Godot.

Run from the project root:
    blender -b ../assets/playerlv0.blend --python tools/blender/export_player.py

The .blend is never saved; everything below happens on the in-memory copy.

What it does:
  * drops the preview cameras / lights,
  * applies Mirror / Bevel / WeightedNormal (the Armature modifier stays for skinning),
  * bakes each vertex's object-space rest position into the UVs (UV0 = x,y  UV1 = z) —
    the materials build their colour from snapped object position + white noise, which glTF
    can't carry; shaders/character_voxel.gdshader rebuilds it from these UVs,
  * adds two generated actions next to Walk / Wave:
        Idle  - the average Walk pose (arms down, legs straight) with a slow breathing cycle,
        Air   - a single tucked pose for jumping / falling,
  * exports every action as a glTF animation (Godot: AnimationPlayer "Idle", "Walk", "Wave", "Air").
"""

import math
import os

import bpy
from mathutils import Quaternion, Vector

PROJECT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT_PATH = os.path.join(PROJECT_DIR, "assets", "characters", "player", "playerlv0.glb")
RIG_NAME = "RIG_Character"


def log(msg):
    print("[export_player] " + msg)


def remove_scene_helpers():
    for o in list(bpy.data.objects):
        if o.type in {"CAMERA", "LIGHT"} or o.name == "CAM_Target":
            bpy.data.objects.remove(o, do_unlink=True)


def apply_modifiers(rig):
    rig.data.pose_position = "REST"
    bpy.context.view_layer.update()
    for o in [o for o in bpy.data.objects if o.type == "MESH"]:
        bpy.ops.object.select_all(action="DESELECT")
        o.select_set(True)
        bpy.context.view_layer.objects.active = o
        # Keep the Armature modifier last so the others apply to the undeformed mesh.
        arm_mods = [m for m in o.modifiers if m.type == "ARMATURE"]
        for m in arm_mods:
            bpy.ops.object.modifier_move_to_index(modifier=m.name, index=len(o.modifiers) - 1)
        for m in [m for m in o.modifiers if m.type != "ARMATURE"]:
            bpy.ops.object.modifier_apply(modifier=m.name)
    rig.data.pose_position = "POSE"


def bake_position_uvs():
    for o in [o for o in bpy.data.objects if o.type == "MESH"]:
        me = o.data
        while len(me.uv_layers) > 0:
            me.uv_layers.remove(me.uv_layers[0])
        uv_xy = me.uv_layers.new(name="PosXY")
        uv_z = me.uv_layers.new(name="PosZ")
        for loop in me.loops:
            co = me.vertices[loop.vertex_index].co
            uv_xy.data[loop.index].uv = (co.x, co.y)
            uv_z.data[loop.index].uv = (co.z, 0.0)


def sample_walk_mean(rig):
    """Per-bone average rotation / location over the Walk cycle."""
    walk = bpy.data.actions["Walk"]
    rig.animation_data_create()
    rig.animation_data.action = walk
    if walk.slots:
        rig.animation_data.action_slot = walk.slots[0]
    start, end = int(walk.frame_range[0]), int(walk.frame_range[1])
    sums = {b.name: [Vector((0, 0, 0, 0)), Vector((0, 0, 0))] for b in rig.pose.bones}
    ref = {}
    frames = range(start, end)  # last frame == first frame
    for f in frames:
        bpy.context.scene.frame_set(f)
        for pb in rig.pose.bones:
            q = pb.rotation_quaternion.copy()
            if pb.name not in ref:
                ref[pb.name] = q
            if ref[pb.name].dot(q) < 0.0:
                q.negate()
            sums[pb.name][0] += Vector(q)
            sums[pb.name][1] += pb.location
    n = float(len(frames))
    mean = {}
    for name, (qs, ls) in sums.items():
        q = Quaternion(qs / n)
        q.normalize()
        mean[name] = (q, ls / n)
    rig.animation_data.action = None
    return mean


def axis_angle(axis, deg):
    return Quaternion(Vector(axis), math.radians(deg))


def key_pose(rig, action, frame, pose):
    """pose: bone -> (quat, loc). Bones not listed keep rest."""
    rig.animation_data.action = action
    bpy.context.scene.frame_set(frame)
    for pb in rig.pose.bones:
        q, l = pose.get(pb.name, (Quaternion(), Vector()))
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = q
        pb.location = l
        pb.keyframe_insert("rotation_quaternion", frame=frame, group=pb.name)
        pb.keyframe_insert("location", frame=frame, group=pb.name)


def make_idle(rig, mean):
    act = bpy.data.actions.new("Idle")
    act.use_fake_user = True
    rig.animation_data.action = act
    base = {k: (q.copy(), Vector((0, 0, 0))) for k, (q, _l) in mean.items()}
    # Legs straight and hips level while standing.
    for b in ("UpperLeg_L", "UpperLeg_R", "LowerLeg_L", "LowerLeg_R", "Foot_L", "Foot_R", "Hips"):
        base[b] = (Quaternion(), Vector((0, 0, 0)))
    breath = dict(base)
    breath["Spine"] = (base["Spine"][0] @ axis_angle((1, 0, 0), -2.0), Vector())
    breath["Head"] = (base["Head"][0] @ axis_angle((1, 0, 0), 1.5), Vector())
    breath["Hips"] = (Quaternion(), Vector((0, -0.03, 0)))  # bone Y = world up: slight dip
    for arm in ("UpperArm_L", "UpperArm_R"):
        breath[arm] = (base[arm][0] @ axis_angle((0, 0, 1), 2.0 if arm.endswith("L") else -2.0), Vector())
    key_pose(rig, act, 1, base)
    key_pose(rig, act, 25, breath)
    key_pose(rig, act, 49, base)
    return act


def make_air(rig, mean):
    act = bpy.data.actions.new("Air")
    act.use_fake_user = True
    rig.animation_data.action = act
    pose = {k: (q.copy(), Vector()) for k, (q, _l) in mean.items()}
    # Positive X rotation swings a leg forward (Walk frame 13 vs 1); knees bend with -X.
    pose["UpperLeg_L"] = (axis_angle((1, 0, 0), 30.0), Vector())
    pose["LowerLeg_L"] = (axis_angle((1, 0, 0), -55.0), Vector())
    pose["UpperLeg_R"] = (axis_angle((1, 0, 0), -12.0), Vector())
    pose["LowerLeg_R"] = (axis_angle((1, 0, 0), -35.0), Vector())
    pose["Foot_L"] = (Quaternion(), Vector())
    pose["Foot_R"] = (Quaternion(), Vector())
    pose["Hips"] = (Quaternion(), Vector())
    # Arms lifted a little away from the body.
    pose["UpperArm_L"] = (mean["UpperArm_L"][0] @ axis_angle((0, 0, 1), 25.0), Vector())
    pose["UpperArm_R"] = (mean["UpperArm_R"][0] @ axis_angle((0, 0, 1), -25.0), Vector())
    key_pose(rig, act, 1, pose)
    key_pose(rig, act, 2, pose)
    return act


def export():
    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    rig = bpy.data.objects[RIG_NAME]
    rig.animation_data.action = None
    bpy.context.scene.frame_set(1)
    bpy.ops.export_scene.gltf(
        filepath=OUT_PATH,
        export_format="GLB",
        use_selection=False,
        export_apply=True,
        export_yup=True,
        export_texcoords=True,
        export_normals=True,
        export_materials="EXPORT",
        export_skins=True,
        export_animations=True,
        export_animation_mode="ACTIONS",
        export_force_sampling=True,
        export_reset_pose_bones=True,
        export_def_bones=False,
        export_cameras=False,
        export_lights=False,
    )
    log("wrote " + OUT_PATH)


def main():
    if bpy.context.object and bpy.context.object.mode != "OBJECT":
        bpy.ops.object.mode_set(mode="OBJECT")
    rig = bpy.data.objects[RIG_NAME]
    remove_scene_helpers()
    mean = sample_walk_mean(rig)
    apply_modifiers(rig)
    bake_position_uvs()
    make_idle(rig, mean)
    make_air(rig, mean)
    export()


main()

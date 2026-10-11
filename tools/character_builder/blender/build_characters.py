"""Builds the Bolt, Kit and Mushi characters in Blender (bpy) and exports them as
rigged .glb files with a palette texture, in the style of the existing characters
(chibi proportions, flat colour atlas, toon shading in Godot).

    pip install bpy numpy pillow
    python build_characters.py <output dir>          # e.g. plugins/characters

Writes <out>/<Name>/<name>.glb and <out>/<Name>/palette.png.

Conventions: Blender is Z up and the character faces -Y (glTF turns that into
Godot's +Z). Positions below are written as (x, up, front) and converted by v().
Animations are written as Godot-style euler degrees (x, y, z) and converted by
g2b(): Godot x -> Blender x, Godot y (turn) -> Blender z, Godot z (roll) -> -Blender y.
"""
import math
import os
import sys

import bpy  # must come before bmesh and mathutils
import bmesh
import mathutils
from PIL import Image

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else sys.argv[1]
FPS = 24

# Polygon budget. The default is the Nintendo 64 look: chunky 10 x 6 spheres, 8 sided cylinders, one bevel step,
# so a character has about 1500 triangles (Mario 64's Mario has less than 1000). POLY=high builds the smooth version
# that was used before (7000 - 15000 triangles).
HIGH_POLY = os.environ.get("POLY", "low") == "high"
SPHERE_SEGMENTS = (20, 12) if HIGH_POLY else (10, 6)
CYLINDER_SEGMENTS = 14 if HIGH_POLY else 8
BEVEL_STEPS = 3 if HIGH_POLY else 1

# ---------------------------------------------------------------- palette

PALETTE_COLORS = {}


def swatch(name, rgb):
    PALETTE_COLORS[name] = rgb
    return name


def hexc(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def write_palette(path, names):
    img = Image.new("RGBA", (256, 256), (255, 255, 255, 255))
    for i, name in enumerate(names):
        col, row = i % 8, i // 8
        c = PALETTE_COLORS[name]
        for x in range(col * 32, col * 32 + 32):
            for y in range(row * 32, row * 32 + 32):
                img.putpixel((x, y), c + (255,))
    img.save(path)


# ---------------------------------------------------------------- mesh helpers

class Builder:
    def __init__(self, name, scale, palette):
        self.name = name
        self.k = scale
        self.palette = list(palette)
        self.bones = []          # (bone name, parent name, head position)
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.verify()
        self.dvert = self.bm.verts.layers.deform.verify()

    def v(self, x, up, front):
        return mathutils.Vector((x * self.k, -front * self.k, up * self.k))

    def bone(self, name, parent, x, up, front):
        self.bones.append((name, parent, self.v(x, up, front)))

    def _add(self, part_bm, color, bone, smooth, detail=False):
        mesh = bpy.data.meshes.new("part")
        part_bm.to_mesh(mesh)
        part_bm.free()
        first_v = len(self.bm.verts)
        first_f = len(self.bm.faces)
        self.bm.from_mesh(mesh)
        bpy.data.meshes.remove(mesh)
        self.bm.verts.ensure_lookup_table()
        self.bm.faces.ensure_lookup_table()
        idx = self.palette.index(color)
        u = (idx % 8 + 0.5) / 8.0
        w = 1.0 - (idx // 8 + 0.5) / 8.0
        group = [b[0] for b in self.bones].index(bone)
        for vert in self.bm.verts[first_v:]:
            vert[self.dvert][group] = 1.0
        for face in self.bm.faces[first_f:]:
            face.smooth = smooth
            face.material_index = 1 if detail else 0
            for loop in face.loops:
                loop[self.uv].uv = (u, w)

    def blob(self, color, bone, pos, size, rot=(0, 0, 0), smooth=True):
        """An ellipsoid. pos=(x, up, front); size = radii (x, up, front)."""
        bm = bmesh.new()
        bmesh.ops.create_uvsphere(bm, u_segments=SPHERE_SEGMENTS[0], v_segments=SPHERE_SEGMENTS[1], radius=1.0)
        self._finish(bm, color, bone, pos, size, rot, smooth)

    def block(self, color, bone, pos, size, rot=(0, 0, 0), bevel=0.0, smooth=False):
        """A box. size = half extents (x, up, front). bevel rounds the edges."""
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=2.0)
        self._finish(bm, color, bone, pos, size, rot, smooth, bevel)

    def cone(self, color, bone, pos, radius, depth, rot=(0, 0, 0), top=0.0, smooth=True):
        """A cone/cylinder along the up axis; rot is (pitch, yaw, roll) degrees."""
        bm = bmesh.new()
        bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=CYLINDER_SEGMENTS,
                              radius1=radius, radius2=top, depth=depth)
        self._finish(bm, color, bone, pos, (1, 1, 1), rot, smooth, detail=depth <= 0.05)

    def _finish(self, bm, color, bone, pos, size, rot, smooth, bevel=0.0, detail=None):
        sx, sy, sz = size
        if detail is None:
            # thin plates on the front (eyes, mouth, chest prints) and thin rings are drawn without the black
            # outline: their outline shells poke through the body as dotted lines
            detail = (pos[2] >= 0.1 and sz <= 0.045) or sy <= 0.03
        # to blender axes: x, y(depth) = -front, z = up
        scale = mathutils.Matrix.Diagonal((sx * self.k, sz * self.k, sy * self.k, 1.0))
        # rot: pitch about x, yaw about up (blender z), roll about front (blender -y)
        rx, ry, rz = (math.radians(a) for a in rot)
        rotation = mathutils.Euler((rx, -rz, ry), "XYZ").to_matrix().to_4x4()
        bmesh.ops.transform(bm, matrix=scale, verts=bm.verts)
        if bevel > 0:
            bmesh.ops.bevel(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces),
                            offset=bevel * self.k, segments=BEVEL_STEPS, affect="EDGES", profile=0.6)
        bmesh.ops.transform(bm, matrix=rotation, verts=bm.verts)
        bmesh.ops.transform(bm, matrix=mathutils.Matrix.Translation(self.v(*pos)), verts=bm.verts)
        self._add(bm, color, bone, smooth, detail)

    # ---- build the object, armature and animations

    def finish(self, anims, folder):
        mesh = bpy.data.meshes.new(self.name + "Mesh")
        self.bm.to_mesh(mesh)
        self.bm.free()
        body = bpy.data.objects.new("Body", mesh)
        bpy.context.collection.objects.link(body)
        for bone in self.bones:
            body.vertex_groups.new(name=bone[0])

        arm_data = bpy.data.armatures.new("Armature")
        arm = bpy.data.objects.new("Armature", arm_data)
        bpy.context.collection.objects.link(arm)
        bpy.context.view_layer.objects.active = arm
        bpy.ops.object.mode_set(mode="EDIT")
        edit = {}
        for name, parent, head in self.bones:
            eb = arm_data.edit_bones.new(name)
            eb.head = head
            eb.tail = head + mathutils.Vector((0, 0.08 * self.k, 0))  # every bone has identity rest orientation
            eb.roll = 0.0
            if parent:
                eb.parent = edit[parent]
            edit[name] = eb
        bpy.ops.object.mode_set(mode="OBJECT")

        body.parent = arm
        mod = body.modifiers.new("Armature", "ARMATURE")
        mod.object = arm

        # material using the palette
        mat = bpy.data.materials.new(self.name)
        mat.use_nodes = True
        tex = mat.node_tree.nodes.new("ShaderNodeTexImage")
        tex.image = bpy.data.images.load(os.path.join(folder, "palette.png"))
        tex.interpolation = "Closest"
        bsdf = mat.node_tree.nodes["Principled BSDF"]
        mat.node_tree.links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
        bsdf.inputs["Roughness"].default_value = 0.75
        mesh.materials.append(mat)
        face_mat = mat.copy()
        face_mat.name = self.name + "Face"
        mesh.materials.append(face_mat)

        self.animate(arm, anims)
        return arm, body

    def animate(self, arm, anims):
        arm.animation_data_create()
        bpy.context.view_layer.objects.active = arm
        bpy.ops.object.mode_set(mode="POSE")
        for pb in arm.pose.bones:
            pb.rotation_mode = "XYZ"
        for name, spec in anims.items():
            action = bpy.data.actions.new(name)
            action.use_fake_user = True
            arm.animation_data.action = action
            for pb in arm.pose.bones:
                pb.rotation_euler = (0, 0, 0)
                pb.location = (0, 0, 0)
            tracks = spec["tracks"]
            for bone_name, keys in tracks.items():
                pb = arm.pose.bones.get(bone_name)
                if pb is None:
                    continue
                for t, value in keys:
                    frame = 1 + round(t * FPS)
                    if bone_name.endswith("@loc"):
                        continue
                    rot = g2b(value)
                    pb.rotation_euler = rot
                    pb.keyframe_insert("rotation_euler", frame=frame)
            for t, dy in spec.get("hips_y", []):
                pb = arm.pose.bones["Hips"]
                pb.location = (0, 0, dy * self.k)
                pb.keyframe_insert("location", frame=1 + round(t * FPS))
            # make loops seamless and give the action its frame range
            action.use_frame_range = True
            action.frame_start = 1
            action.frame_end = 1 + round(spec["length"] * FPS)
        bpy.ops.object.mode_set(mode="OBJECT")
        # one NLA track per action, so every animation is exported by name
        for name in anims:
            track = arm.animation_data.nla_tracks.new()
            track.name = name
            strip = track.strips.new(name, 1, bpy.data.actions[name])
            strip.name = name
        arm.animation_data.action = None


def g2b(rot):
    """Godot-style euler degrees (x, y, z) to blender radians (x, y, z)."""
    x, y, z = rot
    return (math.radians(x), math.radians(-z), math.radians(y))


# ---------------------------------------------------------------- animations

def anim_set(tail=False):
    A = {}

    def loop(name, length, tracks, hips_y):
        A[name] = {"length": length, "tracks": tracks, "hips_y": hips_y}

    r = lambda x, y=0.0, z=0.0: (x, y, z)
    loop("idle", 2.0, {
        "Head": [(0, r(0)), (1, r(-3, 0, 2)), (2, r(0))],
        "ArmL": [(0, r(0, 0, 5)), (1, r(0, 0, 8)), (2, r(0, 0, 5))],
        "ArmR": [(0, r(0, 0, -5)), (1, r(0, 0, -8)), (2, r(0, 0, -5))],
    }, [(0, 0), (1, 0.02), (2, 0)])
    loop("walk", 0.8, {
        "Hips": [(0, r(3, 4)), (0.4, r(3, -4)), (0.8, r(3, 4))],
        "LegL": [(0, r(-25)), (0.4, r(25)), (0.8, r(-25))],
        "LegR": [(0, r(25)), (0.4, r(-25)), (0.8, r(25))],
        "ArmL": [(0, r(20, 0, 5)), (0.4, r(-20, 0, 5)), (0.8, r(20, 0, 5))],
        "ArmR": [(0, r(-20, 0, -5)), (0.4, r(20, 0, -5)), (0.8, r(-20, 0, -5))],
    }, [(0, 0), (0.2, 0.03), (0.4, 0), (0.6, 0.03), (0.8, 0)])
    run = {
        "Hips": [(0, r(12, 6)), (0.25, r(12, -6)), (0.5, r(12, 6))],
        "LegL": [(0, r(-50)), (0.25, r(50)), (0.5, r(-50))],
        "LegR": [(0, r(50)), (0.25, r(-50)), (0.5, r(50))],
        "ArmL": [(0, r(55, 0, 8)), (0.25, r(-55, 0, 8)), (0.5, r(55, 0, 8))],
        "ArmR": [(0, r(-55, 0, -8)), (0.25, r(55, 0, -8)), (0.5, r(-55, 0, -8))],
    }
    run_hips = [(0, 0), (0.125, 0.06), (0.25, 0), (0.375, 0.06), (0.5, 0)]
    loop("run", 0.5, run, run_hips)
    A["jump"] = {"length": 0.8, "hips_y": [(0, 0), (0.15, -0.1), (0.4, 0.05), (0.8, 0)], "tracks": {
        "ArmL": [(0, r(0, 0, 5)), (0.15, r(25, 0, 8)), (0.4, r(-150, 0, 20)), (0.8, r(-100, 0, 15))],
        "ArmR": [(0, r(0, 0, -5)), (0.15, r(25, 0, -8)), (0.4, r(-150, 0, -20)), (0.8, r(-100, 0, -15))],
        "LegL": [(0, r(0)), (0.15, r(-20)), (0.4, r(-35)), (0.8, r(-10))],
        "LegR": [(0, r(0)), (0.15, r(-20)), (0.4, r(15)), (0.8, r(-10))],
    }}
    loop("happy", 1.0, {
        "Head": [(0, r(0, 0, 6)), (0.5, r(0, 0, -6)), (1, r(0, 0, 6))],
        "ArmL": [(0, r(-160, 0, 10)), (0.5, r(-160, 0, 35)), (1, r(-160, 0, 10))],
        "ArmR": [(0, r(-160, 0, -35)), (0.5, r(-160, 0, -10)), (1, r(-160, 0, -35))],
        "LegL": [(0, r(0)), (0.25, r(-15)), (0.5, r(0)), (0.75, r(-15)), (1, r(0))],
        "LegR": [(0, r(0)), (0.25, r(10)), (0.5, r(0)), (0.75, r(10)), (1, r(0))],
    }, [(0, 0), (0.25, 0.16), (0.5, 0), (0.75, 0.16), (1, 0)])
    loop("sad", 2.0, {
        "Hips": [(0, r(0, 0, -2)), (1, r(0, 0, 2)), (2, r(0, 0, -2))],
        "Head": [(0, r(35)), (1, r(40)), (2, r(35))],
        "ArmL": [(0, r(8, 0, -3)), (1, r(12, 0, -3)), (2, r(8, 0, -3))],
        "ArmR": [(0, r(8, 0, 3)), (1, r(12, 0, 3)), (2, r(8, 0, 3))],
    }, [(0, -0.06), (1, -0.07), (2, -0.06)])
    loop("stun", 1.0, {
        "Hips": [(0, r(0, 0, -12)), (0.5, r(0, 0, 12)), (1, r(0, 0, -12))],
        "Head": [(0, r(10, -35, 0)), (0.5, r(10, 35, 0)), (1, r(10, -35, 0))],
        "ArmL": [(0, r(20, 0, 25)), (0.5, r(-10, 0, 35)), (1, r(20, 0, 25))],
        "ArmR": [(0, r(-10, 0, -35)), (0.5, r(20, 0, -25)), (1, r(-10, 0, -35))],
    }, [(0, -0.05), (1, -0.05)])
    A["punch"] = {"length": 0.5, "hips_y": [], "tracks": {
        "Hips": [(0, r(0)), (0.1, r(0, 18)), (0.2, r(0, -22)), (0.5, r(0))],
        "ArmR": [(0, r(0, 0, -5)), (0.1, r(35, 0, -5)), (0.2, r(-95, 0, -3)), (0.5, r(0, 0, -5))],
        "ArmL": [(0, r(0, 0, 5)), (0.2, r(25, 0, 10)), (0.5, r(0, 0, 5))],
    }}
    A["kick"] = {"length": 0.6, "hips_y": [], "tracks": {
        "Hips": [(0, r(0)), (0.35, r(-8)), (0.6, r(0))],
        "LegR": [(0, r(0)), (0.2, r(30)), (0.35, r(-85)), (0.6, r(0))],
        "ArmL": [(0, r(0, 0, 5)), (0.3, r(0, 0, 45)), (0.6, r(0, 0, 5))],
        "ArmR": [(0, r(0, 0, -5)), (0.3, r(0, 0, -45)), (0.6, r(0, 0, -5))],
    }}
    loop("carry", 1.0, {
        "ArmL": [(0, r(-70, 0, -10)), (1, r(-70, 0, -10))],
        "ArmR": [(0, r(-70, 0, 10)), (1, r(-70, 0, 10))],
    }, [(0, 0), (0.5, 0.015), (1, 0)])
    rc = {k: v for k, v in run.items()}
    rc["ArmL"] = [(0, r(-70, 0, -10)), (0.25, r(-76, 0, -10)), (0.5, r(-70, 0, -10))]
    rc["ArmR"] = [(0, r(-70, 0, 10)), (0.25, r(-76, 0, 10)), (0.5, r(-70, 0, 10))]
    loop("run-carry", 0.5, rc, run_hips)
    loop("sit", 1.0, {
        "LegL": [(0, r(-90, 0, 6)), (1, r(-90, 0, 6))],
        "LegR": [(0, r(-90, 0, -6)), (1, r(-90, 0, -6))],
        "ArmL": [(0, r(-20, 0, 8)), (1, r(-20, 0, 8))],
        "ArmR": [(0, r(-20, 0, -8)), (1, r(-20, 0, -8))],
    }, [(0, -0.22), (1, -0.22)])
    if tail:
        A["idle"]["tracks"]["Tail"] = [(0, r(0, -12)), (1, r(0, 12)), (2, r(0, -12))]
        A["walk"]["tracks"]["Tail"] = [(0, r(0, -15)), (0.4, r(0, 15)), (0.8, r(0, -15))]
        A["run"]["tracks"]["Tail"] = [(0, r(35, -8)), (0.25, r(35, 8)), (0.5, r(35, -8))]
        A["run-carry"]["tracks"]["Tail"] = A["run"]["tracks"]["Tail"]
        A["happy"]["tracks"]["Tail"] = [(0, r(0, -35)), (0.25, r(0, 35)), (0.5, r(0, -35)),
                                        (0.75, r(0, 35)), (1, r(0, -35))]
        A["sad"]["tracks"]["Tail"] = [(0, r(-25)), (2, r(-25))]
        A["jump"]["tracks"]["Tail"] = [(0, r(0)), (0.4, r(25)), (0.8, r(10))]
    return A


# ---------------------------------------------------------------- characters

def standard_bones(b, hips_up, shoulder_x, shoulder_up, leg_x, head_up, tail=None):
    b.bone("Hips", None, 0, hips_up, 0)
    b.bone("Head", "Hips", 0, head_up, 0)
    b.bone("ArmL", "Hips", shoulder_x, shoulder_up, 0)
    b.bone("ArmR", "Hips", -shoulder_x, shoulder_up, 0)
    b.bone("LegL", "Hips", leg_x, hips_up, 0)
    b.bone("LegR", "Hips", -leg_x, hips_up, 0)
    if tail:
        b.bone("Tail", "Hips", *tail)


def build_bolt(folder):
    steel = swatch("steel", hexc("#9db7e0"))
    shade = swatch("steel_dark", hexc("#5d6f94"))
    navy = swatch("navy", hexc("#27304a"))
    orange = swatch("orange", hexc("#ff8a1f"))
    white = swatch("white", hexc("#f4f4f4"))
    black = swatch("black", hexc("#141414"))
    red = swatch("red", hexc("#e8312f"))
    cyan = swatch("cyan", hexc("#5fe3f0"))
    pal = [steel, shade, navy, orange, white, black, red, cyan]
    b = Builder("Bolt", 0.62, pal)
    standard_bones(b, 0.36, 0.27, 0.6, 0.14, 0.67)

    for s, sign in (("L", 1), ("R", -1)):
        b.blob(shade, "Leg" + s, (sign * 0.14, 0.2, 0), (0.07, 0.17, 0.075))
        b.block(orange, "Leg" + s, (sign * 0.14, 0.05, 0.04), (0.09, 0.05, 0.14), bevel=0.04, smooth=True)
        b.blob(shade, "Arm" + s, (sign * 0.29, 0.45, 0), (0.05, 0.15, 0.05))
        b.blob(steel, "Arm" + s, (sign * 0.27, 0.6, 0), (0.08, 0.08, 0.08))
        b.blob(orange, "Arm" + s, (sign * 0.29, 0.29, 0), (0.075, 0.075, 0.075))
    b.block(steel, "Hips", (0, 0.5, 0), (0.22, 0.17, 0.17), bevel=0.06, smooth=True)
    b.block(orange, "Hips", (0, 0.5, 0.165), (0.12, 0.08, 0.015), bevel=0.01)
    b.blob(cyan, "Hips", (0, 0.5, 0.185), (0.03, 0.03, 0.015))
    b.cone(shade, "Hips", (0, 0.35, 0), 0.19, 0.06)

    b.block(steel, "Head", (0, 0.97, 0), (0.31, 0.26, 0.25), bevel=0.09, smooth=True)
    b.block(navy, "Head", (0, 0.96, 0.23), (0.25, 0.16, 0.03), bevel=0.02)
    for sign in (1, -1):
        b.blob(white, "Head", (sign * 0.12, 0.99, 0.265), (0.095, 0.105, 0.035))
        b.blob(black, "Head", (sign * 0.12, 0.97, 0.292), (0.05, 0.055, 0.025))
        b.cone(orange, "Head", (sign * 0.33, 0.97, 0), 0.075, 0.11, rot=(0, 0, 90))
    b.block(white, "Head", (0, 0.85, 0.262), (0.09, 0.016, 0.012))
    b.cone(shade, "Head", (0.12, 1.32, 0), 0.02, 0.15)
    b.blob(red, "Head", (0.12, 1.42, 0), (0.06, 0.06, 0.06))
    return b, anim_set(), "Bolt"


def build_kit(folder):
    orange = swatch("fox", hexc("#f28a24"))
    cream = swatch("cream", hexc("#fff0d6"))
    brown = swatch("brown", hexc("#5a3320"))
    black = swatch("black", hexc("#141414"))
    white = swatch("white", hexc("#f6f6f6"))
    pink = swatch("pink", hexc("#ff9aa8"))
    dark = swatch("fox_dark", hexc("#c4651a"))
    pal = [orange, cream, brown, black, white, pink, dark]
    b = Builder("Kit", 0.66, pal)
    standard_bones(b, 0.34, 0.27, 0.58, 0.12, 0.62, tail=(0, 0.38, -0.2))

    for s, sign in (("L", 1), ("R", -1)):
        b.blob(brown, "Leg" + s, (sign * 0.12, 0.18, 0), (0.065, 0.16, 0.07))
        b.blob(brown, "Leg" + s, (sign * 0.12, 0.05, 0.035), (0.085, 0.05, 0.12))
        b.blob(orange, "Arm" + s, (sign * 0.28, 0.46, 0), (0.05, 0.13, 0.05))
        b.blob(brown, "Arm" + s, (sign * 0.28, 0.34, 0), (0.06, 0.06, 0.06))
    b.blob(orange, "Hips", (0, 0.46, 0), (0.24, 0.22, 0.2))
    b.blob(cream, "Hips", (0, 0.44, 0.13), (0.16, 0.17, 0.08))

    b.blob(orange, "Head", (0, 0.92, 0), (0.34, 0.29, 0.3))
    for sign in (1, -1):
        b.blob(cream, "Head", (sign * 0.25, 0.82, 0.16), (0.14, 0.11, 0.1))
        b.blob(white, "Head", (sign * 0.13, 0.96, 0.265), (0.09, 0.105, 0.035))
        b.blob(black, "Head", (sign * 0.13, 0.945, 0.292), (0.05, 0.058, 0.025))
        b.cone(orange, "Head", (sign * 0.21, 1.25, -0.02), 0.14, 0.32, rot=(0, 0, -sign * 14))
        b.cone(pink, "Head", (sign * 0.21, 1.22, 0.03), 0.085, 0.22, rot=(0, 0, -sign * 14))
        b.cone(brown, "Head", (sign * 0.235, 1.37, -0.02), 0.045, 0.08, rot=(0, 0, -sign * 14))
    b.blob(cream, "Head", (0, 0.83, 0.28), (0.15, 0.1, 0.12))
    b.blob(black, "Head", (0, 0.865, 0.385), (0.045, 0.035, 0.035))
    b.block(black, "Head", (0, 0.79, 0.385), (0.025, 0.006, 0.006))

    b.blob(orange, "Tail", (0, 0.56, -0.34), (0.12, 0.3, 0.12), rot=(-50, 0, 0))
    b.blob(cream, "Tail", (0, 0.76, -0.54), (0.115, 0.115, 0.115))
    return b, anim_set(tail=True), "Kit"


def build_mushi(folder):
    red = swatch("cap", hexc("#e23a3e"))
    cream = swatch("cream", hexc("#fbe9c4"))
    spot = swatch("spot", hexc("#fff8ee"))
    brown = swatch("brown", hexc("#6e4326"))
    black = swatch("black", hexc("#141414"))
    white = swatch("white", hexc("#f6f6f6"))
    blush = swatch("blush", hexc("#ff8d8d"))
    shade = swatch("cap_dark", hexc("#a82428"))
    pal = [red, cream, spot, brown, black, white, blush, shade]
    b = Builder("Mushi", 0.78, pal)
    standard_bones(b, 0.3, 0.25, 0.52, 0.1, 0.62)

    for s, sign in (("L", 1), ("R", -1)):
        b.blob(cream, "Leg" + s, (sign * 0.1, 0.17, 0), (0.06, 0.12, 0.06))
        b.blob(brown, "Leg" + s, (sign * 0.1, 0.05, 0.035), (0.09, 0.05, 0.125))
        b.blob(cream, "Arm" + s, (sign * 0.27, 0.41, 0), (0.045, 0.11, 0.045))
        b.blob(cream, "Arm" + s, (sign * 0.27, 0.3, 0), (0.06, 0.06, 0.06))
    b.blob(cream, "Hips", (0, 0.45, 0), (0.25, 0.25, 0.23))
    for sign in (1, -1):
        b.blob(white, "Hips", (sign * 0.1, 0.5, 0.2), (0.085, 0.1, 0.035))
        b.blob(black, "Hips", (sign * 0.1, 0.485, 0.228), (0.048, 0.056, 0.025))
        b.blob(blush, "Hips", (sign * 0.18, 0.39, 0.18), (0.055, 0.032, 0.02), rot=(0, 0, sign * 10))
    b.blob(black, "Hips", (0, 0.385, 0.222), (0.035, 0.012, 0.01))

    b.blob(red, "Head", (0, 0.92, 0), (0.46, 0.28, 0.46))
    b.blob(shade, "Head", (0, 0.69, 0), (0.42, 0.04, 0.42))
    b.blob(spot, "Head", (0, 1.19, 0.02), (0.12, 0.04, 0.12))
    for ang, elev, size in ((0, 28, 0.11), (75, 22, 0.1), (150, 30, 0.1), (230, 25, 0.12), (300, 20, 0.1)):
        a, e = math.radians(ang), math.radians(elev)
        pos = (0.46 * math.cos(e) * math.sin(a) * 0.9, 0.92 + 0.28 * math.sin(e) * 0.9,
               0.46 * math.cos(e) * math.cos(a) * 0.9)
        b.blob(spot, "Head", pos, (size, size * 0.45, size), rot=(0, 0, 0))
    return b, anim_set(), "Mushi"


def build_businessman(folder):
    skin = swatch("skin", hexc("#f4cba8"))
    skin_dark = swatch("skin_dark", hexc("#dba583"))
    hair = swatch("hair", hexc("#5a3a22"))
    suit = swatch("suit", hexc("#1c1c24"))
    suit_light = swatch("suit_light", hexc("#34343f"))
    shirt = swatch("shirt", hexc("#f7f7f7"))
    tie = swatch("tie", hexc("#d12b2b"))
    shoe = swatch("shoe", hexc("#0d0d10"))
    white = swatch("white", hexc("#f6f6f6"))
    black = swatch("black", hexc("#141414"))
    mouth = swatch("mouth", hexc("#8c3b3b"))
    pal = [skin, skin_dark, hair, suit, suit_light, shirt, tie, shoe, white, black, mouth]
    b = Builder("Businessman", 0.68, pal)
    standard_bones(b, 0.34, 0.28, 0.58, 0.1, 0.64)

    for s_, sign in (("L", 1), ("R", -1)):
        b.blob(suit, "Leg" + s_, (sign * 0.1, 0.19, 0), (0.08, 0.17, 0.085))
        b.blob(shoe, "Leg" + s_, (sign * 0.1, 0.045, 0.045), (0.09, 0.05, 0.14))
        b.blob(suit, "Arm" + s_, (sign * 0.29, 0.46, 0), (0.06, 0.14, 0.06))
        b.blob(shirt, "Arm" + s_, (sign * 0.29, 0.325, 0), (0.063, 0.028, 0.063))
        b.blob(skin, "Arm" + s_, (sign * 0.29, 0.285, 0), (0.065, 0.065, 0.065))
    b.block(suit, "Hips", (0, 0.5, 0), (0.235, 0.18, 0.15), bevel=0.07, smooth=True)
    b.block(shirt, "Hips", (0, 0.52, 0.148), (0.07, 0.15, 0.012))
    b.blob(tie, "Hips", (0, 0.46, 0.158), (0.038, 0.12, 0.014))
    b.blob(tie, "Hips", (0, 0.61, 0.155), (0.045, 0.035, 0.022))
    for sign in (1, -1):
        b.block(suit_light, "Hips", (sign * 0.105, 0.54, 0.15), (0.03, 0.12, 0.01), rot=(0, 0, sign * 14))

    b.blob(skin, "Head", (0, 0.93, 0), (0.3, 0.27, 0.27))
    b.blob(hair, "Head", (0, 1.04, -0.04), (0.315, 0.2, 0.27))
    b.blob(hair, "Head", (0.1, 1.15, 0.1), (0.2, 0.07, 0.15), rot=(0, 0, -12))
    b.blob(hair, "Head", (0, 0.97, -0.1), (0.31, 0.21, 0.2))
    for sign in (1, -1):
        b.blob(skin, "Head", (sign * 0.3, 0.92, 0), (0.04, 0.06, 0.035))
        b.blob(white, "Head", (sign * 0.12, 0.965, 0.25), (0.085, 0.1, 0.035))
        b.blob(black, "Head", (sign * 0.12, 0.95, 0.278), (0.048, 0.058, 0.025))
        b.block(hair, "Head", (sign * 0.12, 1.06, 0.262), (0.065, 0.014, 0.012), rot=(0, 0, sign * -8))
    b.blob(skin_dark, "Head", (0, 0.885, 0.275), (0.035, 0.04, 0.04))
    b.block(mouth, "Head", (0, 0.81, 0.262), (0.07, 0.011, 0.01))
    return b, anim_set(), "Businessman"


def build_timber(folder):
    bark = swatch("bark", hexc("#8a5530"))
    bark_dark = swatch("bark_dark", hexc("#5a341c"))
    wood = swatch("wood", hexc("#e2b26a"))
    ring = swatch("ring", hexc("#b97f3f"))
    leaf = swatch("leaf", hexc("#69bd3f"))
    leaf_dark = swatch("leaf_dark", hexc("#3f8c2b"))
    white = swatch("white", hexc("#f6f6f6"))
    black = swatch("black", hexc("#141414"))
    mouth = swatch("mouth", hexc("#4a1f12"))
    moss = swatch("moss", hexc("#7fa84a"))
    pal = [bark, bark_dark, wood, ring, leaf, leaf_dark, white, black, mouth, moss]
    b = Builder("Timber", 0.72, pal)
    standard_bones(b, 0.2, 0.3, 0.64, 0.12, 0.58)

    # lower half of the log and its roots
    b.cone(bark, "Hips", (0, 0.4, 0), 0.27, 0.46, top=0.265)
    b.cone(bark_dark, "Hips", (0, 0.17, 0), 0.285, 0.05, top=0.27)
    b.blob(moss, "Hips", (-0.1, 0.56, -0.2), (0.09, 0.05, 0.07), rot=(30, 0, 0))
    for x, h, up in ((-0.15, 0.22, 0.38), (0.0, 0.18, 0.3), (0.14, 0.2, 0.42), (0.08, 0.14, 0.52), (-0.07, 0.12, 0.52)):
        b.block(bark_dark, "Hips", (x, up, math.sqrt(0.27 ** 2 - x ** 2) + 0.002), (0.011, h / 2, 0.006))
    b.blob(bark_dark, "Hips", (0.21, 0.33, 0.1), (0.05, 0.08, 0.025), rot=(0, 20, 0))
    for s_, sign in (("L", 1), ("R", -1)):
        b.blob(bark_dark, "Leg" + s_, (sign * 0.12, 0.1, 0.02), (0.07, 0.12, 0.07))
        b.blob(bark_dark, "Leg" + s_, (sign * 0.13, 0.035, 0.06), (0.09, 0.045, 0.13))
        # branch arms with a leaf at the tip
        b.blob(bark, "Arm" + s_, (sign * 0.35, 0.52, 0), (0.045, 0.14, 0.045), rot=(0, 0, sign * -22))
        b.blob(bark_dark, "Arm" + s_, (sign * 0.285, 0.64, 0), (0.07, 0.07, 0.07))
        b.blob(bark_dark, "Arm" + s_, (sign * 0.4, 0.38, 0), (0.06, 0.06, 0.06))
        b.blob(leaf, "Arm" + s_, (sign * 0.43, 0.43, 0.03), (0.09, 0.025, 0.05), rot=(0, 0, sign * -40))

    # upper half of the log is the head: face, cut top with rings, leafy sprout
    b.cone(bark, "Head", (0, 0.77, 0), 0.285, 0.4, top=0.28)
    b.cone(bark_dark, "Head", (0, 0.57, 0), 0.295, 0.04, top=0.29)
    b.cone(wood, "Head", (0, 0.975, 0), 0.272, 0.03, top=0.272)
    b.cone(ring, "Head", (0, 0.99, 0), 0.21, 0.012, top=0.21)
    b.cone(wood, "Head", (0, 0.996, 0), 0.15, 0.012, top=0.15)
    b.cone(ring, "Head", (0, 1.002, 0), 0.09, 0.012, top=0.09)
    b.cone(wood, "Head", (0, 1.008, 0), 0.035, 0.012, top=0.035)
    b.blob(leaf_dark, "Head", (0.08, 1.07, 0.02), (0.015, 0.07, 0.015), rot=(0, 0, -15))
    b.blob(leaf, "Head", (0.14, 1.14, 0.02), (0.1, 0.03, 0.055), rot=(0, 0, -28))
    b.blob(leaf, "Head", (0.03, 1.12, 0.02), (0.085, 0.03, 0.05), rot=(0, 0, 25))
    for sign in (1, -1):
        b.blob(white, "Head", (sign * 0.11, 0.8, 0.255), (0.085, 0.1, 0.035))
        b.blob(black, "Head", (sign * 0.11, 0.785, 0.282), (0.048, 0.058, 0.025))
        b.block(bark_dark, "Head", (sign * 0.11, 0.925, 0.262), (0.06, 0.016, 0.012), rot=(0, 0, sign * -10))
    b.blob(bark_dark, "Head", (0.2, 0.7, 0.2), (0.045, 0.07, 0.02), rot=(0, 35, 0))
    b.block(mouth, "Head", (0, 0.665, 0.272), (0.075, 0.013, 0.012))
    for sign in (1, -1):
        b.block(mouth, "Head", (sign * 0.085, 0.685, 0.268), (0.012, 0.022, 0.012), rot=(0, 0, sign * 20))
    for x, h, up in ((-0.22, 0.14, 0.88), (0.22, 0.1, 0.9), (0.0, 0.07, 0.6)):
        b.block(bark_dark, "Head", (x, up, math.sqrt(0.28 ** 2 - x ** 2) + 0.002), (0.01, h / 2, 0.006))
    return b, anim_set(), "Timber"


def build_emo(folder):
    skin = swatch("pale", hexc("#f3dccf"))
    skin_dark = swatch("pale_dark", hexc("#d8b8a8"))
    hair = swatch("hair", hexc("#121216"))
    black = swatch("black", hexc("#17171d"))
    grey = swatch("grey", hexc("#3a3a45"))
    purple = swatch("purple", hexc("#7a2fa8"))
    white = swatch("white", hexc("#f4f4f4"))
    metal = swatch("metal", hexc("#b8bcc8"))
    liner = swatch("liner", hexc("#0b0b0f"))
    pink = swatch("pink", hexc("#e68fa6"))
    mouth = swatch("mouth", hexc("#6b2c3a"))
    pal = [skin, skin_dark, hair, black, grey, purple, white, metal, liner, pink, mouth]
    b = Builder("Emo", 0.68, pal)
    standard_bones(b, 0.37, 0.25, 0.6, 0.1, 0.66)

    for s_, sign in (("L", 1), ("R", -1)):
        b.blob(black, "Leg" + s_, (sign * 0.1, 0.21, 0), (0.062, 0.18, 0.068))
        b.blob(purple, "Leg" + s_, (sign * 0.1, 0.33, 0), (0.066, 0.02, 0.072))
        b.blob(black, "Leg" + s_, (sign * 0.1, 0.07, 0.04), (0.095, 0.07, 0.15))
        b.blob(white, "Leg" + s_, (sign * 0.1, 0.02, 0.04), (0.1, 0.022, 0.16))
        # striped sleeves and a spiked wristband
        b.blob(black, "Arm" + s_, (sign * 0.27, 0.48, 0), (0.05, 0.13, 0.05))
        b.blob(purple, "Arm" + s_, (sign * 0.27, 0.52, 0), (0.054, 0.025, 0.054))
        b.blob(purple, "Arm" + s_, (sign * 0.27, 0.43, 0), (0.054, 0.025, 0.054))
        b.blob(metal, "Arm" + s_, (sign * 0.27, 0.34, 0), (0.058, 0.025, 0.058))
        b.blob(skin, "Arm" + s_, (sign * 0.27, 0.29, 0), (0.06, 0.06, 0.06))
    b.block(black, "Hips", (0, 0.5, 0), (0.2, 0.17, 0.14), bevel=0.06, smooth=True)
    b.block(purple, "Hips", (0, 0.5, 0.139), (0.2, 0.025, 0.006))
    b.block(grey, "Hips", (0, 0.37, 0), (0.205, 0.03, 0.145), bevel=0.01)
    b.blob(metal, "Hips", (0, 0.37, 0.15), (0.035, 0.025, 0.012))
    # a small skull print on the chest
    b.blob(white, "Hips", (0, 0.55, 0.138), (0.05, 0.05, 0.012))
    b.blob(white, "Hips", (0, 0.5, 0.138), (0.03, 0.022, 0.012))
    b.blob(black, "Hips", (0.02, 0.555, 0.147), (0.012, 0.016, 0.006))
    b.blob(black, "Hips", (-0.02, 0.555, 0.147), (0.012, 0.016, 0.006))

    b.blob(skin, "Head", (0, 0.94, 0), (0.3, 0.27, 0.27))
    # swoopy side fringe over the character's right eye, messy back of the hair
    b.blob(hair, "Head", (0, 1.04, -0.04), (0.32, 0.21, 0.28))
    b.blob(hair, "Head", (-0.09, 1.0, 0.17), (0.22, 0.17, 0.12), rot=(10, 0, 18))
    b.blob(hair, "Head", (-0.24, 0.9, 0.1), (0.1, 0.17, 0.12), rot=(0, 0, 8))
    b.cone(hair, "Head", (0.14, 1.28, -0.02), 0.07, 0.2, rot=(0, 0, -20))
    b.cone(hair, "Head", (-0.05, 1.3, -0.06), 0.07, 0.22, rot=(-12, 0, 5))
    b.cone(hair, "Head", (-0.2, 1.2, -0.05), 0.065, 0.2, rot=(0, 0, 28))
    b.cone(hair, "Head", (0.0, 1.05, -0.3), 0.08, 0.22, rot=(-70, 0, 0))
    b.cone(hair, "Head", (0.17, 1.0, -0.26), 0.07, 0.2, rot=(-65, 0, -25))
    b.blob(hair, "Head", (0, 0.93, -0.12), (0.31, 0.21, 0.2))
    for sign in (1, -1):
        b.blob(skin, "Head", (sign * 0.3, 0.93, 0), (0.04, 0.06, 0.035))
    # the visible eye gets heavy eyeliner, the other one hides behind the fringe
    b.blob(liner, "Head", (0.12, 0.965, 0.247), (0.11, 0.125, 0.03))
    b.blob(white, "Head", (0.12, 0.965, 0.262), (0.085, 0.1, 0.03))
    b.blob(black, "Head", (0.12, 0.95, 0.284), (0.05, 0.06, 0.022))
    b.block(hair, "Head", (0.12, 1.07, 0.262), (0.065, 0.014, 0.012), rot=(0, 0, 12))
    b.blob(skin_dark, "Head", (0, 0.89, 0.275), (0.03, 0.035, 0.035))
    b.block(mouth, "Head", (0.01, 0.81, 0.262), (0.06, 0.01, 0.01), rot=(0, 0, -8))
    return b, anim_set(), "Emo"


def build_joy(folder):
    blue = swatch("blue", hexc("#1fa9ff"))
    blue_dark = swatch("blue_dark", hexc("#1678c4"))
    red = swatch("red", hexc("#ff3b4a"))
    red_dark = swatch("red_dark", hexc("#c42433"))
    dark = swatch("dark", hexc("#2a2f3a"))
    gray = swatch("gray", hexc("#aeb6c6"))
    white = swatch("white", hexc("#f6f6f6"))
    black = swatch("black", hexc("#141418"))
    mouth = swatch("mouth", hexc("#5a1020"))
    pink = swatch("pink", hexc("#ff9aa8"))
    yellow = swatch("yellow", hexc("#ffd21f"))
    green = swatch("green", hexc("#3fd36a"))
    cyan = swatch("cyan", hexc("#5fe3f0"))
    pal = [blue, blue_dark, red, red_dark, dark, gray, white, black, mouth, pink, yellow, green, cyan]
    b = Builder("Joy", 0.92, pal)
    standard_bones(b, 0.3, 0.3, 0.5, 0.1, 0.6)

    # the whole controller is body and head in one: a blue half and a red half
    b.block(blue, "Head", (-0.12, 0.6, 0), (0.12, 0.37, 0.1), bevel=0.07, smooth=True)
    b.block(red, "Head", (0.12, 0.6, 0), (0.12, 0.37, 0.1), bevel=0.07, smooth=True)
    b.block(blue_dark, "Head", (-0.2, 0.6, -0.01), (0.04, 0.3, 0.08), bevel=0.02)
    b.block(red_dark, "Head", (0.2, 0.6, -0.01), (0.04, 0.3, 0.08), bevel=0.02)
    b.block(dark, "Head", (0, 0.6, 0.097), (0.007, 0.34, 0.006))
    for sign in (1, -1):
        b.block(dark, "Head", (sign * 0.12, 0.985, 0), (0.07, 0.02, 0.08), bevel=0.01)     # shoulder buttons
    # face
    for sign in (1, -1):
        b.blob(white, "Head", (sign * 0.1, 0.8, 0.093), (0.075, 0.09, 0.03))
        b.blob(black, "Head", (sign * 0.1, 0.79, 0.12), (0.04, 0.052, 0.022))
        b.blob(pink, "Head", (sign * 0.16, 0.68, 0.098), (0.04, 0.022, 0.012))
    b.block(mouth, "Head", (0, 0.68, 0.1), (0.055, 0.012, 0.01))
    b.block(mouth, "Head", (-0.062, 0.692, 0.1), (0.012, 0.016, 0.01), rot=(0, 0, -25))
    b.block(mouth, "Head", (0.062, 0.692, 0.1), (0.012, 0.016, 0.01), rot=(0, 0, 25))
    # thumb stick on the blue side, four buttons on the red side
    b.cone(dark, "Head", (-0.12, 0.47, 0.105), 0.062, 0.03, rot=(90, 0, 0))
    b.blob(gray, "Head", (-0.12, 0.47, 0.13), (0.045, 0.045, 0.028))
    for dx, dy, col in ((0.0, 0.055, yellow), (0.0, -0.055, green), (0.055, 0.0, cyan), (-0.055, 0.0, pink)):
        b.blob(col, "Head", (0.12 + dx, 0.47 + dy, 0.108), (0.03, 0.03, 0.018))
    b.block(dark, "Head", (-0.12, 0.33, 0.097), (0.04, 0.008, 0.006))
    b.block(dark, "Head", (0.12, 0.33, 0.097), (0.04, 0.008, 0.006))
    # sync lights on the side
    for i in range(4):
        b.blob(cyan if i < 2 else white, "Head", (-0.241, 0.78 - i * 0.07, 0.0), (0.012, 0.022, 0.022))

    for s_, sign in (("L", 1), ("R", -1)):
        b.blob(dark, "Leg" + s_, (sign * 0.1, 0.17, 0), (0.055, 0.13, 0.058))
        b.blob(white, "Leg" + s_, (sign * 0.1, 0.045, 0.04), (0.085, 0.05, 0.13))
        b.block(blue if sign > 0 else red, "Leg" + s_, (sign * 0.1, 0.05, 0.1), (0.075, 0.015, 0.03), smooth=True, bevel=0.01)
        b.blob(dark, "Arm" + s_, (sign * 0.32, 0.43, 0), (0.05, 0.12, 0.05))
        b.blob(white, "Arm" + s_, (sign * 0.32, 0.29, 0), (0.07, 0.07, 0.07))
    return b, anim_set(), "Joy"


# ---------------------------------------------------------------- main

def export(builder_fn):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    probe = builder_fn.__name__
    # the palette must exist on disk before the material loads it
    b, anims, char_name = builder_fn(OUT)
    folder = os.path.join(OUT, char_name)
    os.makedirs(folder, exist_ok=True)
    write_palette(os.path.join(folder, "palette.png"), b.palette)
    arm, body = b.finish(anims, folder)
    bpy.ops.object.select_all(action="DESELECT")
    arm.select_set(True)
    body.select_set(True)
    path = os.path.join(folder, char_name.lower() + ".glb")
    bpy.ops.export_scene.gltf(
        filepath=path, export_format="GLB", use_selection=True, export_apply=False,
        export_yup=True, export_skins=True, export_materials="EXPORT", export_image_format="NONE",
        export_animations=True, export_animation_mode="NLA_TRACKS",
        export_optimize_animation_size=False, export_force_sampling=True)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(folder, char_name.lower() + ".blend"))
    print("EXPORTED", path, "height", max(v.co.z for v in body.data.vertices))


ONLY = [n for n in os.environ.get("ONLY", "").split(",") if n]
for fn in (build_bolt, build_kit, build_mushi, build_businessman, build_timber, build_emo, build_joy):
    if ONLY and fn.__name__.replace("build_", "") not in [n.lower() for n in ONLY]:
        continue
    export(fn)

"""Builds the landmark props of the Retro Valley board (houses, castle, graveyard, ...).

    python build_props.py <output dir>

Writes <out>/<Name>.glb for every prop and <out>/palette.png. All props share one
palette texture and one material called "Props"; the Godot import settings point that
name at a toon material with an outline (see build_props_all.py).

The props face +Z in Godot (-Y in Blender). Positions are written as (x, up, front).
"""
import math
import os
import sys

import bpy  # must come before bmesh and mathutils
import bmesh
import mathutils
from PIL import Image

OUT = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else sys.argv[1]
os.makedirs(OUT, exist_ok=True)

PALETTE = {
    "cream": "#f2e3c0", "cream_dark": "#d9c79b", "roof_red": "#c8452f", "brown": "#7a4a28", "brown_dark": "#54301a",
    "wood": "#b9803f", "wood_light": "#d9a55f", "stone": "#a8a69c", "stone_dark": "#7c7a72", "stone_light": "#c8c6bb",
    "white": "#f4f4f4", "black": "#1a1a1f", "red": "#d12b2b", "window": "#7ec8e8", "blue": "#3b6fb8",
    "yellow": "#f2c230", "green": "#4f9a3a", "green_dark": "#2f6d2a", "orange": "#ee8a2a", "pink": "#e68fa6",
    "snow": "#f2f6ff", "ice": "#a9dcec", "hay": "#e6c25a", "hay_dark": "#c79b35", "water": "#4aa3c9",
    "dirt": "#8a6a48", "grave": "#9a9a96", "moss": "#6f8f4a", "thatch": "#d8b45a", "thatch_dark": "#b78f3a",
    "purple": "#7a2fa8", "dark_red": "#8c2a22", "dark_green": "#1f4d2a", "barn_red": "#b5382c", "metal": "#8a929c",
}
NAMES = list(PALETTE)


def write_palette(path):
    img = Image.new("RGBA", (256, 256), (255, 255, 255, 255))
    for i, name in enumerate(NAMES):
        h = PALETTE[name].lstrip("#")
        rgb = tuple(int(h[k:k + 2], 16) for k in (0, 2, 4)) + (255,)
        col, row = i % 8, i // 8
        for x in range(col * 32, col * 32 + 32):
            for y in range(row * 32, row * 32 + 32):
                img.putpixel((x, y), rgb)
    img.save(path)


class Prop:
    def __init__(self, name):
        self.name = name
        self.bm = bmesh.new()
        self.uv = self.bm.loops.layers.uv.verify()

    @staticmethod
    def v(x, up, front):
        return mathutils.Vector((x, -front, up))

    def _swatch(self, color):
        i = NAMES.index(color)
        return (i % 8 + 0.5) / 8.0, 1.0 - (i // 8 + 0.5) / 8.0

    def _add(self, part, color, smooth, alt=None, sectors=0, center=(0, 0)):
        mesh = bpy.data.meshes.new("part")
        part.to_mesh(mesh)
        part.free()
        first = len(self.bm.faces)
        self.bm.from_mesh(mesh)
        bpy.data.meshes.remove(mesh)
        self.bm.faces.ensure_lookup_table()
        for face in self.bm.faces[first:]:
            face.smooth = smooth
            c = color
            if alt and sectors:
                fc = face.calc_center_median()
                sector = int(((math.atan2(fc.y - center[1], fc.x - center[0]) + math.pi) / (2 * math.pi)) * sectors)
                c = color if sector % 2 == 0 else alt
            u, w = self._swatch(c)
            for loop in face.loops:
                loop[self.uv].uv = (u, w)

    def _place(self, bm, pos, size, rot, bevel=0.0):
        sx, sy, sz = size
        bmesh.ops.transform(bm, matrix=mathutils.Matrix.Diagonal((sx, sz, sy, 1.0)), verts=bm.verts)
        if bevel > 0:
            bmesh.ops.bevel(bm, geom=list(bm.verts) + list(bm.edges) + list(bm.faces), offset=bevel,
                            segments=2, affect="EDGES", profile=0.6)
        rx, ry, rz = (math.radians(a) for a in rot)
        bmesh.ops.transform(bm, matrix=mathutils.Euler((rx, -rz, ry), "XYZ").to_matrix().to_4x4(), verts=bm.verts)
        bmesh.ops.transform(bm, matrix=mathutils.Matrix.Translation(self.v(*pos)), verts=bm.verts)

    def blob(self, color, pos, size, rot=(0, 0, 0), smooth=True, alt=None, sectors=0, segs=18):
        bm = bmesh.new()
        bmesh.ops.create_uvsphere(bm, u_segments=segs, v_segments=max(6, segs // 2), radius=1.0)
        self._place(bm, pos, size, rot)
        self._add(bm, color, smooth, alt, sectors, center=(self.v(*pos).x, self.v(*pos).y))

    def block(self, color, pos, size, rot=(0, 0, 0), bevel=0.0, smooth=False):
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=2.0)
        self._place(bm, pos, size, rot, bevel)
        self._add(bm, color, smooth)

    def cone(self, color, pos, radius, depth, rot=(0, 0, 0), top=0.0, segs=16, smooth=True, alt=None, sectors=0,
             squash=(1, 1, 1), twist=0.0, section=(1.0, 1.0)):
        """Cone / cylinder along the up axis. squash scales (x, up, front) before rotating.
        twist turns it about its own axis first and section stretches its cross section;
        a gable roof is cone(..., segs=3, twist=90, section=(w, h), rot=(90, 0, 0)): the ridge runs front to back."""
        bm = bmesh.new()
        bmesh.ops.create_cone(bm, cap_ends=True, cap_tris=False, segments=segs, radius1=radius, radius2=top, depth=depth)
        if twist:
            bmesh.ops.rotate(bm, cent=(0, 0, 0), matrix=mathutils.Matrix.Rotation(math.radians(twist), 3, "Z"), verts=bm.verts)
        if section != (1.0, 1.0):
            bmesh.ops.transform(bm, matrix=mathutils.Matrix.Diagonal((section[0], section[1], 1.0, 1.0)), verts=bm.verts)
        self._place(bm, pos, squash, rot)
        self._add(bm, color, smooth, alt, sectors, center=(self.v(*pos).x, self.v(*pos).y))

    def finish(self, material):
        mesh = bpy.data.meshes.new(self.name)
        self.bm.to_mesh(mesh)
        self.bm.free()
        mesh.materials.append(material)
        obj = bpy.data.objects.new(self.name, mesh)
        bpy.context.collection.objects.link(obj)
        return obj


# ------------------------------------------------------------------ the props

def cottage(p):
    p.block("cream", (0, 2.2, 0), (3.0, 2.2, 2.5), bevel=0.12)
    p.block("brown_dark", (0, 0.2, 0), (3.15, 0.2, 2.65))                      # foundation
    p.cone("roof_red", (0, 5.2, 0), 4.9, 2.6, rot=(0, 45, 0), segs=4, smooth=False, squash=(1.12, 1, 0.95))
    p.block("brown", (0, 1.35, 2.52), (0.62, 1.15, 0.1))                        # door
    p.blob("yellow", (0.4, 1.35, 2.64), (0.07, 0.07, 0.05))
    for sx in (-1, 1):
        p.block("window", (sx * 1.85, 2.6, 2.52), (0.55, 0.55, 0.08))
        p.block("white", (sx * 1.85, 2.6, 2.56), (0.65, 0.07, 0.04))
        p.block("white", (sx * 1.85, 2.6, 2.56), (0.07, 0.65, 0.04))
    p.block("stone", (1.6, 5.3, -1.0), (0.4, 1.0, 0.4))                         # chimney
    p.block("stone_dark", (1.6, 6.4, -1.0), (0.5, 0.12, 0.5))
    p.block("stone_light", (0, 0.1, 3.2), (1.0, 0.1, 0.55))                     # step
    p.block("wood", (-3.2, 0.6, 0.5), (0.5, 0.6, 0.5))                          # crate beside the door


def barn(p):
    p.block("barn_red", (0, 2.6, 0), (4.5, 2.6, 3.6), bevel=0.1)
    p.cone("dark_red", (0, 6.3, 0), 5.0, 8.4, segs=3, twist=90, section=(1.12, 0.45), rot=(90, 0, 0), smooth=False)
    p.block("white", (0, 2.0, 3.65), (1.8, 2.0, 0.1))                           # big doors with a cross
    p.block("barn_red", (0, 2.0, 3.72), (1.6, 1.8, 0.06))
    p.block("white", (0, 2.0, 3.78), (1.65, 0.1, 0.04), rot=(0, 0, 51))
    p.block("white", (0, 2.0, 3.78), (1.65, 0.1, 0.04), rot=(0, 0, -51))
    p.block("hay", (0, 5.0, 3.7), (0.7, 0.55, 0.06))                            # loft hatch
    p.block("white", (-4.55, 2.6, 0), (0.06, 2.4, 3.3))                         # side trim


def windmill(p):
    p.cone("cream", (0, 3.8, 0), 2.6, 7.6, top=1.6, segs=14)
    p.cone("brown", (0, 8.3, 0), 2.1, 1.8, top=0.2, segs=14)
    p.block("brown_dark", (0, 1.0, 2.0), (0.8, 1.0, 0.2))
    p.block("window", (0, 5.0, 1.75), (0.45, 0.6, 0.12))
    p.blob("brown_dark", (0, 6.6, 2.0), (0.45, 0.45, 0.6))
    for a in (0, 90, 180, 270):
        p.block("wood_light", (0, 6.6, 2.5), (0.28, 3.8, 0.06), rot=(0, 0, a + 20))
        p.block("white", (0, 6.6, 2.55), (1.0, 3.2, 0.05), rot=(0, 0, a + 20), bevel=0.0)


def hay(p):
    p.cone("hay", (0, 1.0, 0), 1.1, 1.8, rot=(90, 0, 0), segs=14)
    p.cone("hay_dark", (0, 1.0, 0.92), 0.95, 0.06, rot=(90, 0, 0), segs=14)
    p.cone("hay_dark", (0, 1.0, -0.92), 0.95, 0.06, rot=(90, 0, 0), segs=14)
    p.block("brown", (0, 1.0, 0), (1.15, 0.05, 0.1))


def well(p):
    p.cone("stone", (0, 0.55, 0), 1.7, 1.1, segs=12, smooth=False)
    p.cone("stone_dark", (0, 1.15, 0), 1.75, 0.18, segs=12, smooth=False)
    p.cone("water", (0, 1.0, 0), 1.35, 0.1, segs=12)
    for sx in (-1, 1):
        p.block("brown", (sx * 1.5, 2.2, 0), (0.12, 1.2, 0.12))
    p.cone("roof_red", (0, 3.9, 0), 2.6, 1.5, rot=(0, 0, 0), segs=4, smooth=False, squash=(1.0, 1, 0.8))
    p.block("brown_dark", (0, 3.3, 0), (1.5, 0.08, 0.08))
    p.cone("wood", (0.6, 2.2, 0.0), 0.35, 0.5, segs=10)                         # bucket
    p.block("stone_light", (0, 0.05, 0), (2.0, 0.05, 2.0))


def stall(p):
    p.block("wood", (0, 0.85, 0), (1.6, 0.85, 0.9))
    p.block("wood_light", (0, 1.75, 0), (1.7, 0.08, 1.0))
    for sx in (-1, 1):
        for sz in (-1, 1):
            p.block("brown_dark", (sx * 1.55, 1.9, sz * 0.95), (0.08, 1.2, 0.08))
    for i in range(6):
        col = "red" if i % 2 == 0 else "white"
        p.block(col, (-1.35 + i * 0.54, 3.25, 0.2), (0.27, 0.06, 1.35), rot=(-22, 0, 0))
    for x, c in ((-1.0, "red"), (-0.3, "orange"), (0.4, "yellow"), (1.0, "green")):
        p.blob(c, (x, 2.0, 0.1), (0.25, 0.25, 0.25))


def lantern(p):
    p.cone("black", (0, 1.4, 0), 0.1, 2.8, top=0.07, segs=8)
    p.block("black", (0, 2.95, 0), (0.28, 0.06, 0.28))
    p.blob("yellow", (0, 3.25, 0), (0.22, 0.28, 0.22))
    p.cone("black", (0, 3.65, 0), 0.34, 0.25, top=0.04, segs=8)
    p.cone("stone_dark", (0, 0.1, 0), 0.3, 0.2, segs=8)


def signpost(p):
    p.block("brown", (0, 1.4, 0), (0.12, 1.4, 0.12))
    p.block("wood_light", (0.35, 2.4, 0.14), (0.8, 0.22, 0.04), bevel=0.02)
    p.block("wood_light", (-0.3, 1.8, 0.14), (0.7, 0.22, 0.04), rot=(0, 0, 0), bevel=0.02)
    p.block("red", (0.95, 2.4, 0.14), (0.14, 0.22, 0.045))
    p.block("blue", (-0.9, 1.8, 0.14), (0.14, 0.22, 0.045))


def dock(p):
    p.block("wood_light", (0, 1.05, 3.0), (1.8, 0.12, 6.0), bevel=0.02)
    for i in range(12):
        p.block("wood", (0, 1.2, -2.8 + i * 0.95), (1.82, 0.03, 0.4))
    for sx in (-1, 1):
        for z in (-2.5, 1.0, 4.5, 8.0):
            p.block("brown_dark", (sx * 1.7, 0.4, 3.0 + z - 3.0), (0.14, 1.2, 0.14))
    p.block("brown", (0, 1.4, 8.8), (0.3, 0.3, 0.3))


def lighthouse(p):
    for i, (c, r0, r1) in enumerate((("white", 2.6, 2.3), ("red", 2.3, 2.0), ("white", 2.0, 1.75), ("red", 1.75, 1.55))):
        p.cone(c, (0, 1.6 + i * 3.2, 0), r0, 3.2, top=r1, segs=16)
    p.cone("stone_dark", (0, 0.3, 0), 3.0, 0.6, top=2.8, segs=16)
    p.cone("black", (0, 14.0, 0), 2.1, 0.3, segs=16)
    p.cone("window", (0, 15.0, 0), 1.35, 1.7, segs=16)
    p.blob("yellow", (0, 15.0, 0), (0.7, 0.7, 0.7))
    p.cone("red", (0, 16.9, 0), 1.7, 1.6, top=0.1, segs=16)
    p.block("brown", (0, 1.2, 2.45), (0.6, 1.0, 0.15))


def castle(p):
    stone, dark = "stone", "stone_dark"
    p.block(stone, (0, 5.0, -1.0), (5.5, 5.0, 4.5), bevel=0.15)                    # keep
    p.block(dark, (0, 10.4, -1.0), (5.8, 0.4, 4.8))
    for x in (-5, -2.5, 0, 2.5, 5):
        p.block(stone, (x, 11.2, 3.6), (0.7, 0.55, 0.7))
        p.block(stone, (x, 11.2, -5.6), (0.7, 0.55, 0.7))
    p.cone("blue", (0, 13.6, -1.0), 4.4, 4.4, top=0.1, segs=4, rot=(0, 45, 0), smooth=False)
    # walls and corner towers
    half = 12.0
    for sx in (-1, 1):
        for sz in (-1, 1):
            tx, tz = sx * half, sz * half
            p.cone(stone, (tx, 5.5, tz), 2.6, 11.0, top=2.4, segs=14)
            p.cone(dark, (tx, 11.2, tz), 2.9, 0.5, segs=14)
            p.cone("roof_red", (tx, 14.0, tz), 3.1, 5.0, top=0.1, segs=14)
            p.block("window", (tx * 0.93, 7.5, tz * 0.93 + sz * 0.0), (0.4, 0.6, 0.4))
            p.cone("brown", (tx, 17.4, tz), 0.06, 1.8, segs=6)
            p.block("red", (tx + 0.55, 17.9, tz), (0.55, 0.3, 0.03))
    for sz in (-1, 1):
        wall_z = sz * half
        p.block(stone, (0, 3.2, wall_z), (half - 2.5, 3.2, 0.9), bevel=0.1)
        for i in range(-4, 5):
            p.block(stone, (i * 2.4, 6.9, wall_z), (0.7, 0.55, 0.9))
    for sx in (-1, 1):
        wall_x = sx * half
        p.block(stone, (wall_x, 3.2, 0), (0.9, 3.2, half - 2.5), bevel=0.1)
        for i in range(-4, 5):
            p.block(stone, (wall_x, 6.9, i * 2.4), (0.9, 0.55, 0.7))
    # gate in the front wall (front is +z)
    p.block(dark, (0, 2.6, half + 0.2), (2.4, 2.6, 1.0))
    p.block("black", (0, 2.0, half + 1.0), (1.5, 2.0, 0.1))
    p.cone("black", (0, 4.0, half + 1.0), 1.5, 0.1, rot=(90, 0, 0), segs=14)
    p.block("brown", (0, 2.0, half + 1.12), (1.4, 1.9, 0.05))
    p.block("stone_light", (0, 0.1, half + 3.2), (2.2, 0.1, 2.2))                 # path to the gate
    for sx in (-1, 1):
        p.block("red", (sx * 3.2, 5.4, half + 1.05), (0.5, 1.1, 0.04))


def cave(p):
    # a rock arch around a dark entrance
    p.blob("black", (0, 2.4, 0.2), (3.0, 3.0, 2.0))
    for sx, rz in ((-1, 6), (1, -6)):
        p.blob("stone_dark", (sx * 3.6, 2.8, -0.5), (1.9, 3.6, 2.3), rot=(0, 0, rz))
        p.blob("stone", (sx * 4.8, 1.2, 0.8), (1.6, 1.8, 1.8))
    p.blob("stone", (0, 6.0, -0.4), (4.4, 1.4, 2.2))
    p.blob("stone_dark", (-1.6, 6.9, -0.8), (2.0, 1.2, 1.6))
    p.blob("stone", (2.2, 6.6, -0.6), (1.8, 1.0, 1.6))
    p.blob("stone_dark", (0, 8.0, -2.0), (3.6, 2.4, 3.0))
    p.blob("stone", (-5.5, 0.9, 2.0), (1.3, 1.0, 1.2))
    p.blob("stone", (5.6, 0.8, 2.4), (1.1, 0.9, 1.1))
    p.block("wood", (-2.4, 2.0, 2.3), (0.15, 1.8, 0.15))                           # support beams
    p.block("wood", (2.4, 2.0, 2.3), (0.15, 1.8, 0.15))
    p.block("wood", (0, 3.9, 2.3), (2.6, 0.15, 0.15))


def tombstone(p):
    p.block("grave", (0, 0.8, 0), (0.55, 0.8, 0.14), bevel=0.04)
    p.blob("grave", (0, 1.6, 0), (0.55, 0.5, 0.14))
    p.block("stone_dark", (0, 1.1, 0.15), (0.25, 0.04, 0.02))
    p.block("stone_dark", (0, 0.9, 0.15), (0.3, 0.04, 0.02))
    p.blob("moss", (0, 0.1, 0.55), (0.7, 0.18, 1.1))


def cross(p):
    p.block("grave", (0, 1.0, 0), (0.14, 1.0, 0.12), bevel=0.02)
    p.block("grave", (0, 1.5, 0), (0.5, 0.13, 0.12), bevel=0.02)
    p.blob("moss", (0, 0.1, 0.5), (0.6, 0.18, 1.0))


def crypt(p):
    p.block("stone", (0, 1.6, 0), (3.0, 1.6, 2.8), bevel=0.1)
    p.cone("stone_dark", (0, 3.95, 0), 4.0, 6.4, segs=3, twist=90, section=(0.97, 0.38), rot=(90, 0, 0), smooth=False)
    p.block("black", (0, 1.4, 2.85), (1.0, 1.4, 0.1))
    p.cone("black", (0, 2.8, 2.85), 1.0, 0.1, rot=(90, 0, 0), segs=12)
    for sx in (-1, 1):
        p.cone("stone_light", (sx * 1.6, 1.4, 3.2), 0.28, 2.8, segs=10)
        p.block("stone_light", (sx * 1.6, 2.85, 3.2), (0.4, 0.1, 0.4))
    p.block("stone_light", (0, 0.1, 4.4), (1.6, 0.1, 1.4))
    p.cone("dark_green", (0, 6.1, 0), 0.04, 0.4, segs=6)


def beach_hut(p):
    p.block("wood_light", (0, 1.6, 0), (2.2, 1.6, 1.8), bevel=0.06)
    for i in range(5):
        p.block("wood", (-1.7 + i * 0.85, 1.6, 1.82), (0.04, 1.55, 0.02))
    p.cone("thatch", (0, 4.2, 0), 3.5, 2.2, top=0.1, segs=4, rot=(0, 45, 0), smooth=False, squash=(1.0, 1, 0.85))
    p.block("blue", (0, 1.3, 1.84), (0.55, 1.0, 0.06))
    p.block("window", (1.4, 2.0, 1.84), (0.4, 0.4, 0.06))
    p.block("red", (-1.4, 2.0, 1.84), (0.4, 0.4, 0.06))
    p.block("wood", (0, 0.2, 2.7), (1.2, 0.2, 0.9))


def umbrella(p):
    p.cone("white", (0, 1.7, 0), 0.07, 3.4, segs=8)
    p.cone("red", (0, 3.35, 0), 2.3, 0.9, top=0.05, segs=8, smooth=False, alt="white", sectors=8)
    p.blob("brown", (0.0, 3.85, 0), (0.1, 0.1, 0.1))
    p.block("blue", (1.9, 0.25, 0.3), (0.9, 0.12, 0.45), rot=(0, 0, 0))             # a towel


def igloo(p):
    p.blob("snow", (0, 0, 0), (3.6, 3.2, 3.6), segs=20)
    p.block("snow", (0, 1.0, 3.3), (1.4, 1.0, 1.6), bevel=0.2, smooth=True)
    p.block("black", (0, 0.9, 4.9), (0.95, 0.85, 0.1))
    p.cone("black", (0, 1.75, 4.9), 0.95, 0.1, rot=(90, 0, 0), segs=14)
    for i, (x, h) in enumerate(((-2.2, 1.2), (2.2, 1.2), (-1.6, 2.4), (1.6, 2.4), (0, 3.0))):
        p.block("ice", (x, h, 2.4 if abs(x) < 2.3 else 1.4), (0.4, 0.04, 0.2), rot=(0, 0, 0))


def snowman(p):
    p.blob("snow", (0, 0.7, 0), (0.85, 0.7, 0.85))
    p.blob("snow", (0, 1.7, 0), (0.62, 0.55, 0.62))
    p.blob("snow", (0, 2.5, 0), (0.45, 0.42, 0.45))
    for sx in (-1, 1):
        p.blob("black", (sx * 0.18, 2.6, 0.38), (0.06, 0.06, 0.04))
    p.cone("orange", (0, 2.45, 0.55), 0.09, 0.5, top=0.0, rot=(90, 0, 0), segs=8)
    p.block("red", (0, 2.1, 0.1), (0.5, 0.07, 0.45))
    p.block("red", (0.2, 1.8, 0.4), (0.09, 0.3, 0.05))
    p.cone("black", (0, 3.0, 0), 0.38, 0.45, top=0.34, segs=12)
    p.cone("black", (0, 2.82, 0), 0.6, 0.05, segs=12)
    for y in (1.8, 1.55, 1.3):
        p.blob("black", (0, y, 0.6), (0.06, 0.06, 0.04))
    for sx in (-1, 1):
        p.cone("brown", (sx * 0.95, 1.9, 0), 0.04, 1.2, segs=6, rot=(0, 0, sx * -55))


def portal(p):
    for sx in (-1, 1):
        p.cone("stone", (sx * 2.2, 2.4, 0), 0.65, 4.8, top=0.55, segs=10)
        p.cone("stone_light", (sx * 2.2, 0.15, 0), 0.9, 0.3, segs=10)
        p.blob("purple", (sx * 2.2, 5.0, 0), (0.55, 0.55, 0.55))
    p.block("stone", (0, 5.0, 0), (2.9, 0.5, 0.6), bevel=0.1)
    p.blob("stone_light", (0, 5.9, 0), (1.5, 0.6, 0.55))
    p.blob("purple", (0, 2.5, 0), (2.0, 2.4, 0.18))                              # the swirl
    p.blob("window", (0, 2.5, 0.12), (1.5, 1.8, 0.14))
    p.blob("white", (0, 2.5, 0.2), (0.7, 0.9, 0.1))
    p.cone("stone_dark", (0, 0.1, 0), 3.4, 0.2, segs=12)


def campfire(p):
    for a in range(0, 360, 45):
        r = math.radians(a)
        p.blob("stone_dark", (1.3 * math.sin(r), 0.25, 1.3 * math.cos(r)), (0.32, 0.25, 0.32))
    for a in (20, 100, 200):
        p.cone("brown", (0, 0.45, 0), 0.14, 1.5, rot=(0, a, 60), segs=8)
    p.cone("orange", (0, 0.9, 0), 0.55, 1.2, top=0.0, segs=8)
    p.cone("yellow", (0, 0.8, 0), 0.32, 0.8, top=0.0, segs=8)
    for a, x in ((0, 2.6), (120, -1.6)):
        p.cone("brown_dark", (x, 0.4, 1.2), 0.35, 2.2, rot=(0, 0, 90), segs=8)


def tent(p):
    p.cone("red", (0, 1.7, 0), 2.6, 3.4, segs=3, twist=90, section=(0.9, 0.78), rot=(90, 0, 0), smooth=False,
           alt="white", sectors=3)
    p.block("black", (0, 1.0, 2.55), (0.65, 1.0, 0.05))
    p.block("brown", (0, 0.15, 2.9), (1.0, 0.1, 0.5))
    p.cone("brown_dark", (0, 3.8, 0), 0.07, 1.0, segs=6)


def fountain(p):
    """The grand fountain in the middle of the village plaza (about 18 m across, 9 m high)."""
    p.cone("stone_light", (0, 0.12, 0), 9.4, 0.24, segs=32, smooth=False)                  # base step
    p.cone("stone", (0, 0.2, 0), 8.2, 0.4, segs=32, smooth=False)
    p.cone("stone", (0, 0.95, 0), 7.2, 1.3, top=7.0, segs=32, smooth=False, alt="stone_dark", sectors=16)
    p.cone("stone_light", (0, 1.65, 0), 7.5, 0.28, segs=32, smooth=False)                  # rim
    p.cone("water", (0, 1.62, 0), 6.9, 0.12, segs=32)
    for i in range(8):                                                                       # flower pots on the rim
        a = math.radians(i * 45 + 22.5)
        x, f = 7.5 * math.cos(a), 7.5 * math.sin(a)
        p.cone("stone_dark", (x, 2.0, f), 0.55, 0.5, top=0.45, segs=10)
        p.blob("green", (x, 2.35, f), (0.5, 0.35, 0.5))
        p.blob("pink" if i % 2 == 0 else "yellow", (x, 2.6, f), (0.25, 0.2, 0.25), segs=10)
    p.cone("stone", (0, 2.9, 0), 1.7, 2.6, top=1.2, segs=16)                                 # pedestal
    p.cone("stone_light", (0, 4.3, 0), 4.6, 0.3, segs=24, smooth=False)                      # middle basin
    p.cone("stone", (0, 3.95, 0), 4.3, 0.55, top=3.0, segs=24, smooth=False)
    p.cone("water", (0, 4.4, 0), 4.0, 0.1, segs=24)
    p.cone("stone", (0, 5.5, 0), 0.9, 2.1, top=0.55, segs=14)                                # column
    p.cone("stone_light", (0, 6.7, 0), 2.4, 0.25, segs=20, smooth=False)                     # top bowl
    p.cone("stone", (0, 6.45, 0), 2.1, 0.4, top=1.2, segs=20, smooth=False)
    p.cone("water", (0, 6.8, 0), 2.1, 0.08, segs=20)
    p.cone("stone", (0, 7.6, 0), 0.4, 1.5, top=0.25, segs=10)
    p.blob("yellow", (0, 8.6, 0), (0.95, 0.95, 0.95))                                        # golden orb
    p.cone("yellow", (0, 9.7, 0), 0.4, 1.4, top=0.02, segs=10)
    for i in range(8):                                                                       # water jets
        a = math.radians(i * 45)
        p.cone("ice", (1.3 * math.cos(a), 7.3, 1.3 * math.sin(a)), 0.1, 1.0, top=0.03, segs=6,
               rot=(0, 0, 0))
        p.blob("ice", (3.0 * math.cos(a), 4.9, 3.0 * math.sin(a)), (0.16, 0.5, 0.16), segs=8)
    for i in range(16):                                                                      # splashes in the big basin
        a = math.radians(i * 22.5 + 11)
        p.blob("white", (5.2 * math.cos(a), 1.85, 5.2 * math.sin(a)), (0.35, 0.12, 0.35), segs=8)


def town_hall(p):
    """A grand town hall with a clock tower and columns. Front is +z, about 34 m wide."""
    p.block("stone_dark", (0, 0.5, 0), (9.0, 0.5, 6.4))                                      # plinth
    p.block("cream", (0, 5.0, -0.5), (7.2, 4.0, 4.6), bevel=0.15)                            # main hall
    p.cone("roof_red", (0, 11.9, -0.5), 11.2, 4.6, segs=4, rot=(0, 45, 0), smooth=False, squash=(1.0, 1, 0.66))
    for sx in (-1, 1):                                                                       # wings
        p.block("cream", (sx * 12.0, 3.6, -0.5), (4.6, 2.6, 4.0), bevel=0.12)
        p.cone("roof_red", (sx * 12.0, 7.9, -0.5), 8.0, 3.0, segs=4, rot=(0, 45, 0), smooth=False, squash=(1.0, 1, 0.82))
        p.block("cream_dark", (sx * 16.7, 3.2, 1.6), (0.35, 3.2, 0.35))
        for k in (-2, 0, 2):
            p.block("window", (sx * 12.0 + k * 1.7, 3.9, 3.6), (0.6, 0.85, 0.08))
            p.block("white", (sx * 12.0 + k * 1.7, 3.9, 3.66), (0.7, 0.08, 0.04))
            p.block("white", (sx * 12.0 + k * 1.7, 3.9, 3.66), (0.08, 0.95, 0.04))
    # clock tower
    p.block("cream", (0, 17.0, -0.5), (2.9, 3.5, 2.9), bevel=0.1)
    p.block("stone_dark", (0, 20.7, -0.5), (3.2, 0.3, 3.2))
    p.cone("blue", (0, 25.2, -0.5), 4.3, 8.0, top=0.12, segs=4, rot=(0, 45, 0), smooth=False)
    p.blob("yellow", (0, 29.5, -0.5), (0.55, 0.55, 0.55))
    p.cone("brown", (0, 31.2, -0.5), 0.07, 3.0, segs=6)
    p.block("red", (0.9, 32.0, -0.5), (0.85, 0.5, 0.04))
    p.cone("white", (0, 17.4, 2.45), 2.0, 0.2, segs=24, rot=(90, 0, 0), smooth=False)       # clock face
    p.cone("black", (0, 17.4, 2.58), 2.1, 0.08, segs=24, rot=(90, 0, 0), smooth=False)
    p.cone("white", (0, 17.4, 2.62), 1.85, 0.08, segs=24, rot=(90, 0, 0), smooth=False)
    p.block("black", (0, 18.05, 2.7), (0.1, 0.75, 0.03))
    p.block("black", (0.4, 17.55, 2.7), (0.45, 0.09, 0.03), rot=(0, 0, -25))
    for i in range(12):
        a = math.radians(i * 30)
        p.block("black", (1.6 * math.sin(a), 17.4 + 1.6 * math.cos(a), 2.72), (0.07, 0.07, 0.02))
    for sx in (-1, 1):
        for sz in (-1, 1):
            p.cone("stone", (sx * 2.8, 21.7, sz * 2.3 - 0.5), 0.45, 1.8, top=0.3, segs=8)    # pinnacles
            p.cone("yellow", (sx * 2.8, 22.9, sz * 2.3 - 0.5), 0.35, 0.8, top=0.02, segs=8)
    # entrance: steps, columns, pediment
    p.block("stone_light", (0, 1.1, 6.6), (6.4, 0.12, 1.6))
    p.block("stone_light", (0, 0.9, 7.6), (6.6, 0.1, 1.0))
    for x in (-5.0, -1.7, 1.7, 5.0):
        p.cone("white", (x, 4.7, 6.0), 0.65, 7.0, top=0.55, segs=14)
        p.block("stone_light", (x, 1.35, 6.0), (0.85, 0.15, 0.85))
        p.block("stone_light", (x, 8.3, 6.0), (0.85, 0.15, 0.85))
        p.block("red", (x + 0.0, 5.4, 6.7), (0.28, 1.5, 0.03))
    p.block("stone_light", (0, 8.9, 5.8), (6.4, 0.45, 1.3))
    p.cone("cream_dark", (0, 9.9, 5.8), 9.6, 1.6, segs=4, rot=(0, 45, 0), smooth=False, squash=(1.0, 1, 0.2))
    p.cone("yellow", (0, 10.3, 6.7), 0.55, 0.12, segs=5, rot=(90, 0, 0), smooth=False)       # crest
    p.block("brown", (0, 3.0, 4.15), (1.4, 2.0, 0.12))                                       # doors
    p.block("brown_dark", (0, 3.0, 4.2), (0.06, 2.0, 0.05))
    p.cone("brown", (0, 5.0, 4.15), 1.4, 0.12, segs=14, rot=(90, 0, 0), smooth=False)
    for sx in (-1, 1):
        for k in (1, 2):
            p.block("window", (sx * k * 3.4 + sx * 1.6, 5.0, 4.12), (0.6, 1.1, 0.08))
            p.block("window", (sx * k * 3.4 + sx * 1.6, 8.2, 4.12), (0.6, 0.8, 0.08))
        p.cone("brown", (sx * 8.4, 4.0, 7.4), 0.07, 8.0, segs=6)                              # flag poles on the steps
        p.block("red", (sx * 8.4 + 0.75, 7.4, 7.4), (0.75, 0.5, 0.03))
        p.blob("yellow", (sx * 8.4, 8.1, 7.4), (0.14, 0.14, 0.14))


def arch(p):
    """A gate over a road, 11 m wide. The road runs through along the z axis."""
    for sx in (-1, 1):
        p.block("stone_dark", (sx * 4.8, 0.3, 0), (1.35, 0.3, 1.35))
        p.cone("stone", (sx * 4.8, 3.6, 0), 1.0, 6.6, top=0.85, segs=12)
        p.block("stone_light", (sx * 4.8, 7.1, 0), (1.3, 0.2, 1.3))
        p.cone("yellow", (sx * 4.8, 8.0, 0), 0.5, 1.6, top=0.02, segs=8)
        p.blob("yellow", (sx * 4.8, 7.55, 0), (0.45, 0.45, 0.45))
    p.block("stone", (0, 7.7, 0), (5.3, 0.55, 1.15), bevel=0.06)
    p.block("stone_dark", (0, 8.4, 0), (5.5, 0.18, 1.3))
    for i in range(-5, 6):
        p.block("stone", (i * 0.95, 8.9, 0), (0.33, 0.35, 0.9))
    p.cone("red", (0, 7.7, 1.2), 1.0, 0.1, segs=5, rot=(90, 0, 0), smooth=False)             # emblem
    p.blob("yellow", (0, 7.7, 1.3), (0.45, 0.45, 0.1))
    for sx in (-1, 1):                                                                       # banners
        p.block("red", (sx * 3.2, 5.9, 1.0), (0.55, 1.35, 0.04))
        p.block("yellow", (sx * 3.2, 4.4, 1.0), (0.55, 0.14, 0.05))


def flag(p):
    p.cone("stone", (0, 0.35, 0), 0.6, 0.7, top=0.45, segs=10)
    p.cone("brown", (0, 3.8, 0), 0.09, 6.2, top=0.06, segs=8)
    p.blob("yellow", (0, 6.95, 0), (0.17, 0.17, 0.17))
    p.block("red", (0.95, 6.0, 0), (0.95, 0.6, 0.03), rot=(0, 0, -4))
    p.block("yellow", (0.95, 6.0, 0.04), (0.95, 0.12, 0.02), rot=(0, 0, -4))
    p.blob("yellow", (0.5, 6.0, 0.05), (0.22, 0.22, 0.03), segs=10)


def statue(p):
    """A golden statue of a businessman on a stone pedestal."""
    p.cone("stone_dark", (0, 0.25, 0), 2.1, 0.5, top=1.9, segs=4, rot=(0, 45, 0), smooth=False)
    p.block("stone", (0, 1.4, 0), (1.35, 0.9, 1.35), bevel=0.06)
    p.block("stone_light", (0, 2.4, 0), (1.55, 0.13, 1.55))
    p.block("yellow", (-0.28, 3.3, 0), (0.22, 0.85, 0.25), bevel=0.04)                       # legs
    p.block("yellow", (0.28, 3.3, 0), (0.22, 0.85, 0.25), bevel=0.04)
    p.block("yellow", (0, 5.0, 0), (0.6, 0.95, 0.3), bevel=0.08)                             # torso
    p.block("hay_dark", (0, 4.5, 0.28), (0.07, 0.65, 0.03))                                  # tie
    p.blob("yellow", (0, 6.35, 0), (0.38, 0.42, 0.38))                                       # head
    p.cone("hay_dark", (0, 6.75, 0), 0.5, 0.1, segs=14)                                      # hat
    p.cone("hay_dark", (0, 7.0, 0), 0.34, 0.5, top=0.3, segs=14)
    p.block("yellow", (-0.86, 5.3, 0.0), (0.16, 0.7, 0.2), bevel=0.03)
    p.block("yellow", (0.88, 6.0, 0.2), (0.16, 0.6, 0.2), rot=(0, 0, 25), bevel=0.03)        # waving arm
    p.block("hay_dark", (-1.0, 4.35, 0.15), (0.34, 0.3, 0.14))                               # briefcase


def bench(p):
    """A park bench, about 2.4 m wide. The seat faces +z."""
    for sx in (-1, 1):
        p.block("stone_dark", (sx * 1.0, 0.35, 0), (0.14, 0.35, 0.5))                           # legs
        p.block("brown_dark", (sx * 1.2, 0.75, 0), (0.07, 0.07, 0.5))                           # arm rests
    p.block("wood_light", (0, 0.75, 0.1), (1.25, 0.07, 0.5), bevel=0.02)                        # seat
    p.block("wood", (0, 1.15, -0.4), (1.25, 0.2, 0.06), bevel=0.02, rot=(-8, 0, 0))             # back rest
    p.block("wood", (0, 1.5, -0.45), (1.25, 0.12, 0.06), bevel=0.02, rot=(-8, 0, 0))


def planter(p):
    """A round raised flower bed, about 3.6 m across."""
    p.cone("stone_light", (0, 0.2, 0), 1.9, 0.4, top=1.8, segs=18, smooth=False)
    p.cone("stone_dark", (0, 0.42, 0), 1.95, 0.08, segs=18, smooth=False)
    p.cone("dirt", (0, 0.45, 0), 1.65, 0.12, segs=18, smooth=False)
    p.blob("green", (0, 0.75, 0), (1.0, 0.5, 1.0))
    colors = ["pink", "yellow", "red", "white", "orange", "purple"]
    for i in range(14):
        a = math.radians(i * 360 / 14)
        r = 1.15 if i % 2 == 0 else 0.6
        p.blob("green_dark", (r * math.cos(a), 0.65, r * math.sin(a)), (0.32, 0.25, 0.32), segs=8)
        p.blob(colors[i % len(colors)], (r * math.cos(a), 0.92, r * math.sin(a)), (0.22, 0.2, 0.22), segs=8)
    p.blob("yellow", (0, 1.35, 0), (0.28, 0.28, 0.28), segs=10)


PROPS = dict(Cottage=cottage, Barn=barn, Windmill=windmill, Hay=hay, Well=well, Stall=stall, Lantern=lantern,
             Signpost=signpost, Dock=dock, Lighthouse=lighthouse, Castle=castle, Cave=cave, Tombstone=tombstone,
             Cross=cross, Crypt=crypt, BeachHut=beach_hut, Umbrella=umbrella, Igloo=igloo, Snowman=snowman, Portal=portal, Campfire=campfire, Tent=tent,
             Fountain=fountain, TownHall=town_hall, Arch=arch, Flag=flag, Statue=statue, Bench=bench, Planter=planter)


def export(name, fn):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    prop = Prop(name)
    fn(prop)
    mat = bpy.data.materials.new("Props")
    mat.use_nodes = True
    tex = mat.node_tree.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(os.path.join(OUT, "palette.png"))
    tex.interpolation = "Closest"
    mat.node_tree.links.new(tex.outputs["Color"], mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"])
    obj = prop.finish(mat)
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    path = os.path.join(OUT, name + ".glb")
    bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_selection=True, export_apply=True,
                              export_yup=True, export_materials="EXPORT", export_image_format="NONE")
    print("EXPORTED", name)


write_palette(os.path.join(OUT, "palette.png"))
for name, fn in PROPS.items():
    export(name, fn)

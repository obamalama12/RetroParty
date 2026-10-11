"""Draws layout.json on top of the terrain colours: python preview_layout.py <out dir> <png>."""
import json
import sys

import numpy as np
from PIL import Image, ImageDraw

out, png = sys.argv[1], sys.argv[2]
layout = json.load(open(out + "/layout.json"))
n = layout["n"]
nc = layout.get("nc", n)
colors_full = np.fromfile(out + "/colors.bin", dtype=np.uint8).reshape(nc, nc, 3)
colors = np.array(Image.fromarray(colors_full, "RGB").resize((n, n), Image.BILINEAR))
heights = np.fromfile(out + "/heights.bin", dtype="<f4").reshape(n, n)
img = Image.fromarray(colors, "RGB")
# simple hill shading so the relief is visible
gy, gx = np.gradient(heights)
shade = np.clip(1.0 + (gx - gy) * 0.5, 0.6, 1.4)
img = Image.fromarray(np.clip(colors * shade[..., None], 0, 255).astype(np.uint8), "RGB")
img = img.resize((n * 4, n * 4), Image.NEAREST)
d = ImageDraw.Draw(img)
S = 4 / layout["cell"]
half = layout["half"]
def px(x, z): return ((x + half) * S, (z + half) * S)
by_name = {nd["name"]: nd for nd in layout["nodes"]}
for nd in layout["nodes"]:
    for nx in nd["next"]:
        d.line([px(nd["pos"][0], nd["pos"][2]), px(*[by_name[nx]["pos"][i] for i in (0, 2)])], fill=(60, 40, 20), width=2)
cols = {0: (60, 140, 255), 1: (255, 60, 60), 2: (60, 220, 90), 3: (255, 220, 40), 4: (255, 255, 255), 5: (120, 0, 120), 6: (255, 140, 0), 7: (230, 60, 230)}
for nd in layout["nodes"]:
    x, y = px(nd["pos"][0], nd["pos"][2])
    r = 4 if not nd["cake"] else 7
    d.ellipse((x - r, y - r, x + r, y + r), fill=cols[nd["type"]], outline=(0, 0, 0))
for lm in layout["landmarks"]:
    x, y = px(lm["pos"][0], lm["pos"][2])
    d.rectangle((x - 3, y - 3, x + 3, y + 3), outline=(0, 0, 0))
for kind, items in layout["scatter"].items():
    for it in items[::3]:
        x, y = px(it[0], it[2])
        d.point((x, y), fill=(0, 0, 0))
img.save(png)

#!/usr/bin/env python3
"""Gives the character portraits a hand-drawn look: wobbly ink lines of changing thickness, colour that does not quite
line up with the ink, crayon grain in the colour.

    python tools/character_builder/handdrawn.py plugins/characters [common/scenes/board_logic/controller/icons/host.png]

Run it after draw_portraits.py, which draws the clean vector portraits (icon.png and splash.png). The result replaces
the pictures; draw_portraits.py makes the clean ones again. Needs numpy and pillow. Run tools/first_import.py after it.
"""
import os
import sys

import numpy as np
from PIL import Image, ImageFilter

INK = np.array([27, 20, 74], dtype=float)
rng = np.random.default_rng(64)


def smooth_noise(size, scale, seed_offset=0):
    """Smooth random numbers in -1..1; features are about `scale` pixels big."""
    r = np.random.default_rng(1000 + seed_offset)
    small = r.standard_normal((size // max(scale // 4, 1) + 3, size // max(scale // 4, 1) + 3))
    img = Image.fromarray(small.astype(np.float32), mode="F").resize((size, size), Image.BICUBIC)
    a = np.asarray(img)
    return a / (np.abs(a).max() + 1e-6)


def remap(layer, dx, dy):
    """Samples `layer` (h, w, c) at the displaced positions, bilinear."""
    h, w = layer.shape[:2]
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    sx = np.clip(xs + dx, 0, w - 1.001)
    sy = np.clip(ys + dy, 0, h - 1.001)
    x0 = sx.astype(int)
    y0 = sy.astype(int)
    fx = (sx - x0)[..., None]
    fy = (sy - y0)[..., None]
    a = layer[y0, x0]
    b = layer[y0, x0 + 1]
    c = layer[y0 + 1, x0]
    d = layer[y0 + 1, x0 + 1]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def blur(arr2d, radius):
    img = Image.fromarray((np.clip(arr2d, 0, 1) * 255).astype(np.uint8))
    return np.asarray(img.filter(ImageFilter.GaussianBlur(radius))).astype(float) / 255.0


def handdraw(path, seed=0):
    src = Image.open(path).convert("RGBA")
    size = src.size[0]
    px = np.asarray(src).astype(float)
    alpha = px[..., 3] / 255.0
    rgb = px[..., :3]
    # ink = the dark outline colour, fill = everything else that is drawn
    ink_mask = (np.linalg.norm(rgb - INK, axis=-1) < 38) & (alpha > 0.5)
    fill_mask = (alpha > 0.5) & ~ink_mask

    # colour that continues under the ink lines, so the fill has no holes where the lines wobble away
    weight = fill_mask.astype(float)
    colour = rgb * weight[..., None]
    for radius in (3, 7, 14):
        num = np.stack([blur(colour[..., i] / 255.0, radius) for i in range(3)], axis=-1) * 255.0
        den = blur(weight, radius)[..., None] + 1e-4
        spread = num / den
        colour = np.where(fill_mask[..., None], colour, np.where(weight[..., None] > 0, colour, spread * (blur(weight, radius)[..., None] > 0.02)))
        weight = np.maximum(weight, (blur(weight, radius) > 0.02).astype(float))
    fill_alpha = np.maximum(blur(alpha, 4) > 0.1, fill_mask).astype(float)
    fill_alpha = np.where(ink_mask, np.maximum(fill_alpha, 0.0), fill_alpha)
    # the coloured area reaches under the lines
    fill_alpha = np.maximum(fill_alpha, blur(ink_mask.astype(float), 2) > 0.3)

    # two different wobbles: the ink and the colour drift apart a little, like a real drawing
    s = size / 512.0
    ink_dx = smooth_noise(size, 70, seed) * 3.2 * s + smooth_noise(size, 18, seed + 1) * 1.1 * s
    ink_dy = smooth_noise(size, 70, seed + 2) * 3.2 * s + smooth_noise(size, 18, seed + 3) * 1.1 * s
    fill_dx = smooth_noise(size, 90, seed + 4) * 3.0 * s + 3.0 * s
    fill_dy = smooth_noise(size, 90, seed + 5) * 3.0 * s + 2.5 * s

    ink = remap(ink_mask.astype(float)[..., None], ink_dx, ink_dy)[..., 0]
    fill_col = remap(np.concatenate([colour, fill_alpha[..., None] * 255.0], axis=-1), fill_dx, fill_dy)
    fill_a = fill_col[..., 3] / 255.0
    fill_rgb = fill_col[..., :3]

    # ink: the thickness changes along the line and the edge is a little ragged
    thickness = 0.78 + 0.16 * smooth_noise(size, 30, seed + 6) + 0.08 * smooth_noise(size, 8, seed + 7)
    ink_soft = blur(ink, 2.2 * s)
    ink_a = np.clip((ink_soft - (1.0 - thickness) * 0.62) * 4.5, 0, 1)
    ink_a = np.clip(ink_a + 0.10 * (smooth_noise(size, 5, seed + 8) > 0.55) * (ink_soft > 0.15), 0, 1)

    # crayon grain in the colour: fine speckle, a few paper-white gaps and soft cloudy shading
    grain = smooth_noise(size, 6, seed + 9)
    cloud = smooth_noise(size, 60, seed + 10)
    fill_rgb = fill_rgb * (1.0 + 0.045 * grain[..., None] + 0.05 * cloud[..., None])
    fill_a = fill_a * (1.0 - 0.10 * (smooth_noise(size, 4, seed + 11) > 0.78))
    fill_rgb = np.clip(fill_rgb, 0, 255)

    # compose: colour first, the ink on top
    out_a = np.clip(fill_a + ink_a * (1.0 - fill_a), 0, 1)
    out_rgb = (fill_rgb * (fill_a * (1.0 - ink_a))[..., None] + INK * ink_a[..., None]) / np.maximum(fill_a * (1.0 - ink_a) + ink_a, 1e-4)[..., None]
    out = np.concatenate([out_rgb, out_a[..., None] * 255.0], axis=-1)
    return Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGBA")


def main():
    root = sys.argv[1]
    names = sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d)) and os.path.exists(os.path.join(root, d, "icon.png")))
    for i, name in enumerate(names):
        for file in ("icon.png", "splash.png"):
            path = os.path.join(root, name, file)
            if os.path.exists(path):
                handdraw(path, seed=10 * i).save(path)
        print("hand drawn", name)
    for extra in sys.argv[2:]:
        handdraw(extra, seed=99).save(extra)
        print("hand drawn", extra)


if __name__ == "__main__":
    main()

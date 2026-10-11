#!/usr/bin/env python3
"""Makes plugins/boards/RetroValley/ground_detail.png, the tiling grain that is multiplied over the terrain colours.

    python tools/board_builder/make_ground_detail.py [output png]

Needs numpy and pillow. Random noise is smoothed in the frequency domain, so it tiles without seams.
"""
import os
import sys

import numpy as np
from PIL import Image

SIZE = 256
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "plugins", "boards", "RetroValley", "ground_detail.png")
rng = np.random.default_rng(7)


def band(cutoff):
    """Seamless noise in -1..1 with features about SIZE / cutoff pixels big."""
    spectrum = np.fft.fft2(rng.standard_normal((SIZE, SIZE)))
    fx = np.fft.fftfreq(SIZE)[:, None] * SIZE
    fz = np.fft.fftfreq(SIZE)[None, :] * SIZE
    spectrum *= np.exp(-(fx ** 2 + fz ** 2) / (2.0 * cutoff ** 2))
    n = np.real(np.fft.ifft2(spectrum))
    return n / np.abs(n).max()


v = 0.62 * band(5) + 0.30 * band(14) + 0.22 * band(40)
v /= np.abs(v).max()
img = 0.86 + 0.14 * v                                   # soft blotches, 0.72 .. 1.0

# short dark strokes like blades of grass and a few light specks, wrapped around the edges
for _ in range(1800):
    x, y = rng.integers(0, SIZE, 2)
    length = int(rng.integers(2, 5))
    shade = rng.uniform(0.62, 0.80)
    for k in range(length):
        img[(y - k) % SIZE, (x + k // 3) % SIZE] = min(img[(y - k) % SIZE, (x + k // 3) % SIZE], shade)
for _ in range(260):
    x, y = rng.integers(0, SIZE, 2)
    img[y, x] = 1.0

rgb = np.stack([img, img * 0.99, img * 0.96], axis=-1)   # a little warm
Image.fromarray((np.clip(rgb, 0, 1) * 255).astype("uint8")).save(OUT)
print("wrote", os.path.abspath(OUT))

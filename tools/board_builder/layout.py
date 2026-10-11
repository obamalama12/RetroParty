"""Designs the Retro Valley board: path network, terrain and scenery placement.

    python layout.py <output dir>

Writes layout.json (spaces, warps, scenery lists), heights.bin (float32 grid) and
colors.bin (uint8 RGB grid). build_board.gd turns those into the board scene.

Coordinates are metres. x points east, z points south, y is up. The map has eight
themed areas around a village in the middle:

    castle hill (NW)   lake with bridge (N)   rocky mountain (NE)
    forest + meadow (W)      village          graveyard (E)
    frozen corner (SW)      farm (S)          beach (SE)
"""
import json
import math
import os
import sys

import numpy as np

OUT = sys.argv[1] if len(sys.argv) > 1 else "out"
os.makedirs(OUT, exist_ok=True)
rng = np.random.default_rng(7)

CELL = 1.0                     # terrain grid spacing
HALF = 150.0                   # the terrain covers [-HALF, HALF] on x and z
N = int(2 * HALF / CELL) + 1
WATER_Y = 0.0
SPACING = 5.5                  # distance between spaces
LAND_H = 2.0

# ------------------------------------------------------------------ helpers


def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def value_noise(x, z, scale, seed):
    """Cheap smooth noise in [-1, 1] built from random lattice values."""
    r = np.random.default_rng(seed)
    size = int(2 * HALF / scale) + 4
    lat = r.uniform(-1, 1, (size, size))
    fx = (x + HALF) / scale
    fz = (z + HALF) / scale
    ix, iz = np.floor(fx).astype(int), np.floor(fz).astype(int)
    tx, tz = smooth(0, 1, fx - ix), smooth(0, 1, fz - iz)
    a, b = lat[iz, ix], lat[iz, ix + 1]
    c, d = lat[iz + 1, ix], lat[iz + 1, ix + 1]
    return (a * (1 - tx) + b * tx) * (1 - tz) + (c * (1 - tx) + d * tx) * tz


def catmull_rom(points, closed, samples_per_seg=40):
    pts = np.array(points, dtype=float)
    n = len(pts)
    out = []
    segs = n if closed else n - 1
    for i in range(segs):
        p0 = pts[(i - 1) % n] if (closed or i > 0) else pts[0]
        p1 = pts[i % n]
        p2 = pts[(i + 1) % n]
        p3 = pts[(i + 2) % n] if (closed or i + 2 < n) else pts[-1]
        for t in np.linspace(0, 1, samples_per_seg, endpoint=False):
            t2, t3 = t * t, t * t * t
            out.append(0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2
                              + (-p0 + 3 * p1 - 3 * p2 + p3) * t3))
    if not closed:
        out.append(pts[-1])
    return np.array(out)


def resample(dense, spacing, closed):
    """Evenly spaced points along a dense polyline (x, z, h)."""
    seg = np.linalg.norm(np.diff(dense[:, :2], axis=0, append=dense[:1, :2] if closed else dense[-1:, :2]), axis=1)
    cum = np.concatenate([[0], np.cumsum(seg)])
    total = cum[-1]
    count = max(2, int(round(total / spacing)))
    targets = np.linspace(0, total, count, endpoint=not closed)
    pts = np.stack([np.interp(targets, cum[:len(dense)], dense[:, k]) if len(cum) == len(dense) + 1
                    else np.interp(targets, cum, dense[:, k]) for k in range(3)], axis=1)
    return pts


# ------------------------------------------------------------------ the path network

AREAS = {
    "village": (0, 0), "lake": (0, -85), "mountain": (88, -62), "graveyard": (104, 26),
    "beach": (62, 78), "farm": (0, 88), "frozen": (-68, 72), "forest": (-90, -5), "castle": (-78, -89),
}

# (x, z, height) clockwise around the map. Spaces on x in BRIDGE_X at z = -85 are on the bridge.
RING = [
    (-50, -82, 2.0),
    (-36, -85, 2.3), (-18, -85, 2.6), (0, -85, 2.7), (18, -85, 2.6), (36, -85, 2.3),   # bridge
    (50, -84, 2.0), (62, -76, 2.3),
    (74, -88, 5.0), (90, -96, 8.0), (102, -84, 11.0), (90, -70, 13.0), (80, -58, 14.5),   # mountain climb
    (94, -46, 14.0), (106, -50, 11.0), (114, -38, 7.0), (110, -22, 4.0),
    (112, -6, 2.4), (124, 12, 2.4), (121, 32, 2.4), (107, 46, 2.3),                        # graveyard
    (98, 57, 2.3),
    (98, 68, 2.0), (86, 88, 1.8), (64, 100, 1.5), (42, 102, 1.6),                          # beach
    (22, 100, 2.2), (0, 106, 2.3), (-22, 102, 2.3),                                        # farm
    (-46, 94, 2.2), (-66, 102, 2.2), (-84, 90, 2.2), (-93, 68, 2.2), (-98, 50, 2.3),     # frozen corner
    (-106, 30, 2.4), (-112, 8, 2.6), (-102, -12, 3.0), (-112, -30, 3.2), (-104, -48, 3.6),  # forest + meadow
    (-96, -62, 4.5), (-91, -75, 7.0), (-92, -88, 9.5),                                      # castle hill
    (-88, -100, 10.0), (-72, -104, 10.0), (-62, -92, 10.0), (-64, -80, 9.5), (-58, -74, 6.5),
]
BRIDGE = (-38.0, 38.0)          # x range of the bridge at z = -85

# one-way shortcuts through the village: (name, waypoints, ring index they leave from / join)
ROADS = {
    "west_in": dict(points=[(-100, 6, 2.6), (-78, 4, 2.5), (-56, 2, 2.5), (-34, 1, 2.5)], leave_ring_near=(-106, 12)),
    "north_in": dict(points=[(-42, -72, 2.2), (-30, -56, 2.4), (-18, -40, 2.5), (-8, -26, 2.5)], leave_ring_near=(-50, -82)),
    "east_out": dict(points=[(14, 0, 2.5), (36, -2, 2.5), (62, 2, 2.5), (84, 6, 2.5), (104, -2, 2.4)], join_ring_near=(112, -6)),
    "south_out": dict(points=[(0, 14, 2.5), (0, 36, 2.5), (-1, 58, 2.4), (-2, 80, 2.4), (-2, 96, 2.3)], join_ring_near=(0, 106)),
}
LOOP_R = 24.0

nodes = []        # dicts: name, pos, kind, area
name_counter = [0]


def add_node(x, z, h, area, bridge=False, road=None):
    name_counter[0] += 1
    n = dict(name="N%03d" % name_counter[0], x=float(x), z=float(z), h=float(h), area=area,
             bridge=bridge, road=road, type=0, cake=False, hidden=False, next=[], prev=[])
    nodes.append(n)
    return n


def link(a, b):
    if b["name"] not in a["next"]:
        a["next"].append(b["name"])
    if a["name"] not in b["prev"]:
        b["prev"].append(a["name"])


def area_of(x, z):
    best, bd = "village", 1e9
    for name, (cx, cz) in AREAS.items():
        d = math.hypot(x - cx, z - cz) * (0.8 if name == "village" else 1.0)
        if d < bd:
            best, bd = name, d
    return best


# ring
dense = catmull_rom([(p[0], p[1], p[2]) for p in RING], closed=True)
ring_pts = resample(dense, SPACING, closed=True)
ring = []
for x, z, h in ring_pts:
    on_bridge = abs(z + 85) < 3.5 and BRIDGE[0] <= x <= BRIDGE[1]
    ring.append(add_node(x, z, h, area_of(x, z), bridge=on_bridge))
for i, n in enumerate(ring):
    link(n, ring[(i + 1) % len(ring)])

# village loop
count = 26
loop = []
for i in range(count):
    a = 2 * math.pi * i / count - math.pi / 2          # counter-clockwise from north, i.e. clockwise on screen
    loop.append(add_node(LOOP_R * math.cos(a), LOOP_R * math.sin(a), 2.5, "village", road="loop"))
for i, n in enumerate(loop):
    link(n, loop[(i + 1) % count])


def nearest(nodelist, x, z):
    return min(nodelist, key=lambda n: (n["x"] - x) ** 2 + (n["z"] - z) ** 2)


# roads: they run from one node of the ring to one node of the village loop (or the other way round), so
# the path is closed everywhere. The spline passes through the real end nodes and is cut into equal pieces.
gate = {"west_in": nearest(loop, -LOOP_R, 0), "north_in": nearest(loop, 0, -LOOP_R),
        "east_out": nearest(loop, LOOP_R, 0), "south_out": nearest(loop, 0, LOOP_R)}
road_chains = {}     # name -> [(x, z, h)] including both end nodes, used to paint and flatten the terrain
road_nodes = {}
for name, spec in ROADS.items():
    ring_end = nearest(ring, *spec["leave_ring_near" if name.endswith("_in") else "join_ring_near"])
    a, b = (ring_end, gate[name]) if name.endswith("_in") else (gate[name], ring_end)
    chain = [(a["x"], a["z"], a["h"])] + list(spec["points"]) + [(b["x"], b["z"], b["h"])]
    # the first and last waypoint may sit right next to the end nodes, so they are dropped when they are too close
    chain = [chain[0]] + [q for q in chain[1:-1] if math.hypot(q[0] - a["x"], q[1] - a["z"]) > 6 and math.hypot(q[0] - b["x"], q[1] - b["z"]) > 6
                         and math.hypot(q[0], q[1]) > LOOP_R + 7] + [chain[-1]]
    road_chains[name] = chain
    dense_ = catmull_rom(chain, closed=False)
    seg_ = np.hypot(np.diff(dense_[:, 0]), np.diff(dense_[:, 1]))
    arc_ = np.concatenate([[0.0], np.cumsum(seg_)])
    pieces = max(2, int(round(arc_[-1] / SPACING)))
    targets = np.linspace(0, arc_[-1], pieces + 1)[1:-1]
    road = []
    for t in targets:
        k = int(np.searchsorted(arc_, t))
        k = min(max(k, 1), len(arc_) - 1)
        f = (t - arc_[k - 1]) / max(arc_[k] - arc_[k - 1], 1e-9)
        x, z, h = dense_[k - 1] + (dense_[k] - dense_[k - 1]) * f
        road.append(add_node(x, z, h, area_of(x, z), road=name))
    road_nodes[name] = road
    chain_nodes = [a] + road + [b]
    for u, v in zip(chain_nodes, chain_nodes[1:]):
        link(u, v)

# start space (hidden) in the middle of the village, leads onto the loop
start = add_node(0, LOOP_R - 11.0, 2.5, "village", road="start")
start["hidden"] = True
start["name"] = "Start"
link(start, nearest(loop, 0, LOOP_R))

# types: 0 blue, 1 red, 2 green (warp), 3 yellow, 4 shop (unused, the shop is optional), 5 nolok, 6 gnu
visible = [n for n in nodes if not n["hidden"]]
for n in visible:
    r = rng.random()
    n["type"] = 0 if r < 0.62 else 1 if r < 0.82 else 3 if r < 0.9 else 5 if r < 0.95 else 6


def set_special(area, count_, kind, avoid_neighbours=True):
    pool = [n for n in visible if n["area"] == area and not n["bridge"] and n["type"] in (0, 1) and len(n["next"]) == 1]
    rng.shuffle(pool)
    done = 0
    for n in pool:
        if done >= count_:
            break
        near = [m for m in visible if m is not n and m["type"] in (2, 4) and math.hypot(m["x"] - n["x"], m["z"] - n["z"]) < 24]
        if near and avoid_neighbours:
            continue
        n["type"] = kind
        done += 1
    return done


for area in ("village", "farm", "beach", "castle", "graveyard"):
    set_special(area, 1, 7)

# warps: pairs of green spaces. The player is carried from one to the other.
WARPS = [("lake", "frozen"), ("forest", "castle"), ("mountain", "beach"), ("graveyard", "farm")]
warp_pairs = []
for a, b in WARPS:
    sa = set_special(a, 1, 2, avoid_neighbours=False)
    sb = set_special(b, 1, 2, avoid_neighbours=False)
greens = [n for n in visible if n["type"] == 2]
for area_a, area_b in WARPS:
    ga = [n for n in greens if n["area"] == area_a]
    gb = [n for n in greens if n["area"] == area_b]
    if ga and gb:
        warp_pairs.append((ga[0]["name"], gb[0]["name"]))

# event spaces ("?"): spread over the whole map, away from shops and warps
event_count = 0
pool = [n for n in visible if n["type"] in (0, 1) and not n["bridge"] and len(n["next"]) == 1]
rng.shuffle(pool)
for n in pool:
    if event_count >= 18:
        break
    near = [m for m in visible if m is not n and m["type"] in (2, 4, 7) and math.hypot(m["x"] - n["x"], m["z"] - n["z"]) < 26]
    if near:
        continue
    n["type"] = 7
    event_count += 1
print("event spaces", event_count)

# cake spots: spread over the areas
for area in ("lake", "mountain", "graveyard", "beach", "farm", "frozen", "forest", "castle", "village"):
    pool = [n for n in visible if n["area"] == area and n["type"] in (0, 1, 3) and not n["bridge"] and len(n["next"]) == 1]
    if pool:
        pool[len(pool) // 2]["cake"] = True
        pool[len(pool) // 2]["type"] = 0

# ------------------------------------------------------------------ portals next to the warp spaces
portal_sites = []
for n in visible:
    if n["type"] == 2 and n["next"]:
        nxt = next(m for m in nodes if m["name"] == n["next"][0])
        dx, dz = nxt["x"] - n["x"], nxt["z"] - n["z"]
        length = math.hypot(dx, dz) or 1.0
        px, pz = -dz / length, dx / length          # perpendicular, to the side of the path
        portal_sites.append((n["x"] + px * 5.0, n["z"] + pz * 5.0, n["x"], n["z"]))

# ------------------------------------------------------------------ terrain

gx = np.linspace(-HALF, HALF, N)
X, Z = np.meshgrid(gx, gx)          # X[iz, ix]


def dist_ellipse(cx, cz, rx, rz):
    return np.sqrt(((X - cx) / rx) ** 2 + ((Z - cz) / rz) ** 2)


# island mask
ang = np.arctan2(Z, X)
radius = np.sqrt((X / 1.05) ** 2 + (Z / 1.0) ** 2)
coast = 128 + 8 * np.sin(ang * 3 + 1.0) + 5 * np.sin(ang * 5 + 2.0) + 4 * value_noise(X, Z, 40, 3)
# the beach in the south-east reaches further out
coast += 12 * np.exp(-(((X - 70) / 45) ** 2 + ((Z - 100) / 35) ** 2))
land = smooth(coast + 14, coast - 6, radius)          # 1 on land, 0 at sea

height = LAND_H + 0.55 * value_noise(X, Z, 14, 11) + 0.3 * value_noise(X, Z, 5, 12)
# forest hills
forest_w = np.exp(-dist_ellipse(*AREAS["forest"], 38, 48) ** 2)
height += forest_w * (1.6 * value_noise(X, Z, 18, 13) + 0.6)
# graveyard mounds
gy_w = np.exp(-dist_ellipse(*AREAS["graveyard"], 30, 32) ** 2)
height += gy_w * 0.5 * value_noise(X, Z, 6, 14)
# mountain
mx, mz = AREAS["mountain"]
mdist = np.hypot(X - mx, Z - mz)
height += 13.5 * np.exp(-(mdist / 27.0) ** 2) + 3.0 * np.exp(-(mdist / 40.0) ** 2) * (0.5 + 0.5 * value_noise(X, Z, 9, 15))
# castle hill with a flat top
cx, cz = AREAS["castle"]
cdist = np.hypot(X - cx, Z - cz)
hill = 8.2 * smooth(36, 14, cdist)
height += hill
# lake
lake_d = dist_ellipse(*AREAS["lake"], 38, 22)
lake_w = smooth(1.12, 0.55, lake_d)
height = height * (1 - lake_w) + (-3.6 + 0.4 * value_noise(X, Z, 8, 16)) * lake_w
# beach slopes towards the sea
by, bz = AREAS["beach"]
beach_w = np.exp(-dist_ellipse(by, bz, 40, 34) ** 2)
height -= beach_w * 1.4 * smooth(0, 40, np.hypot(X - 45, Z - 60) - 15)
# the sea around the island
height = height * land + (-4.5) * (1 - land)
# flat village plateau
vd = np.hypot(X, Z)
village_w = smooth(62, 44, vd)
height = height * (1 - village_w) + 2.5 * village_w

# flatten along the path
path_points = []     # (x, z, h) of dense path samples
def densify(points, closed):
    dense_ = catmull_rom(points, closed=closed)
    seg = np.linalg.norm(np.diff(dense_[:, :2], axis=0), axis=1)
    out = [dense_[0]]
    for i in range(1, len(dense_)):
        out.append(dense_[i])
    return np.array(out)

ring_dense = densify([(p[0], p[1], p[2]) for p in RING], True)
for x, z, h in ring_dense:
    if abs(z + 85) < 4 and BRIDGE[0] - 6 <= x <= BRIDGE[1] + 6:
        continue
    path_points.append((x, z, h))
for name, chain in road_chains.items():
    for x, z, h in densify(chain, False):
        path_points.append((x, z, h))
for n in loop:
    pass
for i in range(count * 6):
    a = 2 * math.pi * i / (count * 6)
    path_points.append((LOOP_R * math.cos(a), LOOP_R * math.sin(a), 2.5))
pp = np.array(path_points)
# nearest path sample per cell, in chunks
dist_path = np.full(X.shape, 1e9)
path_h = np.zeros(X.shape)
flat_x, flat_z = X.ravel(), Z.ravel()
dp = dist_path.ravel(); ph = path_h.ravel()
for chunk in range(0, len(pp), 200):
    sub = pp[chunk:chunk + 200]
    d = np.hypot(flat_x[:, None] - sub[None, :, 0], flat_z[:, None] - sub[None, :, 1])
    k = d.argmin(axis=1)
    dm = d[np.arange(len(flat_x)), k]
    better = dm < dp
    dp[better] = dm[better]
    ph[better] = sub[k[better], 2]
dist_path = dp.reshape(X.shape); path_h = ph.reshape(X.shape)
flat_w = smooth(11.0, 3.2, dist_path)
height = height * (1 - flat_w) + (path_h - 0.05) * flat_w

# ------------------------------------------------------------------ colours
# Painted into a texture that is finer than the terrain grid (CELL / 3 per pixel), so the edges of the
# path and of the areas stay smooth.

TEX = 3
NC = (N - 1) * TEX + 1
fx_axis = np.linspace(-HALF, HALF, NC)
XF, ZF = np.meshgrid(fx_axis, fx_axis)


def upsample(a):
    """Bilinear upsampling of a coarse grid to the texture grid."""
    idx = np.linspace(0, N - 1, NC)
    i0 = np.clip(np.floor(idx).astype(int), 0, N - 2)
    t = idx - i0
    rows = a[i0, :] * (1 - t)[:, None] + a[i0 + 1, :] * t[:, None]
    return rows[:, i0] * (1 - t)[None, :] + rows[:, i0 + 1] * t[None, :]


hf = upsample(height)
lake_df = np.sqrt(((XF - AREAS["lake"][0]) / 38) ** 2 + ((ZF - AREAS["lake"][1]) / 22) ** 2)
lake_wf = smooth(1.12, 0.55, lake_df)
landf = upsample(land)
vdf = np.hypot(XF, ZF)
mdistf = np.hypot(XF - mx, ZF - mz)
cdistf = np.hypot(XF - cx, ZF - cz)


def dist_e(cx_, cz_, rx, rz):
    return np.sqrt(((XF - cx_) / rx) ** 2 + ((ZF - cz_) / rz) ** 2)


# distance to the nearest path sample at texture resolution
dist_pathf = np.full(XF.shape, 1e9).ravel()
fxf, fzf = XF.ravel(), ZF.ravel()
for chunk in range(0, len(pp), 12):
    sub = pp[chunk:chunk + 12]
    d = np.sqrt((fxf[:, None] - sub[None, :, 0]) ** 2 + (fzf[:, None] - sub[None, :, 1]) ** 2).min(axis=1)
    dist_pathf = np.minimum(dist_pathf, d)
dist_pathf = dist_pathf.reshape(XF.shape)


def noise_f(scale, seed):
    return value_noise(XF, ZF, scale, seed)


def col(hexstr):
    h = hexstr.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=float)

C = dict(grass=col("#6dbb3a"), grass_dark=col("#4c9a30"), meadow=col("#a6d94c"), forest=col("#3a8a2e"), needles=col("#6a7a34"),
         sand=col("#f0dc94"), sand_wet=col("#c9b377"), snow=col("#eef4fb"), snow_shade=col("#c7d9ee"), ice=col("#a9dcec"),
         rock=col("#8a857b"), rock_dark=col("#615c54"), dirt=col("#a67c52"), grave=col("#55584a"), grave_dark=col("#3d4036"),
         field=col("#8a5a34"), wheat=col("#e1c14e"), pasture=col("#83c944"), cobble=col("#b9b3a8"), cobble_dark=col("#9a948a"),
         lake=col("#3f87a0"), sea=col("#2f7ea0"))

n_fine = noise_f(3, 22)
n_mid = noise_f(9, 23)
color = np.zeros(XF.shape + (3,))
color[:] = C["grass"]
color += (noise_f(6, 21)[..., None] * 10)


def mix(mask, c):
    global color
    mask = np.clip(mask, 0, 1)[..., None]
    color = color * (1 - mask) + c[None, None, :] * mask


def area_mask(d, soft=0.14):
    """1 inside an area (normalised distance d < 1), a short soft edge, wobbly with noise."""
    return smooth(1.0 + soft + 0.12 * n_mid, 1.0 - soft + 0.12 * n_mid, d)


forest_m = area_mask(dist_e(*AREAS["forest"], 44, 56))
mix(forest_m * 0.95, C["forest"])
mix(forest_m * smooth(0.2, 0.6, n_fine) * 0.7, C["needles"])
meadow_m = area_mask(dist_e(-100, 16, 24, 26))
mix(meadow_m * 0.95, C["meadow"])
gy_m = area_mask(dist_e(*AREAS["graveyard"], 30, 32))
mix(gy_m * 0.97, C["grave"])
mix(gy_m * smooth(0.1, 0.5, n_fine) * 0.8, C["grave_dark"])
farm_m = area_mask(dist_e(*AREAS["farm"], 40, 26))
mix(farm_m * 0.9, C["pasture"])
fields = ((np.abs(XF - 0) < 30) & (np.abs(ZF - 80) < 13)).astype(float)
stripes = (np.sin(XF * 0.55) > 0.1)
mix(fields * np.where(stripes, 1.0, 0.0), C["field"])
mix(fields * np.where(stripes, 0.0, 1.0), C["wheat"])
frozen_m = area_mask(dist_e(*AREAS["frozen"], 36, 34))
mix(frozen_m * 0.98, C["snow"])
mix(frozen_m * smooth(0.1, 0.6, n_mid) * 0.7, C["snow_shade"])
mix(smooth(1.0, 0.8, dist_e(-68, 72, 10, 7)), C["ice"])
beach_m = area_mask(dist_e(*AREAS["beach"], 40, 34), soft=0.25)
mix(np.maximum(smooth(1.5, 0.8, hf) * (1 - lake_wf), beach_m) * landf, C["sand"])
mix(smooth(0.5, 0.0, hf) * (1 - lake_wf) * landf, C["sand_wet"])
mnt = np.exp(-(mdistf / 38.0) ** 2)
rock_amt = smooth(5.0, 8.0, hf + 1.2 * n_mid) * mnt
mix(rock_amt, C["rock"])
mix(rock_amt * smooth(0.0, 0.6, n_fine) * 0.7, C["rock_dark"])
mix(smooth(13.8, 15.2, hf) * mnt, C["snow"])
mix(smooth(34, 16, cdistf) * 0.35, C["grass_dark"])
mix(smooth(0.3, -1.5, hf) * lake_wf, C["lake"])
plaza = smooth(33, 24, vdf)
mix(plaza * 0.95, C["cobble"])
mix(plaza * smooth(0.0, 0.5, n_fine) * 0.6, C["cobble_dark"])
mix(smooth(2.5, 2.1, dist_pathf), C["dirt"])
mix(smooth(1.1, 0.0, dist_pathf) * 0.22, C["dirt"] * 0.82)
mix(smooth(-0.2, -2.5, hf), C["sea"])
color = np.clip(color, 0, 255)

# ------------------------------------------------------------------ scenery

def height_at(x, z):
    fx = (x + HALF) / CELL
    fz = (z + HALF) / CELL
    ix = int(np.clip(math.floor(fx), 0, N - 2)); iz = int(np.clip(math.floor(fz), 0, N - 2))
    tx, tz = fx - ix, fz - iz
    h = height
    return float((h[iz, ix] * (1 - tx) + h[iz, ix + 1] * tx) * (1 - tz) + (h[iz + 1, ix] * (1 - tx) + h[iz + 1, ix + 1] * tx) * tz)


def slope_at(x, z):
    return math.hypot(height_at(x + 1, z) - height_at(x - 1, z), height_at(x, z + 1) - height_at(x, z - 1)) / 2.0


node_xz = np.array([[n["x"], n["z"]] for n in nodes])
path_dense_xz = pp[:, :2]
placed = []            # (x, z, radius) of everything already placed, to avoid overlaps


def free(x, z, r, min_path=3.2):
    if np.min(np.hypot(path_dense_xz[:, 0] - x, path_dense_xz[:, 1] - z)) < min_path + r:
        return False
    for px, pz, pr in placed:
        if (px - x) ** 2 + (pz - z) ** 2 < (pr + r) ** 2:
            return False
    return True


scatter = {}


def scatter_area(kinds, center, radii, count_, rmin, rmax, h_min=0.9, h_max=99, scale=(0.9, 1.3), max_slope=0.9,
                 min_path=3.2, clump=None):
    """Random placement of props on land inside an ellipse. kinds: list of prop names (chosen at random)."""
    cx_, cz_ = center
    rx, rz = radii
    tries, made = 0, 0
    while made < count_ and tries < count_ * 40:
        tries += 1
        a = rng.uniform(0, 2 * math.pi)
        rr = math.sqrt(rng.uniform(0, 1))
        x, z = cx_ + math.cos(a) * rr * rx, cz_ + math.sin(a) * rr * rz
        if abs(x) > HALF - 4 or abs(z) > HALF - 4:
            continue
        h = height_at(x, z)
        if h < h_min or h > h_max or slope_at(x, z) > max_slope:
            continue
        s = rng.uniform(*scale)
        r = rmin + (rmax - rmin) * (s - scale[0]) / max(1e-6, scale[1] - scale[0])
        if not free(x, z, r, min_path):
            continue
        kind = kinds[int(rng.integers(len(kinds)))]
        scatter.setdefault(kind, []).append([x, h - 0.05, z, float(rng.uniform(0, 360)), s])
        placed.append((x, z, r))
        made += 1


def tree_kinds(prefix, n=5):
    return ["%s_%d" % (prefix, i) for i in range(1, n + 1)]


landmarks = []         # custom props: kind, x, z, rot, scale


def landmark(kind, x, z, rot=0.0, scale=1.0, radius=3.0, y=None):
    landmarks.append(dict(kind=kind, pos=[x, height_at(x, z) if y is None else y, z], rot=rot, scale=scale))
    placed.append((x, z, radius))


# village: a grand plaza. Fountain in the middle, arches over the four roads, town hall, statues, flags,
# a ring of cottages and market stalls around it
landmark("Fountain", 0, 0, radius=11)
for name, road in road_nodes.items():                       # an arch over each road, a little way out of the plaza
    n0, n1 = (road[-3], road[-2]) if name.endswith("_in") else (road[2], road[3])
    landmark("Arch", n0["x"], n0["z"], rot=math.degrees(math.atan2(n1["x"] - n0["x"], n1["z"] - n0["z"])), radius=6)
landmark("TownHall", 38, -40, rot=math.degrees(math.atan2(-38, 40)), radius=22)
for sx, sz in [(30, 31), (-31, 30), (-30, -31)]:
    landmark("Statue", sx, sz, rot=math.degrees(math.atan2(-sx, -sz)), scale=1.7, radius=5)
for i in range(16):                                         # flags just inside the loop
    a = math.radians(i * 22.5 + 11.25)
    fx, fz = (LOOP_R - 4.5) * math.cos(a), (LOOP_R - 4.5) * math.sin(a)
    if math.hypot(fx, fz - (LOOP_R - 11.0)) > 5:
        landmark("Flag", fx, fz, rot=0, radius=1.2)
for i in range(26):                                         # lanterns along the outside of the loop
    a = math.radians(i * 360 / 26 + 6.9)
    landmark("Lantern", (LOOP_R + 3.2) * math.cos(a), (LOOP_R + 3.2) * math.sin(a), radius=1)
for x, z, rot in [(-15, 12, 20), (15, 12, -20), (12, -14, 160), (-12, -14, 200)]:
    landmark("Stall", x, z, rot=rot, radius=3)
for ang in (18, 62, 118, 162, 198, 248, 292, 342):          # a bench facing the fountain with a flower bed behind it
    a = math.radians(ang)
    bx, bz = 15.0 * math.cos(a), 15.0 * math.sin(a)
    landmark("Bench", bx, bz, rot=math.degrees(math.atan2(-bx, -bz)), radius=2)
    landmark("Planter", 18.8 * math.cos(a), 18.8 * math.sin(a), rot=0, radius=2.2)
for i in range(14):                                         # cottages in a wide ring
    a = math.radians(i * 360 / 14 + 8)
    hx, hz = 46 * math.cos(a), 46 * math.sin(a)
    if free(hx, hz, 5.5, min_path=3.5):
        landmark("Cottage", hx, hz, rot=math.degrees(math.atan2(-hx, -hz)), scale=1.0 + 0.08 * (i % 3), radius=6)

# farm: barn, windmill, hay, fenced fields
landmark("Barn", -26, 78, rot=90, radius=9)
landmark("Windmill", 30, 72, rot=-30, radius=7)
for hx, hz in [(-12, 96), (-8, 97), (14, 96), (18, 94), (-22, 66), (24, 98), (-30, 94)]:
    landmark("Hay", hx, hz, rot=float(rng.uniform(0, 360)), radius=2.2)
for hx, hz, rot in [(-34, 92, 20), (36, 88, -70), (-36, 56, 180)]:
    landmark("Cottage", hx, hz, rot=rot, radius=6)

# lake: dock with boats at the north shore, reeds
landmark("Dock", 20, -63, rot=180, radius=6)
landmark("Dock", -22, -107, rot=0, radius=6)
for bx, bz, rot in [(-14, -96, 30), (10, -100, -50), (30, -100, 70)]:
    landmark("BoatProp", bx, bz, rot=rot, radius=4, y=0.0)
landmark("Lighthouse", 38, -115, rot=0, radius=5)

# castle on the hill
landmark("Castle", cx, cz, rot=0, scale=0.65, radius=12)
# mountain: cave entrance
landmark("Cave", 56, -98, rot=29, radius=8)

# graveyard
gxc, gzc = AREAS["graveyard"]
for i in range(34):
    a = rng.uniform(0, 2 * math.pi); rr = math.sqrt(rng.uniform(0.05, 1)) * 15
    x, z = gxc + math.cos(a) * rr * 0.9, gzc + math.sin(a) * rr * 1.5
    if free(x, z, 1.5):
        landmark("Tombstone" if rng.random() < 0.7 else "Cross", x, z, rot=float(rng.uniform(-25, 25)) + 180, scale=float(rng.uniform(0.9, 1.3)), radius=1.5)
landmark("Crypt", gxc - 6, gzc - 16, rot=200, radius=7)
for lx, lz in [(gxc - 14, gzc - 4), (gxc + 8, gzc + 2), (gxc - 6, gzc + 20), (gxc + 6, gzc - 22)]:
    landmark("Lantern", lx, lz, radius=1)

# beach: huts, umbrellas, a boat on the sand
landmark("BeachHut", 58, 84, rot=200, radius=5)
for ux, uz, rot in [(72, 90, 10), (66, 80, 70), (48, 92, 120), (78, 72, 40)]:
    landmark("Umbrella", ux, uz, rot=rot, radius=2.5)
landmark("BoatProp", 50, 113, rot=100, radius=4, y=0.0)

# frozen corner: igloo and snowmen
fx_, fz_ = AREAS["frozen"]
landmark("Igloo", fx_ - 6, fz_ - 12, rot=40, radius=6)
for sx, sz in [(fx_ + 8, fz_ + 8), (fx_ - 18, fz_ + 6), (fx_ + 14, fz_ - 14), (fx_ - 4, fz_ + 18)]:
    landmark("Snowman", sx, sz, rot=float(rng.uniform(0, 360)), radius=2)

# forest: a camp with tents and a campfire
campx, campz = -88, -20
landmark("Campfire", campx, campz, radius=3)
for ang in (30, 150, 270):
    a = math.radians(ang)
    landmark("Tent", campx + 8 * math.sin(a), campz + 8 * math.cos(a), rot=ang + 180, radius=4)

# signposts at the road junctions
for name, road in road_nodes.items():
    n_ = road[0] if name.endswith("_in") else road[-1]
    landmark("Signpost", n_["x"] + 3, n_["z"] + 3, rot=0, radius=1.5)

for x, z, tx, tz in portal_sites:
    landmark("Portal", x, z, rot=math.degrees(math.atan2(tx - x, tz - z)), radius=3)

# landmarks that sit too close to the path are reported, so their position can be adjusted
for lm in landmarks:
    d = float(np.min(np.hypot(path_dense_xz[:, 0] - lm["pos"][0], path_dense_xz[:, 1] - lm["pos"][2])))
    if d < 3.0 and lm["kind"] not in ("Lantern", "Signpost", "Stall", "Hay", "Tombstone", "Cross", "Snowman", "Umbrella", "Portal", "Arch", "Flag"):
        print("WARNING landmark close to the path:", lm["kind"], [round(v, 1) for v in lm["pos"]], round(d, 1))

# trees and plants (nature models from assets/models/nature)
scatter_area(tree_kinds("PineTree"), (-90, -5), (46, 62), 120, 1.6, 2.6, scale=(0.9, 1.5))
scatter_area(tree_kinds("BirchTree"), (-92, -10), (40, 55), 70, 1.4, 2.2, scale=(0.9, 1.4))
scatter_area(tree_kinds("MapleTree"), (-84, 0), (36, 52), 50, 2.2, 3.4, scale=(0.9, 1.3))
scatter_area(tree_kinds("NormalTree"), (-95, 10), (38, 48), 40, 1.8, 2.6, scale=(0.9, 1.3))
scatter_area(["Bush", "Bush_Large", "Bush_Small", "Bush_Flowers", "Bush_Large_Flowers"], (-95, 5), (46, 60), 90, 1.0, 1.6, scale=(0.8, 1.3))
scatter_area(["Flower_1_Clump", "Flower_2_Clump", "Flower_3_Clump", "Flower_4_Clump", "Flower_5_Clump", "Petals_1", "Petals_2"],
             (-100, 15), (24, 26), 200, 0.4, 0.6, scale=(1.4, 2.4), min_path=1.6)
scatter_area(["Grass_Large", "Grass_Small", "Plant_1", "Plant_Flowers"], (-90, -5), (46, 60), 220, 0.4, 0.8, scale=(1.5, 2.4), min_path=1.8)
scatter_area(["Rock_1", "Rock_2", "Rock_3", "Rock_4", "Rock_5"], (-90, -5), (44, 56), 30, 0.8, 1.6, scale=(1.5, 3.0))

# mountain: pines at the foot, rocks and dead trees higher up
scatter_area(tree_kinds("PineTree"), (88, -62), (44, 40), 60, 1.6, 2.4, h_max=7.5, scale=(0.9, 1.4))
scatter_area(["Rock_1", "Rock_2", "Rock_3", "Rock_4", "Rock_5"], (88, -62), (36, 32), 110, 0.8, 1.8, h_min=2.0, scale=(1.6, 4.2), max_slope=2.5)
scatter_area(tree_kinds("DeadTree"), (88, -62), (36, 34), 24, 1.2, 1.8, h_min=5, h_max=12, scale=(0.9, 1.3), max_slope=1.6)

# castle hill
scatter_area(tree_kinds("NormalTree"), (-82, -78), (44, 40), 26, 1.8, 2.4, h_max=7, scale=(0.9, 1.3))
scatter_area(["Bush", "Bush_Large", "Bush_Flowers"], (-82, -78), (40, 38), 40, 1.0, 1.4, scale=(0.9, 1.2))
scatter_area(["Flower_1_Clump", "Flower_2_Clump", "Flower_3_Clump", "Petals_1"], (-82, -78), (36, 34), 60, 0.4, 0.6, scale=(1.4, 2.2), min_path=1.6)

# graveyard: dead trees, dry plants
scatter_area(tree_kinds("DeadTree"), (104, 26), (26, 38), 36, 1.2, 1.8, scale=(0.9, 1.5))
scatter_area(["Grass_Small", "Plant_1", "Rock_1", "Rock_2"], (104, 26), (24, 36), 60, 0.4, 0.8, scale=(1.2, 2.0), min_path=1.8)

# beach: palms, rocks
scatter_area(tree_kinds("PalmTree"), (66, 84), (46, 36), 38, 1.8, 2.6, h_min=0.7, h_max=2.6, scale=(0.9, 1.3))
scatter_area(["Rock_1", "Rock_2", "Rock_3"], (66, 88), (44, 36), 20, 0.8, 1.2, h_min=0.5, scale=(1.5, 2.6))
scatter_area(["Plant_1", "Grass_Large", "Bush_Small"], (66, 84), (44, 36), 36, 0.5, 0.9, h_min=0.9, scale=(1.2, 2.0), min_path=1.8)

# farm: a few trees along the edge, flowers and bushes
scatter_area(tree_kinds("NormalTree"), (0, 84), (60, 34), 22, 1.8, 2.6, h_min=1.5, scale=(0.9, 1.3))
scatter_area(["Bush", "Bush_Flowers", "Flower_1_Clump", "Flower_2_Clump"], (0, 90), (56, 30), 40, 0.5, 1.0, scale=(1.0, 1.6), min_path=2.0)

# frozen corner: snowy trees (tree_snow.obj handled by the builder), ice rocks
scatter_area(["SnowTree"], (-68, 72), (40, 40), 60, 1.8, 2.6, scale=(0.9, 1.5))
scatter_area(["Rock_1", "Rock_2", "Rock_3"], (-68, 72), (38, 38), 22, 0.8, 1.4, scale=(1.5, 3.0))

# lake: reeds and rocks at the shore, palms for the dock
scatter_area(["Grass_Large", "Plant_1", "Rock_1", "Rock_2", "Bush_Small"], (0, -85), (50, 34), 90, 0.5, 1.0,
             h_min=0.4, h_max=2.3, scale=(1.4, 2.4), min_path=2.5)
scatter_area(tree_kinds("NormalTree") + tree_kinds("BirchTree"), (0, -100), (64, 30), 30, 1.6, 2.4, h_min=1.2, scale=(0.9, 1.3))

placed.append((0, 0, 31))          # keep the plaza clear
# village greenery
scatter_area(["Bush", "Bush_Flowers", "Flower_1_Clump", "Flower_3_Clump"], (0, 0), (50, 50), 60, 0.5, 1.0, scale=(1.0, 1.5), min_path=2.5)
scatter_area(tree_kinds("NormalTree") + tree_kinds("MapleTree"), (0, 0), (46, 46), 14, 2.0, 3.0, scale=(1.0, 1.4))

# ------------------------------------------------------------------ sanity checks on the space graph
by_name = {n["name"]: n for n in nodes}
seen = set()
stack = ["Start"]
while stack:
    cur = stack.pop()
    if cur in seen:
        continue
    seen.add(cur)
    stack.extend(by_name[cur]["next"])
unreachable = [n["name"] for n in nodes if n["name"] not in seen]
dead_ends = [n["name"] for n in nodes if not n["next"]]
assert not unreachable, "unreachable spaces: %s" % unreachable
assert not dead_ends, "spaces without a next space: %s" % dead_ends
for n in nodes:
    for m in n["next"]:
        assert n["name"] in by_name[m]["prev"], "prev/next mismatch %s -> %s" % (n["name"], m)
closest = min(math.hypot(a["x"] - b["x"], a["z"] - b["z"]) for i, a in enumerate(nodes) for b in nodes[i + 1:] if not (a["hidden"] or b["hidden"]))
print("graph ok: every space is reachable and has a next space; closest two spaces are %.1f m apart" % closest)

# ------------------------------------------------------------------ write

# ------------------------------------------------------------------ fit the spaces to the terrain
# A space is a flat hexagon (radius 1, 0.1 thick, its top surface at the node position). On a slope the uphill side
# would sink into the ground, so every space is tilted to the slope of the terrain under it and lifted until
# its top surface is above the terrain mesh everywhere.

def mesh_height(x, z):
    """Height of the terrain mesh as build_board.gd builds it (two triangles per cell)."""
    fx, fz = (x + HALF) / CELL, (z + HALF) / CELL
    ix = int(np.clip(math.floor(fx), 0, N - 2)); iz = int(np.clip(math.floor(fz), 0, N - 2))
    tx, tz = fx - ix, fz - iz
    a, b, c, e = height[iz, ix], height[iz, ix + 1], height[iz + 1, ix], height[iz + 1, ix + 1]
    if tx + tz <= 1.0:
        return float(a + (b - a) * tx + (c - a) * tz)
    return float(e + (c - e) * (1 - tx) + (b - e) * (1 - tz))


FOOT = [(0.0, 0.0)] + [(r_ * math.cos(2 * math.pi * i / 24), r_ * math.sin(2 * math.pi * i / 24))
                       for r_ in (0.35, 0.7, 1.05) for i in range(24)]
for n in nodes:
    if n["bridge"]:
        n["y"] = 2.49                       # the deck of the bridge is flat, its planks end at y = 2.45
        n["normal"] = [0.0, 1.0, 0.0]
        continue
    if n["hidden"]:
        n["y"] = round(n["h"] + 0.02, 3)
        n["normal"] = [0.0, 1.0, 0.0]
        continue
    # the terrain is piecewise linear, so its highest point under the hexagon is on the ring or at a grid vertex
    foot = list(FOOT)
    for gx_ in range(int(math.floor(n["x"] - 1.1)), int(math.ceil(n["x"] + 1.1)) + 1):
        for gz_ in range(int(math.floor(n["z"] - 1.1)), int(math.ceil(n["z"] + 1.1)) + 1):
            if math.hypot(gx_ - n["x"], gz_ - n["z"]) <= 1.1:
                foot.append((gx_ - n["x"], gz_ - n["z"]))
    hs = np.array([mesh_height(n["x"] + dx, n["z"] + dz) for dx, dz in foot])
    A = np.array([[1.0, dx, dz] for dx, dz in foot])
    c0, bx, bz = np.linalg.lstsq(A, hs, rcond=None)[0]
    bx, bz = float(np.clip(bx, -0.7, 0.7)), float(np.clip(bz, -0.7, 0.7))
    top = max(hs[i] - bx * dx - bz * dz for i, (dx, dz) in enumerate(foot)) + 0.04
    n["y"] = round(top, 3)             # the top surface of the hexagon is at the node position, its body hangs 0.1 below
    nl = math.sqrt(1 + bx * bx + bz * bz)
    n["normal"] = [round(-bx / nl, 4), round(1 / nl, 4), round(-bz / nl, 4)]

# ------------------------------------------------------------------ keep the path clear
by_name_ = {n["name"]: n for n in nodes}
seg_list = np.array([[n["x"], n["z"], by_name_[m]["x"], by_name_[m]["z"]] for n in nodes for m in n["next"]])


def path_distance(x, z):
    """Distance to the nearest path segment and the unit vector pointing away from it."""
    ax, az, bx, bz = seg_list[:, 0], seg_list[:, 1], seg_list[:, 2], seg_list[:, 3]
    dx, dz = bx - ax, bz - az
    t = np.clip(((x - ax) * dx + (z - az) * dz) / np.maximum(dx * dx + dz * dz, 1e-9), 0, 1)
    px, pz = ax + t * dx, az + t * dz
    d = np.hypot(px - x, pz - z)
    k = int(np.argmin(d))
    if d[k] < 1e-6:
        return 0.0, (0.0, 1.0)
    return float(d[k]), ((x - px[k]) / d[k], (z - pz[k]) / d[k])


SMALL = {"Lantern": 0.3, "Signpost": 0.6, "Hay": 1.2}
for lm in landmarks:
    if lm["kind"] not in SMALL:
        continue
    for _ in range(6):
        d_, (ux, uz) = path_distance(lm["pos"][0], lm["pos"][2])
        want = SMALL[lm["kind"]] + (2.2 if lm["kind"] != "Lantern" else 1.7)
        if d_ >= want:
            break
        move = want - d_ + 0.1
        lm["pos"][0] += ux * move
        lm["pos"][2] += uz * move
        lm["pos"][1] = height_at(lm["pos"][0], lm["pos"][2])
        if lm["kind"] == "Hay":
            lm["pos"][1] -= 0.0
removed = 0
for kind in list(scatter.keys()):
    size = 0.35 if kind.startswith(("Grass", "Plant", "Flower", "Petals")) else 0.8 if kind.startswith(("Bush", "Rock")) else 1.0
    limit = 0.9 if kind.startswith(("Grass", "Plant", "Flower", "Petals")) else 1.8
    keep = [it for it in scatter[kind] if path_distance(it[0], it[2])[0] - size * it[4] >= limit]
    removed += len(scatter[kind]) - len(keep)
    scatter[kind] = keep
print("scenery removed from the path:", removed)

layout = dict(
    cell=CELL, half=HALF, n=N, nc=NC, water_y=WATER_Y,
    nodes=[dict(name=n["name"], pos=[round(n["x"], 3), n["y"], round(n["z"], 3)], type=n["type"], cake=n["cake"],
                hidden=n["hidden"], next=n["next"], prev=n["prev"], area=n["area"], bridge=n["bridge"], normal=n["normal"]) for n in nodes],
    start="Start", warps=warp_pairs,
    scatter={k: [[round(v, 3) for v in item] for item in items] for k, items in scatter.items()},
    landmarks=landmarks,
    bridge=dict(x0=BRIDGE[0], x1=BRIDGE[1], z=-85.0, y=2.45),
    areas={k: list(v) for k, v in AREAS.items()},
)
with open(os.path.join(OUT, "layout.json"), "w") as f:
    json.dump(layout, f, default=lambda o: o.item() if hasattr(o, "item") else str(o))
height.astype("<f4").tofile(os.path.join(OUT, "heights.bin"))
color.astype("uint8").tofile(os.path.join(OUT, "colors.bin"))
layout_extra = NC

counts = {}
for n in nodes:
    counts[n["type"]] = counts.get(n["type"], 0) + 1
print("spaces", len(nodes), "types", counts, "cakes", sum(n["cake"] for n in nodes), "warps", warp_pairs)
print("scatter instances", sum(len(v) for v in scatter.values()), "landmarks", len(landmarks))
print("height range", float(height.min()), float(height.max()))

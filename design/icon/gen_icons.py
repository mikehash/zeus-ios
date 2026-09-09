#!/usr/bin/env python3
"""Zeus iOS icon candidates: stdlib-only SVG generator (rasterized by rsvg-convert)."""
import math, random, os, sys

OUT = "/private/tmp/claude-501/-Users-mike-Zeus/399a732f-e00d-4cce-ba0e-dbcd231f6e88/scratchpad"
S = 1024.0           # logical canvas
C = S / 2

BG_A = "#120806"
BG_B = "#1A0A06"
ACCENT = "#FF5028"
DEEP = "#C92808"
AMBER = (0xFF, 0xB3, 0x47)
ORANGE = (0xFF, 0x78, 0x38)


def hexc(rgb):
    return "#%02X%02X%02X" % tuple(int(max(0, min(255, v))) for v in rgb)


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


# ---------- 3D helpers ----------
def rot(p, tilt_x, spin_z):
    x, y, z = p
    # spin about y (longitude drift)
    cz, sz = math.cos(spin_z), math.sin(spin_z)
    x, z = x * cz - z * sz, x * sz + z * cz
    # tilt about x (axis lean toward viewer)
    cx, sx = math.cos(tilt_x), math.sin(tilt_x)
    y, z = y * cx - z * sx, y * sx + z * cx
    return x, y, z


def lattice_paths(R, cx, cy, tilt_x, spin_z, lean, n_lat=8, n_lon=12, steps=180):
    """Return list of (path_d, is_front, mean_z_norm) for lat/lon rings, split into
    front and back segments. lean = in-plane rotation of the whole sphere (radians)."""
    cl, sl = math.cos(lean), math.sin(lean)
    out = []

    def emit(pts3):
        seg, front_flag, zs = [], None, []
        for (x, y, z) in pts3:
            px, py = x * cl - y * sl, x * sl + y * cl
            X, Y = cx + px * R, cy - py * R
            f = z >= 0
            if front_flag is None:
                front_flag = f
            if f != front_flag:
                if len(seg) > 1:
                    out.append((seg, front_flag, sum(zs) / len(zs)))
                seg, zs, front_flag = [], [], f
            seg.append((X, Y))
            zs.append(z)
        if len(seg) > 1:
            out.append((seg, front_flag, sum(zs) / len(zs)))

    # latitude rings (exclude poles)
    for i in range(1, n_lat):
        lat = -math.pi / 2 + math.pi * i / n_lat
        r = math.cos(lat)
        yy = math.sin(lat)
        pts = []
        for k in range(steps + 1):
            a = 2 * math.pi * k / steps
            pts.append(rot((r * math.cos(a), yy, r * math.sin(a)), tilt_x, spin_z))
        emit(pts)
    # longitude rings (full great circles through poles)
    for j in range(n_lon):
        lon = math.pi * j / n_lon
        pts = []
        for k in range(steps + 1):
            a = 2 * math.pi * k / steps
            x, y, z = math.cos(a) * math.cos(lon), math.sin(a), math.cos(a) * math.sin(lon)
            pts.append(rot((x, y, z), tilt_x, spin_z))
        emit(pts)
    return out


def path_d(seg):
    d = "M%.2f %.2f" % seg[0]
    d += "".join("L%.2f %.2f" % p for p in seg[1:])
    return d


def lattice_svg(R, cx, cy, tilt_x, spin_z, lean, color, stroke_w, op_front, op_back,
                n_lat=8, n_lon=12, limb_fade=True):
    parts = []
    for seg, front, mz in lattice_paths(R, cx, cy, tilt_x, spin_z, lean, n_lat, n_lon):
        op = op_front if front else op_back
        if limb_fade:
            # thin toward the limb: lines nearer z=0 fade a touch
            op *= 0.55 + 0.45 * min(1.0, abs(mz) * 1.6)
        parts.append('<path d="%s" fill="none" stroke="%s" stroke-width="%.2f" '
                     'stroke-opacity="%.3f" stroke-linecap="round"/>'
                     % (path_d(seg), color, stroke_w, op))
    return "\n".join(parts)


# ---------- particles ----------
def particles(rng, n, R, cx, cy, tilt_x, spin_z, lean, core_sigma=0.38, r_min=1.2, r_max=6.5,
              shell_bias=0.0, min_alpha=0.18):
    """Gaussian cloud inside the sphere volume, projected. Returns list of dicts."""
    cl, sl = math.cos(lean), math.sin(lean)
    pts = []
    tries = 0
    while len(pts) < n and tries < n * 40:
        tries += 1
        if shell_bias > 0 and rng.random() < shell_bias:
            # a few sit near the surface, following the lattice
            u = rng.uniform(-1, 1); a = rng.uniform(0, 2 * math.pi)
            rr = rng.uniform(0.86, 0.99)
            x, y, z = rr * math.sqrt(1 - u * u) * math.cos(a), rr * u, rr * math.sqrt(1 - u * u) * math.sin(a)
        else:
            x, y, z = rng.gauss(0, core_sigma), rng.gauss(0, core_sigma), rng.gauss(0, core_sigma)
            if x * x + y * y + z * z > 0.96:
                continue
        x, y, z = rot((x, y, z), tilt_x, spin_z)
        px, py = x * cl - y * sl, x * sl + y * cl
        d = math.sqrt(x * x + y * y + z * z)
        depth = (z + 1) / 2                      # 0 back .. 1 front
        heat = max(0.0, 1.0 - d / 0.95)          # 1 at centre
        size = r_min + (r_max - r_min) * (rng.random() ** 2.2) * (0.5 + 0.5 * depth)
        col = mix(ORANGE, AMBER, min(1.0, heat * 1.15 + rng.random() * 0.12))
        alpha = min_alpha + (1 - min_alpha) * (0.35 * depth + 0.65 * heat) * rng.uniform(0.75, 1.0)
        pts.append(dict(x=cx + px * R, y=cy - py * R, z=z, r=size, col=col, a=alpha, heat=heat))
    pts.sort(key=lambda p: p["z"])               # back to front
    return pts


def particles_svg(pts, glow_mult=3.2, glow_alpha=0.28, hot_only=False):
    parts = []
    for p in pts:
        c = hexc(p["col"])
        # soft halo
        if p["r"] > 2.2 or not hot_only:
            parts.append('<circle cx="%.2f" cy="%.2f" r="%.2f" fill="url(#halo)" opacity="%.3f"/>'
                         % (p["x"], p["y"], p["r"] * glow_mult, p["a"] * glow_alpha * (0.6 + 0.4 * p["heat"])))
        parts.append('<circle cx="%.2f" cy="%.2f" r="%.2f" fill="%s" fill-opacity="%.3f"/>'
                     % (p["x"], p["y"], p["r"], c, p["a"]))
    return "\n".join(parts)


# ---------- document ----------
def defs(extra=""):
    return f"""<defs>
  <radialGradient id="ground" cx="50%" cy="46%" r="72%">
    <stop offset="0%" stop-color="{BG_B}"/>
    <stop offset="70%" stop-color="{BG_A}"/>
    <stop offset="100%" stop-color="#0D0504"/>
  </radialGradient>
  <radialGradient id="halo" cx="50%" cy="50%" r="50%">
    <stop offset="0%" stop-color="#FFC060" stop-opacity="1"/>
    <stop offset="45%" stop-color="#FF8A3C" stop-opacity="0.35"/>
    <stop offset="100%" stop-color="#FF5028" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="coreglow" cx="50%" cy="50%" r="50%">
    <stop offset="0%" stop-color="#FFB347" stop-opacity="0.95"/>
    <stop offset="18%" stop-color="#FF8A3C" stop-opacity="0.62"/>
    <stop offset="45%" stop-color="#FF5028" stop-opacity="0.22"/>
    <stop offset="75%" stop-color="#C92808" stop-opacity="0.06"/>
    <stop offset="100%" stop-color="#C92808" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="bleed" cx="50%" cy="50%" r="50%">
    <stop offset="0%" stop-color="#FF5028" stop-opacity="0.30"/>
    <stop offset="55%" stop-color="#C92808" stop-opacity="0.10"/>
    <stop offset="100%" stop-color="#C92808" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="limb" cx="50%" cy="50%" r="50%">
    <stop offset="86%" stop-color="#C92808" stop-opacity="0"/>
    <stop offset="97%" stop-color="#C92808" stop-opacity="0.16"/>
    <stop offset="100%" stop-color="#C92808" stop-opacity="0"/>
  </radialGradient>
  <filter id="soft" x="-30%" y="-30%" width="160%" height="160%">
    <feGaussianBlur stdDeviation="9"/>
  </filter>
  <filter id="softer" x="-30%" y="-30%" width="160%" height="160%">
    <feGaussianBlur stdDeviation="22"/>
  </filter>
  <clipPath id="frame"><rect x="0" y="0" width="{int(S)}" height="{int(S)}"/></clipPath>
  {extra}
</defs>"""


def wrap(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{int(S)}" height="{int(S)}" '
            f'viewBox="0 0 {int(S)} {int(S)}">\n{defs()}\n'
            f'<rect width="{int(S)}" height="{int(S)}" fill="{BG_A}"/>\n'
            f'<rect width="{int(S)}" height="{int(S)}" fill="url(#ground)"/>\n'
            f'<g clip-path="url(#frame)">\n{body}\n</g>\n</svg>\n')


# ================= Candidate A =================
def icon_a():
    rng = random.Random(7)
    R = S * 0.70 / 2                     # orb fills ~70%
    cx, cy = C, C
    tilt, spin, lean = math.radians(22), math.radians(14), math.radians(-12)
    b = []
    # ground bleed + core glow
    b.append(f'<circle cx="{cx+8:.1f}" cy="{cy+6:.1f}" r="{R*1.62:.1f}" fill="url(#bleed)"/>')
    b.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{R*1.18:.1f}" fill="url(#coreglow)" filter="url(#soft)"/>')
    # back lattice
    b.append(lattice_svg(R, cx, cy, tilt, spin, lean, DEEP, 1.2, 0.0, 0.12))
    # limb ring (barely there)
    b.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{R:.1f}" fill="url(#limb)"/>')
    # particles: a dense fine cloud, fewer large motes
    pts = particles(rng, 1250, R, cx, cy, tilt, spin, lean, core_sigma=0.33, r_min=0.8, r_max=5.0)
    b.append(particles_svg(pts, glow_mult=3.6, glow_alpha=0.34))
    # hot core
    b.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{R*0.30:.1f}" fill="url(#coreglow)" filter="url(#soft)" opacity="0.95"/>')
    # front lattice, low contrast
    b.append(lattice_svg(R, cx, cy, tilt, spin, lean, DEEP, 1.3, 0.30, 0.0))
    return wrap("\n".join(b))


# ================= Candidate B =================
def icon_b():
    rng = random.Random(23)
    R = S * 1.20 / 2                     # 120%: only the central region shows
    cx, cy = C + 46, C - 30              # subtle off-centre so meridians sweep asymmetrically
    tilt, spin, lean = math.radians(28), math.radians(20), math.radians(-18)
    b = []
    b.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{R*1.1:.1f}" fill="url(#coreglow)" filter="url(#softer)" opacity="0.42"/>')
    # back lattice, faint: reads as the far wall of the sphere
    b.append(lattice_svg(R, cx, cy, tilt, spin, lean, DEEP, 1.6, 0.0, 0.10, n_lat=10, n_lon=14))
    pts = particles(rng, 240, R, cx, cy, tilt, spin, lean, core_sigma=0.42, r_min=1.2, r_max=4.8,
                    shell_bias=0.22, min_alpha=0.14)
    b.append(particles_svg(pts, glow_mult=3.0, glow_alpha=0.22))
    # front lattice, the visible lattice curving across the frame
    b.append(lattice_svg(R, cx, cy, tilt, spin, lean, DEEP, 1.9, 0.40, 0.0, n_lat=10, n_lon=14))
    # the one bright particle, off-centre (lower-right of centre, on the golden-ish diagonal)
    bx, by = C + 118, C + 74
    b.append(f'<circle cx="{bx}" cy="{by}" r="120" fill="url(#halo)" opacity="0.50"/>')
    b.append(f'<circle cx="{bx}" cy="{by}" r="40" fill="url(#halo)" opacity="0.95"/>')
    b.append(f'<circle cx="{bx}" cy="{by}" r="7.5" fill="#FFD27A"/>')
    b.append(f'<circle cx="{bx}" cy="{by}" r="4.2" fill="#FFF1C8"/>')
    return wrap("\n".join(b))


# ================= Candidate C =================
def icon_c():
    rng = random.Random(3)
    R = S * 0.62 / 2
    cx, cy = C, C
    tilt, spin, lean = math.radians(24), math.radians(10), math.radians(-14)
    b = []
    # faint ground warmth only around the centre
    b.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{R*1.05:.1f}" fill="url(#bleed)" opacity="0.55"/>')
    # wireframe: deep red, low opacity, both hemispheres (back fainter)
    b.append(lattice_svg(R, cx, cy, tilt, spin, lean, DEEP, 1.2, 0.0, 0.10, n_lat=6, n_lon=8))
    b.append(lattice_svg(R, cx, cy, tilt, spin, lean, DEEP, 1.3, 0.30, 0.0, n_lat=6, n_lon=8))
    # a thin ring of a few particles around the disc
    ring = []
    n = 14
    ring_r = R * 0.31
    phase = math.radians(-97)
    for i in range(n):
        a = phase + 2 * math.pi * i / n + rng.uniform(-0.05, 0.05)
        rr = ring_r * rng.uniform(0.97, 1.03)
        x, y = cx + rr * math.cos(a), cy + rr * math.sin(a)
        r = rng.uniform(1.6, 3.4)
        col = hexc(mix(ORANGE, AMBER, rng.uniform(0.3, 0.9)))
        alpha = rng.uniform(0.55, 0.95)
        ring.append(f'<circle cx="{x:.2f}" cy="{y:.2f}" r="{r*3.0:.2f}" fill="url(#halo)" opacity="{alpha*0.28:.3f}"/>')
        ring.append(f'<circle cx="{x:.2f}" cy="{y:.2f}" r="{r:.2f}" fill="{col}" fill-opacity="{alpha:.3f}"/>')
    b.append("\n".join(ring))
    # the solid accent disc, small, dead centre, with a whisper of glow so it sits in the dark
    disc = S * 0.072
    b.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{disc*2.8:.1f}" fill="url(#halo)" opacity="0.30"/>')
    b.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{disc:.1f}" fill="{ACCENT}"/>')
    return wrap("\n".join(b))


if __name__ == "__main__":
    for name, fn in (("A", icon_a), ("B", icon_b), ("C", icon_c)):
        p = os.path.join(OUT, f"icon-{name}.svg")
        with open(p, "w") as f:
            f.write(fn())
        print("wrote", p)

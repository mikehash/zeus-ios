#!/usr/bin/env python3
"""Assert a captured store-screenshot set is what the capture script claims.

WHY THIS IS A SEPARATE FILE AND NOT FOUR LINES OF SHELL
-------------------------------------------------------
Every cheap property of a store set is GREEN on a broken set:

  * file exists          - green when all four frames are the same screen
  * non-zero bytes       - green when all four frames are the same screen
  * 1320x2868            - green when all four frames are the same screen
  * `ls | wc -l` == 4    - green when all four frames are the same screen

`LaunchArgs.initialTab` falls back to `.zeus` on an unrecognised value, and a
RELEASE build ignores the launch arguments entirely (`#if DEBUG`). Both faults
produce a complete, well-formed, correctly-sized set in which every frame is
the same tab. The ONLY property that separates a good set from those two is
that the frames differ from one another.

THE DISCRIMINATION
------------------
Byte-inequality is not enough on its own but it is not nothing: two launches of
the SAME screen do differ in bytes (status-bar clock, antialiasing), so a byte
compare would call a broken set good. So the comparison is on DOWNSAMPLED
CONTENT: each frame is reduced to a coarse grid of average colours, and two
frames are "the same screen" when that grid matches within a tolerance. A clock
digit cannot move a 12x24 cell average; a different tab can.

CONTROLS
--------
A distinctness check has the dead-probe failure mode of every other census: if
the comparison is broken it reports "all distinct" on identical inputs. So the
suite runs a POSITIVE control by construction - it compares a frame against
ITSELF and REQUIRES that to be reported as a collision. If the self-comparison
does not collide, the comparator is dead and the verdict is void (rc=2), not
green.

EXIT
----
  0  the set is good      1  the set is BAD      2  the INSTRUMENT faulted
"""
import sys, os, glob, zlib, struct

GRID_W, GRID_H = 12, 24
# Two frames collide when every cell of the coarse grid is within this L1
# distance. The value is MEASURED, not chosen by taste, and both bounds were
# taken on this box at the commit that introduced this file:
#
#   SAME screen, two independent launches (mutant: `-zeusTab sesion`, a typo
#   that LaunchArgs resolves to `.zeus`)          -> d = 3
#   closest genuinely-DISTINCT pair in the real
#   set (3-session vs 4-nodes)                    -> d = 102
#
# So the discriminating band is [3, 102] and 6 sits just above the noise floor
# with a 17x margin below the nearest true signal. The clock, the battery
# glyph and antialiasing move a coarse cell average by ~3; a different tab
# moves it by ~100. Both numbers are printed on every run, so the day the UI
# changes enough to shrink that band, the run says so before the verdict does.
TOL = 6

def read_png(path):
    d = open(path, 'rb').read()
    if d[:8] != b'\x89PNG\r\n\x1a\n':
        raise ValueError(f"{path}: not a PNG")
    i, idat, hdr = 8, b'', None
    while i < len(d):
        ln = struct.unpack('>I', d[i:i+4])[0]
        typ = d[i+4:i+8]
        data = d[i+8:i+8+ln]
        if typ == b'IHDR':
            hdr = struct.unpack('>IIBBBBB', data[:13])
        elif typ == b'IDAT':
            idat += data
        i += 12 + ln
    if hdr is None:
        raise ValueError(f"{path}: no IHDR")
    w, h, bd, ct, comp, filt, il = hdr
    if bd != 8 or ct not in (2, 6) or il != 0:
        raise ValueError(f"{path}: unsupported PNG (depth={bd} colortype={ct} interlace={il})")
    bpp = 3 if ct == 2 else 4
    raw = zlib.decompress(idat)
    stride = w * bpp
    prev = bytearray(stride)
    rows = []
    pos = 0
    for _ in range(h):
        f = raw[pos]; pos += 1
        line = bytearray(raw[pos:pos+stride]); pos += stride
        if f == 1:
            for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 255
        elif f == 2:
            for x in range(stride): line[x] = (line[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride):
                a = line[x-bpp] if x >= bpp else 0
                line[x] = (line[x] + ((a + prev[x]) >> 1)) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x-bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x-bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pr) & 255
        prev = line
        rows.append(bytes(line))
    return w, h, bpp, rows

def grid(path):
    """Reduce a frame to GRID_W x GRID_H average RGB cells."""
    w, h, bpp, rows = read_png(path)
    cells = []
    for gy in range(GRID_H):
        y0, y1 = gy * h // GRID_H, (gy + 1) * h // GRID_H
        for gx in range(GRID_W):
            x0, x1 = gx * w // GRID_W, (gx + 1) * w // GRID_W
            r = g = b = n = 0
            # Sample every 4th row/col: a cell is thousands of pixels and the
            # average is stable under subsampling. Full scan is ~40x slower for
            # an answer that does not change.
            for y in range(y0, y1, 4):
                row = rows[y]
                for x in range(x0, x1, 4):
                    o = x * bpp
                    r += row[o]; g += row[o+1]; b += row[o+2]; n += 1
            if n == 0:
                n = 1
            cells.append((r // n, g // n, b // n))
    return (w, h), cells

def l1(a, b):
    return max(abs(x[0]-y[0]) + abs(x[1]-y[1]) + abs(x[2]-y[2]) for x, y in zip(a, b))

def main(argv):
    if len(argv) != 2:
        print("usage: verify_store_screens.py <dir>", file=sys.stderr)
        return 2
    d = argv[1]
    paths = sorted(glob.glob(os.path.join(d, "*.png")))
    if len(paths) < 2:
        print(f"VOID: {len(paths)} frame(s) in {d} - distinctness is undefined below 2", file=sys.stderr)
        return 2

    try:
        loaded = [(p, *grid(p)) for p in paths]
    except Exception as e:
        print(f"VOID: decode failed: {e}", file=sys.stderr)
        return 2

    # --- POSITIVE CONTROL, by construction -------------------------------
    # Compare frame 0 with itself. This MUST collide. If it does not, the
    # comparator is dead and every "distinct" below is a false negative.
    self_d = l1(loaded[0][2], loaded[0][2])
    if self_d > TOL:
        print(f"VOID: positive control failed - a frame does not match ITSELF "
              f"(d={self_d} > tol={TOL}). The comparator is dead; the set is UNMEASURED.",
              file=sys.stderr)
        return 2
    print(f"pos ctl: self-compare d={self_d} <= tol={TOL}  (comparator live)")

    # --- Size agreement ---------------------------------------------------
    sizes = {sz for _, sz, _ in loaded}
    if len(sizes) != 1:
        print(f"FAIL: frames disagree on size: {sizes}", file=sys.stderr)
        return 1
    (w, h) = sizes.pop()
    print(f"size   : {w}x{h}  ({len(loaded)} frames)")

    # --- The load-bearing check ------------------------------------------
    collisions = []
    worst = None
    for i in range(len(loaded)):
        for j in range(i + 1, len(loaded)):
            dist = l1(loaded[i][2], loaded[j][2])
            if worst is None or dist < worst[0]:
                worst = (dist, loaded[i][0], loaded[j][0])
            if dist <= TOL:
                collisions.append((os.path.basename(loaded[i][0]),
                                   os.path.basename(loaded[j][0]), dist))
    print(f"closest distinct pair: d={worst[0]}  "
          f"{os.path.basename(worst[1])} vs {os.path.basename(worst[2])}")

    if collisions:
        for a, b, dist in collisions:
            print(f"FAIL: {a} and {b} are the SAME SCREEN (d={dist} <= tol={TOL})",
                  file=sys.stderr)
        print("A typo'd -zeusTab, or a Release build ignoring #if DEBUG launch "
              "args, produces exactly this.", file=sys.stderr)
        return 1
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv))

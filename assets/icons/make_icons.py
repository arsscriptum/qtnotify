#!/usr/bin/env python3
"""
make_icons.py

Renders the qtnotify window icon (a warning triangle on a rounded red
tile) to PNG at the sizes listed in SIZES. Pure standard library, no
Pillow, no ImageMagick, no rsvg: only zlib and struct, so it runs on a
bare Raspberry Pi OS or Ubuntu install.

The generated PNGs are committed to the repository and compiled into the
binary by rcc (assets/qtnotify.qrc), so a normal build never needs this
script. Run it only after editing the geometry or the palette below:

    make assets            (from the top of the project)
    python3 assets/icons/make_icons.py --out-dir assets/icons

qtnotify.svg is the same artwork, kept for scalable uses (desktop files,
documentation); it is maintained by hand alongside this script.
"""

import argparse
import os
import struct
import sys
import zlib

SIZES = (16, 32, 64, 128, 256)
SUPERSAMPLE = 4

# Palette, matching the dialog stylesheet in src/tempmon_alert.cpp.
TILE = (0xCC, 0x22, 0x22, 0xFF)
MARK = (0xFF, 0xFF, 0xFF, 0xFF)
CLEAR = (0, 0, 0, 0)

# Geometry, in unit coordinates (0..1) so it scales to any size.
CORNER_RADIUS = 0.16
TRIANGLE = ((0.500, 0.150), (0.880, 0.815), (0.120, 0.815))
BAR = (0.462, 0.330, 0.538, 0.615)          # x0, y0, x1, y1
DOT = (0.500, 0.700, 0.042)                 # cx, cy, r


def in_rounded_rect(x, y, r):
    """Unit square with the four corners rounded off at radius r."""
    cx = min(max(x, r), 1.0 - r)
    cy = min(max(y, r), 1.0 - r)
    dx = x - cx
    dy = y - cy
    return dx * dx + dy * dy <= r * r


def in_triangle(x, y, tri):
    (ax, ay), (bx, by), (cx, cy) = tri

    def edge(x0, y0, x1, y1):
        return (x - x0) * (y1 - y0) - (y - y0) * (x1 - x0)

    d1 = edge(ax, ay, bx, by)
    d2 = edge(bx, by, cx, cy)
    d3 = edge(cx, cy, ax, ay)
    return (d1 >= 0 and d2 >= 0 and d3 >= 0) or (d1 <= 0 and d2 <= 0 and d3 <= 0)


def in_rect(x, y, rect):
    x0, y0, x1, y1 = rect
    return x0 <= x <= x1 and y0 <= y <= y1


def in_circle(x, y, circle):
    cx, cy, r = circle
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r


def sample(x, y):
    """Colour of the artwork at unit coordinate (x, y)."""
    if not in_rounded_rect(x, y, CORNER_RADIUS):
        return CLEAR
    if in_rect(x, y, BAR) or in_circle(x, y, DOT):
        return TILE
    if in_triangle(x, y, TRIANGLE):
        return MARK
    return TILE


def render(size, supersample=SUPERSAMPLE):
    """Box filtered RGBA rows, premultiplied nowhere, straight alpha."""
    rows = []
    step = 1.0 / (size * supersample)
    samples = supersample * supersample

    for py in range(size):
        row = bytearray()
        for px in range(size):
            r = g = b = a = 0
            for sy in range(supersample):
                y = (py * supersample + sy + 0.5) * step
                for sx in range(supersample):
                    x = (px * supersample + sx + 0.5) * step
                    sr, sg, sb, sa = sample(x, y)
                    r += sr * sa
                    g += sg * sa
                    b += sb * sa
                    a += sa
            if a == 0:
                row += b"\x00\x00\x00\x00"
            else:
                row += bytes((r // a, g // a, b // a, a // samples))
        rows.append(bytes(row))

    return rows


def chunk(tag, data):
    body = tag + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def write_png(path, size, rows):
    raw = b"".join(b"\x00" + row for row in rows)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )

    tmp = path + ".tmp"
    try:
        with open(tmp, "wb") as handle:
            handle.write(png)
        os.replace(tmp, path)
    except OSError as exc:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise SystemExit("make_icons.py: cannot write %s: %s" % (path, exc))


def main(argv):
    parser = argparse.ArgumentParser(description="render the qtnotify icon to PNG")
    parser.add_argument("--out-dir", default=os.path.dirname(os.path.abspath(__file__)),
                        help="directory to write qtnotify-<size>.png into")
    parser.add_argument("--sizes", default=",".join(str(s) for s in SIZES),
                        help="comma separated pixel sizes (default: %(default)s)")
    args = parser.parse_args(argv[1:])

    try:
        sizes = [int(s) for s in args.sizes.split(",") if s.strip()]
    except ValueError:
        raise SystemExit("make_icons.py: --sizes wants a comma separated list of integers")

    if not sizes or any(s < 8 or s > 1024 for s in sizes):
        raise SystemExit("make_icons.py: sizes must be between 8 and 1024")

    if not os.path.isdir(args.out_dir):
        raise SystemExit("make_icons.py: no such directory: %s" % args.out_dir)

    for size in sizes:
        path = os.path.join(args.out_dir, "qtnotify-%d.png" % size)
        write_png(path, size, render(size))
        print("make_icons.py: wrote %s (%d bytes)" % (path, os.path.getsize(path)))

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

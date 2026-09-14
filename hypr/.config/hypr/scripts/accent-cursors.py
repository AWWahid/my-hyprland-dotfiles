#!/usr/bin/env python3
"""Build an xcursor theme whose busy cursors are a minimal accent-colored spinner.

usage: accent-cursors.py RRGGBB dark|light OUTDIR

Both modes get a thin Windows-style I-beam (black in dark mode, white in light).
Light mode also gets a white arrow and the original white macOS hands (the cursor takes the
background's color); everything else is inherited from macOS-plain (black arrow and hands).
Runs only when accent.conf or this script changes (theme-toggle.sh checks timestamps);
the animation itself is played by the compositor.
"""
import math, os, shutil, struct, sys

SIZES = [16, 20, 22, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96]
FRAMES, DELAY = 30, 33          # one turn per second
ARC = math.radians(100)         # length of the moving arc
MACOS = os.path.expanduser("~/.local/share/icons/macOS/cursors")


def read_cursor(path):
    """{nominal size: (w, h, xhot, yhot, premultiplied BGRA bytes)} for the first frame of each size."""
    d = open(path, "rb").read()
    out = {}
    for i in range(struct.unpack_from("<I", d, 12)[0]):
        typ, size, pos = struct.unpack_from("<III", d, 16 + i * 12)
        if typ == 0xFFFD0002 and size not in out:
            w, h, xh, yh = struct.unpack_from("<4I", d, pos + 16)
            out[size] = (w, h, xh, yh, bytearray(d[pos + 36:pos + 36 + w * h * 4]))
    return out


def write_cursor(path, images):
    """images: list of (size, w, h, xhot, yhot, delay, BGRA bytes)."""
    pos = 16 + 12 * len(images)
    toc, chunks = b"", b""
    for size, w, h, xh, yh, delay, px in images:
        toc += struct.pack("<III", 0xFFFD0002, size, pos + len(chunks))
        chunks += struct.pack("<9I", 36, 0xFFFD0002, size, 1, w, h, xh, yh, delay) + bytes(px)
    open(path, "wb").write(b"Xcur" + struct.pack("<III", 16, 0x10000, len(images)) + toc + chunks)


def invert(path):
    """Swap black and white in a cursor file, keeping the faint drop shadow dark."""
    d = bytearray(open(path, "rb").read())
    for i in range(struct.unpack_from("<I", d, 12)[0]):
        typ, _, pos = struct.unpack_from("<III", d, 16 + i * 12)
        if typ != 0xFFFD0002:
            continue
        w, h = struct.unpack_from("<2I", d, pos + 16)
        for k in range(pos + 36, pos + 36 + w * h * 4, 4):
            a = d[k + 3]
            if not a:
                continue
            t = max(0.0, min(1.0, (a / 255 - 0.45) / 0.35))
            f = t * t * (3 - 2 * t)             # solid glyph inverts, low-alpha shadow doesn't
            for j in range(3):
                c = d[k + j] / a * 255
                d[k + j] = round((c + (255 - 2 * c) * f) * a / 255)
    return bytes(d)


def link_aliases(cur, targets):
    """Recreate every macOS alias pointing at targets, so lookups don't fall through to macOS-plain."""
    for name in os.listdir(MACOS):
        full = os.path.join(MACOS, name)
        if os.path.islink(full) and os.readlink(full) in targets:
            link = os.path.join(cur, name)
            if os.path.lexists(link):
                os.remove(link)
            os.symlink(os.readlink(full), link)


def ibeam(s, fill, outline):
    """Thin Windows-style text cursor, snapped to whole pixels so it stays crisp: (w, h, xhot, yhot, BGRA)."""
    w, o = max(1, round(s / 24)), max(1, round(s / 48))   # stroke, outline
    h, bar = round(s * 0.66), round(s * 0.26)
    if (bar - w) % 2:
        bar += 1                                           # keep the caps symmetric around the stem
    x0, y0 = (s - w) // 2, (s - h) // 2
    bx = x0 - (bar - w) // 2
    rects = [(x0, y0, w, h), (bx, y0, bar, w), (bx, y0 + h - w, bar, w)]
    px = bytearray(s * s * 4)
    for grow, (r, g, b) in ((o, outline), (0, fill)):
        for x, y, rw, rh in rects:
            for yy in range(y - grow, y + rh + grow):
                for xx in range(x - grow, x + rw + grow):
                    i = (yy * s + xx) * 4
                    px[i:i + 4] = bytes((b, g, r, 255))
    return s, s, x0 + w // 2, s // 2, px


def ring(px, w, cx, cy, radius, stroke, angle, color, halo):
    """Composite a spinner (halo + faint track + arc with round caps) over px, anti-aliased by distance."""
    r, g, b = color
    a0, a1 = angle, angle + ARC
    caps = [(cx + radius * math.cos(a), cy + radius * math.sin(a)) for a in (a0, a1)]
    half = stroke / 2
    for y in range(int(cy - radius - stroke - 1), int(cy + radius + stroke + 2)):
        for x in range(int(cx - radius - stroke - 1), int(cx + radius + stroke + 2)):
            if not (0 <= x < w and 0 <= y < w):
                continue
            px_, py_ = x + 0.5 - cx, y + 0.5 - cy
            dr = abs(math.hypot(px_, py_) - radius)
            a = (math.atan2(py_, px_) - a0) % (2 * math.pi)
            d_arc = dr if a <= ARC else min(math.hypot(x + 0.5 - ex, y + 0.5 - ey) for ex, ey in caps)
            cov = lambda dist, hw: max(0.0, min(1.0, hw - dist + 0.5))
            layers = [(halo, cov(dr, half + max(1.0, stroke * 0.35))),   # contrast outline
                      ((r, g, b, 0.30), cov(dr, half)),                     # track
                      ((r, g, b, 1.00), cov(d_arc, half))]                  # moving arc
            for (lr, lg, lb, la), c in layers:
                sa = la * c
                if sa <= 0:
                    continue
                i = (y * w + x) * 4
                inv = 1 - sa
                px[i] = round(lb * sa + px[i] * inv)
                px[i + 1] = round(lg * sa + px[i + 1] * inv)
                px[i + 2] = round(lr * sa + px[i + 2] * inv)
                px[i + 3] = round(255 * sa + px[i + 3] * inv)


def main():
    hexcolor, mode, outdir = sys.argv[1].lstrip("#"), sys.argv[2], sys.argv[3]
    color = tuple(int(hexcolor[i:i + 2], 16) for i in (0, 2, 4))
    halo = (0, 0, 0, 0.55) if mode == "dark" else (255, 255, 255, 0.85)
    cur = os.path.join(outdir, "cursors")
    os.makedirs(cur, exist_ok=True)
    if mode == "light":
        open(os.path.join(cur, "left_ptr"), "wb").write(invert(os.path.join(MACOS, "left_ptr")))
        for hand in ("hand1", "hand2", "move"):
            shutil.copyfile(os.path.join(MACOS, hand), os.path.join(cur, hand))
        link_aliases(cur, {"left_ptr", "hand1", "hand2", "move"})
    arrows = read_cursor(os.path.join(cur if mode == "light" else MACOS, "left_ptr"))
    wait, progress = [], []
    for s in SIZES:
        aw, ah, axh, ayh, apx = arrows[s]
        for f in range(FRAMES):
            angle = 2 * math.pi * f / FRAMES - math.pi / 2
            px = bytearray(s * s * 4)
            ring(px, s, s / 2, s / 2, s * 0.34, s * 0.10, angle, color, halo)
            wait.append((s, s, s, s // 2, s // 2, DELAY, px))
            px = bytearray(apx)                       # macOS arrow with a small spinner at the lower right
            ring(px, aw, aw * 0.76, ah * 0.76, s * 0.15, s * 0.075, angle, color, halo)
            progress.append((s, aw, ah, axh, ayh, DELAY, px))

    ink = ((0, 0, 0), (255, 255, 255))                   # (fill, outline): black in dark mode, white in light
    fill, outline = ink if mode == "dark" else ink[::-1]
    texts = []
    for s in SIZES:
        w, h, xh, yh, px = ibeam(s, fill, outline)
        texts.append((s, w, h, xh, yh, 0, px))
    write_cursor(os.path.join(cur, "xterm"), texts)
    write_cursor(os.path.join(cur, "wait"), wait)
    write_cursor(os.path.join(cur, "left_ptr_watch"), progress)
    link_aliases(cur, {"xterm"})
    for alias, target in [("watch", "wait"), ("progress", "left_ptr_watch"), ("half-busy", "left_ptr_watch"),
                          ("00000000000000020006000e7e9ffc3f", "left_ptr_watch"),
                          ("08e8e1c95fe2fc01f976f1e063a24ccd", "left_ptr_watch"),
                          ("3ecb610c1bf2410f44200f48c40d3599", "left_ptr_watch")]:
        link = os.path.join(cur, alias)
        if os.path.lexists(link):
            os.remove(link)
        os.symlink(target, link)
    with open(os.path.join(outdir, "index.theme"), "w") as f:
        f.write(f"[Icon Theme]\nName={os.path.basename(outdir)}\nComment=macOS cursors with an accent spinner\nInherits=macOS-plain\n")


if __name__ == "__main__":
    main()

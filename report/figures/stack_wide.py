"""Re-pack a wide diagram (a row of separate boxes) into two rows, so it can be
printed larger. The boxes are found by the columns of pure background between
them; nothing inside a box is changed.

    python stack_wide.py <in.png> <out.png> [rows]
"""
import sys

from PIL import Image

src, dst = sys.argv[1], sys.argv[2]
rows = int(sys.argv[3]) if len(sys.argv) > 3 else 2
im = Image.open(src).convert("RGB")
w, h = im.size
bg = im.getpixel((0, 0))
px = im.load()


def blank_col(x):
    return all(px[x, y] == bg for y in range(h))


# column groups separated by at least 12 blank columns
groups, start, gap = [], None, 0
for x in range(w):
    if blank_col(x):
        gap += 1
        if start is not None and gap >= 12:
            groups.append((start, x - gap + 1))
            start = None
    else:
        if start is None:
            start = x
        gap = 0
if start is not None:
    groups.append((start, w))
crops = []
for a, b in groups:
    c = im.crop((a, 0, b, h))
    # trim blank rows top and bottom
    cp = c.load()
    ys = [y for y in range(h) if any(cp[x, y] != bg for x in range(c.size[0]))]
    crops.append(c.crop((0, min(ys), c.size[0], max(ys) + 1)))
per_row = -(-len(crops) // rows)
pad = 24
lines = [crops[i:i + per_row] for i in range(0, len(crops), per_row)]
W = max(sum(c.size[0] for c in ln) + pad * (len(ln) - 1) for ln in lines)
H = sum(max(c.size[1] for c in ln) for ln in lines) + pad * (len(lines) - 1)
out = Image.new("RGB", (W, H), bg)
y = 0
for ln in lines:
    lw = sum(c.size[0] for c in ln) + pad * (len(ln) - 1)
    x = (W - lw) // 2
    for c in ln:
        out.paste(c, (x, y))
        x += c.size[0] + pad
    y += max(c.size[1] for c in ln) + pad
out.save(dst)
print(f"{src}: {len(crops)} groups -> {len(lines)} rows, {w}x{h} -> {W}x{H}")

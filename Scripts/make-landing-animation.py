#!/usr/bin/env python3
"""The animated icon in About Kehai and in kehai.jp's header (kehai.html in the sibling
littlebobert.github.io repository), in the app icon's black glass: the eight glass pieces
of its 回 lift off the cream and turn askew, like windows tossed onto a desk, then settle
back into place one after another, the inner square first, and a glint of light crosses
the glass. The loop starts and ends on the app icon itself.

Built from the icon: each piece is cut out of it with its glass rim, the cream behind is
filled in, and the pieces cast their own shadows while they move. Writes
kehai-icon-sketch.mp4 and, for Reduce Motion or a blocked video, the icon as
kehai-icon-sketch.jpg, both 224 px, into Kehai/Resources and the site's assets. The page
loads them with ?v= cache versions: bump those after a change. Nothing is committed or
pushed.

    /usr/bin/python3 Scripts/make-landing-animation.py [ICON.png] [--preview DIR]

ICON defaults to Kehai/Resources/AppIconSource.png. --preview writes a contact sheet of
frames to DIR instead of the videos. Needs Pillow (macOS's /usr/bin/python3 has it) and
ffmpeg. Replaces make-landing-sketch.mjs, the pencil flipbook it used to be.
"""
import math
import shutil
import subprocess
import sys
import tempfile
from collections import deque
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

root = Path(__file__).resolve().parent.parent
args = sys.argv[1:]
preview_dir = None
if "--preview" in args:
    i = args.index("--preview")
    preview_dir = Path(args[i + 1])
    del args[i:i + 2]
icon_path = Path(args[0]) if args else root / "Kehai/Resources/AppIconSource.png"
out_dirs = [root / "Kehai/Resources", root.parent / "littlebobert.github.io/assets"]

SIZE = 1024
OUT = 224
FPS = 30
W = SIZE

icon = Image.open(icon_path).convert("RGB").resize((SIZE, SIZE), Image.LANCZOS)
lum = icon.convert("L")


def flood(mask, seeds):
    """Grows labelled seeds through `mask` (a bytearray, nonzero = open) breadth first, so
    each open pixel joins the nearest seed. seeds: {index: label}. Returns the labels."""
    labels = [0] * (W * W)
    queue = deque()
    for index, label in seeds.items():
        labels[index] = label
        queue.append(index)
    while queue:
        i = queue.popleft()
        x = i % W
        for j in (i - 1 if x > 0 else -1, i + 1 if x < W - 1 else -1, i - W, i + W):
            if 0 <= j < W * W and mask[j] and not labels[j]:
                labels[j] = labels[i]
                queue.append(j)
    return labels


def components(mask):
    """Connected regions of `mask`, largest first, as lists of pixel indices."""
    seen = bytearray(W * W)
    found = []
    for start in range(W * W):
        if mask[start] and not seen[start]:
            seen[start] = 1
            queue, pixels = deque([start]), []
            while queue:
                i = queue.popleft()
                pixels.append(i)
                x = i % W
                for j in (i - 1 if x > 0 else -1, i + 1 if x < W - 1 else -1, i - W, i + W):
                    if 0 <= j < W * W and mask[j] and not seen[j]:
                        seen[j] = 1
                        queue.append(j)
            found.append(pixels)
    return sorted(found, key=len, reverse=True)


# --- The cream behind the glass -------------------------------------------------------
# The icon's cream is a soft gradient. Where it's untouched (no glass, no shadow) keep it,
# grain and all; fill the rest from the surrounding cream, wider and wider.
def normalized_blur(image, weight, radius):
    w = weight.filter(ImageFilter.GaussianBlur(radius))
    num = Image.composite(image, Image.new("RGB", image.size), weight).filter(ImageFilter.GaussianBlur(radius))
    # num / w, where w is large enough to trust.
    out = Image.new("RGB", image.size)
    n, wd = num.load(), w.load()
    o = out.load()
    for y in range(SIZE):
        for x in range(SIZE):
            k = wd[x, y]
            if k > 8:
                r, g, b = n[x, y]
                o[x, y] = (min(255, r * 255 // k), min(255, g * 255 // k), min(255, b * 255 // k))
    return out, w


rough = lum.point(lambda v: 255 if v >= 236 else 0)
estimate, _ = normalized_blur(icon, rough, 90)
est_lum = estimate.convert("L")
# Untouched cream: within a few levels of the cream around it, and well clear of the glass.
near_glass = lum.point(lambda v: 255 if v < 215 else 0).filter(ImageFilter.MaxFilter(31))
untouched = ImageChops.subtract(ImageChops.subtract(est_lum, lum).point(lambda v: 255 if v <= 3 else 0), near_glass)

def fitted_cream():
    """A smooth quadratic fit of the untouched cream, per channel: the gradient with no
    glass and no shadows on it."""
    keep, ic = untouched.load(), icon.load()
    rows = []
    for y in range(0, SIZE, 6):
        for x in range(0, SIZE, 6):
            if keep[x, y]:
                u, v = x / SIZE - 0.5, y / SIZE - 0.5
                rows.append(((1, u, v, u * u, u * v, v * v), ic[x, y]))
    coefficients = []
    for channel in range(3):
        # Normal equations, solved by Gaussian elimination.
        m = [[sum(r[0][i] * r[0][j] for r in rows) for j in range(6)] + [sum(r[0][i] * r[1][channel] for r in rows)] for i in range(6)]
        for i in range(6):
            pivot = max(range(i, 6), key=lambda k: abs(m[k][i]))
            m[i], m[pivot] = m[pivot], m[i]
            for k in range(6):
                if k != i:
                    f = m[k][i] / m[i][i]
                    m[k] = [a - f * b for a, b in zip(m[k], m[i])]
        coefficients.append([m[i][6] / m[i][i] for i in range(6)])
    cream = Image.new("RGB", (SIZE, SIZE))
    c = cream.load()
    for y in range(SIZE):
        v = y / SIZE - 0.5
        for x in range(SIZE):
            u = x / SIZE - 0.5
            terms = (1, u, v, u * u, u * v, v * v)
            c[x, y] = tuple(round(sum(k * t for k, t in zip(cs, terms))) for cs in coefficients)
    return cream


# The icon's cream is smooth enough to replace outright, which leaves no seam where the
# icon's own shadows ended.
plate = fitted_cream()

# --- The glass pieces ------------------------------------------------------------------
# Their dark bodies separate cleanly. Each then claims everything around it that's darker
# than the cream (its paler rim and its shadow), as a layer whose alpha is how much darker,
# and whose colour has the cream taken back out. Laid back over the cream, the pieces give
# the icon again.
lum_bytes = lum.tobytes()
cream_lum = plate.convert("L").tobytes()
dark = bytearray(1 if v < 150 else 0 for v in lum_bytes)
bodies = components(dark)[:8]
assert len(bodies) == 8 and len(bodies[7]) > 5000, "expected the icon's eight glass pieces"
seeds = {}
for label, pixels in enumerate(bodies, start=1):
    for i in pixels:
        seeds[i] = label
darker = bytearray(1 if c - v > 2 else 0 for v, c in zip(lum_bytes, cream_lum))
labels = flood(darker, seeds)
# The glass itself, rim included; the rest of what a piece claims is the shadow it casts
# lying down, which it leaves behind as it lifts.
solid_bytes = Image.frombytes("L", (SIZE, SIZE), bytes(255 if v < 185 else 0 for v in lum_bytes)).filter(ImageFilter.MaxFilter(5)).tobytes()

pieces = []
ic, cr = icon.load(), plate.load()
for label in range(1, 9):
    glass_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    shadow_layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    gl, sh = glass_layer.load(), shadow_layer.load()
    xs = ys = count = 0
    for i, l in enumerate(labels):
        if l != label:
            continue
        x, y = i % W, i // W
        bg = cream_lum[i]
        k = max(0, min(255, round((bg - lum_bytes[i]) * 255 / max(1, bg - 150))))
        if k == 0:
            continue
        t = k / 255
        colour = tuple(round(max(0, min(255, (a - (1 - t) * b) / t))) for a, b in zip(ic[x, y], cr[x, y]))
        if solid_bytes[i]:
            gl[x, y] = (*colour, k)
        else:
            sh[x, y] = (*colour, k)
        if lum_bytes[i] < 150:
            xs += x
            ys += y
            count += 1
    centre = (xs / count, ys / count)
    angle = math.atan2(centre[1] - 512, centre[0] - 512)
    distance = math.hypot(centre[0] - 512, centre[1] - 512)
    pieces.append({"glass": glass_layer.convert("RGBa"), "shadow": shadow_layer.convert("RGBa"),
                   "centre": centre, "angle": angle, "outer": distance > 250})

# Clockwise from the top, the inner square first, as they settle.
def clockwise(piece):
    return (piece["angle"] + math.pi / 2) % (2 * math.pi)
pieces.sort(key=lambda p: (p["outer"], clockwise(p)))


# --- Rendering ---------------------------------------------------------------------------
SHADOW = (70, 58, 44)
LIFTED_SHADOW = (30, 64, 34, 0.24)   # dx, dy, blur, strength of a piece's shadow when held up


def transformed(image, piece, dx, dy, turn, scale):
    """A layer of the piece moved by (dx, dy), turned by `turn` degrees and scaled about the
    piece's centre."""
    cx, cy = piece["centre"]
    t = math.radians(turn)
    cos, sin = math.cos(t) / scale, math.sin(t) / scale
    ox, oy = cx + dx, cy + dy
    # Inverse map: output (x, y) -> source.
    coeffs = (cos, sin, cx - cos * ox - sin * oy, -sin, cos, cy + sin * ox - cos * oy)
    return image.transform((SIZE, SIZE), Image.AFFINE, coeffs, Image.BICUBIC).convert("RGBA")


def shifted(mask, dx, dy):
    """`mask` moved by (dx, dy), with nothing wrapping round from the far edge."""
    out = Image.new("L", mask.size, 0)
    out.paste(mask, (dx, dy))
    return out


def render(states):
    """states: per piece (dx, dy, turn, scale, lift), lift 0 lying down to 1 held up."""
    frame = plate.copy()
    shadow_ink = Image.new("RGB", (SIZE, SIZE), SHADOW)
    glasses = []
    for piece, state in zip(pieces, states):
        lift = state[4]
        glass_layer = transformed(piece["glass"], piece, *state[:4])
        glasses.append(glass_layer)
        # Lying down, the shadow it was given; lifting, that fades and its own takes over,
        # further off and softer the higher it is.
        if lift < 1:
            baked = transformed(piece["shadow"], piece, *state[:4])
            frame = Image.composite(baked.convert("RGB"), frame, baked.getchannel("A").point(lambda v: round(v * (1 - lift))))
        if lift > 0:
            sx, sy, blur, strength = (v * min(1, 0.35 + lift) for v in LIFTED_SHADOW)
            cast = glass_layer.getchannel("A").filter(ImageFilter.GaussianBlur(blur))
            cast = shifted(cast, round(sx), round(sy)).point(lambda v: round(v * strength * min(1, lift * 3)))
            frame = Image.composite(shadow_ink, frame, cast)
    for glass_layer in glasses:
        frame = Image.composite(glass_layer.convert("RGB"), frame, glass_layer.getchannel("A"))
    return frame


union = Image.new("L", (SIZE, SIZE), 0)
for piece in pieces:
    union = ImageChops.lighter(union, piece["glass"].convert("RGBA").getchannel("A"))


def glint(frame, progress):
    """A band of light crossing the glass, top left to bottom right, on the pieces only."""
    # A soft vertical stripe on a canvas twice the size, tilted, then cut back to the icon.
    big = Image.new("L", (SIZE * 2, SIZE * 2), 0)
    x = SIZE * 0.35 + SIZE * 1.3 * progress
    ImageDraw.Draw(big).rectangle((x - 22, 0, x + 22, SIZE * 2), fill=255)
    big = big.filter(ImageFilter.GaussianBlur(16)).rotate(-28, Image.BICUBIC)
    band = big.crop((SIZE // 2, SIZE // 2, SIZE // 2 + SIZE, SIZE // 2 + SIZE))
    light = ImageChops.multiply(band, union).point(lambda v: round(v * 0.62))
    return Image.composite(Image.new("RGB", (SIZE, SIZE), (255, 252, 244)), frame, light)


ease_in_out = lambda t: t * t * (3 - 2 * t)
ease_out = lambda t: 1 - (1 - t) ** 3


def back(t):
    """Settles with a little overshoot, as glass set down rocks once."""
    c = 1.9
    return 1 + (c + 1) * (t - 1) ** 3 + c * (t - 1) ** 2


def lifted_state(piece, amount, drift=0.0):
    """Lifted toward the viewer, out from the centre and turned askew, the outer square one
    way and the inner the other. Big enough to read at the page's 56-point icon."""
    # The outer pieces are long, so a small turn swings their ends a long way: they move and
    # turn less, to stay inside the icon's rounded corners.
    out = (40 if piece["outer"] else 88) * amount
    turn = ((9 if piece["outer"] else -18) + 3 * drift) * amount
    return (math.cos(piece["angle"]) * out, math.sin(piece["angle"]) * out - 18 * amount,
            turn, 1 + 0.08 * amount, amount)


REST = [(0, 0, 0, 1, 0)] * 8
frames = []  # ("icon", glint progress or None) or ("pieces", states)
def hold(seconds, glint_progress=None):
    frames.extend([("icon", glint_progress)] * round(seconds * FPS))

hold(0.8)
# Lift, one after another round the square.
LIFT, STAGGER = 0.5, 0.035
n = round((LIFT + STAGGER * 7) * FPS)
for f in range(1, n + 1):
    t = f / FPS
    frames.append(("pieces", [lifted_state(p, ease_in_out(min(1, max(0, (t - STAGGER * k) / LIFT)))) for k, p in enumerate(pieces)]))
# Held up, drifting a touch further.
n = round(0.35 * FPS)
for f in range(1, n + 1):
    frames.append(("pieces", [lifted_state(p, 1, ease_in_out(f / n)) for p in pieces]))
# Set back down one by one, the inner square first.
DROP, STAGGER = 0.42, 0.075
n = round((DROP + STAGGER * 7) * FPS)
for f in range(1, n + 1):
    t = f / FPS
    states = []
    for k, p in enumerate(pieces):
        u = min(1, max(0, (t - STAGGER * k) / DROP))
        amount = 1 - back(u) if u < 1 else 0
        states.append(lifted_state(p, amount, 1) if amount else (0, 0, 0, 1, 0))
        if u >= 1:
            states[-1] = (0, 0, 0, 1, 0)
    frames.append(("pieces", states))
# Back to the icon itself, and the glint.
hold(0.15)
n = round(0.8 * FPS)
for f in range(1, n + 1):
    frames.append(("icon", f / n))
hold(1.3)

# Ease from the icon into the rebuilt pieces and back, so the switch doesn't show.
rebuilt_rest = render(REST)


def image_for(kind, value, index):
    if kind == "icon":
        return glint(icon, value) if value is not None else icon
    frame = render(value)
    # Blend with the real icon for the first and last few frames of movement.
    first = next(i for i, f in enumerate(frames) if f[0] == "pieces")
    last = max(i for i, f in enumerate(frames) if f[0] == "pieces")
    edge = min(index - first, last - index)
    if edge < 4:
        frame = Image.blend(icon, frame, (edge + 1) / 5)
    return frame


if preview_dir:
    preview_dir.mkdir(parents=True, exist_ok=True)
    picks = list(range(0, len(frames), max(1, len(frames) // 24)))
    thumbs = [image_for(*frames[i], i).resize((256, 256), Image.LANCZOS) for i in picks]
    sheet = Image.new("RGB", (256 * 6, 256 * math.ceil(len(thumbs) / 6)), (40, 40, 40))
    for k, thumb in enumerate(thumbs):
        sheet.paste(thumb, ((k % 6) * 256, (k // 6) * 256))
    sheet.save(preview_dir / "sheet.png")
    Image.blend(icon, rebuilt_rest, 1).save(preview_dir / "rebuilt-rest.png")
    plate.save(preview_dir / "plate.png")
    print(f"{len(frames)} frames, {len(frames) / FPS:.1f} s, sheet of {len(thumbs)}")
    sys.exit()

work = Path(tempfile.mkdtemp(prefix="kehai-glass-"))
cache = {}
for index, (kind, value) in enumerate(frames):
    key = (kind, value) if kind == "icon" else None
    if key is not None and key in cache:
        image = cache[key]
    else:
        image = image_for(kind, value, index).resize((OUT * 2, OUT * 2), Image.LANCZOS)
        if key is not None:
            cache[key] = image
    image.save(work / f"{index:04d}.png")
for out_dir in out_dirs:
    out_dir.mkdir(parents=True, exist_ok=True)
    icon.resize((OUT, OUT), Image.LANCZOS).save(out_dir / "kehai-icon-sketch.jpg", quality=92)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-framerate", str(FPS), "-i", str(work / "%04d.png"),
                    "-vf", f"scale={OUT}:{OUT}:flags=lanczos,format=yuv420p", "-c:v", "libx264", "-profile:v", "high",
                    "-crf", "20", "-preset", "slow", "-an", "-movflags", "+faststart", str(out_dir / "kehai-icon-sketch.mp4")], check=True)
shutil.rmtree(work)
print(f"{len(frames)} frames, {len(frames) / FPS:.1f} s")

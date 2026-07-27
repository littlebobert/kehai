#!/usr/bin/env python3
from pathlib import Path
import sys
from PIL import Image, ImageDraw, ImageFilter

if len(sys.argv) != 3:
    raise SystemExit("usage: generate-app-icon.py SOURCE OUTPUT_DIRECTORY")

source_path = Path(sys.argv[1])
output_directory = Path(sys.argv[2])
output_directory.mkdir(parents=True, exist_ok=True)

source = Image.open(source_path).convert("RGB")
side = min(source.size)
left = (source.width - side) // 2
top = (source.height - side) // 2
source = source.crop((left, top, left + side, top + side))
# Remove only a narrow source edge before applying the rounded icon silhouette.
edge_trim = round(side * 0.015)
source = source.crop((edge_trim, edge_trim, side - edge_trim, side - edge_trim))

canvas_size = 1024
art_size = 824
art_origin = (canvas_size - art_size) // 2
corner_radius = 178

art = source.resize((art_size, art_size), Image.Resampling.LANCZOS)
mask = Image.new("L", (art_size, art_size), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, art_size - 1, art_size - 1), radius=corner_radius, fill=255)

master = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
shadow = Image.new("RGBA", master.size, (0, 0, 0, 0))
shadow_shape = Image.new("L", master.size, 0)
ImageDraw.Draw(shadow_shape).rounded_rectangle(
    (art_origin + 4, art_origin + 18, art_origin + art_size - 4, art_origin + art_size + 10),
    radius=corner_radius,
    fill=115,
)
shadow_shape = shadow_shape.filter(ImageFilter.GaussianBlur(22))
shadow.putalpha(shadow_shape)
master.alpha_composite(shadow)
master.paste(art, (art_origin, art_origin), mask)

highlight = Image.new("RGBA", master.size, (0, 0, 0, 0))
ImageDraw.Draw(highlight).rounded_rectangle(
    (art_origin + 2, art_origin + 2, art_origin + art_size - 3, art_origin + art_size - 3),
    radius=corner_radius,
    outline=(255, 246, 218, 70),
    width=4,
)
master.alpha_composite(highlight)
master.save(output_directory / "AppIcon-1024.png")

representations = {
    "AppIcon-16.png": 16,
    "AppIcon-32.png": 32,
    "AppIcon-64.png": 64,
    "AppIcon-128.png": 128,
    "AppIcon-256.png": 256,
    "AppIcon-512.png": 512,
}
for filename, size in representations.items():
    master.resize((size, size), Image.Resampling.LANCZOS).save(output_directory / filename)

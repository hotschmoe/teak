#!/usr/bin/env python3
"""Pick, crop, pair and compress the QA shots into docs/images/showcase/ (called by tools/showcase.sh).

usage: showcase.py <tmp-dir> <out-dir>

Native shots are tmp/native/<example>-<state>@<scale>x.png, web shots tmp/web/<example>-<state>@1x.png.
Images are flat UI colours, so an adaptive 256-colour palette (no dithering) is visually lossless
and PNG-deflates well; needs Pillow.
"""
import os
import sys
from PIL import Image

tmp, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)

SINGLE = [  # (output name, native file)
    ("gallery-retro-controls", "gallery-retro_controls"), ("gallery-retro-inputs", "gallery-retro_inputs"),
    ("gallery-retro-data", "gallery-retro_data"), ("gallery-retro-overlays", "gallery-retro_overlays"),
    ("gallery-retro-layout", "gallery-retro_layout"), ("gallery-retro-scene", "gallery-retro_scene"),
    ("gallery-dark-controls", "gallery-dark_controls"), ("gallery-dark-data", "gallery-dark_data"),
    ("gallery-dark-overlays", "gallery-dark_overlays"), ("gallery-dark-layout", "gallery-dark_layout"),
    ("gallery-light-controls", "gallery-light_controls"), ("gallery-light-inputs", "gallery-light_inputs"),
    ("gallery-light-data", "gallery-light_data"), ("gallery-light-scene", "gallery-light_scene"),
    ("kerf-section", "kerf_viewer-section_hover"), ("kerf-iso", "kerf_viewer-iso"),
    ("kerf-3d-cut", "kerf_viewer-cut"), ("kerf-palette", "kerf_viewer-palette"), ("kerf-chat", "kerf_viewer-chat"),
    ("scene-layers", "scene_layers-initial"), ("notes", "notes-chat"),
    ("tables-100k", "tables-scrolled"), ("chrome-retro", "chrome-initial"),
    ("chrome-modern", "chrome-modern"), ("todo", "todo-three_items"),
]
PAIRS = [  # (output name, example, native state, web state)
    ("pair-gallery", "gallery", "retro_controls", "controls"),
    ("pair-kerf", "kerf_viewer", "section", "section"),
    ("pair-chrome-modern", "chrome", "modern", "modern"),
    ("pair-tables", "tables", "initial", "initial"),
]


def save(im, name):
    im = im.convert("RGB").quantize(colors=256, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    path = os.path.join(out, name + ".png")
    im.save(path, optimize=True)
    return os.path.getsize(path)


def load(kind, ex_state, scale=1):
    return Image.open(os.path.join(tmp, kind, f"{ex_state}@{scale}x.png"))


total = 0
n_images = 0
for name, src in SINGLE:
    total += save(load("native", src), name)
    n_images += 1

# HarfBuzz notes shot: only when the script fonts were found (tools/showcase.sh)
hb = os.path.join(tmp, "native", "notes-scripts@1x.png")
if os.path.exists(hb):
    total += save(Image.open(hb), "notes-scripts-harfbuzz")
    n_images += 1

# platform shots taken on other machines (env: SHOWCASE_MAC / SHOWCASE_WIN = path to a PNG)
for name, env in [("platform-macos", "SHOWCASE_MAC"), ("platform-windows-arm64", "SHOWCASE_WIN")]:
    path = os.environ.get(env)
    if path and os.path.exists(path):
        total += save(Image.open(path), name)
        n_images += 1

for name, ex, ns, ws in PAIRS:
    a = load("native", f"{ex}-{ns}")
    b = load("web", f"{ex}-{ws}")
    w = 800  # each half, so the pair stays readable at ~1600 px
    a = a.resize((w, round(a.height * w / a.width)), Image.LANCZOS)
    b = b.resize((w, round(b.height * w / b.width)), Image.LANCZOS)
    pair = Image.new("RGB", (2 * w + 8, max(a.height, b.height)), (128, 128, 128))
    pair.paste(a, (0, 0))
    pair.paste(b, (w + 8, 0))
    total += save(pair, name)

# one 2x HiDPI crop: device pixels, no resampling
hi = load("native", "kerf_viewer-section_hover", 2)
total += save(hi.crop((780, 440, 1580, 1000)), "hidpi-2x-crop")

print(f"wrote {n_images + len(PAIRS) + 1} images, {total / 1e6:.2f} MB, to {out}")

#!/usr/bin/env python3
"""Prepare a 2x2 transparent sprite sheet for BlueFish.

The generated sheet is not always split exactly on the half-way lines, so the
split coordinates can be supplied manually.

    python3 scripts/prepare_sheet.py dsh-image-gen/image-a5bdf8f9.png --split 570,620
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Assets"
NAMES = ["idle", "work", "happy", "panic"]


def clean_alpha(img: Image.Image, erode: int = 1) -> Image.Image:
    arr = np.array(img).astype(np.uint8)
    alpha = arr[..., 3]
    # Kill the faint, near-invisible matte halo the generator leaves behind.
    alpha = np.where(alpha < 28, 0, alpha).astype(np.uint8)
    alpha_img = Image.fromarray(alpha, "L")
    if erode > 0:
        alpha_img = alpha_img.filter(ImageFilter.MinFilter(3 if erode == 1 else 5))
        # Feather the freshly eroded edge by a hair so it does not look cut out.
        alpha_img = alpha_img.filter(ImageFilter.GaussianBlur(0.6))
    arr[..., 3] = np.array(alpha_img)
    return Image.fromarray(arr, "RGBA")


def trim(img: Image.Image, pad: int = 14) -> Image.Image:
    bbox = img.getchannel("A").point(lambda v: 255 if v > 12 else 0).getbbox()
    if bbox is None:
        raise SystemExit("empty sprite")
    left, top, right, bottom = bbox
    return img.crop((max(0, left - pad), max(0, top - pad), min(img.width, right + pad), min(img.height, bottom + pad)))


def make_icon(happy: Image.Image, out: Path) -> None:
    size = 1024
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    grad = Image.new("RGB", (1, size))
    top = np.array([12, 33, 92], dtype=np.float32)
    bottom = np.array([3, 9, 30], dtype=np.float32)
    for y in range(size):
        t = y / (size - 1)
        grad.putpixel((0, y), tuple(int(v) for v in (top * (1 - t) + bottom * t)))
    grad = grad.resize((size, size))
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle((30, 30, size - 30, size - 30), radius=226, fill=255)
    canvas.paste(grad, (0, 0), mask)

    rng = np.random.default_rng(11)
    bubbles = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bubbles)
    for _ in range(28):
        x = int(rng.uniform(70, size - 70))
        y = int(rng.uniform(70, size - 70))
        rad = int(rng.uniform(5, 30))
        a = int(rng.uniform(18, 52))
        bd.ellipse((x - rad, y - rad, x + rad, y + rad), outline=(150, 225, 255, a), width=max(2, rad // 6))
    bubbles = bubbles.filter(ImageFilter.GaussianBlur(1.2))
    canvas = Image.alpha_composite(canvas, bubbles)

    sprite = happy.copy()
    target_h = 850
    scale = target_h / sprite.height
    sprite = sprite.resize((max(1, int(sprite.width * scale)), target_h), Image.LANCZOS)
    if sprite.width > size - 70:
        scale = (size - 70) / sprite.width
        sprite = sprite.resize((size - 70, int(sprite.height * scale)), Image.LANCZOS)
    sx = (size - sprite.width) // 2
    sy = size - sprite.height - 40

    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.ellipse((size // 2 - 245, size - 120, size // 2 + 245, size - 40), fill=(0, 0, 0, 115))
    shadow = shadow.filter(ImageFilter.GaussianBlur(30))
    canvas = Image.alpha_composite(canvas, shadow)
    canvas.alpha_composite(sprite, (sx, sy))
    canvas.save(out)

    iconset = ROOT / "build" / "AppIcon.iconset"
    iconset.mkdir(parents=True, exist_ok=True)
    for base in (16, 32, 128, 256, 512):
        for suffix, mult in (("", 1), ("@2x", 2)):
            canvas.resize((base * mult, base * mult), Image.LANCZOS).save(iconset / f"icon_{base}x{base}{suffix}.png")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("--split", default="", help="x,y split lines inside the sheet")
    parser.add_argument("--erode", type=int, default=1)
    parser.add_argument("--alpha-threshold", type=int, default=28)
    args = parser.parse_args()

    src = Path(args.source).resolve()
    sheet = Image.open(src).convert("RGBA")
    w, h = sheet.size
    if args.split:
        sx, sy = (int(v) for v in args.split.split(","))
    else:
        sx, sy = w // 2, h // 2

    sheet = clean_alpha(sheet, erode=args.erode)

    boxes = {
        "idle": (0, 0, sx, sy),
        "work": (sx, 0, w, sy),
        "happy": (0, sy, sx, h),
        "panic": (sx, sy, w, h),
    }

    ASSETS.mkdir(exist_ok=True)
    meta = {"source": str(src), "sheet": [w, h], "split": [sx, sy], "sprites": {}}
    for name in NAMES:
        cell = sheet.crop(boxes[name])
        sprite = trim(cell)
        max_side = 760
        if max(sprite.size) > max_side:
            s = max_side / max(sprite.size)
            sprite = sprite.resize((max(1, round(sprite.width * s)), max(1, round(sprite.height * s))), Image.LANCZOS)
        out = ASSETS / f"pet_{name}.png"
        sprite.save(out, optimize=True)
        meta["sprites"][name] = {"file": out.name, "size": list(sprite.size)}
        print(f"{name:6s} -> {out.relative_to(ROOT)} {sprite.size}")

    make_icon(Image.open(ASSETS / "pet_happy.png"), ASSETS / "icon.png")
    (ASSETS / "sprites.json").write_text(json.dumps(meta, indent=2, ensure_ascii=False) + "\n")
    print("icon  -> Assets/icon.png")


if __name__ == "__main__":
    main()

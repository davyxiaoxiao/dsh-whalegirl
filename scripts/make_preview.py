#!/usr/bin/env python3
"""Compose the README preview image from the live view snapshots."""

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
SNAP = ROOT / "snapshots"
OUT = ROOT / "preview.png"

FONT = "/System/Library/Fonts/Hiragino Sans GB.ttc"
W, H = 1600, 1000


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT, size, index=1 if bold else 0)


def gradient() -> Image.Image:
    top = np.array([14, 36, 86], dtype=np.float32)
    bottom = np.array([3, 7, 18], dtype=np.float32)
    arr = np.zeros((H, W, 3), dtype=np.uint8)
    for y in range(H):
        t = y / (H - 1)
        arr[y, :, :] = (top * (1 - t) + bottom * t).astype(np.uint8)
    return Image.fromarray(arr, "RGB")


def add_shadow(canvas: Image.Image, sprite: Image.Image, xy: tuple[int, int], blur=26) -> None:
    alpha = sprite.getchannel("A").filter(ImageFilter.GaussianBlur(blur))
    shadow = Image.new("RGBA", sprite.size, (0, 0, 0, 0))
    shadow.putalpha(alpha.point(lambda v: int(v * 0.55)))
    canvas.alpha_composite(shadow, xy)


def main() -> None:
    base = gradient().convert("RGBA")

    # Soft cyan halo and bokeh.
    overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    for (x, y, r, a) in [
        (290, 640, 330, 34), (1250, 620, 380, 30), (1450, 180, 120, 22),
        (200, 140, 80, 18), (760, 860, 160, 14),
    ]:
        draw.ellipse((x - r, y - r, x + r, y + r), fill=(70, 170, 255, a))
    overlay = overlay.filter(ImageFilter.GaussianBlur(70))
    base = Image.alpha_composite(base, overlay)

    rng = np.random.default_rng(4)
    bub = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bub)
    for _ in range(60):
        x = int(rng.uniform(0, W))
        y = int(rng.uniform(0, H))
        r = int(rng.uniform(2, 10))
        a = int(rng.uniform(12, 42))
        bd.ellipse((x - r, y - r, x + r, y + r), outline=(150, 225, 255, a), width=1)
    base = Image.alpha_composite(base, bub.filter(ImageFilter.GaussianBlur(0.4)))

    # Card.
    card = Image.open(SNAP / "08_card.png").convert("RGBA")
    card = card.resize((int(840 * 0.62), int(1088 * 0.62)), Image.LANCZOS)
    card_xy = (100, 250)
    add_shadow(base, card, card_xy, blur=30)
    base.alpha_composite(card, card_xy)

    # Pet (working pose, with its status chip).
    pet = Image.open(SNAP / "10_working_bubble.png").convert("RGBA")
    pet = pet.resize((int(720 * 0.78), int(800 * 0.78)), Image.LANCZOS)
    pet_xy = (980, 275)
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((pet_xy[0] + 120, pet_xy[1] + 170, pet_xy[0] + 540, pet_xy[1] + 620), fill=(80, 180, 255, 42))
    base = Image.alpha_composite(base, glow.filter(ImageFilter.GaussianBlur(70)))
    add_shadow(base, pet, pet_xy, blur=24)
    base.alpha_composite(pet, pet_xy)

    draw = ImageDraw.Draw(base)
    draw.text((96, 86), "鲸鱼娘", font=font(74, True), fill=(235, 246, 255, 255))
    draw.text((100, 180), "DeepSeek Harness 桌面宠物", font=font(26), fill=(150, 195, 235, 255))
    draw.text((100, 222), "吃白饭的时候，也帮你盯着任务。", font=font(18), fill=(120, 162, 205, 255))
    draw.text((100, 925), "Swift + AppKit  ·  常驻桌面  ·  只读 ~/.dsh  ·  macOS 13+", font=font(16), fill=(120, 160, 200, 230))

    # A small tag on the pet side.
    tag_font = font(15)
    label = "干饭中 · 吃白饭也要看日志"
    tw = int(draw.textlength(label, font=tag_font))
    draw.rounded_rectangle((1010, 905, 1010 + tw + 34, 943), radius=19, fill=(10, 24, 50, 210), outline=(70, 160, 220, 120))
    draw.ellipse((1024, 917, 1034, 927), fill=(70, 200, 255, 255))
    draw.text((1044, 913), label, font=tag_font, fill=(190, 225, 250, 255))

    base.convert("RGB").save(OUT, optimize=True)
    print("wrote", OUT, base.size)


if __name__ == "__main__":
    main()

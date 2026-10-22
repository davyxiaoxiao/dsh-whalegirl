#!/usr/bin/env python3
"""Cut a horizontal walk-cycle sheet into aligned drag frames.

All frames are placed on an identical canvas, aligned by the head centre and
the ground line. Without this the crops have slightly different sizes and the
pet jitters / flickers while the frames alternate.

    python3 scripts/prepare_walk.py dsh-image-gen/image-bdf45770.png --splits 417,836
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
from PIL import Image

from prepare_sheet import clean_alpha, trim

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "Assets"
NAMES = ["pet_walk_a.png", "pet_walk_b.png", "pet_walk_c.png"]


def align(frames: list[Image.Image], height: int = 760, margin: int = 20) -> list[Image.Image]:
    scaled: list[Image.Image] = []
    for frame in frames:
        scale = height / frame.height
        scaled.append(frame.resize((max(1, round(frame.width * scale)), height), Image.LANCZOS))

    anchors: list[tuple[float, int]] = []
    for frame in scaled:
        alpha = np.array(frame)[..., 3]
        ys, xs = np.where(alpha > 40)
        if len(ys) == 0:
            anchors.append((frame.width / 2, frame.height))
            continue
        top, bottom = int(ys.min()), int(ys.max())
        head_band = alpha[top:top + max(1, (bottom - top) // 4)]
        hy, hx = np.where(head_band > 40)
        head_cx = float(hx.mean()) if len(hx) else frame.width / 2
        anchors.append((head_cx, bottom))

    half = max(
        max(cx, frame.width - cx) for frame, (cx, _) in zip(scaled, anchors)
    ) + margin
    canvas_w = int(half * 2)
    canvas_h = height + margin * 2

    out: list[Image.Image] = []
    for frame, (cx, bottom) in zip(scaled, anchors):
        canvas = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
        x = int(round(half - cx))
        y = int(canvas_h - margin - bottom)
        canvas.alpha_composite(frame, (max(0, x), max(0, y)))
        out.append(canvas)
    return out


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", nargs="?", default="dsh-image-gen/image-bdf45770.png")
    parser.add_argument("--splits", default="", help="comma separated x split lines")
    parser.add_argument("--height", type=int, default=760)
    args = parser.parse_args()

    src = Path(args.source).resolve()
    sheet = clean_alpha(Image.open(src).convert("RGBA"), erode=1)
    w, h = sheet.size

    cuts = [int(v) for v in args.splits.split(",") if v.strip()] if args.splits else []
    bounds = [0] + cuts + [w]
    boxes = [(bounds[i], 0, bounds[i + 1], h) for i in range(len(bounds) - 1)]
    frames = align([trim(sheet.crop(box)) for box in boxes], height=args.height)

    for name, sprite in zip(NAMES, frames):
        out = ASSETS / name
        sprite.save(out, optimize=True)
        print(name, sprite.size)


if __name__ == "__main__":
    main()

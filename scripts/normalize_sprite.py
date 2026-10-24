#!/usr/bin/env python3
"""Normalise a freshly edited sprite: transparent or white background -> trimmed RGBA.

    python3 scripts/normalize_sprite.py in.png out.png [--pad 14]

White-background edits are keyed with a border flood fill; the remaining matte
fringe is removed by un-premultiplying the edge pixels against white.
"""
from __future__ import annotations

import argparse

import cv2
import numpy as np
from PIL import Image, ImageFilter


def from_alpha(im: Image.Image) -> Image.Image:
    arr = np.array(im).astype(np.uint8)
    alpha = arr[..., 3]
    a = np.where(alpha < 28, 0, alpha).astype(np.uint8)
    a = Image.fromarray(a, "L").filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(0.6))
    arr[..., 3] = np.array(a)
    return Image.fromarray(arr, "RGBA")


def from_white(im: Image.Image) -> Image.Image:
    arr = np.array(im.convert("RGB"))
    h, w = arr.shape[:2]
    mask = np.zeros((h + 2, w + 2), np.uint8)
    work = arr.copy()
    seeds = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1),
             (w // 2, 0), (w // 2, h - 1), (0, h // 2), (w - 1, h // 2)]
    for x, y in seeds:
        if work[y, x].min() >= 249:
            cv2.floodFill(work, mask, (x, y), (0, 0, 0),
                          loDiff=(7,) * 3, upDiff=(7,) * 3,
                          flags=4 | cv2.FLOODFILL_FIXED_RANGE)
    bg = mask[1:-1, 1:-1].astype(bool)
    alpha = np.where(bg, 0, 255).astype(np.uint8)
    alpha = cv2.erode(alpha, np.ones((3, 3), np.uint8), iterations=1)
    af = cv2.GaussianBlur(alpha, (0, 0), 0.7).astype(np.float32) / 255.0
    a = np.clip(af, 0.001, 1.0)[..., None]
    rgb = np.clip((arr.astype(np.float32) - (1 - a) * 255.0) / a, 0, 255)
    return Image.fromarray(np.dstack([rgb, af[..., None] * 255]).astype(np.uint8), "RGBA")


def trim(im: Image.Image, pad: int) -> Image.Image:
    bbox = im.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    if bbox is None:
        raise SystemExit("empty sprite")
    l, t, r, b = bbox
    return im.crop((max(0, l - pad), max(0, t - pad),
                    min(im.width, r + pad), min(im.height, b + pad)))


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("src")
    p.add_argument("dst")
    p.add_argument("--pad", type=int, default=14)
    args = p.parse_args()

    im = Image.open(args.src).convert("RGBA")
    arr = np.array(im)
    transparent = float((arr[..., 3] < 10).mean())
    out = from_alpha(im) if transparent > 0.05 else from_white(im)
    out = trim(out, args.pad)
    out.save(args.dst, optimize=True)
    print(f"{args.dst} {out.size} bg={'alpha' if transparent > 0.05 else 'white'}")


if __name__ == "__main__":
    main()

"""Synthesize golf-ball detection training images by compositing ball sprites
onto ball-free backgrounds.

Why: open golf-ball datasets are dominated by large, static, in-focus balls,
but the app sees 6-30 px balls on mats/grass at address and motion-blurred
streaks in flight. This script pastes real ball crops (from Open Images boxes)
and procedurally rendered balls (white/yellow range balls with dimple noise)
at small scales, with directional motion blur, shadows and photometric jitter.

Usage:
  python -I synth_balls.py --sprites-from <yolo_dir_with_images_and_labels> \
      --backgrounds <dir> [--backgrounds <dir> ...] --out <dir> --count 6000

Output: <out>/images/*.jpg and <out>/labels/*.txt (YOLO, class 0 = golf_ball).
"""
import argparse
import glob
import math
import os
import random

import cv2
import numpy as np

IMG_EXT = (".jpg", ".jpeg", ".png")


def load_real_sprites(yolo_dir, min_px=36, limit=400):
    """Crop large, single (non-group) golf balls from a YOLO dataset."""
    sprites = []
    for img_path in sorted(glob.glob(os.path.join(yolo_dir, "images", "*"))):
        lbl = os.path.join(yolo_dir, "labels", os.path.splitext(os.path.basename(img_path))[0] + ".txt")
        if not os.path.exists(lbl):
            continue
        im = cv2.imread(img_path)
        if im is None:
            continue
        h, w = im.shape[:2]
        for line in open(lbl):
            _, cx, cy, bw, bh = map(float, line.split())
            pw, ph = bw * w, bh * h
            # Round balls only: near-square boxes, big enough to downscale cleanly.
            if min(pw, ph) < min_px or max(pw, ph) / max(1, min(pw, ph)) > 1.25:
                continue
            x0, y0 = int((cx - bw / 2) * w), int((cy - bh / 2) * h)
            x1, y1 = int((cx + bw / 2) * w), int((cy + bh / 2) * h)
            crop = im[max(0, y0):y1, max(0, x0):x1]
            if crop.size == 0:
                continue
            side = max(crop.shape[:2])
            crop = cv2.resize(crop, (side, side), interpolation=cv2.INTER_AREA)
            sprites.append(crop)
            if len(sprites) >= limit:
                return sprites
    return sprites


def render_procedural_ball(size=96, rng=random):
    """White (or tinted range) ball: Lambert shading + specular + dimple noise."""
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    c = (size - 1) / 2
    r = size / 2 - 1
    nx, ny = (xx - c) / r, (yy - c) / r
    d2 = nx ** 2 + ny ** 2
    inside = d2 <= 1
    nz = np.sqrt(np.clip(1 - d2, 0, 1))
    lx, ly, lz = rng.uniform(-0.6, 0.6), rng.uniform(-0.9, -0.2), 0.8
    ln = math.sqrt(lx * lx + ly * ly + lz * lz)
    lambert = np.clip((nx * lx + ny * ly + nz * lz) / ln, 0, 1)
    shade = 0.35 + 0.65 * lambert
    spec = np.clip((nx * lx + ny * ly + nz * lz) / ln, 0, 1) ** rng.uniform(18, 40)
    dimples = cv2.GaussianBlur(np.random.rand(size, size).astype(np.float32), (0, 0), size / 40 + 0.5)
    dimples = (dimples - dimples.mean()) * rng.uniform(0.6, 1.6)
    tints = [(1.0, 1.0, 1.0)] * 6 + [(0.55, 0.95, 1.0), (0.45, 0.65, 1.0), (0.8, 0.75, 1.0)]  # BGR: white, yellow, orange, pink
    tint = np.array(rng.choice(tints), dtype=np.float32)
    base = np.clip(shade + dimples * 0.15 + spec * 0.6, 0, 1)
    img = (base[..., None] * tint[None, None, :] * rng.uniform(200, 255)).clip(0, 255).astype(np.uint8)
    img[~inside] = 0
    return img


def circular_alpha(size, feather=1.5):
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    c = (size - 1) / 2
    dist = np.sqrt((xx - c) ** 2 + (yy - c) ** 2)
    r = size / 2 * 0.96
    return np.clip((r - dist) / max(feather, 0.5) + 0.5, 0, 1)


def motion_kernel(length, angle_deg):
    length = max(1, int(round(length)))
    k = np.zeros((length * 2 + 1, length * 2 + 1), np.float32)
    c = length
    dx, dy = math.cos(math.radians(angle_deg)), math.sin(math.radians(angle_deg))
    for t in np.linspace(-length / 2, length / 2, length * 4):
        k[int(round(c + dy * t)), int(round(c + dx * t))] = 1
    return k / k.sum()


def paste_ball(bg, sprite, diameter, cx, cy, blur_len, blur_angle, rng):
    """Alpha-composite a resized, optionally motion-blurred ball. Returns bbox."""
    d = max(3, int(round(diameter)))
    spr = cv2.resize(sprite, (d, d), interpolation=cv2.INTER_AREA).astype(np.float32)
    alpha = circular_alpha(d, feather=max(0.6, d / 24))
    pad = int(blur_len) + 2
    canvas = np.zeros((d + 2 * pad, d + 2 * pad, 3), np.float32)
    acanvas = np.zeros((d + 2 * pad, d + 2 * pad), np.float32)
    canvas[pad:pad + d, pad:pad + d] = spr * alpha[..., None]
    acanvas[pad:pad + d, pad:pad + d] = alpha
    if blur_len >= 1.5:
        k = motion_kernel(blur_len, blur_angle)
        canvas = cv2.filter2D(canvas, -1, k)
        acanvas = cv2.filter2D(acanvas, -1, k)
    # Exposure match: pull the sprite toward the local background brightness a bit.
    H, W = bg.shape[:2]
    S = canvas.shape[0]
    x0, y0 = int(cx - S / 2), int(cy - S / 2)
    x1, y1 = x0 + S, y0 + S
    if x0 < 0 or y0 < 0 or x1 > W or y1 > H:
        return None
    region = bg[y0:y1, x0:x1].astype(np.float32)
    gain = rng.uniform(0.75, 1.1)
    premult = canvas * gain
    a = acanvas[..., None]
    out = premult + region * (1 - a)
    bg[y0:y1, x0:x1] = np.clip(out, 0, 255).astype(np.uint8)
    ys, xs = np.where(acanvas > 0.25)
    if len(xs) == 0:
        return None
    return (x0 + xs.min(), y0 + ys.min(), x0 + xs.max() + 1, y0 + ys.max() + 1)


def add_shadow(bg, cx, cy, diameter, rng):
    H, W = bg.shape[:2]
    ax, ay = int(diameter * rng.uniform(0.5, 0.9)), int(diameter * rng.uniform(0.12, 0.25))
    mask = np.zeros((H, W), np.float32)
    cv2.ellipse(mask, (int(cx + diameter * 0.15), int(cy + diameter * 0.45)), (max(1, ax), max(1, ay)), 0, 0, 360, 1, -1)
    mask = cv2.GaussianBlur(mask, (0, 0), max(1, diameter / 6))
    bg[:] = np.clip(bg.astype(np.float32) * (1 - 0.35 * mask[..., None]), 0, 255).astype(np.uint8)


def random_crop_640(img, rng, size=640):
    h, w = img.shape[:2]
    scale = rng.uniform(0.5, 1.2) * size / min(h, w)
    scale = max(scale, size / min(h, w))
    img = cv2.resize(img, (int(w * scale) + 1, int(h * scale) + 1), interpolation=cv2.INTER_AREA)
    h, w = img.shape[:2]
    x0, y0 = rng.randint(0, w - size), rng.randint(0, h - size)
    return img[y0:y0 + size, x0:x0 + size].copy()


def photometric(img, rng):
    img = img.astype(np.float32)
    img = img * rng.uniform(0.75, 1.25) + rng.uniform(-20, 20)
    if rng.random() < 0.5:
        img += np.random.normal(0, rng.uniform(2, 8), img.shape)
    img = np.clip(img, 0, 255).astype(np.uint8)
    if rng.random() < 0.6:
        q = rng.randint(55, 92)
        img = cv2.imdecode(cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, q])[1], cv2.IMREAD_COLOR)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sprites-from", required=True)
    ap.add_argument("--backgrounds", action="append", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--count", type=int, default=6000)
    ap.add_argument("--negatives", type=float, default=0.08, help="fraction of images with no balls")
    ap.add_argument("--seed", type=int, default=7)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    np.random.seed(args.seed)
    real = load_real_sprites(args.sprites_from)
    print(f"real sprites: {len(real)}")
    bgs = [p for d in args.backgrounds for p in glob.glob(os.path.join(d, "**", "*"), recursive=True)
           if p.lower().endswith(IMG_EXT)]
    print(f"backgrounds: {len(bgs)}")
    os.makedirs(os.path.join(args.out, "images"), exist_ok=True)
    os.makedirs(os.path.join(args.out, "labels"), exist_ok=True)

    written = 0
    while written < args.count:
        bg = cv2.imread(rng.choice(bgs))
        if bg is None or min(bg.shape[:2]) < 320:
            continue
        img = random_crop_640(bg, rng)
        labels = []
        if rng.random() >= args.negatives:
            for _ in range(rng.choice([1, 1, 1, 2, 2, 3])):
                # Log-uniform diameter: most balls tiny, like the real camera.
                diameter = math.exp(rng.uniform(math.log(5), math.log(56)))
                sprite = rng.choice(real) if (real and rng.random() < 0.55) else render_procedural_ball(96, rng)
                in_flight = rng.random() < 0.45
                if in_flight:
                    blur_len = rng.uniform(2, min(48, diameter * 4 + 6))
                    blur_angle = rng.choice([rng.uniform(-60, 0), rng.uniform(180, 240), rng.uniform(-180, 180)])
                    cy = rng.uniform(0.05, 0.85) * 640
                else:
                    blur_len, blur_angle = 0, 0
                    cy = rng.uniform(0.35, 0.95) * 640
                cx = rng.uniform(0.05, 0.95) * 640
                if not in_flight and rng.random() < 0.6:
                    add_shadow(img, cx, cy, diameter, rng)
                box = paste_ball(img, sprite, diameter, cx, cy, blur_len, blur_angle, rng)
                if box:
                    labels.append(box)
        img = photometric(img, rng)
        name = f"syn_{written:06d}"
        cv2.imwrite(os.path.join(args.out, "images", name + ".jpg"), img, [cv2.IMWRITE_JPEG_QUALITY, 92])
        with open(os.path.join(args.out, "labels", name + ".txt"), "w") as f:
            for x0, y0, x1, y1 in labels:
                f.write(f"0 {(x0 + x1) / 1280:.6f} {(y0 + y1) / 1280:.6f} {(x1 - x0) / 640:.6f} {(y1 - y0) / 640:.6f}\n")
        written += 1
        if written % 500 == 0:
            print(f"{written}/{args.count}")


if __name__ == "__main__":
    main()

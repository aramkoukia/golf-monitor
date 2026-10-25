"""Assemble the GolfDetector training set (classes: golf_ball, golf_club, club_head).

Small objects need native resolution: Ultralytics resizes every image to
imgsz, which shrinks a 15 px ball in a 1600 px photo to 6 px. So besides the
full image, each large image contributes 640x640 native-resolution crops
centred (with jitter) on its small objects and one random crop — the same
slicing the app uses at inference time (ROI / tiles around the ball).

Splits are decided per SOURCE image (all crops of an image share a split).

Usage:
  python -I build_dataset_v2.py --out <dir> --src <dir>[:tile|:asis][:weight] ... \
      [--negatives <img dir>:<count>] [--val-frac 0.1]
"""
import argparse
import hashlib
import os
import random
import shutil

import cv2
import numpy as np

NAMES = ["golf_ball", "golf_club", "club_head"]
CROP = 640


def split_of(key, frac):
    h = int(hashlib.md5(key.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
    return "val" if h < frac else "train"


def read_labels(path, w, h):
    out = []
    if os.path.exists(path):
        for line in open(path):
            p = line.split()
            if len(p) < 5:
                continue
            if len(p) > 5:  # polygon → bounding box
                xs, ys = list(map(float, p[1::2])), list(map(float, p[2::2]))
                p = [p[0], (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, max(xs) - min(xs), max(ys) - min(ys)]
            c, cx, cy, bw, bh = int(p[0]), *map(float, p[1:])
            out.append((c, (cx - bw / 2) * w, (cy - bh / 2) * h, (cx + bw / 2) * w, (cy + bh / 2) * h))
    return out


def write(img, labels, out, split, name):
    h, w = img.shape[:2]
    cv2.imwrite(os.path.join(out, "images", split, name + ".jpg"), img, [cv2.IMWRITE_JPEG_QUALITY, 92])
    with open(os.path.join(out, "labels", split, name + ".txt"), "w") as f:
        for c, x0, y0, x1, y1 in labels:
            f.write(f"{c} {(x0 + x1) / 2 / w:.6f} {(y0 + y1) / 2 / h:.6f} {(x1 - x0) / w:.6f} {(y1 - y0) / h:.6f}\n")


def blur_box(img, b):
    x0, y0, x1, y1 = [int(round(v)) for v in b]
    x0, y0, x1, y1 = max(0, x0), max(0, y0), min(img.shape[1], x1), min(img.shape[0], y1)
    if x1 - x0 >= 2 and y1 - y0 >= 2:
        k = max(3, (max(x1 - x0, y1 - y0) // 2) * 2 + 1)
        img[y0:y1, x0:x1] = cv2.GaussianBlur(img[y0:y1, x0:x1], (k, k), 0)


def crop(img, labels, x0, y0):
    """640 crop at (x0, y0) with labels clipped; partial objects blurred out."""
    patch = img[y0:y0 + CROP, x0:x0 + CROP].copy()
    out = []
    for c, a0, b0, a1, b1 in labels:
        area = max(1e-6, (a1 - a0) * (b1 - b0))
        i0, j0 = max(a0, x0), max(b0, y0)
        i1, j1 = min(a1, x0 + CROP), min(b1, y0 + CROP)
        inter = max(0, i1 - i0) * max(0, j1 - j0)
        frac = inter / area
        box = (i0 - x0, j0 - y0, i1 - x0, j1 - y0)
        if frac >= 0.6:
            out.append((c, *box))
        elif frac > 0.05 and c != 1:  # partial ball/head: hide it; a partial club shaft is fine unlabeled
            blur_box(patch, box)
        elif frac > 0.05 and c == 1 and frac >= 0.3:
            out.append((c, *box))
    return patch, out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--src", action="append", required=True)
    ap.add_argument("--negatives", action="append", default=[])
    ap.add_argument("--val-frac", type=float, default=0.1)
    ap.add_argument("--seed", type=int, default=3)
    a = ap.parse_args()
    rng = random.Random(a.seed)
    if os.path.exists(a.out):
        shutil.rmtree(a.out)
    for s in ("train", "val"):
        os.makedirs(os.path.join(a.out, "images", s))
        os.makedirs(os.path.join(a.out, "labels", s))
    stats = {"train": 0, "val": 0, "crops": 0, "negatives": 0, "boxes": [0, 0, 0]}

    for spec in a.src:
        parts = spec.split(":")
        path, mode = parts[0], (parts[1] if len(parts) > 1 else "tile")
        weight = int(parts[2]) if len(parts) > 2 else 1
        limit = int(parts[3]) if len(parts) > 3 else 10 ** 9          # max images from this source
        neg_limit = int(parts[4]) if len(parts) > 4 else 10 ** 9      # max label-less images
        tag = os.path.basename(path.rstrip("/"))
        files = sorted(os.listdir(os.path.join(path, "images")))
        rng.shuffle(files)
        used = negs = 0
        for fn in files:
            if used >= limit:
                break
            stem = os.path.splitext(fn)[0]
            lp = os.path.join(path, "labels", stem + ".txt")
            empty = not os.path.exists(lp) or os.path.getsize(lp) == 0
            if empty and negs >= neg_limit:
                continue
            img = cv2.imread(os.path.join(path, "images", fn))
            if img is None:
                continue
            used += 1
            negs += int(empty)
            h, w = img.shape[:2]
            labels = read_labels(lp, w, h)
            split = split_of(f"{tag}/{stem}", a.val_frac)
            for c, *_ in labels:
                stats["boxes"][c] += 1
            for r in range(weight if split == "train" else 1):
                write(img, labels, a.out, split, f"{tag}_{stem}_full{r}")
                stats[split] += 1
            if mode != "tile" or max(h, w) <= CROP * 1.15:
                continue
            # Native-resolution crops around small objects + one random crop.
            small = [l for l in labels if l[0] in (0, 2) or max(l[3] - l[1], l[4] - l[2]) < CROP * 0.5]
            rng.shuffle(small)
            centers = [((l[1] + l[3]) / 2, (l[2] + l[4]) / 2) for l in small[:3]]
            centers.append((rng.uniform(0, w), rng.uniform(0, h)))
            for k, (cx, cy) in enumerate(centers):
                x0 = int(np.clip(cx - CROP / 2 + rng.uniform(-200, 200), 0, max(0, w - CROP)))
                y0 = int(np.clip(cy - CROP / 2 + rng.uniform(-200, 200), 0, max(0, h - CROP)))
                patch, pl = crop(img, labels, x0, y0)
                if patch.shape[0] < CROP or patch.shape[1] < CROP:
                    pad = np.full((CROP, CROP, 3), 114, np.uint8)
                    pad[:patch.shape[0], :patch.shape[1]] = patch
                    patch = pad
                write(patch, pl, a.out, split, f"{tag}_{stem}_crop{k}")
                stats[split] += 1
                stats["crops"] += 1

    for spec in a.negatives:
        path, count = spec.rsplit(":", 1)
        files = sorted(f for f in os.listdir(path) if f.lower().endswith((".jpg", ".jpeg", ".png")))
        rng.shuffle(files)
        for fn in files[:int(count)]:
            img = cv2.imread(os.path.join(path, fn))
            if img is None:
                continue
            split = split_of("neg/" + fn, a.val_frac)
            write(img, [], a.out, split, "neg_" + os.path.splitext(fn)[0])
            stats[split] += 1
            stats["negatives"] += 1

    with open(os.path.join(a.out, "data.yaml"), "w") as f:
        f.write(f"path: {os.path.abspath(a.out)}\ntrain: images/train\nval: images/val\nnames:\n")
        for i, n in enumerate(NAMES):
            f.write(f"  {i}: {n}\n")
    print(stats)


if __name__ == "__main__":
    main()

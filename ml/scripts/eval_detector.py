"""Evaluate a trained GolfDetector against teacher pseudo-ground-truth on the
held-out CC0 swing clips (never used for training).

  1. Extract every Nth frame from the clips.
  2. Pseudo-GT = autolabel_teachers.py output on those frames (pass --gt).
  3. Student = Ultralytics .pt predictions, both full-frame (imgsz 640) and
     native-resolution 640 tiles (how the app runs it around the ball/club).
  4. Per-class precision/recall at IoU >= 0.3 + a contact sheet.

Usage:
  python eval_detector.py --model best.pt --frames <dir> --gt <teacher out dir> --sheet out.jpg
  python eval_detector.py --extract clip1.mp4 clip2.mp4 --every 12 --frames <dir>
"""
import argparse
import glob
import os

import cv2
import numpy as np

NAMES = ["golf_ball", "golf_club", "club_head"]


def iou(a, b):
    ix0, iy0, ix1, iy1 = max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])
    inter = max(0.0, ix1 - ix0) * max(0.0, iy1 - iy0)
    ua = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / ua if ua > 0 else 0.0


def load_gt(path, w, h):
    out = []
    if os.path.exists(path):
        for line in open(path):
            c, cx, cy, bw, bh = line.split()
            c, cx, cy, bw, bh = int(c), float(cx) * w, float(cy) * h, float(bw) * w, float(bh) * h
            out.append((c, cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2))
    return out


def predict_full(model, img, conf):
    r = model.predict(img, imgsz=640, conf=conf, verbose=False, device="cpu")[0]
    return [(int(c), *b, float(s)) for c, s, b in zip(r.boxes.cls.tolist(), r.boxes.conf.tolist(), r.boxes.xyxy.tolist())]


def predict_tiled(model, img, conf, tile=640, overlap=0.25):
    h, w = img.shape[:2]
    step = int(tile * (1 - overlap))
    dets = []
    for y0 in range(0, max(1, h - int(tile * overlap)), step):
        for x0 in range(0, max(1, w - int(tile * overlap)), step):
            t = img[y0:y0 + tile, x0:x0 + tile]
            r = model.predict(t, imgsz=640, conf=conf, verbose=False, device="cpu")[0]
            for c, s, b in zip(r.boxes.cls.tolist(), r.boxes.conf.tolist(), r.boxes.xyxy.tolist()):
                dets.append((int(c), b[0] + x0, b[1] + y0, b[2] + x0, b[3] + y0, float(s)))
    keep = []
    for d in sorted(dets, key=lambda d: -d[5]):
        if all(k[0] != d[0] or iou(k[1:5], d[1:5]) < 0.5 for k in keep):
            keep.append(d)
    return keep


def score(preds, gts, thr=0.3):
    tp = [0, 0, 0]; fp = [0, 0, 0]; fn = [0, 0, 0]
    for c in range(3):
        g = [x for x in gts if x[0] == c]
        p = sorted([x for x in preds if x[0] == c], key=lambda d: -d[5])
        used = set()
        for d in p:
            best, bi = 0, -1
            for i, x in enumerate(g):
                if i in used:
                    continue
                v = iou(d[1:5], x[1:5])
                if v > best:
                    best, bi = v, i
            if best >= thr:
                tp[c] += 1; used.add(bi)
            else:
                fp[c] += 1
        fn[c] += len(g) - len(used)
    return tp, fp, fn


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--extract", nargs="*", default=[])
    ap.add_argument("--every", type=int, default=12)
    ap.add_argument("--frames", required=True)
    ap.add_argument("--model")
    ap.add_argument("--gt")
    ap.add_argument("--conf", type=float, default=0.3)
    ap.add_argument("--sheet")
    a = ap.parse_args()

    if a.extract:
        os.makedirs(a.frames, exist_ok=True)
        for clip in a.extract:
            cap = cv2.VideoCapture(clip); i = 0
            stem = os.path.splitext(os.path.basename(clip))[0]
            while True:
                ok, f = cap.read()
                if not ok:
                    break
                if i % a.every == 0:
                    cv2.imwrite(os.path.join(a.frames, f"{stem}_f{i:04d}.jpg"), f, [cv2.IMWRITE_JPEG_QUALITY, 95])
                i += 1
        print("extracted", len(os.listdir(a.frames)))
        return

    from ultralytics import YOLO
    model = YOLO(a.model)
    totals = {m: ([0, 0, 0], [0, 0, 0], [0, 0, 0]) for m in ("full", "tiled")}
    tiles = []
    files = sorted(glob.glob(os.path.join(a.frames, "*.jpg")))
    for k, f in enumerate(files):
        img = cv2.imread(f); h, w = img.shape[:2]
        gt = load_gt(os.path.join(a.gt, "labels", os.path.basename(f)[:-4] + ".txt"), w, h)
        for mode, fn in (("full", predict_full), ("tiled", predict_tiled)):
            p = fn(model, img, a.conf)
            tp, fp, fnn = score(p, gt)
            for c in range(3):
                totals[mode][0][c] += tp[c]; totals[mode][1][c] += fp[c]; totals[mode][2][c] += fnn[c]
            if mode == "tiled" and a.sheet and k % max(1, len(files) // 16) == 0:
                vis = img.copy()
                for c, x0, y0, x1, y1 in gt:
                    cv2.rectangle(vis, (int(x0), int(y0)), (int(x1), int(y1)), (0, 255, 0), 1)
                for c, x0, y0, x1, y1, s in p:
                    col = [(0, 255, 255), (255, 160, 0), (255, 0, 255)][c]
                    cv2.rectangle(vis, (int(x0), int(y0)), (int(x1), int(y1)), col, 2)
                tiles.append(cv2.resize(vis, (270, 480)))
    for mode, (tp, fp, fn) in totals.items():
        parts = []
        for c in range(3):
            prec = tp[c] / max(1, tp[c] + fp[c]); rec = tp[c] / max(1, tp[c] + fn[c])
            parts.append(f"{NAMES[c]} P={prec:.2f} R={rec:.2f} (tp {tp[c]} fp {fp[c]} fn {fn[c]})")
        print(f"[{mode}] " + " | ".join(parts))
    if a.sheet and tiles:
        while len(tiles) % 8:
            tiles.append(np.zeros_like(tiles[0]))
        cv2.imwrite(a.sheet, np.vstack([np.hstack(tiles[i:i + 8]) for i in range(0, len(tiles), 8)]))


if __name__ == "__main__":
    main()

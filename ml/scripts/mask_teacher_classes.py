"""For datasets whose backgrounds are not reliably golf scenes (synthetic
composites), teacher club/head detections can be hallucinations. Keep the
original ground-truth classes and BLUR the teacher's detections of the other
classes, so the detector neither learns false labels nor sees unlabeled clubs.

Usage: python -I mask_teacher_classes.py <orig_dir> <teacher_dir> <out_dir> --keep 0 --mask 1 --mask 2
(each dir has images/ and labels/)
"""
import argparse
import os

import cv2


def boxes(path, w, h):
    out = []
    if os.path.exists(path):
        for line in open(path):
            c, cx, cy, bw, bh = line.split()
            c, cx, cy, bw, bh = int(c), float(cx) * w, float(cy) * h, float(bw) * w, float(bh) * h
            out.append((c, cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2, line))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("orig")
    ap.add_argument("teacher")
    ap.add_argument("out")
    ap.add_argument("--keep", type=int, action="append", default=[0])
    ap.add_argument("--mask", type=int, action="append", default=[])
    a = ap.parse_args()
    os.makedirs(os.path.join(a.out, "images"), exist_ok=True)
    os.makedirs(os.path.join(a.out, "labels"), exist_ok=True)
    masked = kept = 0
    for fn in sorted(os.listdir(os.path.join(a.orig, "images"))):
        stem = os.path.splitext(fn)[0]
        img = cv2.imread(os.path.join(a.orig, "images", fn))
        if img is None:
            continue
        h, w = img.shape[:2]
        gt = [b for b in boxes(os.path.join(a.orig, "labels", stem + ".txt"), w, h) if b[0] in a.keep]
        for c, x0, y0, x1, y1, _ in boxes(os.path.join(a.teacher, "labels", stem + ".txt"), w, h):
            if c not in a.mask:
                continue
            # Never blur over a kept ground-truth object.
            if any(not (x1 < g[1] or x0 > g[3] or y1 < g[2] or y0 > g[4]) for g in gt):
                continue
            x0, y0 = max(0, int(x0) - 3), max(0, int(y0) - 3)
            x1, y1 = min(w, int(x1) + 3), min(h, int(y1) + 3)
            if x1 - x0 >= 2 and y1 - y0 >= 2:
                k = max(3, (max(x1 - x0, y1 - y0) // 2) * 2 + 1)
                img[y0:y1, x0:x1] = cv2.GaussianBlur(cv2.blur(img[y0:y1, x0:x1], (k, k)), (k, k), 0)
                masked += 1
        cv2.imwrite(os.path.join(a.out, "images", stem + ".jpg"), img, [cv2.IMWRITE_JPEG_QUALITY, 92])
        with open(os.path.join(a.out, "labels", stem + ".txt"), "w") as f:
            for b in gt:
                f.write(b[5] if b[5].endswith("\n") else b[5] + "\n")
                kept += 1
    print(f"kept {kept} boxes, masked {masked} teacher detections")


if __name__ == "__main__":
    main()

"""Auto-label golf images / video frames with an open-vocabulary detector
(Ultralytics YOLOE-11L, text prompts) plus a pose model for the hands.

Classes written (YOLO format):
  0 golf_ball   — YOLOE "golf ball" boxes
  1 golf_club   — YOLOE "golf club" boxes (whole club)
  2 club_head   — derived: a square at the club-box corner farthest from the
                  golfer's hands (pose wrists), sized from the club length

Detections in the uncertain confidence band are painted out with a blurred
patch so they don't become false negatives during training.

Usage:
  python autolabel_yoloe.py --out <dir> [--images <dir>]... [--video <file> --every N]...
"""
import argparse
import glob
import math
import os

import cv2
import numpy as np
from ultralytics import YOLO, YOLOE

BALL_KEEP, BALL_DROP = 0.30, 0.12
CLUB_KEEP, CLUB_DROP = 0.45, 0.10


def frames_from_video(path, every):
    cap = cv2.VideoCapture(path)
    i = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if i % every == 0:
            yield f"{os.path.splitext(os.path.basename(path))[0]}_f{i:05d}", frame
        i += 1
    cap.release()


def frames_from_dir(d):
    for p in sorted(glob.glob(os.path.join(d, "*"))):
        if p.lower().endswith((".jpg", ".jpeg", ".png")):
            im = cv2.imread(p)
            if im is not None:
                yield os.path.splitext(os.path.basename(p))[0], im


def hands_of_main_person(pose_result):
    """Midpoint of both wrists of the largest person, or None."""
    if pose_result.keypoints is None or len(pose_result.boxes) == 0:
        return None
    boxes = pose_result.boxes.xyxy.cpu().numpy()
    areas = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
    i = int(np.argmax(areas))
    kp = pose_result.keypoints.data[i].cpu().numpy()  # 17 x 3
    lw, rw = kp[9], kp[10]
    pts = [p[:2] for p in (lw, rw) if p[2] > 0.35]
    if not pts:
        return None
    return np.mean(pts, axis=0)


def club_head_box(club, hands, w, h):
    x0, y0, x1, y1 = club
    corners = np.array([[x0, y0], [x1, y0], [x0, y1], [x1, y1]], dtype=np.float32)
    if hands is None:
        return None
    # Hands must be near the club box, otherwise the pairing is unreliable.
    margin = 0.25 * max(x1 - x0, y1 - y0)
    if not (x0 - margin <= hands[0] <= x1 + margin and y0 - margin <= hands[1] <= y1 + margin):
        return None
    far = corners[np.argmax(np.linalg.norm(corners - hands, axis=1))]
    length = math.hypot(x1 - x0, y1 - y0)
    side = float(np.clip(0.16 * length, 10, 0.2 * max(w, h)))
    cx = np.clip(far[0], side / 2, w - side / 2)
    cy = np.clip(far[1], side / 2, h - side / 2)
    return (cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2)


def paint_out(img, box):
    x0, y0, x1, y1 = [int(round(v)) for v in box]
    x0, y0 = max(0, x0 - 3), max(0, y0 - 3)
    x1, y1 = min(img.shape[1], x1 + 3), min(img.shape[0], y1 + 3)
    if x1 - x0 < 2 or y1 - y0 < 2:
        return
    patch = img[y0:y1, x0:x1]
    k = max(3, (max(x1 - x0, y1 - y0) // 2) * 2 + 1)
    img[y0:y1, x0:x1] = cv2.GaussianBlur(cv2.blur(patch, (k, k)), (k, k), 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--images", action="append", default=[])
    ap.add_argument("--video", action="append", default=[])
    ap.add_argument("--every", type=int, default=6)
    ap.add_argument("--imgsz", type=int, default=1280)
    ap.add_argument("--device", default="mps")
    ap.add_argument("--max-side", type=int, default=1600)
    a = ap.parse_args()

    os.makedirs(os.path.join(a.out, "images"), exist_ok=True)
    os.makedirs(os.path.join(a.out, "labels"), exist_ok=True)
    det = YOLOE("yoloe-11l-seg.pt")
    names = ["golf ball", "golf club"]
    det.set_classes(names, det.get_text_pe(names))
    pose = YOLO("yolo11n-pose.pt")

    sources = [frames_from_dir(d) for d in a.images] + [frames_from_video(v, a.every) for v in a.video]
    stats = {"images": 0, "ball": 0, "club": 0, "head": 0, "masked": 0}
    for src in sources:
        for stem, img in src:
            h, w = img.shape[:2]
            if max(h, w) > a.max_side:
                s = a.max_side / max(h, w)
                img = cv2.resize(img, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA)
                h, w = img.shape[:2]
            r = det.predict(img, conf=min(BALL_DROP, CLUB_DROP), imgsz=a.imgsz, device=a.device, verbose=False)[0]
            pr = pose.predict(img, conf=0.4, imgsz=640, device=a.device, verbose=False)[0]
            hands = hands_of_main_person(pr)
            labels, uncertain = [], []
            for c, s, b in zip(r.boxes.cls.tolist(), r.boxes.conf.tolist(), r.boxes.xyxy.tolist()):
                keep, drop = (BALL_KEEP, BALL_DROP) if c == 0 else (CLUB_KEEP, CLUB_DROP)
                if s >= keep:
                    labels.append((int(c), b))
                    if c == 1:
                        head = club_head_box(b, hands, w, h)
                        if head:
                            labels.append((2, head))
                elif s >= drop:
                    uncertain.append(b)
            # Don't paint over something we're keeping.
            for u in uncertain:
                if all(ioa(u, b) < 0.3 for _, b in labels):
                    paint_out(img, u)
                    stats["masked"] += 1
            cv2.imwrite(os.path.join(a.out, "images", stem + ".jpg"), img, [cv2.IMWRITE_JPEG_QUALITY, 92])
            with open(os.path.join(a.out, "labels", stem + ".txt"), "w") as f:
                for c, (x0, y0, x1, y1) in labels:
                    f.write(f"{c} {(x0 + x1) / 2 / w:.6f} {(y0 + y1) / 2 / h:.6f} {(x1 - x0) / w:.6f} {(y1 - y0) / h:.6f}\n")
                    stats[["ball", "club", "head"][c]] += 1
            stats["images"] += 1
            if stats["images"] % 100 == 0:
                print(stats, flush=True)
    print("DONE", stats)


def ioa(a, b):
    """Intersection over area of a."""
    ix0, iy0, ix1, iy1 = max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])
    inter = max(0, ix1 - ix0) * max(0, iy1 - iy0)
    return inter / max(1e-6, (a[2] - a[0]) * (a[3] - a[1]))


if __name__ == "__main__":
    main()

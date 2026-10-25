"""Pseudo-label golf images / video frames with teacher models (knowledge
distillation for the bundled GolfDetector).

Teachers (none are redistributed with the app):
  - club / club head: a Core ML Ultralytics detector with classes {club, head}
    (1280 px, NMS pipeline) — run with coremltools on macOS
  - golf ball: an ONNX YOLO11n single-class golf-ball detector (320 px),
    run on overlapping native-resolution tiles
  - hands: Ultralytics YOLO11n-pose wrists, used to reject "balls" that are
    gloves and to sanity-check club heads

Output classes (YOLO txt): 0 golf_ball, 1 golf_club, 2 club_head.
Detections in the uncertain confidence band are painted out (blurred) so
they don't turn into false negatives. Existing labels can be merged in
(--keep-existing-class 0 keeps ground-truth/synthetic balls).

Usage (export venv: coremltools + onnxruntime + ultralytics):
  python autolabel_teachers.py --club-model GolfTracer.mlmodel --ball-model ball.onnx \
     --pose-model yolo11n-pose.pt --out <dir> [--images <dir>]... [--video <file> --every N]... \
     [--existing-labels <dir> --keep-existing-class 0]
"""
import argparse
import glob
import os

import coremltools as ct
import cv2
import numpy as np
import onnxruntime as ort
from PIL import Image
from ultralytics import YOLO

BALL_KEEP, BALL_DROP = 0.55, 0.25
CLUB_KEEP, CLUB_DROP = 0.50, 0.15
HEAD_KEEP, HEAD_DROP = 0.40, 0.12


def iou(a, b):
    ix0, iy0, ix1, iy1 = max(a[0], b[0]), max(a[1], b[1]), min(a[2], b[2]), min(a[3], b[3])
    inter = max(0.0, ix1 - ix0) * max(0.0, iy1 - iy0)
    ua = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / ua if ua > 0 else 0.0


def nms(boxes, thr=0.45):
    keep = []
    for b in sorted(boxes, key=lambda x: -x[4]):
        if all(iou(b, k) < thr for k in keep):
            keep.append(b)
    return keep


class ClubTeacher:
    def __init__(self, path):
        self.m = ct.models.MLModel(path)
        self.side = 1280

    def __call__(self, bgr):
        h, w = bgr.shape[:2]
        s = self.side / max(h, w)
        nw, nh = int(round(w * s)), int(round(h * s))
        canvas = np.full((self.side, self.side, 3), 114, np.uint8)
        px, py = (self.side - nw) // 2, (self.side - nh) // 2
        canvas[py:py + nh, px:px + nw] = cv2.resize(bgr, (nw, nh), interpolation=cv2.INTER_AREA)
        out = self.m.predict({"image": Image.fromarray(canvas[:, :, ::-1]),
                              "iouThreshold": 0.45, "confidenceThreshold": min(CLUB_DROP, HEAD_DROP)})
        res = []
        for c, b in zip(out["confidence"], out["coordinates"]):
            k = int(np.argmax(c))
            cx, cy, bw, bh = (b * self.side).tolist()
            x0, y0 = (cx - bw / 2 - px) / s, (cy - bh / 2 - py) / s
            res.append((x0, y0, x0 + bw / s, y0 + bh / s, float(c[k]), k))  # k: 0 club, 1 head
        return res


class BallTeacher:
    def __init__(self, path):
        self.sess = ort.InferenceSession(path, providers=["CPUExecutionProvider"])
        self.inp = self.sess.get_inputs()[0].name
        self.side = 320

    def _tile(self, tile):
        h, w = tile.shape[:2]
        s = self.side / max(h, w)
        canvas = np.full((self.side, self.side, 3), 114, np.uint8)
        r = cv2.resize(tile, (max(1, int(w * s)), max(1, int(h * s))), interpolation=cv2.INTER_AREA)
        canvas[:r.shape[0], :r.shape[1]] = r
        x = canvas[:, :, ::-1].transpose(2, 0, 1)[None].astype(np.float32) / 255.0
        out = self.sess.run(None, {self.inp: x})[0][0]  # (5, N): cx, cy, w, h, conf
        keep = out[4] >= BALL_DROP
        return [(cx / s, cy / s, bw / s, bh / s, float(c)) for cx, cy, bw, bh, c in out[:, keep].T]

    def __call__(self, bgr):
        h, w = bgr.shape[:2]
        dets = []
        # Native-resolution tiles (balls are tiny), plus one whole-image pass
        # for close-up balls.
        step = 240
        for y0 in range(0, max(1, h - 80), step):
            for x0 in range(0, max(1, w - 80), step):
                for cx, cy, bw, bh, c in self._tile(bgr[y0:y0 + 320, x0:x0 + 320]):
                    dets.append((x0 + cx - bw / 2, y0 + cy - bh / 2, x0 + cx + bw / 2, y0 + cy + bh / 2, c))
        s = 320 / max(h, w)
        for cx, cy, bw, bh, c in self._tile(bgr):
            dets.append(((cx - bw / 2), (cy - bh / 2), (cx + bw / 2), (cy + bh / 2), c))
        return nms(dets, 0.4)


def hands(pose_model, bgr):
    r = pose_model.predict(bgr, conf=0.35, imgsz=640, verbose=False, device="cpu")[0]
    pts = []
    if r.keypoints is None:
        return pts
    for kp in r.keypoints.data.cpu().numpy():
        for j in (9, 10):  # wrists
            if kp[j][2] > 0.35:
                pts.append(kp[j][:2])
    return pts


def paint_out(img, box):
    x0, y0, x1, y1 = [int(round(v)) for v in box[:4]]
    x0, y0 = max(0, x0 - 3), max(0, y0 - 3)
    x1, y1 = min(img.shape[1], x1 + 3), min(img.shape[0], y1 + 3)
    if x1 - x0 < 2 or y1 - y0 < 2:
        return
    k = max(3, (max(x1 - x0, y1 - y0) // 2) * 2 + 1)
    img[y0:y1, x0:x1] = cv2.GaussianBlur(cv2.blur(img[y0:y1, x0:x1], (k, k)), (k, k), 0)


def frames(a):
    for d in a.images:
        for p in sorted(glob.glob(os.path.join(d, "*"))):
            if p.lower().endswith((".jpg", ".jpeg", ".png")):
                im = cv2.imread(p)
                if im is not None:
                    yield os.path.splitext(os.path.basename(p))[0], im
    for v in a.video:
        cap = cv2.VideoCapture(v)
        i = 0
        while True:
            ok, f = cap.read()
            if not ok:
                break
            if i % a.every == 0:
                yield f"{os.path.splitext(os.path.basename(v))[0]}_f{i:05d}", f
            i += 1
        cap.release()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--club-model", required=True)
    ap.add_argument("--ball-model", required=True)
    ap.add_argument("--pose-model", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--images", action="append", default=[])
    ap.add_argument("--video", action="append", default=[])
    ap.add_argument("--every", type=int, default=4)
    ap.add_argument("--max-side", type=int, default=1600)
    ap.add_argument("--existing-labels", default=None, help="dir of YOLO labels to merge (same stems)")
    ap.add_argument("--keep-existing-class", type=int, action="append", default=[])
    ap.add_argument("--remap", default="", help="existing class remap, e.g. '0:0,1:2,2:1'")
    ap.add_argument("--no-balls", action="store_true", help="don't pseudo-label balls (existing balls kept)")
    a = ap.parse_args()

    os.makedirs(os.path.join(a.out, "images"), exist_ok=True)
    os.makedirs(os.path.join(a.out, "labels"), exist_ok=True)
    club_t, ball_t, pose = ClubTeacher(a.club_model), BallTeacher(a.ball_model), YOLO(a.pose_model)
    stats = dict(images=0, ball=0, club=0, head=0, masked=0, rejected_balls=0)

    for stem, img in frames(a):
        h0, w0 = img.shape[:2]
        if max(h0, w0) > a.max_side:
            s = a.max_side / max(h0, w0)
            img = cv2.resize(img, (int(w0 * s), int(h0 * s)), interpolation=cv2.INTER_AREA)
        h, w = img.shape[:2]
        labels, uncertain = [], []

        if a.existing_labels:
            lp = os.path.join(a.existing_labels, stem + ".txt")
            if os.path.exists(lp):
                for line in open(lp):
                    vals = line.split()
                    if len(vals) < 5:
                        continue
                    if len(vals) > 5:  # polygon: class x1 y1 x2 y2 ... → bounding box
                        xs, ys = list(map(float, vals[1::2])), list(map(float, vals[2::2]))
                        vals = [vals[0], (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2, max(xs) - min(xs), max(ys) - min(ys)]
                    c, cx, cy, bw, bh = vals
                    remap = dict(tuple(map(int, kv.split(":"))) for kv in a.remap.split(",") if kv)
                    c = remap.get(int(c), int(c))
                    if int(c) in a.keep_existing_class:
                        cx, cy, bw, bh = float(cx) * w, float(cy) * h, float(bw) * w, float(bh) * h
                        labels.append((int(c), (cx - bw / 2, cy - bh / 2, cx + bw / 2, cy + bh / 2)))

        clubs = club_t(img)
        heads = [d for d in clubs if d[5] == 1]
        for x0, y0, x1, y1, c, k in clubs:
            keep, drop = (CLUB_KEEP, CLUB_DROP) if k == 0 else (HEAD_KEEP, HEAD_DROP)
            cls = 1 if k == 0 else 2
            if any(l[0] == cls and iou(l[1], (x0, y0, x1, y1)) > 0.3 for l in labels):
                continue  # ground truth already has it
            if c >= keep:
                labels.append((cls, (x0, y0, x1, y1)))
            elif c >= drop:
                uncertain.append((x0, y0, x1, y1))

        if not a.no_balls:
            wrists = hands(pose, img)
            hand_r = 0.035 * max(h, w)
            for x0, y0, x1, y1, c in ball_t(img):
                cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
                on_head = any(iou((x0, y0, x1, y1), hd) > 0.05 or (hd[0] <= cx <= hd[2] and hd[1] <= cy <= hd[3]) for hd in heads)
                on_hand = any(np.hypot(cx - p[0], cy - p[1]) < hand_r for p in wrists)
                if on_head or on_hand:
                    stats["rejected_balls"] += 1
                    continue
                if any(l[0] == 0 and iou(l[1], (x0, y0, x1, y1)) > 0.3 for l in labels):
                    continue  # already labeled (ground truth / synthetic)
                if c >= BALL_KEEP:
                    labels.append((0, (x0, y0, x1, y1)))
                elif c >= BALL_DROP:
                    uncertain.append((x0, y0, x1, y1))

        for u in uncertain:
            if all(iou(u, b) < 0.2 for _, b in labels):
                paint_out(img, u)
                stats["masked"] += 1

        cv2.imwrite(os.path.join(a.out, "images", stem + ".jpg"), img, [cv2.IMWRITE_JPEG_QUALITY, 92])
        with open(os.path.join(a.out, "labels", stem + ".txt"), "w") as f:
            for c, (x0, y0, x1, y1) in labels:
                x0, y0, x1, y1 = max(0, x0), max(0, y0), min(w, x1), min(h, y1)
                if x1 - x0 < 2 or y1 - y0 < 2:
                    continue
                f.write(f"{c} {(x0 + x1) / 2 / w:.6f} {(y0 + y1) / 2 / h:.6f} {(x1 - x0) / w:.6f} {(y1 - y0) / h:.6f}\n")
                stats[["ball", "club", "head"][c]] += 1
        stats["images"] += 1
        if stats["images"] % 100 == 0:
            print(stats, flush=True)
    print("DONE", stats, flush=True)


if __name__ == "__main__":
    main()

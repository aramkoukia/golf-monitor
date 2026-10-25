"""Download Open Images V7 images that contain a 'Golf ball' box and write YOLO labels.

Usage: python -I fetch_openimages_golfball.py <annotations_dir> <out_dir>
Images: CC BY 2.0 (per-image), annotations: CC BY 4.0 (Google Open Images).
"""
import csv, os, sys, urllib.request, concurrent.futures as cf

ann_dir, out = sys.argv[1], sys.argv[2]
splits = {"train": "train", "validation": "validation", "test": "test"}
boxes = {}
for split in splits:
    with open(os.path.join(ann_dir, f"{split}-golfball-bbox.csv")) as f:
        for row in csv.reader(f):
            img, _src, _label, _conf, xmin, xmax, ymin, ymax, occl, trunc, group = row[:11]
            boxes.setdefault((split, img), []).append((float(xmin), float(xmax), float(ymin), float(ymax), group))

os.makedirs(os.path.join(out, "images"), exist_ok=True)
os.makedirs(os.path.join(out, "labels"), exist_ok=True)
if os.path.exists(os.path.join(out, "group_images.txt")):
    os.remove(os.path.join(out, "group_images.txt"))

def fetch(key):
    split, img = key
    dst = os.path.join(out, "images", f"oi_{img}.jpg")
    if not os.path.exists(dst):
        url = f"https://open-images-dataset.s3.amazonaws.com/{splits[split]}/{img}.jpg"
        try:
            urllib.request.urlretrieve(url, dst)
        except Exception as e:  # noqa: BLE001
            return f"fail {img}: {e}"
    if any(group == "1" for *_, group in boxes[key]):
        # A group box stands for several unlabeled balls: unusable as ground truth.
        with open(os.path.join(out, "group_images.txt"), "a") as f:
            f.write(f"oi_{img}\n")
    with open(os.path.join(out, "labels", f"oi_{img}.txt"), "w") as f:
        for xmin, xmax, ymin, ymax, _group in boxes[key]:
            cx, cy, w, h = (xmin + xmax) / 2, (ymin + ymax) / 2, xmax - xmin, ymax - ymin
            f.write(f"0 {cx:.6f} {cy:.6f} {w:.6f} {h:.6f}\n")
    return None

fails = [r for r in map(fetch, boxes) if r]  # sequential: group_images.txt appends
print(f"{len(boxes)} images, {sum(len(v) for v in boxes.values())} boxes, {len(fails)} failures")
for f in fails[:10]:
    print(f)

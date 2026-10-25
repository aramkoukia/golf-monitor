"""Assemble an Ultralytics YOLO dataset from several YOLO-format sources.

Usage:
  python -I build_dataset.py --out <dir> --names golf_ball [--names club_head] \
     --real <yolo_dir>[:oversample] ... --synth <yolo_dir> ... [--val-frac 0.15]

Each source dir has images/ and labels/ (flat). Real sources are split
train/val deterministically by file-name hash and oversampled in train;
synthetic sources contribute 95% train / 5% val. Images listed in a source's
group_images.txt are skipped. Files are symlinked, labels copied.
"""
import argparse, hashlib, os, shutil


def split_of(name, val_frac):
    h = int(hashlib.md5(name.encode()).hexdigest()[:8], 16) / 0xFFFFFFFF
    return "val" if h < val_frac else "train"


def add_source(src, out, val_frac, oversample, tag, stats):
    skip = set()
    gpath = os.path.join(src, "group_images.txt")
    if os.path.exists(gpath):
        skip = {l.strip() for l in open(gpath) if l.strip()}
    for fn in sorted(os.listdir(os.path.join(src, "images"))):
        stem, ext = os.path.splitext(fn)
        if stem in skip:
            stats["skipped"] += 1
            continue
        lbl = os.path.join(src, "labels", stem + ".txt")
        if not os.path.exists(lbl):
            continue
        split = split_of(stem, val_frac)
        copies = oversample if split == "train" else 1
        for k in range(copies):
            name = f"{tag}_{stem}" + (f"_r{k}" if k else "")
            dst_img = os.path.join(out, "images", split, name + ext)
            if not os.path.exists(dst_img):
                os.symlink(os.path.abspath(os.path.join(src, "images", fn)), dst_img)
            shutil.copyfile(lbl, os.path.join(out, "labels", split, name + ".txt"))
            stats[split] += 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--names", action="append", required=True)
    ap.add_argument("--real", action="append", default=[])
    ap.add_argument("--synth", action="append", default=[])
    ap.add_argument("--val-frac", type=float, default=0.15)
    a = ap.parse_args()
    if os.path.exists(a.out):
        shutil.rmtree(a.out)
    for sub in ("images/train", "images/val", "labels/train", "labels/val"):
        os.makedirs(os.path.join(a.out, sub))
    stats = {"train": 0, "val": 0, "skipped": 0}
    for i, spec in enumerate(a.real):
        path, _, over = spec.partition(":")
        add_source(path, a.out, a.val_frac, int(over or 3), f"real{i}", stats)
    for i, path in enumerate(a.synth):
        add_source(path, a.out, 0.05, 1, f"syn{i}", stats)
    with open(os.path.join(a.out, "data.yaml"), "w") as f:
        f.write(f"path: {os.path.abspath(a.out)}\ntrain: images/train\nval: images/val\nnames:\n")
        for i, n in enumerate(a.names):
            f.write(f"  {i}: {n}\n")
    print(stats)


if __name__ == "__main__":
    main()

"""Download Open Images golf scenes whose 'Golf ball' label was human-verified ABSENT.

These are clean backgrounds / hard negatives for synth_balls.py (golfers, clubs,
tees and courses with no ball to leave unlabeled).
Usage: python -I fetch_openimages_backgrounds.py <imagelabels_dir> <out_dir> [limit]
"""
import collections, csv, os, sys, time, urllib.error, urllib.request, concurrent.futures as cf

src, out = sys.argv[1], sys.argv[2]
limit = int(sys.argv[3]) if len(sys.argv) > 3 else 1200
GOLF_SCENE = {"/m/037hz", "/m/025smyp", "/m/07npwc", "/m/02vk5tw", "/m/03gzqq",
              "/m/03cld36", "/m/03clckp", "/m/068hl_", "/m/02w7b0t", "/m/03b44g"}
pos = collections.defaultdict(set)
ball_absent, ball_present = set(), set()
folders = {"train": "train", "val": "validation", "test": "test"}
for split in folders:
    with open(os.path.join(src, f"{split}-golf-imagelabels.csv")) as f:
        for img, _s, label, conf in csv.reader(f):
            key = (split, img)
            if label == "/m/044r5d":
                (ball_present if float(conf) > 0.5 else ball_absent).add(key)
            elif float(conf) > 0.5 and label in GOLF_SCENE:
                pos[key].add(label)
scenes = sorted(k for k in pos if k in ball_absent and k not in ball_present)
others = sorted(k for k in ball_absent if k not in pos and k not in ball_present)
keys = (scenes + others)[:limit]
print(f"ball verified absent: {len(scenes)} golf scenes + {len(others)} other hard negatives -> {len(keys)}")
os.makedirs(out, exist_ok=True)

def fetch(key):
    split, img = key
    dst = os.path.join(out, f"oibg_{img}.jpg")
    if os.path.exists(dst):
        return None
    url = f"https://open-images-dataset.s3.amazonaws.com/{folders[split]}/{img}.jpg"
    for attempt in range(4):
        try:
            urllib.request.urlretrieve(url, dst)
            return None
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return f"missing {img}"
            time.sleep(1.5 * (attempt + 1))
        except Exception:  # noqa: BLE001
            time.sleep(1.5 * (attempt + 1))
    return f"fail {img}"

with cf.ThreadPoolExecutor(6) as ex:
    fails = [r for r in ex.map(fetch, keys) if r]
print(f"downloaded {len(keys) - len(fails)}, missing {sum(f.startswith('missing') for f in fails)}, failed {sum(f.startswith('fail') for f in fails)}")

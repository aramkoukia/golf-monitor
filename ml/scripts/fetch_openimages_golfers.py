"""Download Open Images images human-verified to show golfers / golf clubs
(image-level labels only — boxes come from autolabel_yoloe.py).
Usage: python -I fetch_openimages_golfers.py <imagelabels_dir> <out_dir> [limit]
"""
import collections, csv, os, sys, time, urllib.error, urllib.request, concurrent.futures as cf

src, out = sys.argv[1], sys.argv[2]
limit = int(sys.argv[3]) if len(sys.argv) > 3 else 3000
STRONG = {"/m/025smyp", "/m/07npwc", "/m/03gzqq", "/m/03cld36", "/m/03clckp", "/m/068hl_"}
folders = {"train": "train", "val": "validation", "test": "test"}
pos = collections.defaultdict(set)
for split in folders:
    for img, _s, label, conf in csv.reader(open(os.path.join(src, f"{split}-golf-imagelabels.csv"))):
        if float(conf) > 0.5:
            pos[(split, img)].add(label)
strong = sorted(k for k, v in pos.items() if v & STRONG)
weak = sorted(k for k, v in pos.items() if not v & STRONG and "/m/037hz" in v)
keys = (strong + weak)[:limit]
print(f"candidates: {len(strong)} golfer/club + {len(weak)} golf -> {len(keys)}")
os.makedirs(out, exist_ok=True)

def fetch(key):
    split, img = key
    dst = os.path.join(out, f"oigolf_{img}.jpg")
    if os.path.exists(dst):
        return "ok"
    for attempt in range(4):
        try:
            urllib.request.urlretrieve(f"https://open-images-dataset.s3.amazonaws.com/{folders[split]}/{img}.jpg", dst)
            return "ok"
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return "missing"
            time.sleep(1.5 * (attempt + 1))
        except Exception:  # noqa: BLE001
            time.sleep(1.5 * (attempt + 1))
    return "fail"

with cf.ThreadPoolExecutor(6) as ex:
    res = list(ex.map(fetch, keys))
print({r: res.count(r) for r in set(res)})

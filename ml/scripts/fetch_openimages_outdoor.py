"""Download Open Images validation images showing grass/lawn/meadow/sky/net
(outdoor range-like textures) with no golf ball, as synth_balls.py backgrounds.
Usage: python -I fetch_openimages_outdoor.py <labels.csv> <out_dir> [limit]
"""
import collections, csv, os, sys, time, urllib.error, urllib.request, concurrent.futures as cf

labels_csv, out = sys.argv[1], sys.argv[2]
limit = int(sys.argv[3]) if len(sys.argv) > 3 else 1500
GROUND = {"/m/08t9c_", "/m/01v327", "/m/025st_8", "/m/01c7cq", "/m/02qdwbp"}
pos = collections.defaultdict(set)
for img, _s, label, conf in csv.reader(open(labels_csv)):
    if float(conf) > 0.5:
        pos[img].add(label)
# Ground-texture scenes first (where a teed ball would sit), then sky-only.
keys = [k for k, v in pos.items() if v & GROUND and "/m/044r5d" not in v and "/m/037hz" not in v]
keys += [k for k, v in pos.items() if not v & GROUND and "/m/01bqvp" in v and "/m/044r5d" not in v and "/m/037hz" not in v]
keys = keys[:limit]
os.makedirs(out, exist_ok=True)

def fetch(img):
    dst = os.path.join(out, f"oiout_{img}.jpg")
    if os.path.exists(dst):
        return None
    for attempt in range(4):
        try:
            urllib.request.urlretrieve(f"https://open-images-dataset.s3.amazonaws.com/validation/{img}.jpg", dst)
            return None
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return "missing"
            time.sleep(1.5 * (attempt + 1))
        except Exception:  # noqa: BLE001
            time.sleep(1.5 * (attempt + 1))
    return "fail"

with cf.ThreadPoolExecutor(6) as ex:
    res = list(ex.map(fetch, keys))
print(f"requested {len(keys)}, ok {res.count(None)}, missing {res.count('missing')}, failed {res.count('fail')}")

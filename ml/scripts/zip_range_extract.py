"""List / extract members of a remote ZIP using HTTP range requests, so a
small subset of a multi-GB dataset archive can be fetched without
downloading the whole file.

Usage:
  python -I zip_range_extract.py <url> --list [--pattern REGEX] [--limit N]
  python -I zip_range_extract.py <url> --out <dir> --pattern REGEX [--sample N] [--seed S] [--workers 8]
Image members matching the pattern are extracted together with their
sibling YOLO label (images/ → labels/, .jpg → .txt).
"""
import argparse
import concurrent.futures as cf
import io
import os
import random
import re
import urllib.request
import zipfile


class HTTPRangeFile(io.RawIOBase):
    def __init__(self, url, size):
        self.url, self.size, self.pos = url, size, 0

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=io.SEEK_SET):
        self.pos = {io.SEEK_SET: offset, io.SEEK_CUR: self.pos + offset, io.SEEK_END: self.size + offset}[whence]
        return self.pos

    def readinto(self, b):
        if self.pos >= self.size:
            return 0
        end = min(self.size, self.pos + len(b)) - 1
        req = urllib.request.Request(self.url, headers={"Range": f"bytes={self.pos}-{end}"})
        for attempt in range(5):
            try:
                data = urllib.request.urlopen(req, timeout=60).read()
                break
            except Exception:  # noqa: BLE001
                if attempt == 4:
                    raise
        b[:len(data)] = data
        self.pos += len(data)
        return len(data)


def resolve(url):
    req = urllib.request.Request(url, method="HEAD")
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.geturl(), int(r.headers["Content-Length"])


def open_zip(url, size):
    return zipfile.ZipFile(io.BufferedReader(HTTPRangeFile(url, size), buffer_size=1 << 20))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("url")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--pattern", default=".*")
    ap.add_argument("--limit", type=int, default=50)
    ap.add_argument("--out")
    ap.add_argument("--sample", type=int, default=0)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--workers", type=int, default=8)
    a = ap.parse_args()

    url, size = resolve(a.url)
    z = open_zip(url, size)
    names = z.namelist()
    rx = re.compile(a.pattern)
    hits = [n for n in names if rx.search(n)]
    if a.list:
        print(f"{len(names)} members, {len(hits)} match")
        for n in hits[:a.limit]:
            print(n, z.getinfo(n).file_size)
        return

    images = [n for n in hits if n.lower().endswith((".jpg", ".jpeg", ".png"))]
    if a.sample:
        random.Random(a.seed).shuffle(images)
        images = images[:a.sample]
    nameset = set(names)
    os.makedirs(os.path.join(a.out, "images"), exist_ok=True)
    os.makedirs(os.path.join(a.out, "labels"), exist_ok=True)

    def job(chunk):
        zz = open_zip(url, size)
        done = 0
        for n in chunk:
            stem = os.path.splitext(os.path.basename(n))[0]
            lbl = re.sub(r"/images/", "/labels/", n)
            lbl = os.path.splitext(lbl)[0] + ".txt"
            if lbl not in nameset:
                continue
            dst = os.path.join(a.out, "images", os.path.basename(n))
            if not os.path.exists(dst):
                with open(dst, "wb") as f:
                    f.write(zz.read(n))
                with open(os.path.join(a.out, "labels", stem + ".txt"), "wb") as f:
                    f.write(zz.read(lbl))
            done += 1
        return done

    chunks = [images[i::a.workers] for i in range(a.workers)]
    with cf.ThreadPoolExecutor(a.workers) as ex:
        total = sum(ex.map(job, chunks))
    print(f"extracted {total} image/label pairs")


if __name__ == "__main__":
    main()

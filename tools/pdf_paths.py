# -*- coding: utf-8 -*-
"""Extract the vector paths of 7.pdf page 13 (the NearLink mark) and render each one."""
import os
import re
import zlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

BASE = Path(__file__).resolve().parents[1]
PDF = Path(os.environ.get("TRAY_PDF", BASE / "tools" / "7.pdf"))
OUT = Path(os.environ.get("TRAY_WORK", BASE / "work"))

NUM = re.compile(rb"[-+]?(\d+\.?\d*|\.\d+)")
TOKEN = re.compile(rb"[A-Za-z*\"'0-9\.\+\-]+|\[|\]|<[^>]*>|\([^)]*\)|\s+|[^A-Za-z0-9\s\[\]<>\(\)]")


def obj_body(data, num):
    m = re.search(rb"(?m)^%d\s+0\s+obj\b" % num, data)
    if not m:
        return None
    e = data.find(b"endobj", m.end())
    return data[m.end():e]


def decode_stream(body):
    i = body.find(b"stream")
    if i < 0:
        return None
    j = i + 6
    while body[j:j + 1] in (b"\r", b"\n"):
        j += 1
    k = body.rfind(b"endstream")
    raw = body[j:k]
    return zlib.decompress(raw) if b"FlateDecode" in body[:i] else raw


def parse_paths(content):
    """Return [(pathlist, ctm)] for every path that is used as a clip/fill."""
    paths = []
    cur = []
    ctm = [1, 0, 0, 1, 0, 0]
    stack = []
    xs = []
    # tokenise
    toks = [t for t in TOKEN.findall(content) if t.strip()]
    i = 0

    def num(t):
        try:
            return float(t)
        except Exception:
            return None

    while i < len(toks):
        t = toks[i]
        if t == b"q":
            stack.append(list(ctm))
        elif t == b"Q":
            if stack:
                ctm = stack.pop()
        elif t == b"cm" and i >= 6:
            vals = [num(x) for x in toks[i - 6:i]]
            if all(v is not None for v in vals):
                a, b, c, d, e, f = vals
                ca, cb, cc, cd, ce, cf = ctm
                ctm = [a * ca + b * cc, a * cb + b * cd,
                       c * ca + d * cc, c * cb + d * cd,
                       e * ca + f * cc + ce, e * cb + f * cd + cf]
        elif t in (b"m", b"l", b"c", b"re", b"h", b"v", b"y"):
            n = {b"m": 2, b"l": 2, b"c": 6, b"re": 4, b"h": 0, b"v": 4, b"y": 4}[t]
            vals = [num(x) for x in toks[i - n:i]] if n else []
            if all(v is not None for v in vals):
                p = transform(vals, t, ctm)
                if t == b"re":
                    x, y, w, h = p
                    cur.extend([("m", (x, y)), ("l", (x + w, y)), ("l", (x + w, y + h)),
                                ("l", (x, y + h)), ("h", None)])
                elif t == b"h":
                    cur.append(("h", None))
                elif t == b"m":
                    cur.append(("m", tuple(p)))
                elif t == b"l":
                    cur.append(("l", tuple(p)))
                elif t == b"c":
                    cur.append(("c", tuple(p)))
        elif t in (b"W", b"W*"):
            if cur:
                paths.append((list(cur), list(ctm)))
                cur = []
        elif t in (b"f", b"f*", b"sh", b"n"):
            if t == b"sh":
                pass
            cur = []
        i += 1
    return paths


def transform(vals, op, ctm):
    a, b, c, d, e, f = ctm
    out = []
    if op == b"re":
        x, y, w, h = vals
        return (x, y, w, h)
    for k in range(0, len(vals), 2):
        x, y = vals[k], vals[k + 1]
        out += [a * x + c * y + e, b * x + d * y + f]
    return out


def flatten(path):
    pts = []
    cur = None
    start = None
    for op, val in path:
        if op == "m":
            cur = val
            start = val
            pts.append(("M", val))
        elif op == "l":
            pts.append(("L", val))
            cur = val
        elif op == "h":
            if start:
                pts.append(("L", start))
                cur = start
        elif op == "c":
            p0 = cur
            p1 = (val[0], val[1])
            p2 = (val[2], val[3])
            p3 = (val[4], val[5])
            for s in range(1, 25):
                t = s / 24.0
                x = ((1 - t) ** 3 * p0[0] + 3 * (1 - t) ** 2 * t * p1[0]
                     + 3 * (1 - t) * t * t * p2[0] + t ** 3 * p3[0])
                y = ((1 - t) ** 3 * p0[1] + 3 * (1 - t) ** 2 * t * p1[1]
                     + 3 * (1 - t) * t * t * p2[1] + t ** 3 * p3[1])
                pts.append(("L", (x, y)))
            cur = p3
    return pts


def render(path, size=600, mode="L", margin=0.06):
    pts = flatten(path)
    xs = [p[1][0] for p in pts]
    ys = [p[1][1] for p in pts]
    x0, x1, y0, y1 = min(xs), max(xs), min(ys), max(ys)
    w, h = x1 - x0, y1 - y0
    scale = size / max(w, h) * (1 - 2 * margin)
    img = Image.new(mode, (size, size), 0)
    d = ImageDraw.Draw(img)
    poly = [((x - x0) * scale + (size - w * scale) / 2,
             (y - y0) * scale + (size - h * scale) / 2) for (_op, (x, y)) in pts]
    d.polygon(poly, fill=255)
    return img, (x0, y0, x1, y1)


def main():
    data = PDF.read_bytes()
    page = 23
    body = obj_body(data, page)
    cm = re.search(rb"/Contents\s+(\d+)\s+0\s+R", body)
    content = decode_stream(obj_body(data, int(cm.group(1))))
    paths = parse_paths(content)
    print("paths:", len(paths), "sizes:", [len(p) for p, _ in paths][:20])
    tiles = []
    for idx, (p, ctm) in enumerate(paths[:12]):
        img, bbox = render(p)
        print(idx, "bbox", [round(v) for v in bbox])
        tiles.append(img)
    sheet = Image.new("L", (600 * 4, 600 * 3), 40)
    for i, t in enumerate(tiles):
        sheet.paste(t, ((i % 4) * 600, (i // 4) * 600))
    sheet.save(OUT / "pdf_paths.png")
    print("saved pdf_paths.png")


if __name__ == "__main__":
    main()

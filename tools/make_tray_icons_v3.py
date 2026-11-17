# -*- coding: utf-8 -*-
"""v3: 用 7.pdf 里两个 D 各自的矢量轮廓生成图标，交叉处留缝（不再连成一片）。

与 v2 的区别
------------
v2 用 mark-master.png（两片合在一起的位图）做母版，两片在交叉处是实心连着的。
v3 直接把 PDF 里两片（leaf A / leaf B）的路径分开取出来，渲染时各自退让
GAP 像素，于是两个 D 永远隔着一条细缝——既保持互扣，又不会被看成连体。
"""
from __future__ import annotations

import json
import os
import re
import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

try:                                   # 只有现场解析 PDF 时才需要
    import pdf_paths as P
except Exception:                      # noqa: BLE001
    P = None

BASE = Path(__file__).resolve().parent.parent
OUT = Path(os.environ.get("TRAY_ICON_OUT", BASE / "icons"))
PDF = Path(os.environ.get("TRAY_PDF", BASE / "tools" / "7.pdf"))
PAGE_OBJ = int(os.environ.get("TRAY_PDF_PAGE", 23))
PAIR = (3, 6)          # 同一处 logo 的两个 D

SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]
FILL = {16: 0.88, 20: 0.88, 24: 0.87, 32: 0.88, 40: 0.90, 48: 0.90, 64: 0.90}
FILL_DEFAULT = 0.90

GAP = 0.0              # 两个 D 之间的缝宽 = GAP × 该尺寸像素；0 = 交叉处实心（连在一起）

CRISP = {16: (0.32, 0.68), 20: (0.30, 0.70), 24: (0.28, 0.72),
         32: (0.18, 0.82), 40: (0.10, 0.90), 48: (0.06, 0.94), 64: (0.02, 0.98)}

WEIGHT_THIN = {16: 0.06, 20: 0.0, 24: -0.03, 32: -0.02, 40: 0.0, 48: 0.0, 64: 0.0}
WEIGHT_BOLD = {16: 0.28, 20: 0.32, 24: 0.34, 32: 0.38, 40: 0.40, 48: 0.42, 64: 0.44}

COLORS = {
    "tray": (45, 185, 141),
    "tray-green": (45, 185, 141),
    "tray-yellow": (255, 193, 7),
    "tray-red": (229, 72, 77),
    "tray-white": (255, 255, 255),
    "tray-black": (0, 0, 0),
}


# ------------------------------------------------------------------ vectors
LEAVES_JSON = Path(os.environ.get("TRAY_LEAVES", BASE / "tools" / "mark-leaves.json"))


def load_leaves():
    """优先读 tools/mark-leaves.json（从 7.pdf 抽出来的两个 D 的轮廓）；
    没有 json 时退回现场解析 PDF。"""
    if LEAVES_JSON.exists():
        data = json.loads(LEAVES_JSON.read_text(encoding="utf-8"))
        polys = [np.asarray(p, dtype=np.float64) for p in data["leaves"]]
        return polys, float(data["aspect"])
    data = PDF.read_bytes()
    body = P.obj_body(data, PAGE_OBJ)
    m = re.search(rb"/Contents\s+(\d+)\s+0\s+R", body)
    content = P.decode_stream(P.obj_body(data, int(m.group(1))))
    paths = P.parse_paths(content)
    polys = []
    for idx in PAIR:
        pts = P.flatten(paths[idx][0])
        polys.append(np.array([[x, y] for _op, (x, y) in pts], dtype=np.float64))
    allp = np.vstack(polys)
    x0, y0 = allp.min(0)
    x1, y1 = allp.max(0)
    h = y1 - y0
    norm = [np.column_stack([(p[:, 0] - x0) / h, (p[:, 1] - y0) / h]) for p in polys]
    return norm, (x1 - x0) / h          # aspect


# --------------------------------------------------------------- rendering
def ss_for(size: int) -> int:
    return 8 if size <= 32 else (4 if size <= 64 else 2)


def _disc(a: np.ndarray, r: float) -> np.ndarray:
    """fractional-radius max filter (dilation)."""
    if r <= 1e-6:
        return a
    R = int(np.floor(r))
    t = r - R
    m0 = a
    if R > 0:
        m0 = a.copy()
        for dy in range(-R, R + 1):
            for dx in range(-R, R + 1):
                if dx * dx + dy * dy <= R * R:
                    m0 = np.maximum(m0, np.roll(np.roll(a, dy, 0), dx, 1))
    if t <= 1e-6:
        return m0
    m1 = m0.copy()
    R1 = R + 1
    for dy in range(-R1, R1 + 1):
        for dx in range(-R1, R1 + 1):
            if dx * dx + dy * dy <= R1 * R1:
                m1 = np.maximum(m1, np.roll(np.roll(a, dy, 0), dx, 1))
    return m0 * (1 - t) + m1 * t


def render_leaves(size: int, fill: float, weight: float, ss: int):
    """Return two boolean-ish coverage maps (size*ss) plus canvas geometry."""
    n = size * ss
    scale = size * fill * ss
    w_px = shapes_aspect * scale
    off_x = (n - w_px) / 2.0
    off_y = (n - scale) / 2.0
    out = []
    for poly in LEAVES:
        img = Image.new("L", (n, n), 0)
        pts = [(x * scale + off_x, y * scale + off_y) for x, y in poly]
        ImageDraw.Draw(img).polygon(pts, fill=255)
        a = np.asarray(img, dtype=np.float64) / 255.0
        out.append(a)
    if abs(weight) > 1e-6:
        r = weight * ss
        if r > 0:
            out = [_disc(a, r) for a in out]
        else:
            out = [1.0 - _disc(1.0 - a, -r) for a in out]
    return out


def compose(size: int, fill: float, weight: float, gap_px: float) -> np.ndarray:
    ss = ss_for(size)
    a, b = render_leaves(size, fill, weight, ss)
    if gap_px <= 1e-6:
        # GAP=0：两片取并集，交叉处是实心的（恢复成连在一起）
        ink = np.maximum(a, b)
    else:
        g = gap_px * ss
        keep_a = 1.0 - _disc(b, g)
        keep_b = 1.0 - _disc(a, g)
        ink = np.maximum(a * keep_a, b * keep_b)
    cov = ink.reshape(size, ss, size, ss).mean(axis=(1, 3))
    lo, hi = CRISP.get(size, (0.02, 0.98))
    x = np.clip((cov - lo) / (hi - lo), 0, 1)
    return x * x * (3 - 2 * x)


def frame(size: int, rgb, weight: float, gap_px: float | None = None) -> Image.Image:
    fill = FILL.get(size, FILL_DEFAULT)
    if gap_px is None:
        gap_px = GAP * size
    a = compose(size, fill, weight, gap_px)
    px = np.zeros((size, size, 4), np.uint8)
    px[:, :, 0:3] = rgb
    px[:, :, 3] = np.round(np.clip(a, 0, 1) * 255).astype(np.uint8)
    return Image.fromarray(px, "RGBA")


# --------------------------------------------------------------------- ICO
def ico_bytes(frames):
    blobs = []
    for img in frames:
        rgba = np.asarray(img.convert("RGBA"), np.uint8)
        w, h = img.size
        rows = rgba[::-1]
        xor = rows[:, :, [2, 1, 0, 3]].tobytes()
        stride = ((w + 31) // 32) * 4
        mask = bytearray(stride * h)
        alpha = rows[:, :, 3]
        for y in range(h):
            row = mask[y * stride:(y + 1) * stride]
            for x in range(w):
                if alpha[y, x] == 0:
                    row[x >> 3] |= 0x80 >> (x & 7)
        blobs.append(struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0,
                                 len(xor) + stride * h, 0, 0, 0, 0) + xor + bytes(mask))
    buf = bytearray(struct.pack("<HHH", 0, 1, len(frames)))
    offset = 6 + 16 * len(frames)
    for img, blob in zip(frames, blobs):
        buf += struct.pack("<BBBBHHII", 0 if img.width >= 256 else img.width,
                           0 if img.height >= 256 else img.height,
                           0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    return bytes(buf + b"".join(blobs))


LEAVES, shapes_aspect = load_leaves()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for weight, is_bold in (("thin", False), ("bold", True)):
        for s in SIZES:
            w = WEIGHT_BOLD.get(s, 0.44) if is_bold else WEIGHT_THIN.get(s, 0.0)
            print(f"  {weight} {s}px ok", flush=True)
        for name, rgb in COLORS.items():
            frames = [frame(s, rgb, WEIGHT_BOLD.get(s, 0.44) if is_bold else WEIGHT_THIN.get(s, 0.0))
                      for s in SIZES]
            p = OUT / weight / f"{name}.ico"
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(ico_bytes(frames))
            print(f"{weight}/{name}.ico {p.stat().st_size}", flush=True)
    app_sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
    app = [frame(s, COLORS["tray"], WEIGHT_BOLD.get(s, 0.0) if s <= 24 else 0.0, gap_px=GAP * s)
           for s in app_sizes]
    (OUT / "app.ico").write_bytes(ico_bytes(app))
    print("app.ico", (OUT / "app.ico").stat().st_size)


if __name__ == "__main__":
    main()

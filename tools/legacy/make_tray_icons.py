# -*- coding: utf-8 -*-
"""重建托盘图标（去白边版）。

问题：旧流程（make_icon_levels.py）把「白底哑光」烘焙进了 RGB —— 半透明边缘像素的
RGB 被拉向白色（例如 alpha=12 时 RGB≈(219,243,235)）。Windows 再按 alpha 合成到
黑色桌面上，边缘就多出一圈白/灰边，看起来发虚。

做法：
1. 形状母版 = tools/mark-master.png，由 7.pdf 第 13 页（2.07 标志的其他形态）
   里「反白标志」的白色 mark 按矢量渲染到 ~560px 高再取 alpha，曲线干净无台阶。
2. 每个尺寸用「面积覆盖率 + 亚像素对齐」重新采样，边缘只保留 ~1px 抗锯齿。
3. RGB 恒为纯色，alpha 之外的像素不再带白，彻底消除白边。
4. AND mask 按标准写好（透明处为 1），老渲染器也不会画出白/黑方块。
"""
import os
import struct
from pathlib import Path

import numpy as np
from PIL import Image

BASE = Path(__file__).resolve().parents[2]          # HuaweiMouseTray 目录
SRC_APP = BASE / "icons" / "app.ico"                     # 备用形状母版（256px 帧）
MASTER = BASE / "tools" / "mark-master.png"              # 形状母版：7.pdf 2.07 矢量渲染
OUT = Path(os.environ.get("TRAY_ICON_OUT", BASE / "icons"))

SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]
FILL = 0.88          # 字形在方形画布里的占比（沿用原版）


# ------------------------------------------------------------------ 形状
def load_master():
    """形状母版：优先 tools/mark-master.png（PDF 矢量渲出的 alpha 位图），
    否则退回 icons/app.ico 的 256px 帧。"""
    if MASTER.exists():
        a = np.asarray(Image.open(MASTER).convert("L"), dtype=np.float64) / 255.0
    else:
        fr = Image.open(SRC_APP).ico.getimage((256, 256)).convert("RGBA")
        a = np.asarray(fr.getchannel("A"), dtype=np.float64) / 255.0
    bb = Image.fromarray((a * 255).astype(np.uint8)).getbbox()
    return a[bb[1]:bb[3], bb[0]:bb[2]]


def disc_dilate(a, r):
    """圆形结构元素膨胀，避免 MaxFilter 的方形台阶。"""
    if r <= 0.02:
        return a
    R = int(np.ceil(r))
    m = a.copy()
    for dy in range(-R, R + 1):
        for dx in range(-R, R + 1):
            if dx * dx + dy * dy <= r * r:
                m = np.maximum(m, np.roll(np.roll(a, dy, axis=0), dx, axis=1))
    return m


def erode(a, r):
    """圆形结构元素腐蚀（小尺寸用，让笔画之间透气）。"""
    return 1.0 - disc_dilate(1.0 - a, r)


def integral(a):
    ii = np.zeros((a.shape[0] + 1, a.shape[1] + 1), dtype=np.float64)
    ii[1:, 1:] = a.cumsum(0).cumsum(1)
    return ii


def sample_ii(ii, xs, ys):
    xs = np.clip(xs, 0, ii.shape[1] - 1)
    ys = np.clip(ys, 0, ii.shape[0] - 1)
    x0 = np.floor(xs).astype(int)
    y0 = np.floor(ys).astype(int)
    x1 = np.minimum(x0 + 1, ii.shape[1] - 1)
    y1 = np.minimum(y0 + 1, ii.shape[0] - 1)
    tx, ty = xs - x0, ys - y0
    return (ii[y0, x0] * (1 - tx) * (1 - ty) + ii[y0, x1] * tx * (1 - ty)
            + ii[y1, x0] * (1 - tx) * ty + ii[y1, x1] * tx * ty)


def coverage(ii, size, ox, oy):
    """目标图每像素覆盖的源面积比例。

    master 以「高 = size * FILL」等比缩放进方形画布并居中；
    ox/oy 是目标像素单位的亚像素偏移。
    """
    H = ii.shape[0] - 1
    W = ii.shape[1] - 1
    k = H / (size * FILL)                   # 源像素 / 目标像素
    e = np.arange(size + 1, dtype=np.float64)
    xs = (e - size / 2.0 + ox) * k + W / 2.0
    ys = (e - size / 2.0 + oy) * k + H / 2.0
    X0, X1 = np.tile(xs[:-1], (size, 1)), np.tile(xs[1:], (size, 1))
    Y0, Y1 = np.tile(ys[:-1][:, None], (1, size)), np.tile(ys[1:][:, None], (1, size))
    v = (sample_ii(ii, X1, Y1) - sample_ii(ii, X0, Y1)
         - sample_ii(ii, X1, Y0) + sample_ii(ii, X0, Y0))
    return np.clip(v / (k * k), 0.0, 1.0)


def hint(ii, size):
    """亚像素网格搜索：墨量不变的前提下让中间调（虚边）最少。"""
    ref = coverage(ii, size, 0.0, 0.0).sum()
    best = (1e18, 0.0, 0.0)
    for ox in np.arange(0.0, 1.0, 0.125):
        for oy in np.arange(0.0, 1.0, 0.125):
            c = coverage(ii, size, ox, oy)
            v = float(np.sum(4 * c * (1 - c))) + 400.0 * abs(c.sum() - ref)
            if v < best[0]:
                best = (v, ox, oy)
    c = coverage(ii, size, best[1], best[2])
    c *= ref / max(c.sum(), 1e-6)
    return np.clip(c, 0, 1)


def tighten(cov, size):
    """边缘锐化：小尺寸强一点，大尺寸轻一点，过渡控制在 ~1px。"""
    strength = 0.68 if size <= 24 else (0.52 if size <= 48 else 0.34)
    x = np.clip((cov - 0.02) / 0.96, 0, 1)
    sm = x * x * (3 - 2 * x)
    return (1 - strength) * cov + strength * sm


def erode(a, r):
    """圆形结构元素腐蚀（小尺寸用，让笔画之间透气）。"""
    return 1.0 - disc_dilate(1.0 - a, r)


def optical_px(size):
    """16/20px 那一档对笔画做一点点收细，避免笔画糊在一起。"""
    if size <= 16:
        return -0.09
    if size <= 20:
        return -0.05
    return 0.0


def build(master, color, extra_px_at_24):
    frames = []
    for size in SIZES:
        px24 = extra_px_at_24 + optical_px(size)
        # master 高度对应 size*FILL 个目标像素
        r = px24 * (master.shape[0] / (24.0 * FILL))
        a = disc_dilate(master, r) if r > 0.02 else (erode(master, -r) if r < -0.02 else master)
        ii = integral(a)
        cov = tighten(hint(ii, size), size)
        px = np.zeros((size, size, 4), dtype=np.uint8)
        px[:, :, 0:3] = color
        px[:, :, 3] = np.round(cov * 255).astype(np.uint8)
        frames.append(Image.fromarray(px, "RGBA"))
    return frames


# ------------------------------------------------------------------ ICO
def ico_bytes(frames):
    blobs = []
    for img in frames:
        w, h = img.size
        rgba = np.asarray(img.convert("RGBA"), dtype=np.uint8)
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
        blob = struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0,
                           len(xor) + stride * h, 0, 0, 0, 0) + xor + bytes(mask)
        blobs.append(blob)
    buf = bytearray(struct.pack("<HHH", 0, 1, len(frames)))
    entries = bytearray()
    offset = 6 + 16 * len(frames)
    for img, blob in zip(frames, blobs):
        entries += struct.pack("<BBBBHHII", 0 if img.width >= 256 else img.width,
                               0 if img.height >= 256 else img.height,
                               0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    return bytes(buf + entries + b"".join(blobs))


COLORS = {
    "tray": (45, 185, 141),
    "tray-green": (45, 185, 141),
    "tray-yellow": (255, 193, 7),
    "tray-red": (229, 72, 77),
    "tray-white": (255, 255, 255),
    "tray-black": (32, 32, 32),
}
WEIGHTS = {"thin": 0.02, "bold": 0.42}   # 24px 上的额外加粗（px）

def main():
    print(f"源形状 {SRC_APP}")
    print(f"输出   {OUT}")
    master = load_master()
    for weight, extra in WEIGHTS.items():
        for name, rgb in COLORS.items():
            frames = build(master, rgb, extra)
            p = OUT / weight / f"{name}.ico"
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(ico_bytes(frames))
            print(f"{weight}/{name}.ico", p.stat().st_size)


if __name__ == "__main__":
    main()

# -*- coding: utf-8 -*-
"""HuaweiMouseTray 托盘/应用图标生成器 v2（单色、锐边、无白边）。

设计要点
--------
1. 母版：tools/mark-master.png（7.pdf 2.07「标志的其他形态」反白标志的矢量渲染）。
   先裁到墨迹外框，再用标志本身的 180° 点对称做一次平均，去掉 JPEG 压缩噪点；
   上采样 4x 后做轻微高斯模糊，得到干净的连续 alpha 场。
2. 每个尺寸按「面积覆盖率」精确重采样（8x 超采样再箱式降采样），
   所以边缘不会有半透明灰边以外的脏东西。
3. **单色控制**：RGB 恒为同一色值（纯色），透明度只由覆盖率决定；
   不再把白底哑光烘进 RGB，因此黑底上不会出现白边/灰边。
4. 尺寸光学补偿：
   - 16/20/24px 托盘实际尺寸：加强对比、亚像素对齐、略微加粗，边缘 1px 内收，
     白色像素比例最大化 → 在黑色任务栏上"干净、不虚"。
   - 32px 以上：平滑抗锯齿，大图标不锯齿。
5. 两套粗细（thin / bold），六种颜色，写入标准 32bpp ICO（含 AND mask）。
"""
from __future__ import annotations

import struct
from pathlib import Path

import numpy as np
from PIL import Image

BASE = Path(__file__).resolve().parents[2]
MASTER = Path(__import__("os").environ.get("TRAY_MASTER", BASE / "tools" / "mark-master.png"))
OUT = Path(__import__("os").environ.get("TRAY_ICON_OUT", BASE / "icons"))

SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]
SS = 8                     # 超采样倍数
# 占位：对齐 Windows 11 系统托盘字形（wifi/音量/电池 在 24px 里约占 20px），
# 之前 0.99 会把画布撑满，比系统图标胖一圈。16px 反而要略大一点，否则笔画断掉。
FILL = {16: 0.88, 20: 0.88, 24: 0.87, 32: 0.88, 40: 0.90, 48: 0.90, 64: 0.90}
FILL_SMALL = 0.87           # 兜底
FILL_LARGE = 0.90

# 每个尺寸的 (对比度 lo, hi) —— 越小越"软"，越大越"硬"
CRISP = {
    16: (0.32, 0.68),
    20: (0.30, 0.70),
    24: (0.28, 0.72),
    32: (0.18, 0.82),
    40: (0.10, 0.90),
    48: (0.06, 0.94),
    64: (0.02, 0.98),
}
# 各尺寸的笔画调整（px @ 该尺寸）：
#   thin 整体收细到接近系统托盘的线条量级，bold 明显加粗 —— 两档在 24px 上差 ~0.45px
#   （约 18% 笔画宽度），远看就能分出来；16px 收窄幅度以免笔画断掉。
WEIGHT_THIN = {16: -0.12, 20: -0.16, 24: -0.20, 32: -0.22, 40: -0.22, 48: -0.20, 64: -0.18}
WEIGHT_BOLD = {16: 0.22, 20: 0.28, 24: 0.34, 32: 0.38, 40: 0.40, 48: 0.42, 64: 0.44}

COLORS = {
    "tray": (45, 185, 141),
    "tray-green": (45, 185, 141),
    "tray-yellow": (255, 193, 7),
    "tray-red": (229, 72, 77),
    "tray-white": (255, 255, 255),
    "tray-black": (0, 0, 0),        # 最黑一档（原 #202020）
}


# --------------------------------------------------------------------- master
def gauss(img: np.ndarray, sigma: float) -> np.ndarray:
    r = max(1, int(round(sigma * 2.5)))
    x = np.arange(-r, r + 1, dtype=np.float64)
    k = np.exp(-(x * x) / (2 * sigma * sigma))
    k /= k.sum()
    a = np.pad(img, ((0, 0), (r, r)), mode="edge")
    a = np.apply_along_axis(lambda m: np.convolve(m, k, "valid"), 1, a)
    a = np.pad(a, ((r, r), (0, 0)), mode="edge")
    a = np.apply_along_axis(lambda m: np.convolve(m, k, "valid"), 0, a)
    return a


def load_master(up: int = 4) -> np.ndarray:
    im = Image.open(MASTER).convert("L")
    a = np.asarray(im, dtype=np.float64) / 255.0
    a = np.clip((a - 0.05) / 0.90, 0.0, 1.0)
    ys, xs = np.nonzero(a > 0.5)
    a = a[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    # 标志是 180° 点对称：平均掉扫描/压缩带来的不对称噪点
    a = 0.5 * (a + a[::-1, ::-1])
    h, w = a.shape
    f = Image.fromarray(a.astype(np.float32), "F").resize((w * up, h * up), Image.BICUBIC)
    return np.clip(gauss(np.asarray(f, dtype=np.float64), 2.2), 0.0, 1.0)


# ------------------------------------------------------------------ sampling
def integral(a: np.ndarray) -> np.ndarray:
    ii = np.zeros((a.shape[0] + 1, a.shape[1] + 1), dtype=np.float64)
    ii[1:, 1:] = a.cumsum(0).cumsum(1)
    return ii


def _sample(ii: np.ndarray, xs: np.ndarray, ys: np.ndarray) -> np.ndarray:
    xs = np.clip(xs, 0, ii.shape[1] - 1)
    ys = np.clip(ys, 0, ii.shape[0] - 1)
    x0 = np.floor(xs).astype(int)
    y0 = np.floor(ys).astype(int)
    x1 = np.minimum(x0 + 1, ii.shape[1] - 1)
    y1 = np.minimum(y0 + 1, ii.shape[0] - 1)
    tx, ty = xs - x0, ys - y0
    return (ii[y0, x0] * (1 - tx) * (1 - ty) + ii[y0, x1] * tx * (1 - ty)
            + ii[y1, x0] * (1 - tx) * ty + ii[y1, x1] * tx * ty)


def coverage(ii: np.ndarray, size: int, fill: float, ox: float = 0.0, oy: float = 0.0,
             ss: int = SS) -> np.ndarray:
    H = ii.shape[0] - 1
    W = ii.shape[1] - 1
    n = size * ss
    k = H / (size * fill)
    e = np.arange(n + 1, dtype=np.float64) / ss
    xs = (e - size / 2.0 + ox) * k + W / 2.0
    ys = (e - size / 2.0 + oy) * k + H / 2.0
    X0 = np.tile(xs[:-1], (n, 1))
    X1 = np.tile(xs[1:], (n, 1))
    Y0 = np.tile(ys[:-1][:, None], (1, n))
    Y1 = np.tile(ys[1:][:, None], (1, n))
    v = (_sample(ii, X1, Y1) - _sample(ii, X0, Y1)
         - _sample(ii, X1, Y0) + _sample(ii, X0, Y0))
    step = k / ss
    return np.clip(v / (step * step), 0.0, 1.0)


def _disc_max_int(a: np.ndarray, R: int) -> np.ndarray:
    if R <= 0:
        return a
    m = a.copy()
    for dy in range(-R, R + 1):
        for dx in range(-R, R + 1):
            if dx * dx + dy * dy <= R * R:
                m = np.maximum(m, np.roll(np.roll(a, dy, axis=0), dx, axis=1))
    return m


def morph(a: np.ndarray, r: float) -> np.ndarray:
    """在超采样 coverage 上做分数半径的膨胀(r>0)/腐蚀(r<0)。"""
    if abs(r) < 1e-6:
        return a
    if r > 0:
        R = int(np.floor(r))
        t = r - R
        m0 = _disc_max_int(a, R)
        return m0 if t <= 1e-6 else m0 * (1 - t) + _disc_max_int(a, R + 1) * t
    return 1.0 - morph(1.0 - a, -r)


def downsample(c: np.ndarray, size: int, ss: int = SS) -> np.ndarray:
    return c.reshape(size, ss, size, ss).mean(axis=(1, 3))


def contrast(c: np.ndarray, lo: float, hi: float) -> np.ndarray:
    x = np.clip((c - lo) / (hi - lo), 0, 1)
    return x * x * (3 - 2 * x)


def ss_for(size: int) -> int:
    if size <= 32:
        return 8
    if size <= 64:
        return 4
    return 2


def best_offset(ii: np.ndarray, size: int, fill: float) -> tuple[float, float]:
    """亚像素对齐：在墨量不变的前提下让中间调最少（最锐）。"""
    if size > 32:
        return 0.0, 0.0
    ss = ss_for(size)
    ref = downsample(coverage(ii, size, fill, ss=ss), size, ss)
    best = (1e18, 0.0, 0.0)
    for ox in np.arange(-0.5, 0.5, 0.125):
        for oy in np.arange(-0.5, 0.5, 0.125):
            c = downsample(coverage(ii, size, fill, ox, oy, ss=ss), size, ss)
            v = float(np.sum(4 * c * (1 - c))) + 200.0 * abs(c.sum() - ref.sum())
            if v < best[0]:
                best = (v, ox, oy)
    return best[1], best[2]


def alpha_for(ii: np.ndarray, size: int, weight_px: float, fill: float | None = None) -> np.ndarray:
    ss = ss_for(size)
    if fill is None:
        fill = FILL.get(size, FILL_LARGE)
    ox, oy = best_offset(ii, size, fill)
    c_ss = coverage(ii, size, fill, ox, oy, ss=ss)
    if abs(weight_px) > 1e-6:
        c_ss = morph(c_ss, weight_px * ss)
    c = downsample(c_ss, size, ss)
    lo, hi = CRISP.get(size, (0.02, 0.98))
    # lo/hi 关于 0.5 对称，对比度拉伸不改变墨量，不需要再做归一化
    return np.clip(contrast(c, lo, hi), 0.0, 1.0)


def tint(alpha: np.ndarray, color, scale: int = 1) -> Image.Image:
    size = alpha.shape[0]
    px = np.zeros((size, size, 4), dtype=np.uint8)
    px[:, :, 0:3] = color
    px[:, :, 3] = np.round(np.clip(alpha, 0, 1) * 255).astype(np.uint8)
    return Image.fromarray(px, "RGBA")


# ----------------------------------------------------------------------- ICO
def ico_bytes(frames: list[Image.Image]) -> bytes:
    blobs = []
    for img in frames:
        rgba = np.asarray(img.convert("RGBA"), dtype=np.uint8)
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
        buf += struct.pack("<BBBBHHII",
                           0 if img.width >= 256 else img.width,
                           0 if img.height >= 256 else img.height,
                           0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    return bytes(buf + b"".join(blobs))


def build_set(ii: np.ndarray, color, weight_px: float, sizes=SIZES):
    return [tint(alpha_for(ii, s, weight_px), color) for s in sizes]


def main():
    ii = integral(load_master())
    OUT.mkdir(parents=True, exist_ok=True)
    for weight, table in (("thin", WEIGHT_THIN), ("bold", WEIGHT_BOLD)):
        alphas = {}
        for s in SIZES:
            alphas[s] = alpha_for(ii, s, table.get(s, 0.0))
            print(f"  {weight} {s}px ok", flush=True)
        for name, rgb in COLORS.items():
            frames = [tint(alphas[s], rgb) for s in SIZES]
            p = OUT / weight / f"{name}.ico"
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(ico_bytes(frames))
            print(f"{weight}/{name}.ico  {p.stat().st_size} bytes", flush=True)
    # 应用图标（exe/快捷方式）：品牌绿、四周留白更多（桌面图标需要呼吸空间）
    app_sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
    app = [tint(alpha_for(ii, s, WEIGHT_BOLD.get(s, 0.0) if s <= 24 else 0.0, fill=0.86),
                COLORS["tray"]) for s in app_sizes]
    (OUT / "app.ico").write_bytes(ico_bytes(app))
    print("app.ico", (OUT / "app.ico").stat().st_size)


if __name__ == "__main__":
    main()

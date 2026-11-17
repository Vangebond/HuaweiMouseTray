"""第三版图标：沿用第一版的尺寸（留白、不撑满），
但用 256px 原生帧做「轻微加粗 + 平滑降采样」，让 24px 下的描边实一点、
曲线保持 PDF 里的圆滑，而不是硬阈值造成的台阶。
"""

import struct
from pathlib import Path

from PIL import Image, ImageFilter

BASE = Path(__file__).resolve().parents[2]
SRC = BASE / "preview" / "nearlink-white-v1.ico"
OUT_ICO = BASE / "preview" / "nearlink-white.ico"

TARGETS = [16, 20, 24, 32, 40, 48, 64, 128, 256]
FILL = 0.88          # 与第一版一致（不撑满）
DILATE = 7           # 256px 上半径 3px ≈ 24px 下的 0.28px 加粗
PAD = 24

src = Image.open(SRC)
master = src.ico.getimage((256, 256)).convert("RGBA")
print("master:", master.size)

master = master.crop(master.getchannel("A").getbbox())
print("ink bbox ->", master.size)

# 先补透明边距，否则膨胀会被裁边吃掉
canvas = Image.new("RGBA", (master.width + 2 * PAD, master.height + 2 * PAD), (255, 255, 255, 0))
canvas.paste(master, (PAD, PAD), master)

a = canvas.getchannel("A")
a = a.filter(ImageFilter.MaxFilter(DILATE))
a = a.filter(ImageFilter.GaussianBlur(0.8))
canvas.putalpha(a)

bbox = a.point(lambda v: 255 if v > 8 else 0).getbbox()
master = canvas.crop(bbox)
print("after dilate ->", master.size)


def frame(size: int) -> Image.Image:
    inner = max(1, round(size * FILL))
    ratio = min(inner / master.width, inner / master.height)
    w = max(1, round(master.width * ratio))
    h = max(1, round(master.height * ratio))
    small = master.resize((w, h), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    out.paste(small, ((size - w) // 2, (size - h) // 2), small)
    return out


frames = {s: frame(s) for s in TARGETS}


def ico_bytes(images):
    blobs = []
    for img in images:
        rgba = img.convert("RGBA")
        w, h = rgba.size
        px = rgba.load()
        xor = bytearray()
        for y in range(h - 1, -1, -1):
            for x in range(w):
                r, g, b, al = px[x, y]
                xor += bytes((b, g, r, al))
        and_mask = bytes((((w + 31) // 32) * 4) * h)
        blobs.append(struct.pack("<IiiHHIIiiII", 40, w, h * 2, 1, 32, 0, len(xor) + len(and_mask), 0, 0, 0, 0)
                     + bytes(xor) + and_mask)
    buf = bytearray(struct.pack("<HHH", 0, 1, len(blobs)))
    offset = 6 + 16 * len(blobs)
    for img, blob in zip(images, blobs):
        buf += struct.pack("<BBBBHHII", 0 if img.width >= 256 else img.width,
                           0 if img.height >= 256 else img.height, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    for blob in blobs:
        buf += blob
    return bytes(buf)


OUT_ICO.write_bytes(ico_bytes([frames[s] for s in TARGETS]))
print("ico:", OUT_ICO.stat().st_size, "bytes")
frames[24].save(BASE / "preview" / "nearlink-white-24.png")
frames[48].save(BASE / "preview" / "nearlink-white-48.png")

# 对照：第一版 vs 第三版，24px 1:1 + 8 倍放大，深色底
Z = 8
pairs = [("v1", SRC), ("v3", OUT_ICO)]
sheet = Image.new("RGB", (24 * Z * 2 + 60, 24 * Z + 60), (30, 30, 34))
x = 20
for label, ico in pairs:
    im = Image.open(ico).ico.getimage((24, 24)).convert("RGBA")
    sheet.paste(im, (x, 14), im)
    big = im.resize((24 * Z, 24 * Z), Image.NEAREST)
    sheet.paste(big, (x, 44), big)
    x += 24 * Z + 20
sheet.save(BASE / "preview" / "icon-before-after.png")
print("comparison -> preview/icon-before-after.png (左 v1，右 v3)")

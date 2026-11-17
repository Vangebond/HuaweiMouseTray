"""把图标从「反白（白）」换成规范里「单色绿字标反白标志」用的品牌绿。

几何、尺寸、加粗程度全部沿用当前版本，只替换 RGB，alpha 保留 —— 形状一点都不变。
品牌绿取自 PDF 第 13 页该标记的 fill 值：rgb(0.17514, 0.72381, 0.55135)。
"""

import struct
from pathlib import Path

from PIL import Image

BASE = Path(__file__).resolve().parents[2]
PREVIEW = BASE / "preview"
SRC = PREVIEW / "nearlink-white.ico"
OUT_ICO = PREVIEW / "nearlink-white.ico"
BACKUP = PREVIEW / "nearlink-white-v3.ico"

BRAND = (45, 185, 141)          # #2DB98D
SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]


def ico_bytes(images):
    blobs = []
    for img in images:
        rgba = img.convert("RGBA")
        w, h = rgba.size
        px = rgba.load()
        xor = bytearray()
        for y in range(h - 1, -1, -1):
            for x in range(w):
                r, g, b, a = px[x, y]
                xor += bytes((b, g, r, a))
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


if not BACKUP.exists():
    BACKUP.write_bytes(SRC.read_bytes())
    print("备份白色版 ->", BACKUP.name)

src = Image.open(SRC)
avail = sorted(s for s, _ in src.ico.sizes())
solid = Image.new("RGBA", (1, 1), BRAND + (255,))

green = {}
for s in avail:
    im = src.ico.getimage((s, s)).convert("RGBA")
    # 用纯色图 + 原 alpha 合成，形状与白色版逐像素一致
    out = Image.new("RGBA", im.size, BRAND + (255,))
    out.putalpha(im.getchannel("A"))
    green[s] = out
print("重上色尺寸:", avail)

OUT_ICO.write_bytes(ico_bytes([green[s] for s in SIZES]))
print("ico:", OUT_ICO.stat().st_size, "bytes")

for s in (24, 48, 256):
    if s in green:
        green[s].save(PREVIEW / f"nearlink-green-{s}.png")

# 对照：白色 / 绿色，深底与浅底，24px 1:1 与 8 倍
Z = 8
white24 = src.ico.getimage((24, 24)).convert("RGBA")
green24 = green[24]
cell = 24 * Z
sheet = Image.new("RGB", (cell * 2 + 60, cell * 2 + 90), (28, 28, 32))
sheet.paste(Image.new("RGB", (sheet.width, cell + 45), (243, 243, 243)), (0, cell + 45))
for col, im in enumerate((white24, green24)):
    x = 20 + col * (cell + 20)
    sheet.paste(im.resize((cell, cell), Image.NEAREST), (x, 10), im.resize((cell, cell), Image.NEAREST))
    sheet.paste(im.resize((cell, cell), Image.NEAREST), (x, cell + 55), im.resize((cell, cell), Image.NEAREST))
sheet.save(PREVIEW / "icon-before-after.png")
print("对照图 -> preview/icon-before-after.png（左白 右绿，上深底 下浅底）")

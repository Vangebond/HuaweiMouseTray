"""托盘四套图标：高=绿 / 中=黄 / 低=红 / 关闭=白。
几何沿用现有图标，只换 RGB。
"""

import struct
from pathlib import Path

from PIL import Image

BASE = Path(__file__).resolve().parents[2]
PREVIEW = BASE / "preview"
SRC = PREVIEW / "nearlink-white.ico"

LEVELS = {
    "green": (45, 185, 141),      # #2DB98D 品牌绿（2.07 单色绿字标反白标志的标记色）
    "yellow": (255, 193, 7),      # #FFC107 中电量
    "red": (229, 72, 77),         # #E5484D 低电量
    "white": (255, 255, 255),     # #FFFFFF 关闭个性化时
}


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


src = Image.open(SRC)
sizes = sorted(s for s, _ in src.ico.sizes())

for name, rgb in LEVELS.items():
    frames = []
    for s in sizes:
        im = src.ico.getimage((s, s)).convert("RGBA")
        out = Image.new("RGBA", im.size, rgb + (255,))
        out.putalpha(im.getchannel("A"))
        frames.append(out)
    target = PREVIEW / f"level-{name}.ico"
    target.write_bytes(ico_bytes(frames))
    print(f"{target.name}: {target.stat().st_size} bytes")

# 四色预览：深底 + 浅底
Z = 6
cell = 24 * Z
order = ["green", "yellow", "red", "white"]
sheet = Image.new("RGB", (cell * len(order) + 30 * (len(order) + 1), cell * 2 + 90), (28, 28, 32))
sheet.paste(Image.new("RGB", (sheet.width, cell + 45), (243, 243, 243)), (0, cell + 45))
x = 30
for name in order:
    im = Image.open(PREVIEW / f"level-{name}.ico").ico.getimage((24, 24)).convert("RGBA")
    big = im.resize((cell, cell), Image.NEAREST)
    sheet.paste(big, (x, 20), big)
    sheet.paste(big, (x, cell + 65), big)
    x += cell + 30
sheet.save(PREVIEW / "level-colors.png")
print("预览 -> preview/level-colors.png （绿/黄/红/白，上深底 下浅底）")

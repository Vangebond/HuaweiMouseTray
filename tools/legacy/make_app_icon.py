"""生成「应用图标」：给 exe 和桌面快捷方式用。

和托盘图标不同：
  * 用回第一版的逐尺寸矢量帧（nearlink-white-v1.ico），不做为 24px 加粗的膨胀；
  * 留白更大（0.76），因为桌面/资源管理器里图标四周需要呼吸空间，否则显得"太大"；
  * 固定品牌绿，不跟电量变色（快捷方式不该闪）。
"""

import struct
from pathlib import Path

from PIL import Image

BASE = Path(__file__).resolve().parents[2]
PREVIEW = BASE / "preview"
SRC = PREVIEW / "nearlink-white-v1.ico"
OUT = PREVIEW / "app.ico"

BRAND = (45, 185, 141)      # #2DB98D
FILL = 0.76                 # 比托盘的 0.88 更收一点
SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]


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
available = sorted(s for s, _ in src.ico.sizes())
# 用最大的一帧当母版，保证所有尺寸都是从矢量渲染的高分辨率降采样来的
master = src.ico.getimage((max(available), max(available))).convert("RGBA")
master = master.crop(master.getchannel("A").getbbox())
print("master:", master.size)

frames = []
for size in SIZES:
    inner = max(1, round(size * FILL))
    ratio = min(inner / master.width, inner / master.height)
    w = max(1, round(master.width * ratio))
    h = max(1, round(master.height * ratio))
    small = master.resize((w, h), Image.LANCZOS)
    tinted = Image.new("RGBA", small.size, BRAND + (255,))
    tinted.putalpha(small.getchannel("A"))
    canvas = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    canvas.paste(tinted, ((size - w) // 2, (size - h) // 2), tinted)
    frames.append(canvas)

OUT.write_bytes(ico_bytes(frames))
print("app.ico:", OUT.stat().st_size, "bytes,", len(SIZES), "sizes")

# 预览：48 / 96 / 256 在浅底和深底上
Z = 3 if False else 1
sheet = Image.new("RGB", (256 + 96 + 48 + 80, 300), (243, 243, 243))
x = 20
for idx, size in enumerate([256, 96, 48]):
    f = frames[SIZES.index(size)]
    sheet.paste(f, (x, 20), f)
    x += size + 20
sheet.save(PREVIEW / "app-icon-preview.png")
frames[SIZES.index(256)].save(PREVIEW / "app-256.png")
print("preview -> preview/app-icon-preview.png")

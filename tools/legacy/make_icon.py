"""从官方规范 PDF 第 13 页（2.07）的「反白标志」里取白色 mark，
按每个目标尺寸分别从矢量渲染，输出白字透明底 ICO + PNG。"""

import struct
import sys
from pathlib import Path

# 需要 numpy + Pillow（pip install numpy pillow）
import fitz  # noqa: E402
from PIL import Image  # noqa: E402

BASE = Path(__file__).resolve().parents[2]
PDF = Path(os.environ.get("TRAY_PDF", BASE / "tools" / "7.pdf"))
OUT = BASE / "extracted"
PREVIEW = BASE / "preview"
OUT.mkdir(exist_ok=True)
PREVIEW.mkdir(exist_ok=True)

# 「反白标志」色块里竖版组合的白色 mark 包围盒（PDF 点）
CLIP = fitz.Rect(437.0, 337.0, 475.0, 380.0)
SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]
FILL_RATIO = 0.88          # mark 在方形图标里的占比
BG_THRESHOLD = 10          # 低于此亮度视为背景

doc = fitz.open(PDF)
page = doc[12]


def render_mark(target_px: int) -> Image.Image:
    """把 mark 按目标像素高度精确渲染成白字透明底 RGBA。"""
    inner = max(1, round(target_px * FILL_RATIO))
    zoom = inner / max(CLIP.width, CLIP.height)
    pix = page.get_pixmap(clip=CLIP, matrix=fitz.Matrix(zoom, zoom), alpha=False)
    gray = Image.frombytes("RGB", (pix.width, pix.height), pix.samples).convert("L")
    alpha = gray.point(lambda v: 0 if v < BG_THRESHOLD else v)
    alpha = alpha.crop(alpha.getbbox())

    canvas = Image.new("RGBA", (target_px, target_px), (255, 255, 255, 0))
    layer = Image.new("RGBA", alpha.size, (255, 255, 255, 255))
    layer.putalpha(alpha)
    canvas.paste(layer, ((target_px - layer.width) // 2, (target_px - layer.height) // 2), layer)
    return canvas


frames = {s: render_mark(s) for s in SIZES}
print("rendered sizes:", {s: frames[s].size for s in (16, 24, 256)})


def ico_bytes(images):
    """手写多尺寸 32bpp ICO（DIB 条目，兼容性最好，System.Drawing 也能读）。"""
    blobs = []
    for img in images:
        rgba = img.convert("RGBA")
        w, h = rgba.size
        px = rgba.load()
        xor = bytearray()
        for y in range(h - 1, -1, -1):          # 自下而上
            for x in range(w):
                r, g, b, a = px[x, y]
                xor += bytes((b, g, r, a))      # BGRA
        and_stride = ((w + 31) // 32) * 4
        and_mask = bytes(and_stride * h)
        header = struct.pack(
            "<IiiHHIIiiII",
            40, w, h * 2, 1, 32, 0, len(xor) + len(and_mask), 0, 0, 0, 0,
        )
        blobs.append(header + bytes(xor) + and_mask)

    out = bytearray(struct.pack("<HHH", 0, 1, len(blobs)))
    offset = 6 + 16 * len(blobs)
    for img, blob in zip(images, blobs):
        w = 0 if img.width >= 256 else img.width
        h = 0 if img.height >= 256 else img.height
        out += struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32, len(blob), offset)
        offset += len(blob)
    for blob in blobs:
        out += blob
    return bytes(out)


ordered = [frames[s] for s in SIZES]
ico_path = PREVIEW / "nearlink-white.ico"
ico_path.write_bytes(ico_bytes(ordered))
print("ico:", ico_path.name, ico_path.stat().st_size, "bytes,", len(SIZES), "frames")

frames[256].save(OUT / "nearlink-white-256.png")
frames[512].save(OUT / "nearlink-white-512.png") if 512 in frames else frames[256].save(OUT / "nearlink-white-512.png")

# 对照图：深底 / 浅底，1:1 与 4 倍放大小尺寸
top = 300
w = sum(SIZES) + 10 * (len(SIZES) + 1)
sheet = Image.new("RGB", (w, 2 * (top + 20)), (28, 28, 32))
sheet.paste(Image.new("RGB", (w, top + 20), (28, 28, 32)), (0, 0))
sheet.paste(Image.new("RGB", (w, top + 20), (243, 243, 243)), (0, top + 20))
x = 10
for s in SIZES:
    f = frames[s]
    sheet.paste(f, (x, 10 + (top - s) // 2), f)
    sheet.paste(f, (x, top + 30 + (top - s) // 2), f)
    x += s + 10
sheet.save(OUT / "icon-sheet.png")

# 小尺寸放大 8 倍看细节
zoom_sheet = Image.new("RGB", (4 * (24 * 8 + 10) + 10, 24 * 8 + 20), (28, 28, 32))
for i, s in enumerate([16, 20, 24, 32]):
    z = frames[s].resize((s * 8, s * 8), Image.NEAREST)
    zoom_sheet.paste(z, (10 + i * (24 * 8 + 10), 10), z)
zoom_sheet.save(OUT / "icon-zoom-sheet.png")

doc.close()
print("done")

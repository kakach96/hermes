"""生成极简 icon.ico：暗底方块 + 琥珀圆点（与桌面 UI 同款视觉）。
纯 struct 手写 ICO（32bpp BMP 路径），不依赖 PIL。"""
import struct, sys, math

SIZE = 32          # 图标边长
RADIUS = 8         # 圆点半径
BG = (0x13, 0x10, 0x10, 0xFF)   # BGR! --panel #101013
ACCENT = (0x5F, 0xA2, 0xD9, 0xFF)  # BGR! --accent #D9A25F
RING = (0x2A, 0x24, 0x1E, 0xFF)

W = H = SIZE
# ICO 的 BMP 自底向上（y=0 是最底行）
pixels = []
for y in range(H):
    row = []
    for x in range(W):
        row.append(BG)
    pixels.append(row)

cx = cy = (SIZE - 1) / 2
for y in range(H):
    for x in range(W):
        d = math.hypot(x - cx, y - cy)
        if d <= RADIUS:
            pixels[y][x] = ACCENT
        elif d <= RADIUS + 1.5:
            pixels[y][x] = RING

# BITMAPINFOHEADER（高度翻倍：XOR + AND 掩码）
bmi = struct.pack(
    "<IiiHHIIiiII",
    40, W, H * 2, 1, 32, 0, W * H * 4 + (H * ((W + 31) // 32) * 4), 0, 0, 0, 0,
)
xor = b"".join(bytes(px) for row in reversed(pixels) for px in row)
mask_row = b"\x00" * (((W + 31) // 32) * 4)
mask = mask_row * H
img = bmi + xor + mask

ico = struct.pack("<HHH", 0, 1, 1)
ico += struct.pack(
    "<BBBBHHII", W % 256, H % 256, 0, 0, 1, 32, len(img), 22
)
ico += img

with open(sys.argv[1], "wb") as f:
    f.write(ico)
print(f"icon.ico written ({len(ico)} bytes)")

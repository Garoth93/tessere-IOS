#!/usr/bin/env python3
"""Generates the app icon: a tilted card with a barcode on OLED black.
   python3 scripts/make-icon.py apps/Tessere/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 4                      # supersampling
W = 1024 * S
icon = Image.new("RGB", (W, W), (0, 0, 0))

# Card (credit-card ratio) drawn flat, then rotated.
cw, ch = int(700 * S), int(441 * S)
card = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
grad = Image.new("RGBA", (cw, ch))
top, bottom = (78, 255, 205), (0, 158, 128)   # acid teal → deep teal
gp = grad.load()
for y in range(ch):
    for x in range(cw):
        t = (x / cw * 0.55 + y / ch * 0.45)
        gp[x, y] = tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)) + (255,)
mask = Image.new("L", (cw, ch), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, cw - 1, ch - 1], radius=int(58 * S), fill=255)
card.paste(grad, (0, 0), mask)

d = ImageDraw.Draw(card)
# White panel with barcode.
px0, py0, px1, py1 = int(60 * S), int(190 * S), cw - int(60 * S), ch - int(52 * S)
d.rounded_rectangle([px0, py0, px1, py1], radius=int(26 * S), fill=(255, 255, 255, 255))
pattern = "1101001110101100111010011011101011001110100111011010111001101011101"
bw = (px1 - px0 - int(56 * S)) / len(pattern)
x = px0 + int(28 * S)
for b in pattern:
    if b == "1":
        d.rectangle([int(x), py0 + int(26 * S), int(x + bw), py1 - int(26 * S)], fill=(10, 10, 12, 255))
    x += bw
# Logo dot + bar on the top of the card.
d.ellipse([int(60 * S), int(60 * S), int(140 * S), int(140 * S)], fill=(255, 255, 255, 235))
d.rounded_rectangle([int(165 * S), int(82 * S), int(420 * S), int(118 * S)], radius=int(18 * S), fill=(255, 255, 255, 200))

rot = card.rotate(14, resample=Image.BICUBIC, expand=True)
# Soft glow under the card.
ox, oy = (W - rot.width) // 2, (W - rot.height) // 2 + int(10 * S)
glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
glow.paste((40, 255, 200, 110), (ox, oy + int(30 * S)), rot.split()[3])
glow = glow.filter(ImageFilter.GaussianBlur(40 * S))
icon.paste(glow, (0, 0), glow)
icon.paste(rot, (ox, oy), rot)
icon = icon.resize((1024, 1024), Image.LANCZOS)
icon.save(sys.argv[1])
print("ok", icon.size)

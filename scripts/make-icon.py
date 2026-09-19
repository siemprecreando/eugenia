#!/usr/bin/env python3
"""Genera el icono de la app (1024x1024, opaco: iOS aplica la máscara redondeada).

Onda de voz blanca sobre degradado índigo → violeta. Se dibuja a 4x y se reduce
para tener bordes suaves. Uso: python3 scripts/make-icon.py
"""
from PIL import Image, ImageDraw, ImageFilter

S, K = 1024, 4
W = S * K
OUT = "Eugenia/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"

top, bottom = (58, 42, 160), (124, 58, 237)   # índigo → violeta
img = Image.new("RGB", (W, W))
px = ImageDraw.Draw(img)
for y in range(W):
    t = y / (W - 1)
    px.line([(0, y), (W, y)], fill=tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)))

# Resplandor suave detrás de la onda
glow = Image.new("L", (W, W), 0)
ImageDraw.Draw(glow).ellipse([W * .18, W * .18, W * .82, W * .82], fill=70)
glow = glow.filter(ImageFilter.GaussianBlur(W * .08))
img.paste(Image.new("RGB", (W, W), (255, 255, 255)), (0, 0), glow)

# Barras de la onda, simétricas
heights = [.16, .30, .48, .64, .48, .30, .16]
bw, gap = W * .062, W * .038
total = len(heights) * bw + (len(heights) - 1) * gap
x = (W - total) / 2
d = ImageDraw.Draw(img)
for h in heights:
    hh = W * h
    d.rounded_rectangle([x, (W - hh) / 2, x + bw, (W + hh) / 2], radius=bw / 2, fill=(255, 255, 255))
    x += bw + gap

img.resize((S, S), Image.LANCZOS).save(OUT, optimize=True)
print(OUT)

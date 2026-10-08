#!/usr/bin/env python3
# Renders DejaVu Sans Mono Bold (Bitstream Vera license) into an 8x16 bitmap font for the projector:
# src/lib/shulker/font8x16.lua, one 32-hex-digit string (16 rows, MSB = left pixel) per ASCII 32..126.
import sys
from PIL import Image, ImageDraw, ImageFont
ttf = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf"
font = ImageFont.truetype(ttf, 14)
out = ["-- 8x16 bitmap font for the projector (tools/gen-font.py from DejaVu Sans Mono Bold,",
       "-- Bitstream Vera license). Glyph = 16 rows as hex bytes, MSB is the left pixel; ASCII 32..126.",
       "return {"]
for code in range(32, 127):
    img = Image.new("L", (8, 16), 0)
    d = ImageDraw.Draw(img)
    d.text((0, 0), chr(code), font=font, fill=255)
    rows = []
    for y in range(16):
        b = 0
        for x in range(8):
            if img.getpixel((x, y)) >= 110:
                b |= 0x80 >> x
        rows.append("%02x" % b)
    out.append('  [%d] = "%s", -- %s' % (code, "".join(rows), repr(chr(code))))
out.append("}")
open("src/lib/shulker/font8x16.lua", "w").write("\n".join(out) + "\n")

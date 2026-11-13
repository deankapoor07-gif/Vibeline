"""Draws the DMG window background: dark, in the app icon's purple/magenta,
with an arrow from the app to the Applications folder and "DRAG TO INSTALL".
Window is 660x400 points; icons sit at (170, 200) and (490, 200).
    python3 tool/dmg/make_background.py   ->  tool/dmg/background.png (+ @2x)"""
import math
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 660, 400
APP_X, APPS_X, ICON_Y = 170, 490, 200
MAGENTA, VIOLET = (255, 61, 187), (143, 91, 255)
FONT = "/System/Library/Fonts/Avenir Next Condensed.ttc"


def draw(scale):
    w, h = W * scale, H * scale
    s = lambda v: int(round(v * scale))
    img = Image.new("RGB", (w, h), (12, 12, 17))
    # Vertical gradient, near-black to the app's panel grey.
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        c = tuple(int(a + (b - a) * t) for a, b in zip((22, 20, 30), (10, 10, 14)))
        for x in range(w):
            px[x, y] = c
    # Soft purple glow behind each icon.
    glow = Image.new("RGB", (w, h), (0, 0, 0))
    g = ImageDraw.Draw(glow)
    for cx, col in ((APP_X, VIOLET), (APPS_X, MAGENTA)):
        g.ellipse([s(cx - 95), s(ICON_Y - 95), s(cx + 95), s(ICON_Y + 95)], fill=tuple(v // 4 for v in col))
    glow = glow.filter(ImageFilter.GaussianBlur(s(45)))
    img = _add(img, glow)
    d = ImageDraw.Draw(img)
    # Faint record grooves behind the app icon.
    for r in range(78, 132, 6):
        d.ellipse([s(APP_X - r), s(ICON_Y - r), s(APP_X + r), s(ICON_Y + r)],
                  outline=(40, 34, 56), width=max(1, s(0.6)))
    # Arrow: gradient shaft with a chevron head.
    x0, x1, y = APP_X + 92, APPS_X - 92, ICON_Y
    steps = s(x1 - x0)
    for i in range(steps):
        t = i / max(1, steps - 1)
        col = tuple(int(a + (b - a) * t) for a, b in zip(VIOLET, MAGENTA))
        xx = s(x0) + i
        d.line([(xx, s(y - 1.5)), (xx, s(y + 1.5))], fill=col)
    d.line([(s(x1 - 14), s(y - 12)), (s(x1 + 1), s(y)), (s(x1 - 14), s(y + 12))],
           fill=MAGENTA, width=s(3), joint="curve")
    # Text.
    big = ImageFont.truetype(FONT, s(17), index=2)   # Demi Bold
    small = ImageFont.truetype(FONT, s(12), index=5)  # Medium
    def centred(text, font, cy, fill, spacing):
        chars = list(text)
        widths = [d.textlength(c, font=font) for c in chars]
        total = sum(widths) + s(spacing) * (len(chars) - 1)
        x = (w - total) / 2
        for c, cw in zip(chars, widths):
            d.text((x, s(cy)), c, font=font, fill=fill, anchor="lm")
            x += cw + s(spacing)
    centred("DRAG TO INSTALL", big, ICON_Y - 30, (235, 230, 245), 3.2)
    centred("D-JAY NOODLES", small, 40, (140, 140, 152), 4)
    d.line([(s(W / 2 - 40), s(56)), (s(W / 2 + 40), s(56))], fill=MAGENTA, width=max(1, s(1)))
    centred("Drag the app onto the Applications folder", small, H - 48, (140, 140, 152), 0.6)
    return img


def _add(a, b):
    from PIL import ImageChops
    return ImageChops.add(a, b)


if __name__ == "__main__":
    draw(1).save(os.path.join(HERE, "background.png"))
    draw(2).save(os.path.join(HERE, "background@2x.png"))
    print("ok")

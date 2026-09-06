#!/usr/bin/env python3
"""One-impression email card: headline, the live panel, the capy. Run from Marketing/."""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter
SP = os.path.dirname(os.path.abspath(__file__))
W, H = 2880, 1800
BG = (251, 251, 253); INK = (29, 29, 31); SUB = (110, 110, 115); ACCENT = (10, 132, 255)
SF = "/System/Library/Fonts/SFNS.ttf"
def font(size, weight="Bold"):
    f = ImageFont.truetype(SF, size)
    try: f.set_variation_by_name(weight)
    except Exception: pass
    return f
def shot(name, d="shots-v3"):
    img = Image.open(os.path.join(SP, "..", d, name)).convert("RGBA")
    return img.crop(img.getbbox())
def place(c, img, cx, top, target_w, **kw):
    sheet, pad = with_shadow(img, **kw)
    scale = target_w / (sheet.width - pad * 2)
    sh = sheet.resize((int(sheet.width * scale), int(sheet.height * scale)), Image.LANCZOS)
    c.alpha_composite(sh, (int(cx - sh.width / 2), int(top - pad * scale)))
def with_shadow(img, radius_big=70, alpha_big=54, dy_big=34, radius_tight=22, alpha_tight=46, dy_tight=10):
    pad = radius_big * 3
    sheet = Image.new("RGBA", (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
    mask = img.split()[3]
    for rad, alpha, dy in ((radius_big, alpha_big, dy_big), (radius_tight, alpha_tight, dy_tight)):
        shadow = Image.new("RGBA", sheet.size, (0, 0, 0, 0))
        shadow.paste(Image.new("RGBA", img.size, (0, 0, 0, alpha)), (pad, pad + dy), mask)
        sheet = Image.alpha_composite(sheet, shadow.filter(ImageFilter.GaussianBlur(rad)))
    sheet.paste(img, (pad, pad), img)
    return sheet, pad
def canvas():
    c = Image.new("RGBA", (W, H), BG + (255,))
    glow = Image.new("RGBA", (W // 8, H // 8), (0, 0, 0, 0)); gd = ImageDraw.Draw(glow)
    def blob(cx, cy, r, rgb, a): gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=rgb + (a,))
    blob(int(W*0.18)//8, int(H*0.10)//8, 135, (115, 145, 255), 66)
    blob(int(W*0.85)//8, int(H*0.16)//8, 145, (175, 120, 255), 60)
    blob(int(W*0.50)//8, int(H*1.04)//8, 185, (135, 165, 255), 62)
    blob(int(W*0.05)//8, int(H*0.72)//8, 125, (255, 150, 200), 40)
    glow = glow.filter(ImageFilter.GaussianBlur(60)).resize((W, H), Image.BICUBIC)
    return Image.alpha_composite(c, glow)
def center(dr, y, text, f, fill): dr.text(((W - dr.textlength(text, font=f)) / 2, y), text, font=f, fill=fill)

c = canvas(); dr = ImageDraw.Draw(c)
t = font(190, "Bold")
center(dr, 150, "My hands don't work.", t, INK)
center(dr, 150 + 215, "So I built this.", t, ACCENT)
s = font(60, "Regular")
center(dr, 640, "Dictation for the Mac. Free, open source, and everything stays on your Mac.", s, SUB)
# The three panel forms, arranged like the hero poster: expanded right, compact left, mini below.
place(c, shot("panel-expanded.png"), W * 0.665, 760, 1560, radius_big=70, alpha_big=64)
place(c, shot("panel-compact.png"), W * 0.205, 880, 1120, radius_big=60, alpha_big=70)
place(c, shot("panel-mini.png"), W * 0.235, 1270, 800, radius_big=55, alpha_big=66)
capy = shot("capy-glyph.png", "shots"); capy = capy.resize((150, int(150 * capy.height / capy.width)), Image.LANCZOS)
c.alpha_composite(capy, (int(W / 2 - capy.width / 2), 1560))
# Bottom right: the name, then the one line the email ends on.
dr = ImageDraw.Draw(c)
nf = font(72, "Bold"); ff = font(46, "Regular")
right = W - 150
dr.text((right - dr.textlength("YapToText", font=nf), 1520), "YapToText", font=nf, fill=INK)
dr.text((right - dr.textlength("Available on the Mac App Store.", font=ff), 1615), "Available on the Mac App Store.", font=ff, fill=SUB)
out = os.path.join(SP, "..", "email", "yaptotext-card.jpg")
c.convert("RGB").resize((1600, 1000), Image.LANCZOS).save(out, quality=88, optimize=True)
print(out, os.path.getsize(out) // 1024, "KB")

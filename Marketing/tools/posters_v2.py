#!/usr/bin/env python3
"""YapToText App Store posters v2: the expressive set.

Same Apple-poster DNA as v1 (2880x1800, SF Pro, soft double shadows) plus the fun:
soft tinted washes, the app's own signature wave ribbon drawn under headlines,
feature chips, the capybara everywhere it earns its place, and a punchline poster.
Run from Marketing/: python3 tools/posters_v2.py   ->  writes ../posters-v2
"""
import os, math
from PIL import Image, ImageDraw, ImageFont, ImageFilter

SP = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(SP, "..", "shots-v2")   # fresh captures first
SHOTS_V1 = os.path.join(SP, "..", "shots")    # legacy assets (symbols, capy, icon)
OUT = os.path.join(SP, "..", "posters-v2")
os.makedirs(OUT, exist_ok=True)

W, H = 2880, 1800
BG = (251, 251, 253)
INK = (29, 29, 31)
SUB = (110, 110, 115)
ACCENT = (10, 132, 255)
MINT = (48, 209, 88)
SF = "/System/Library/Fonts/SFNS.ttf"

def font(size, weight="Bold"):
    f = ImageFont.truetype(SF, size)
    try: f.set_variation_by_name(weight)
    except Exception: pass
    return f

def load_shot(name):
    path = os.path.join(SHOTS, name)
    if not os.path.exists(path): path = os.path.join(SHOTS_V1, name)
    img = Image.open(path).convert("RGBA")
    b = img.getbbox()
    return img.crop(b) if b else img

def with_shadow(img, rb=70, ab=54, dyb=34, rt=22, at=46, dyt=10):
    pad = rb * 3
    sheet = Image.new("RGBA", (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
    mask = img.split()[3]
    for rad, alpha, dy in ((rb, ab, dyb), (rt, at, dyt)):
        sh = Image.new("RGBA", sheet.size, (0, 0, 0, 0))
        black = Image.new("RGBA", img.size, (0, 0, 0, alpha))
        sh.paste(black, (pad, pad + dy), mask)
        sh = sh.filter(ImageFilter.GaussianBlur(rad))
        sheet = Image.alpha_composite(sheet, sh)
    sheet.paste(img, (pad, pad), img)
    return sheet, pad

def place(canvas, sheet, pad, cx, top, tw):
    scale = tw / (sheet.width - 2 * pad)
    ns = sheet.resize((int(sheet.width * scale), int(sheet.height * scale)), Image.LANCZOS)
    np_ = int(pad * scale)
    canvas.alpha_composite(ns, (int(cx - tw / 2 - np_), int(top - np_)))

# ---- v2 signature elements -------------------------------------------------

def wash(canvas, tints):
    """Soft, very light color wash: a few huge blurred blobs. Keeps the Apple field
    but lets each poster breathe its own color."""
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for (x, y, r, color, a) in tints:
        d.ellipse([x - r, y - r, x + r, y + r], fill=color + (a,))
    layer = layer.filter(ImageFilter.GaussianBlur(260))
    canvas.alpha_composite(layer)

def ribbon(canvas, cy, width=1180, amp=26, thick=7, alpha=255, cx=W // 2):
    """The app's own wave: three overlapping smooth ribbons in the brand gradient.
    Drawn 2x and downsampled so the curves are silk."""
    S = 2
    lay = Image.new("RGBA", (width * S, (amp * 6) * S), (0, 0, 0, 0))
    d = ImageDraw.Draw(lay)
    mid = lay.height // 2
    cols = [(10, 132, 255), (60, 190, 255), (52, 219, 170)]
    for k, col in enumerate(cols):
        pts = []
        for i in range(0, lay.width + 1, 6):
            u = i / lay.width
            envelope = math.sin(u * math.pi) ** 0.8
            y = mid + S * amp * envelope * math.sin(u * math.tau * (1.6 + 0.25 * k) + k * 1.9)
            pts.append((i, y))
        d.line(pts, fill=col + (alpha,), width=thick * S, joint="curve")
    glow = lay.filter(ImageFilter.GaussianBlur(10 * S))
    lay = Image.alpha_composite(glow, lay)
    lay = lay.resize((width, amp * 6), Image.LANCZOS)
    canvas.alpha_composite(lay, (int(cx - width / 2), int(cy - lay.height / 2)))

def chips(canvas, y, labels, size=44, cx=W // 2, gap=26):
    """Rounded feature chips - quiet gray capsules with ink text, one accent chip max."""
    f = font(size, "Semibold")
    dr = ImageDraw.Draw(canvas)
    widths = [dr.textlength(t, font=f) + size * 1.6 for t, _ in labels]
    total = sum(widths) + gap * (len(labels) - 1)
    x = cx - total / 2
    hgt = size * 1.9
    for (t, accent), w in zip(labels, widths):
        S = 4
        chip = Image.new("RGBA", (int(w) * S, int(hgt) * S), (0, 0, 0, 0))
        cd = ImageDraw.Draw(chip)
        fill = (10, 132, 255, 26) if accent else (29, 29, 31, 14)
        cd.rounded_rectangle([S, S, chip.width - S, chip.height - S], radius=int(hgt * S / 2), fill=fill)
        chip = chip.resize((int(w), int(hgt)), Image.LANCZOS)
        canvas.alpha_composite(chip, (int(x), int(y)))
        col = ACCENT if accent else INK
        dr.text((x + (w - dr.textlength(t, font=f)) / 2, y + hgt / 2 - size * 0.62), t, font=f, fill=col)
        x += w + gap

def headline(canvas, title, sub=None, sub2=None, y=118, ts=158, ss=57, ink=INK, eyebrow=None):
    dr = ImageDraw.Draw(canvas)
    yy = y
    if eyebrow:
        f = font(52, "Semibold")
        dr.text(((W - dr.textlength(eyebrow, font=f)) / 2, yy), eyebrow, font=f, fill=ACCENT)
        yy += 52 * 1.7
    t = font(ts, "Bold")
    dr.text(((W - dr.textlength(title, font=t)) / 2, yy), title, font=t, fill=ink)
    yy += ts * 1.22
    if sub:
        s = font(ss, "Regular")
        dr.text(((W - dr.textlength(sub, font=s)) / 2, yy), sub, font=s, fill=SUB)
        yy += ss * 1.5
    if sub2:
        s = font(ss, "Regular")
        dr.text(((W - dr.textlength(sub2, font=s)) / 2, yy), sub2, font=s, fill=SUB)
        yy += ss * 1.5
    return yy

def base(tints):
    c = Image.new("RGBA", (W, H), BG + (255,))
    wash(c, tints)
    return c

def save(c, name):
    c.convert("RGB").save(os.path.join(OUT, name), quality=95)
    print("wrote", name)

# ---- posters ---------------------------------------------------------------

def p01_hero():
    c = base([(500, 300, 700, (10, 132, 255), 26), (2400, 1500, 800, (150, 90, 255), 22)])
    headline(c, "Yap. It types.",
             "Free, beautiful dictation that runs entirely on your Mac.",
             y=96, ts=176, eyebrow="Introducing YapToText")
    ribbon(c, 570, width=1240, amp=24)
    chips(c, 620, [("Free forever", False), ("100% on-device", True), ("Open source", False)])
    win, pad = with_shadow(load_shot("page-home.png"))
    place(c, win, pad, W // 2, 780, 1900)
    panel, ppad = with_shadow(load_shot("panel-compact.png"), rb=50, ab=60)
    place(c, panel, ppad, 560, 1460, 700)
    # the appicon leaning in from the corner - clean transparent asset, playful tilt
    icon = load_shot("appicon.png").rotate(-10, expand=True, resample=Image.BICUBIC)
    cs, cp = with_shadow(icon, rb=40, ab=30, dyb=18)
    place(c, cs, cp, 2400, 1330, 400)
    save(c, "01-hero.jpg")

def p02_punchline():
    c = base([(1440, 500, 900, (255, 100, 60), 16), (600, 1500, 700, (10, 132, 255), 20)])
    dr = ImageDraw.Draw(c)
    t1 = font(210, "Bold")
    dr.text(((W - dr.textlength("My hands don't work.", font=t1)) / 2, 260),
            "My hands don't work.", font=t1, fill=INK)
    t2 = font(210, "Bold")
    msg = "So I built this."
    dr.text(((W - dr.textlength(msg, font=t2)) / 2, 540), msg, font=t2, fill=ACCENT)
    s = font(60, "Regular")
    for i, line in enumerate([
        "YapToText is an accessibility tool first: built by someone who depends on it,",
        "for everyone who types with their voice. Free forever, because it has to be."]):
        dr.text(((W - dr.textlength(line, font=s)) / 2, 880 + i * 92), line, font=s, fill=SUB)
    ribbon(c, 1120, width=1400, amp=28)
    row = ["sym-accessibility.png", "sym-voiceover.png", "sym-keyboard-fill.png",
           "sym-ear-fill.png", "sym-textformat-size.png"]
    x = W // 2 - (len(row) * 170 - 50) // 2
    for name in row:
        try:
            g = load_shot(name)
            g = g.resize((120, int(g.height * 120 / g.width)), Image.LANCZOS)
            c.alpha_composite(g, (x, 1260))
        except Exception: pass
        x += 170
    glyph = load_shot("capy-glyph.png")
    c.alpha_composite(glyph.resize((240, 240), Image.LANCZOS), (W // 2 - 120, 1440))
    save(c, "02-punchline.jpg")

def p03_panels():
    c = base([(1440, 1500, 900, (10, 132, 255), 22)])
    headline(c, "One key. It's listening.",
             "Tap your key anywhere - even Caps Lock - and speak.",
             "The wave dances to your voice, winds into a ring while it thinks, and your words land.")
    p1, pad1 = with_shadow(load_shot("panel-mini.png"), rb=55, ab=58)
    p2, pad2 = with_shadow(load_shot("panel-expanded.png"), rb=55, ab=58)
    p3, pad3 = with_shadow(load_shot("panel-compact.png"), rb=55, ab=58)
    r1, rpad1 = with_shadow(load_shot("ring-expanded.png"), rb=45, ab=52)
    place(c, p2, pad2, W // 2, 640, 1440)
    place(c, p1, pad1, 620, 1230, 760)
    place(c, p3, pad3, 2110, 1230, 1180)
    place(c, r1, rpad1, W // 2, 1500, 190)
    chips(c, 1660, [("Three sizes", False), ("Your colors + RGB", True), ("Spam-proof", False)])
    save(c, "03-live-panel.jpg")

def p04_auto():
    c = base([(700, 400, 700, (150, 90, 255), 22)])
    headline(c, "Edit anything by voice.",
             "Select text in any app, tap your Quick Edit key, and say the change.",
             "The wave listens, winds into the ring while it works, and the ring calls the verdict.")
    q1, qp1 = with_shadow(load_shot("qe-listening.png"), rb=50, ab=55)
    q2, qp2 = with_shadow(load_shot("qe-working.png"), rb=50, ab=55)
    q3, qp3 = with_shadow(load_shot("qe-done.png"), rb=50, ab=55)
    place(c, q1, qp1, W // 2, 640, 1240)
    place(c, q2, qp2, 800, 1130, 900)
    place(c, q3, qp3, 2080, 1130, 780)
    chips(c, 1620, [("\u201cScratch that\u201d", False), ("\u201cMake it formal\u201d", True),
                    ("\u201cAdd this to my dictionary\u201d", False)])
    save(c, "04-quick-edit.jpg")

def p05_modes():
    c = base([(2300, 500, 700, (52, 219, 170), 24)])
    headline(c, "Your voice, your rules.",
             "Modes shape how dictation lands - and AI cleanup is one switch on every row.",
             "Verbatim when you want exact words. Cleaned up when you don't. Yours to remix.")
    win, pad = with_shadow(load_shot("page-modes.png"))
    place(c, win, pad, W // 2 - 220, 640, 1780)
    sw, spad = with_shadow(load_shot("switcher.png"), rb=50, ab=55)
    place(c, sw, spad, 2330, 980, 800)
    save(c, "05-modes.jpg")

def p06_hearing():
    c = base([(1440, 400, 900, (10, 132, 255), 24), (500, 1500, 600, (52, 219, 170), 20)])
    headline(c, "Built for hard rooms.",
             "Loud background noise, whispers, shouting over the fan - it still gets your words.",
             "Peak-guarded capture, speech enhancement, and a deeper search when audio gets rough.")
    ribbon(c, 760, width=1900, amp=64, thick=9)
    dr = ImageDraw.Draw(c)
    labels = [("Whisper-quiet", 640), ("Normal voice", 1440), ("Shouting over noise", 2240)]
    f = font(46, "Semibold")
    for text, x in labels:
        dr.text((x - dr.textlength(text, font=f) / 2, 900), text, font=f, fill=SUB)
    panel, pad = with_shadow(load_shot("panel-expanded.png"), rb=55, ab=58)
    place(c, panel, pad, W // 2, 1020, 1500)
    chips(c, 1660, [("Said nothing? Inserts nothing.", False), ("No clipped shouts", True),
                    ("Long pauses welcome", False)])
    save(c, "06-hearing.jpg")

def p07_privacy():
    c = base([(1440, 900, 1000, (10, 132, 255), 14)])
    dr = ImageDraw.Draw(c)
    t = font(190, "Bold")
    dr.text(((W - dr.textlength("Your voice never", font=t)) / 2, 240), "Your voice never", font=t, fill=INK)
    dr.text(((W - dr.textlength("leaves your Mac.", font=t)) / 2, 480), "leaves your Mac.", font=t, fill=INK)
    s = font(60, "Regular")
    for i, line in enumerate([
        "Transcription, AI cleanup, history - every byte stays on device.",
        "No account. No analytics. No network calls. The source is public, so it isn't a promise - it's checkable."]):
        dr.text(((W - dr.textlength(line, font=s)) / 2, 830 + i * 96), line, font=s, fill=SUB)
    win, pad = with_shadow(load_shot("page-history.png"))
    place(c, win, pad, W // 2, 1120, 1500)
    save(c, "07-privacy.jpg")

def p08_personalize():
    c = base([(500, 400, 650, (255, 60, 120), 16), (2400, 500, 650, (10, 132, 255), 20),
              (1440, 1600, 800, (52, 219, 170), 18)])
    headline(c, "Make it yours.",
             "Three independent colors - accent, pop-up, waveform - plus a full RGB mode",
             "with speed, spread, and strength dials. Yes, your dictation app can have RGB.")
    win, pad = with_shadow(load_shot("page-settings.png"))
    place(c, win, pad, W // 2, 640, 1980)
    save(c, "08-personalize.jpg")

def p09_everywhere():
    c = base([(1440, 300, 800, (10, 132, 255), 20)])
    headline(c, "Right where you are.",
             "The menu bar holds the whole toolkit: transcribe any audio or video file,",
             "regenerate a past dictation in a new tone, or type the last one into the app you're in.")
    pop, pad = with_shadow(load_shot("popover.png"), rb=55, ab=58)
    place(c, pop, pad, W // 2 - 560, 640, 980)
    win, wpad = with_shadow(load_shot("page-utility.png"), rb=50, ab=45)
    place(c, win, wpad, W // 2 + 620, 720, 1340)
    save(c, "09-everywhere.jpg")

def p10_history():
    c = base([(700, 1500, 800, (150, 90, 255), 18)])
    headline(c, "Every word, accounted for.",
             "History with audio playback, search, and per-entry pipeline details -",
             "plus statistics that show how much your voice actually wrote.")
    w1, p1 = with_shadow(load_shot("page-history.png"))
    w2, p2 = with_shadow(load_shot("page-stats.png"))
    place(c, w1, p1, W // 2 - 420, 620, 1560)
    place(c, w2, p2, W // 2 + 620, 900, 1560)
    save(c, "10-history-stats.jpg")

if __name__ == "__main__":
    p01_hero(); p02_punchline(); p03_panels(); p04_auto(); p05_modes()
    p06_hearing(); p07_privacy(); p08_personalize(); p09_everywhere(); p10_history()
    print("done ->", OUT)

#!/usr/bin/env python3
"""Posters v3: back to the ORIGINAL Apple canvas (near-white, no washes/ribbons),
with the new capture set: boosted waves, per-menu demo text, mid-close + ring
animation frames, true-glass popover. Menus big. Copy rewritten per showcase.
Run from Marketing/: python3 tools/posters_v3.py -> ../posters-v3
"""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

SP = os.path.dirname(os.path.abspath(__file__))
DIRS = [os.path.join(SP, "..", d) for d in ("shots-v3", "shots-v2", "shots")]
OUT = os.path.join(SP, "..", "posters-v3")
os.makedirs(OUT, exist_ok=True)
W, H = 2880, 1800
BG = (251, 251, 253); INK = (29, 29, 31); SUB = (110, 110, 115); ACCENT = (10, 132, 255)
SF = "/System/Library/Fonts/SFNS.ttf"

def font(size, weight="Bold"):
    f = ImageFont.truetype(SF, size)
    try: f.set_variation_by_name(weight)
    except Exception: pass
    return f

def load_shot(name):
    for d in DIRS:
        p = os.path.join(d, name)
        if os.path.exists(p):
            img = Image.open(p).convert("RGBA")
            b = img.getbbox()
            return img.crop(b) if b else img
    raise FileNotFoundError(name)

def with_shadow(img, rb=70, ab=54, dyb=34, rt=22, at=46, dyt=10):
    pad = rb * 3
    sheet = Image.new("RGBA", (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
    mask = img.split()[3]
    for rad, alpha, dy in ((rb, ab, dyb), (rt, at, dyt)):
        sh = Image.new("RGBA", sheet.size, (0, 0, 0, 0))
        sh.paste(Image.new("RGBA", img.size, (0, 0, 0, alpha)), (pad, pad + dy), mask)
        sheet = Image.alpha_composite(sheet, sh.filter(ImageFilter.GaussianBlur(rad)))
    sheet.paste(img, (pad, pad), img)
    return sheet, pad

def place(c, sheet, pad, cx, top, tw):
    s = tw / (sheet.width - 2 * pad)
    ns = sheet.resize((int(sheet.width * s), int(sheet.height * s)), Image.LANCZOS)
    c.alpha_composite(ns, (int(cx - tw / 2 - pad * s), int(top - pad * s)))

def head(c, title, subs=(), y=112, ts=150, ss=56):
    dr = ImageDraw.Draw(c)
    t = font(ts)
    dr.text(((W - dr.textlength(title, font=t)) / 2, y), title, font=t, fill=INK)
    yy = y + ts * 1.24
    s = font(ss, "Regular")
    for line in subs:
        dr.text(((W - dr.textlength(line, font=s)) / 2, yy), line, font=s, fill=SUB)
        yy += ss * 1.5
    return yy

def caption(c, x, y, text, size=44):
    dr = ImageDraw.Draw(c)
    f = font(size, "Semibold")
    dr.text((x - dr.textlength(text, font=f) / 2, y), text, font=f, fill=SUB)

def base(): return Image.new("RGBA", (W, H), BG + (255,))
def save(c, n): c.convert("RGB").save(os.path.join(OUT, n), quality=95); print("wrote", n)

def p01():  # hero: the ORIGINAL layout and copy, equal gaps between every text block
    c = base()
    dr = ImageDraw.Draw(c)
    GAP = 46
    y = 64.0
    for text, f, fill in (
        ("Introducing YapToText", font(58, "Semibold"), ACCENT),
        ("Yap it. Bam. It's typed.", font(150), INK),
        ("Speech to text, done right.", font(70, "Semibold"), INK),
        ("Free. Private and on-device. Open source. Built for accessibility.", font(54, "Regular"), SUB),
    ):
        bb = dr.textbbox((0, 0), text, font=f)
        dr.text(((W - (bb[2] - bb[0])) / 2 - bb[0], y - bb[1]), text, font=f, fill=fill)
        y += (bb[3] - bb[1]) + GAP
    win, pad = with_shadow(load_shot("page-home.png"))
    place(c, win, pad, W / 2, 615, 1760)
    comp, cp = with_shadow(load_shot("panel-compact.png"), rb=60, ab=70)
    place(c, comp, cp, W * 0.22, 1345, 800)
    expd, ep = with_shadow(load_shot("panel-expanded.png"), rb=60, ab=70)
    place(c, expd, ep, W * 0.74, 1095, 1120)
    save(c, "01-hero.jpg")

def p02():  # punchline
    c = base()
    dr = ImageDraw.Draw(c)
    t = font(216)
    dr.text(((W - dr.textlength("My hands don't work.", font=t)) / 2, 300), "My hands don't work.", font=t, fill=INK)
    dr.text(((W - dr.textlength("So I built this.", font=t)) / 2, 590), "So I built this.", font=t, fill=ACCENT)
    s = font(60, "Regular")
    for i, line in enumerate((
        "YapToText is an accessibility tool first: built by someone who depends on it,",
        "for everyone who types with their voice. Free forever, because it has to be.")):
        dr.text(((W - dr.textlength(line, font=s)) / 2, 950 + i * 94), line, font=s, fill=SUB)
    # symbol row exactly as the original release did it: fixed 120pt cells, even pitch,
    # each glyph FIT inside its cell (no stretching) and centered on a shared midline
    syms = ["sym-accessibility.png", "sym-voiceover.png", "sym-waveform-and-mic.png",
            "sym-keyboard-fill.png", "sym-ear-fill.png", "sym-textformat-size.png"]
    pitch, cell = 190, 120
    x = W // 2 - (len(syms) * pitch - (pitch - cell)) // 2
    for name in syms:
        try:
            g = load_shot(name)
            s = min(cell / g.width, cell / g.height)
            g = g.resize((max(1, int(g.width * s)), max(1, int(g.height * s))), Image.LANCZOS)
            c.alpha_composite(g, (x + (cell - g.width) // 2, 1270 + (cell - g.height) // 2))
        except Exception: pass
        x += pitch
    g = load_shot("capy-glyph.png")
    c.alpha_composite(g.resize((230, 230), Image.LANCZOS), (W // 2 - 115, 1460))
    save(c, "02-punchline.jpg")

def p03():  # the animation, all three acts
    c = base()
    head(c, "Watch it think.",
         ("Speak, and the wave dances. Stop, and it winds itself through invisible gates",
          "into a spinning ring. Finish, and the whole card folds up after it. Every size, one signature."))
    live, lp = with_shadow(load_shot("panel-compact.png"), rb=55, ab=58)
    mid, mp = with_shadow(load_shot("midclose-compact.png"), rb=50, ab=55)
    ring, rp = with_shadow(load_shot("ring-compact.png"), rb=45, ab=52)
    place(c, live, lp, W // 2, 560, 1760)
    caption(c, W // 2, 1030, "1. The wave rides your voice")
    place(c, mid, mp, 780, 1180, 1080)
    caption(c, 780, 1600, "2. It winds into the ring")
    place(c, ring, rp, 2130, 1250, 360)
    caption(c, 2130, 1600, "3. And spins while it thinks")
    save(c, "03-the-animation.jpg")

def p04():  # three sizes, three waves
    c = base()
    head(c, "Pick your presence.",
         ("Big with a live transcript, medium in one clean row, or tiny - just the wave.",
          "Cycle them from one button, even mid-dictation. Your colors ride along."))
    e, ep = with_shadow(load_shot("panel-expanded.png"), rb=55, ab=58)
    co, cp = with_shadow(load_shot("panel-compact.png"), rb=55, ab=58)
    m, mp = with_shadow(load_shot("panel-mini.png"), rb=55, ab=58)
    place(c, e, ep, W // 2, 520, 1700)
    place(c, co, cp, 900, 1290, 1420)
    place(c, m, mp, 2280, 1330, 760)
    save(c, "04-three-sizes.jpg")

def p05():  # quick edit
    c = base()
    head(c, "Edit anything by voice.",
         ("Select text in any app, tap your Quick Edit key, and say the change.",
          "The ring works, then calls the verdict: green means done, red means untouched."))
    q1, p1 = with_shadow(load_shot("qe-listening.png"), rb=50, ab=55)
    q2, p2 = with_shadow(load_shot("qe-working.png"), rb=50, ab=55)
    q3, p3 = with_shadow(load_shot("qe-done.png"), rb=50, ab=55)
    place(c, q1, p1, W // 2, 600, 1420)
    place(c, q2, p2, 840, 1150, 1000)
    place(c, q3, p3, 2100, 1180, 860)
    save(c, "05-quick-edit.jpg")

def p06():  # hard rooms
    c = base()
    head(c, "Built for hard rooms.",
         ("A rebuilt listening engine: loud noise, whispers, machine-gun talkers, long pauses -",
          "peak-guarded capture, deeper decoding when audio gets rough, and silence inserts nothing."))
    panel, pp = with_shadow(load_shot("panel-compact.png"), rb=55, ab=58)
    place(c, panel, pp, W // 2, 660, 1980)
    win, wp = with_shadow(load_shot("page-dictation.png"))
    place(c, win, wp, W // 2, 1120, 1560)
    save(c, "06-hard-rooms.jpg")

def p07():  # privacy
    c = base()
    dr = ImageDraw.Draw(c)
    t = font(190)
    dr.text(((W - dr.textlength("Your voice never", font=t)) / 2, 240), "Your voice never", font=t, fill=INK)
    dr.text(((W - dr.textlength("leaves your Mac.", font=t)) / 2, 480), "leaves your Mac.", font=t, fill=INK)
    s = font(60, "Regular")
    for i, line in enumerate((
        "Transcription, AI cleanup, history - every byte stays on device. No account,",
        "no analytics, no network calls. The source is public: it isn't a promise, it's checkable.")):
        dr.text(((W - dr.textlength(line, font=s)) / 2, 830 + i * 96), line, font=s, fill=SUB)
    win, pad = with_shadow(load_shot("page-history.png"))
    place(c, win, pad, W // 2, 1120, 1560)
    save(c, "07-privacy.jpg")

def p08():  # modes + pipeline
    c = base()
    head(c, "Your words, your pipeline.",
         ("Modes shape how dictation lands: verbatim, cleaned up, email-ready, note-tidy.",
          "AI cleanup is one switch on every row, and Auto mode picks for you."))
    win, pad = with_shadow(load_shot("page-modes.png"))
    place(c, win, pad, W // 2, 620, 2080)
    save(c, "08-modes.jpg")

def p09():  # menu bar, true glass
    c = base()
    head(c, "Right where you are.",
         ("The menu bar holds the whole toolkit: transcribe any audio or video file,",
          "regenerate a dictation in a new tone, or type the last one into the app you're in."))
    pop, pp = with_shadow(load_shot("popover.png"), rb=55, ab=58)
    place(c, pop, pp, W // 2 - 620, 620, 1060)
    win, wp = with_shadow(load_shot("page-utility.png"))
    place(c, win, wp, W // 2 + 560, 700, 1460)
    save(c, "09-menu-bar.jpg")

def p10():  # personalize
    c = base()
    head(c, "Make it yours.",
         ("Three independent colors - accent, pop-up, waveform - plus full RGB with speed,",
          "spread, and strength dials. Any key as your trigger. Every detail adjustable."))
    win, pad = with_shadow(load_shot("page-settings.png"))
    place(c, win, pad, W // 2, 620, 2080)
    save(c, "10-personalize.jpg")

if __name__ == "__main__":
    for f in (p01, p02, p03, p04, p05, p06, p07, p08, p09, p10): f()
    print("done ->", OUT)

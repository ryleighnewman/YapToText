#!/usr/bin/env python3
"""Posters v5: the v4 set re-shot for 1.5 (new Home, Dictation, Quick Edit, folders).
Gradient-hinted canvas on every poster, big consistent screenshots, bottom fade
when a window runs off the page, feature copy that names the new engine work.
Run from Marketing/: python3 tools/posters_v5.py -> ../posters-v5"""
import os, math
from PIL import Image, ImageDraw, ImageFont, ImageFilter

SP = os.path.dirname(os.path.abspath(__file__))
DIRS = [os.path.join(SP, "..", d) for d in ("shots-v5", "shots-v3", "shots")]
OUT = os.path.join(SP, "..", "posters-v5")
os.makedirs(OUT, exist_ok=True)

W, H = 2880, 1800
BG = (251, 251, 253)
INK = (29, 29, 31)
SUB = (110, 110, 115)
ACCENT = (10, 132, 255)
SF = "/System/Library/Fonts/SFNS.ttf"

def font(size, weight="Bold"):
    f = ImageFont.truetype(SF, size)
    try: f.set_variation_by_name(weight)
    except Exception: pass
    f._size, f._weight = size, weight
    return f

def load_shot(name):
    for d in DIRS:
        p = os.path.join(d, name)
        if os.path.exists(p):
            img = Image.open(p).convert("RGBA")
            bbox = img.getbbox()
            return img.crop(bbox) if bbox else img
    raise FileNotFoundError(name)

def with_shadow(img, radius_big=70, alpha_big=54, dy_big=34, radius_tight=22, alpha_tight=46, dy_tight=10):
    pad = radius_big * 3
    sheet = Image.new("RGBA", (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
    mask = img.split()[3]
    for rad, alpha, dy in ((radius_big, alpha_big, dy_big), (radius_tight, alpha_tight, dy_tight)):
        shadow = Image.new("RGBA", sheet.size, (0, 0, 0, 0))
        black = Image.new("RGBA", img.size, (0, 0, 0, alpha))
        shadow.paste(black, (pad, pad + dy), mask)
        shadow = shadow.filter(ImageFilter.GaussianBlur(rad))
        sheet = Image.alpha_composite(sheet, shadow)
    sheet.paste(img, (pad, pad), img)
    return sheet, pad

def draw_center(dr, y, text, f, fill, max_w=W - 200):
    # Bigger type everywhere; a line that would run off the canvas steps down until it fits.
    size, weight = getattr(f, "_size", 60), getattr(f, "_weight", "Bold")
    while dr.textlength(text, font=f) > max_w and size > 30:
        size -= 3; f = font(size, weight)
    dr.text(((W - dr.textlength(text, font=f)) / 2, y), text, font=f, fill=fill)
    return y

def headline_block(canvas, title, sub, y=118, title_size=170, sub_size=66, sub2=None):
    dr = ImageDraw.Draw(canvas)
    t = font(title_size, "Bold")
    s = font(sub_size, "Regular")
    draw_center(dr, y, title, t, INK)
    yy = y + title_size * 1.22
    draw_center(dr, yy, sub, s, SUB)
    if sub2:
        draw_center(dr, yy + sub_size * 1.5, sub2, s, SUB)
    return yy + sub_size * (2.9 if sub2 else 1.6)

def place(canvas, sheet, pad, cx, top, target_w):
    scale = target_w / (sheet.width - pad * 2)
    nw, nh = int(sheet.width * scale), int(sheet.height * scale)
    sh = sheet.resize((nw, nh), Image.LANCZOS)
    canvas.alpha_composite(sh, (int(cx - nw / 2), int(top - pad * scale)))

# The gradient canvas: near-white with soft tinted light, like the app's own glass.
def new_canvas():
    c = Image.new("RGBA", (W, H), BG + (255,))
    glow = Image.new("RGBA", (W // 8, H // 8), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    def blob(cx, cy, r, rgb, a):
        gd.ellipse([cx - r, cy - r, cx + r, cy + r], fill=rgb + (a,))
    blob(int(W*0.18)//8, int(H*0.10)//8, 135, (115, 145, 255), 66)   # blue, top left
    blob(int(W*0.85)//8, int(H*0.16)//8, 145, (175, 120, 255), 60)   # lavender, top right
    blob(int(W*0.50)//8, int(H*1.04)//8, 185, (135, 165, 255), 62)   # blue bloom, bottom
    blob(int(W*0.05)//8, int(H*0.72)//8, 125, (255, 150, 200), 40)   # pink, left
    glow = glow.filter(ImageFilter.GaussianBlur(46)).resize((W, H), Image.LANCZOS)
    return Image.alpha_composite(c, glow)

# Fade the bottom of the composition back into the canvas gradient: windows that
# run off the page dissolve instead of hitting a hard edge.
def fade_bottom(c, bg, depth=150):
    ramp = Image.new("L", (1, H), 0)
    for y in range(H):
        if y >= H - depth:
            ramp.putpixel((0, y), int(255 * ((y - (H - depth)) / depth) ** 1.7))
    mask = ramp.resize((W, H))
    return Image.composite(bg, c, mask)

def save(canvas, name):
    canvas.convert("RGB").save(os.path.join(OUT, name), quality=95)
    print("wrote", name)

def fit(img, box):
    s = min(box / img.width, box / img.height)
    return img.resize((max(1, int(img.width * s)), max(1, int(img.height * s))), Image.LANCZOS)

def chip_row(c, labels, y, size=46):
    SS = 4
    f = font(size * SS, "Semibold")
    mdr = ImageDraw.Draw(Image.new("RGBA", (8, 8)))
    padx, gap, hgt = 44, 36, int(size * 2.0)
    widths = [mdr.textlength(t, font=f) / SS + padx * 2 for t in labels]
    x = (W - (sum(widths) + gap * (len(labels) - 1))) / 2
    for t, w in zip(labels, widths):
        cw, ch = int(w * SS), hgt * SS
        chip = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
        cd = ImageDraw.Draw(chip)
        cd.rounded_rectangle([SS, SS, cw - SS, ch - SS], radius=(ch - 2 * SS) // 2,
                             fill=(255, 255, 255, 120), outline=(10, 132, 255, 70), width=SS)
        tw = cd.textlength(t, font=f)
        cd.text(((cw - tw) / 2, (ch - size * SS * 1.28) / 2), t, font=f, fill=ACCENT + (235,))
        chip = chip.resize((int(w), hgt), Image.LANCZOS)
        c.alpha_composite(chip, (int(x), int(y)))
        x += w + gap

def dash_row(c, labels, y, size=52, gap=90):
    """Plain dashed bullets in a centered row: black dash, blue label, no capsule.
    The row shrinks only if it would run off the canvas."""
    dr = ImageDraw.Draw(c)
    f = font(size, "Semibold")
    dash = "-  "
    def total(f): return sum(dr.textlength(dash, font=f) + dr.textlength(t, font=f) for t in labels) + gap * (len(labels) - 1)
    while total(f) > W - 160 and size > 40:
        size -= 2; f = font(size, "Semibold")
    widths = [dr.textlength(dash, font=f) + dr.textlength(t, font=f) for t in labels]
    x = (W - (sum(widths) + gap * (len(labels) - 1))) / 2
    for t, w in zip(labels, widths):
        dr.text((x, y), dash, font=f, fill=INK)
        dr.text((x + dr.textlength(dash, font=f), y), t, font=f, fill=ACCENT)
        x += w + gap

# ---- 01 HERO: everything bigger ----
bg = new_canvas(); c = new_canvas()
dr = ImageDraw.Draw(c)
eb = font(66, "Semibold")
draw_center(dr, 56, "Introducing YapToText", eb, ACCENT)
t = font(172, "Bold")
draw_center(dr, 150, "Yap it. Bam. It's typed!", t, INK)
s1 = font(76, "Semibold")
draw_center(dr, 372, "Powerful local dictation. Built for accessibility.", s1, INK)
shot = load_shot("page-home.png")
sheet, pad = with_shadow(shot)
place(c, sheet, pad, W/2, 560, 2340)
comp = load_shot("panel-compact.png")
csheet, cpad = with_shadow(comp, radius_big=60, alpha_big=70)
place(c, csheet, cpad, W*0.225, 975, 1180)
expd = load_shot("panel-expanded.png")
esheet, epad = with_shadow(expd, radius_big=60, alpha_big=70)
place(c, esheet, epad, W*0.765, 915, 1420)
mini = load_shot("panel-mini.png")
msheet, mpad = with_shadow(mini, radius_big=55, alpha_big=66)
place(c, msheet, mpad, W*0.24, 1360, 880)
c = fade_bottom(c, bg, 150)
save(c, "01-hero.jpg")

# ---- 02 PUNCHLINE ----
c = new_canvas()
dr = ImageDraw.Draw(c)
t = font(216)
draw_center(dr, 300, "I created this because", t, INK)
draw_center(dr, 590, "my hands don't work.", t, ACCENT)
s = font(68, "Regular")
draw_center(dr, 930, "YapToText is an accessibility tool first... built by someone who depends on it,", s, SUB)
draw_center(dr, 1034, "for everyone who types with their voice. Because it has to just work!", s, SUB)
syms = ["sym-accessibility.png", "sym-voiceover.png", "sym-waveform-and-mic.png",
        "sym-keyboard-fill.png", "sym-ear-fill.png", "sym-textformat-size.png"]
row_w = 1500
x0 = (W - row_w) / 2
for i, f in enumerate(syms):
    try:
        ic = fit(load_shot(f), 120)
        c.alpha_composite(ic, (int(x0 + i * (row_w - 120) / (len(syms) - 1) + (120 - ic.width) / 2),
                               int(1270 + (120 - ic.height) / 2)))
    except FileNotFoundError:
        pass
g = fit(load_shot("capy-glyph.png"), 230)
c.alpha_composite(g, (int(W/2 - g.width/2), int(1460 + (230 - g.height) / 2)))
save(c, "02-punchline.jpg")

# ---- 03 QUICK EDIT: right up front with dictation ----
bg = new_canvas(); c = new_canvas()
content_top = headline_block(c, "Edit anything by voice!",
                             "Select some text in any app, press your Quick Edit key, and just say the change...",
                             sub2="Rewrite it, shorten it, fix the tone, capitalize, translate. It lands right where the selection was.")
q1, p1 = with_shadow(load_shot("qe-listening.png"), radius_big=60, alpha_big=60)
q2, p2 = with_shadow(load_shot("qe-working.png"), radius_big=60, alpha_big=60)
q3, p3 = with_shadow(load_shot("qe-done.png"), radius_big=60, alpha_big=60)
# every card at the same 2.8x so the hugging "Done" card stays small next to the others
place(c, q1, p1, W/2, content_top + 60, 1500)
place(c, q2, p2, W*0.29, content_top + 660, 1120)
place(c, q3, p3, W*0.73, content_top + 700, int(load_shot("qe-done.png").width * 2.8))
c = fade_bottom(c, bg, 140)
save(c, "03-quick-edit.jpg")

# ---- 04 THE LISTENING ENGINE: why it is better ----
bg = new_canvas(); c = new_canvas()
content_top = headline_block(c, "It hears you... through anything!",
                             "A custom listening engine, tuned on the hard stuff: loud rooms, quiet voices,",
                             y=150, title_size=166, sub_size=66,
                             sub2="fast talkers, and long pauses. You just talk. It sorts out the rest.")
dash_row(c, ["Background-noise removal", "Adaptive normalization", "Deep decoding in noise"],
         content_top + 50, 72)
dash_row(c, ["Peak-guarded capture", "Silence understanding", "Pace correction"],
         content_top + 200, 72)
comp = load_shot("panel-expanded.png")
csheet, cpad = with_shadow(comp, radius_big=70, alpha_big=64)
place(c, csheet, cpad, W/2, content_top + 430, 1720)
c = fade_bottom(c, bg, 140)
save(c, "04-listening-engine.jpg")

# ---- 05 MENU BAR (untouched layout) ----
bg = new_canvas(); c = new_canvas()
content_top = headline_block(c, "The whole app... right in your menu bar.",
                             "Tap the capybara and it's all there: regenerate, redo, switch modes, edit selected text!",
                             y=230, title_size=170, sub_size=66)
img = load_shot("popover.png")
sheet, pad = with_shadow(img, radius_big=80)
place(c, sheet, pad, W/2, content_top + 60, 1020)
def raw_shot(name):
    for d in DIRS:
        p = os.path.join(d, name)
        if os.path.exists(p): return Image.open(p).convert("RGBA")
    raise FileNotFoundError(name)
body = raw_shot("capy-body.png")
bub = raw_shot("capy-bubble.png")
def fillc(src, rgb):
    t2 = Image.new("RGBA", src.size, rgb + (255,))
    t2.putalpha(src.split()[3])
    return t2
INKC = (29, 29, 31)
def capy_state(bubble_rgb=None, spinner=False):
    cnv = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    cnv.alpha_composite(fillc(body, INKC))
    if spinner:
        sd = ImageDraw.Draw(cnv)
        bx, by, br = 0.8165 * 1024, 0.2541 * 1024, 0.1328 * 1024
        for i in range(8):
            ang = -i * math.pi / 4
            a = int(255 * (1 - i / 9))
            x1 = bx + math.cos(ang) * br * 0.45; y1 = by + math.sin(ang) * br * 0.45
            x2 = bx + math.cos(ang) * br * 0.95; y2 = by + math.sin(ang) * br * 0.95
            sd.line([(x1, y1), (x2, y2)], fill=INKC + (a,), width=26)
    else:
        cnv.alpha_composite(fillc(bub, bubble_rgb or INKC))
    return cnv.crop(cnv.getbbox())
states = [
    (capy_state(),                W*0.14,  10, content_top + 210),
    (capy_state((255, 59, 48)),   W*0.86, -10, content_top + 190),
    (capy_state(spinner=True),    W*0.155, -8, content_top + 640),
    (capy_state((255, 179, 64)),  W*0.845,  8, content_top + 660),
]
for img2, cx, angle, top in states:
    rot = img2.rotate(angle, expand=True, resample=Image.BICUBIC)
    isheet, ipad = with_shadow(rot, radius_big=50, alpha_big=26)
    place(c, isheet, ipad, cx, top, 360)
c = fade_bottom(c, bg, 120)
save(c, "05-menubar.jpg")

# ---- 06 AI PIPELINES (mode switching folded in as the sub-feature it is) ----
bg = new_canvas(); c = new_canvas()
content_top = headline_block(c, "AI pipelines, tuned your way.",
                             "Every mode is its own pipeline: transcription, dictionaries, cleanup model, output style...",
                             sub2="Tune each stage, tap 1-9 to switch mid-dictation, or just let Auto pick for you!")
shot = load_shot("page-modes.png")
sheet, pad = with_shadow(shot)
place(c, sheet, pad, W/2, content_top + 60, 2340)
c = fade_bottom(c, bg, 150)
save(c, "06-ai-pipelines.jpg")

# ---- 07 THE PIPELINE, LIVE ----
bg = new_canvas(); c = new_canvas()
content_top = headline_block(c, "Watch the pipeline work.",
                             "Every dictation keeps its receipts... the audio, what the speech model heard,",
                             sub2="and what the AI delivered, with the model, mode, and timings on record. No mysteries!")
shot = load_shot("pipeline-details.png")
sheet, pad = with_shadow(shot)
place(c, sheet, pad, W/2, content_top + 60, 2340)
c = fade_bottom(c, bg, 150)
save(c, "07-pipeline-live.jpg")

# ---- 08 PRIVACY ----
bg = new_canvas(); c = new_canvas()
dr = ImageDraw.Draw(c)
t = font(200, "Bold")
draw_center(dr, 140, "Nothing leaves your Mac.", t, INK)
s = font(66, "Regular")
draw_center(dr, 400, "On-device speech recognition. Local AI models built in. Open source, so you can verify every word!", s, SUB)
w1 = font(88, "Semibold")
words = [("Gorgeous.", INK), ("Private.", ACCENT), ("Yours!", INK)]
total = sum(dr.textlength(w, font=w1) for w, _ in words) + 2 * 70
x = (W - total) / 2
for word, col in words:
    dr.text((x, 540), word, font=w1, fill=col)
    x += dr.textlength(word, font=w1) + 70
shot = load_shot("page-models.png")
sheet, pad = with_shadow(shot)
place(c, sheet, pad, W/2, 800, 2340)
c = fade_bottom(c, bg, 150)
save(c, "08-privacy.jpg")

# ---- 09 PERSONALIZE ----
bg = new_canvas(); c = new_canvas()
content_top = headline_block(c, "Teach it your words!",
                             "Dictionaries fix the names it mishears... Commands type anything you say.")
left = load_shot("page-dictionaries.png"); right = load_shot("page-commands.png")
sl, pl = with_shadow(left);  place(c, sl, pl, W*0.28 - 40, content_top + 40, 1360)
sr, pr = with_shadow(right); place(c, sr, pr, W*0.72 + 60, content_top + 190, 1360)
dr = ImageDraw.Draw(c)
ex = font(64, "Semibold")
exs = font(64, "Regular")
def example(cx, y, lead, tail):
    wlead = dr.textlength(lead, font=exs); warr = dr.textlength("  →  ", font=exs)
    total = wlead + warr + dr.textlength(tail, font=ex)
    x = cx - total / 2
    dr.text((x, y), lead, font=exs, fill=SUB); x += wlead
    dr.text((x, y), "  →  ", font=exs, fill=SUB); x += warr
    dr.text((x, y), tail, font=ex, fill=ACCENT)
example(W*0.28 - 40, 1500, "“Riley”", "“Ryleigh”")
example(W*0.72 + 60, 1645, "Say “insert phone number”", "(555) 123-4567")
c = fade_bottom(c, bg, 110)
save(c, "09-personalize.jpg")

# ---- 10 HISTORY ----
bg = new_canvas(); c = new_canvas()
content_top = headline_block(c, "Never lose a word. Ever.",
                             "Every dictation saved, searchable, and editable, with the whole pipeline behind it.",
                             sub2="Crash detection and recovery bring your words right back... if anything ever happens!")
shot = load_shot("page-history.png")
sheet, pad = with_shadow(shot)
place(c, sheet, pad, W/2, content_top + 60, 2340)
c = fade_bottom(c, bg, 150)
save(c, "10-history.jpg")

print("ALL DONE ->", OUT)

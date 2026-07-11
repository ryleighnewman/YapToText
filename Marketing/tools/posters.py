#!/usr/bin/env python3
"""YapToText App Store posters: Apple-marketing style composites.
2880x1800 (Mac App Store spec), near-white field, soft double shadow, SF Pro type."""
import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter

SP = os.path.dirname(os.path.abspath(__file__))
SHOTS = os.path.join(SP, "..", "shots")
OUT = os.path.join(SP, "..", "posters")
os.makedirs(OUT, exist_ok=True)

W, H = 2880, 1800
BG = (251, 251, 253)          # Apple near-white
INK = (29, 29, 31)            # Apple near-black
SUB = (110, 110, 115)         # Apple secondary gray
ACCENT = (10, 132, 255)       # system blue

SF = "/System/Library/Fonts/SFNS.ttf"

def font(size, weight="Bold"):
    f = ImageFont.truetype(SF, size)
    try: f.set_variation_by_name(weight)
    except Exception: pass
    return f

def load_shot(name):
    img = Image.open(os.path.join(SHOTS, name)).convert("RGBA")
    bbox = img.getbbox()          # trim transparent margins
    if bbox: img = img.crop(bbox)
    return img

def with_shadow(img, radius_big=70, alpha_big=54, dy_big=34, radius_tight=22, alpha_tight=46, dy_tight=10):
    """Composite img onto a transparent sheet with a soft ambient + tight contact shadow."""
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

def draw_center(dr, y, text, f, fill, tracking=0):
    w = dr.textlength(text, font=f)
    x = (W - w) / 2
    dr.text((x, y), text, font=f, fill=fill)
    return y

def headline_block(canvas, title, sub, y=128, title_size=150, sub_size=56, sub2=None):
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

def new_canvas():
    return Image.new("RGBA", (W, H), BG + (255,))

def save(canvas, name):
    canvas.convert("RGB").save(os.path.join(OUT, name), quality=95)
    print("wrote", name)

# ---- 01 HERO: the window plus BOTH visualizers, and a little swagger ----
c = new_canvas()
dr = ImageDraw.Draw(c)
# Eyebrow: one string so color, font, and size are identical across every word
eb = font(58, "Semibold")
draw_center(dr, 66, "Introducing YapToText", eb, ACCENT)
t = font(150, "Bold")
draw_center(dr, 160, "Yap it. Bam. It's typed.", t, INK)
s0 = font(70, "Semibold")
draw_center(dr, 360, "Speech to text, done right.", s0, INK)
s1 = font(54, "Regular")
draw_center(dr, 468, "Free. Private and on-device. Open source. Built for accessibility.", s1, SUB)
shot = load_shot("page-home.png")
sheet, pad = with_shadow(shot)
place(c, sheet, pad, W/2, 615, 1760)
# both visualizer styles float over the window's lower corners
comp = load_shot("panel-compact.png")
csheet, cpad = with_shadow(comp, radius_big=60, alpha_big=70)
place(c, csheet, cpad, W*0.22, 1345, 800)
expd = load_shot("panel-live2.png")
esheet, epad = with_shadow(expd, radius_big=60, alpha_big=70)
place(c, esheet, epad, W*0.74, 1095, 1120)
save(c, "01-hero.jpg")

# ---- 02 LIVE PANEL: the waveform moment ----
c = new_canvas()
content_top = headline_block(c, "Your keyboard, your rules.",
                             "Tap 1-9 to switch modes mid-dictation. Esc cancels. One key starts everything.",
                             y=300, title_size=170, sub_size=60,
                             sub2="Every hotkey is remappable, down to a single bare key.")
shot = load_shot("switcher.png")
sheet, pad = with_shadow(shot, radius_big=90, alpha_big=60)
place(c, sheet, pad, W/2, content_top + 60, 1150)
save(c, "03-live-panel.jpg")

# ---- 03 AUTO MODE ----
c = new_canvas()
content_top = headline_block(c, "Every mode you need. One that thinks.",
                             "Raw Transcription, Clean Up, Email, Note, Message, Code, or your own custom modes.",
                             sub2="And smart Auto mode reads each dictation and picks the right format, all on local AI.",
                             title_size=128)
shot = load_shot("page-modes.png")
sheet, pad = with_shadow(shot)
place(c, sheet, pad, W/2, content_top + 40, 1980)
save(c, "04-auto-mode.jpg")

# ---- 04 MODES ----
c = new_canvas()
content_top = headline_block(c, "The whole pipeline, step by step.",
                             "Utility breaks it all down: dictate, transcribe any file, transform text, run AI actions.",
                             sub2="Easy edits, one-click regeneration, and energy-saving AI cooldowns built in.")
shot = load_shot("page-utility.png")
sheet, pad = with_shadow(shot)
place(c, sheet, pad, W/2, content_top + 40, 1980)
save(c, "06-workbench.jpg")

# ---- 05 MENU BAR (popover, cropped above Recent) ----
c = new_canvas()
content_top = headline_block(c, "The whole app, from your menu bar.",
                             "The capybara in the menu bar opens this: regenerate, redo, switch modes, edit selected text.",
                             y=250, title_size=160, sub_size=58)
img = load_shot("popover-alpha.png")   # per-window capture: real translucency, no desktop bleed
img = img.crop((0, 34, img.width, img.height))
pm = Image.new("L", (img.width * 4, img.height * 4), 0)
ImageDraw.Draw(pm).rounded_rectangle([8, 8, img.width * 4 - 9, img.height * 4 - 9], radius=208, fill=255)
pm = pm.resize(img.size, Image.LANCZOS)   # supersampled = smooth, non-pixelated corners
# our own liquid backdrop behind the glass: a soft purple gradient card
grad = Image.new("RGBA", img.size)
gd = ImageDraw.Draw(grad)
for yy in range(img.height):
    t = yy / img.height
    gd.line([(0, yy), (img.width, yy)],
            fill=(int(72 + 30 * t), int(38 + 18 * t), int(150 - 30 * t), 255))
grad = grad.filter(ImageFilter.GaussianBlur(60))
backed = Image.alpha_composite(grad, img)
backed.putalpha(pm)
img = backed
sheet, pad = with_shadow(img, radius_big=80)
place(c, sheet, pad, W/2, content_top + 60, 1020)
body = Image.open(os.path.join(SHOTS, "capy-body.png")).convert("RGBA")   # keep full canvas: layers share registration
bub  = Image.open(os.path.join(SHOTS, "capy-bubble.png")).convert("RGBA")
def fill(src, rgb):
    t = Image.new("RGBA", src.size, rgb + (255,))
    t.putalpha(src.split()[3])
    return t
INKC = (29, 29, 31)
def capy_state(bubble_rgb=None, spinner=False):
    cnv = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    cnv.alpha_composite(fill(body, INKC))
    if spinner:
        # eight clock spokes fading behind the leader, right where the bubble sat
        sd = ImageDraw.Draw(cnv)
        bx, by, br = 0.8165 * 1024, 0.2541 * 1024, 0.1328 * 1024
        import math
        for i in range(8):
            ang = -i * math.pi / 4
            a = int(255 * (1 - i / 9))
            x1 = bx + math.cos(ang) * br * 0.45; y1 = by + math.sin(ang) * br * 0.45
            x2 = bx + math.cos(ang) * br * 0.95; y2 = by + math.sin(ang) * br * 0.95
            sd.line([(x1, y1), (x2, y2)], fill=INKC + (a,), width=26)
    else:
        cnv.alpha_composite(fill(bub, bubble_rgb or INKC))
    return cnv.crop(cnv.getbbox())
states = [
    (capy_state(),                      W*0.14, 10,  content_top + 210),   # idle
    (capy_state((255, 59, 48)),         W*0.86, -10, content_top + 190),   # recording red
    (capy_state(spinner=True),          W*0.155, -8, content_top + 640),   # thinking spinner
    (capy_state((255, 179, 64)),        W*0.845, 8,  content_top + 660),   # busy yellow
]
for img, cx, angle, top in states:
    rot = img.rotate(angle, expand=True, resample=Image.BICUBIC)
    isheet, ipad = with_shadow(rot, radius_big=50, alpha_big=26)
    place(c, isheet, ipad, cx, top, 360)
save(c, "05-menubar.jpg")

# ---- 06 PRIVACY: typography + the pop-up (no half-cropped window) ----
c = new_canvas()
dr = ImageDraw.Draw(c)
t = font(190, "Bold")
draw_center(dr, 150, "Nothing leaves your Mac.", t, INK)
s = font(60, "Regular")
draw_center(dr, 400, "On-device speech recognition. Local AI models built in. Open source, so you can verify every word.", s, SUB)
w1 = font(78, "Semibold")
words = [("Gorgeous.", INK), ("Private.", ACCENT), ("Yours.", INK)]
total = sum(dr.textlength(w, font=w1) for w, _ in words) + 2 * 70
x = (W - total) / 2
for word, col in words:
    dr.text((x, 540), word, font=w1, fill=col)
    x += dr.textlength(word, font=w1) + 70
shot = load_shot("page-models.png")
sheet, pad = with_shadow(shot)
place(c, sheet, pad, W/2, 800, 1760)
save(c, "07-privacy.jpg")

# ---- 07 HISTORY / NEVER LOSE A WORD ----
c = new_canvas()
content_top = headline_block(c, "Never lose a word.",
                             "Every dictation saved, searchable, and editable.",
                             sub2="Crash detection and recovery bring your words back, if anything ever happens.")
shot = load_shot("page-history.png")
sheet, pad = with_shadow(shot)
place(c, sheet, pad, W/2, content_top + 40, 1980)
save(c, "09-history.jpg")

# ---- 08 STATS ----
c = new_canvas()
content_top = headline_block(c, "Your dictation story.",
                             "Words, streaks, and the time you saved. Computed on your Mac, for your eyes only.",
                             title_size=140)
shot = load_shot("page-stats.png")
sheet, pad = with_shadow(shot)
place(c, sheet, pad, W/2, content_top + 40, 1980)
save(c, "10-statistics.jpg")

# ---- 09 DICTIONARIES + COMMANDS (pair) ----
c = new_canvas()
content_top = headline_block(c, "Teach it your words.",
                             "Dictionaries fix the names it mishears. Commands type anything you say.")
left = load_shot("page-dictionaries.png"); right = load_shot("page-commands.png")
# staggered: left sits high, right drops lower so the pair reads as a cascade
sl, pl = with_shadow(left);  place(c, sl, pl, W*0.29 - 60, content_top + 40, 1450)
sr, pr = with_shadow(right); place(c, sr, pr, W*0.71 + 120, content_top + 230, 1450)
dr = ImageDraw.Draw(c)
ex = font(54, "Semibold")
exs = font(54, "Regular")
def example(cx, y, lead, tail):
    wlead = dr.textlength(lead, font=exs); warr = dr.textlength("  \u2192  ", font=exs)
    total = wlead + warr + dr.textlength(tail, font=ex)
    x = cx - total / 2
    dr.text((x, y), lead, font=exs, fill=SUB); x += wlead
    dr.text((x, y), "  \u2192  ", font=exs, fill=SUB); x += warr
    dr.text((x, y), tail, font=ex, fill=ACCENT)
example(W*0.29 - 60, 1400, "\u201CRiley\u201D", "\u201CRyleigh\u201D")
example(W*0.71 + 120, 1655, "Say \u201Cinsert phone number\u201D", "(555) 123-4567")
save(c, "08-personalize.jpg")

# ---- 10 ACCESSIBILITY ----
c = new_canvas()
dr = ImageDraw.Draw(c)
t = font(200, "Bold")
draw_center(dr, 250, "Hands off.", t, INK)
draw_center(dr, 498, "Words on.", t, (10, 132, 255))
s = font(60, "Regular")
draw_center(dr, 790, "Built as an accessibility tool first: one key starts everything, and it works", s, SUB)
draw_center(dr, 882, "with VoiceOver, Voice Control, and every macOS accessibility setting.", s, SUB)
syms = ["sym-accessibility.png", "sym-voiceover.png", "sym-waveform-and-mic.png",
        "sym-keyboard-fill.png", "sym-ear-fill.png", "sym-textformat-size.png"]
n = len(syms)
row_w = 1500
x0 = (W - row_w) / 2
for i, f in enumerate(syms):
    ic = Image.open(os.path.join(SHOTS, f)).convert("RGBA").resize((120, 120), Image.LANCZOS)
    c.alpha_composite(ic, (int(x0 + i * (row_w - 120) / (n - 1)), 1010))
shot = load_shot("panel-live.png")
sheet, pad = with_shadow(shot, radius_big=90)
place(c, sheet, pad, W/2, 1200, 1200)
save(c, "02-accessibility.jpg")

print("ALL DONE ->", OUT)

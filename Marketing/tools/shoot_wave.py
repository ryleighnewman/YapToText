"""Reshoot ONE panel style's wave at several hold points and lay them out on a numbered
contact sheet, so the frame can be chosen by eye. The chosen number is then written into
shots-v5/panel-<style>.png with --pick N. Same studio as shoot_v5 (purple wallpaper, every
other app hidden, marketing look), no page captures, no demo data."""
import os, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shoot_v5 as r
from PIL import Image, ImageDraw, ImageFont

STYLE = "expanded"
LOOK = "accent||0.35|accent|"
BOOST = "2.3"
TS = [round(0.8 + 0.6 * i, 1) for i in range(20)]   # 0.8 .. 12.2 s
CAND = os.path.join(r.MK, "shots-v5", "wave-candidates"); os.makedirs(CAND, exist_ok=True)

def shoot():
    r.OUT = CAND
    r.stage_begin()
    try:
        r.quit_app(); time.sleep(1.5); r.launch_app(); time.sleep(8)
        r.note("yap.debug.whatsnew", "close"); r.note("yap.debug.welcome", "close"); time.sleep(1)
        r.stage_settings()
        r.osa('tell application "System Events" to tell every desktop to set picture to "/System/Library/Desktop Pictures/Mac Purple.heic"')
        r.osa('tell application "System Events" to set visible of (every process whose visible is true and name is not "Finder" and name is not "YapToText") to false')
        time.sleep(6)
        r.note("yap.debug.closeWindow"); time.sleep(1.2)
        r.note("yap.debug.waveboost", BOOST)
        r.note("yap.debug.panellook", LOOK); time.sleep(0.5)
        r.note("yap.debug.stagepanel", f"{STYLE}|{r.SENTENCE}|1.7"); time.sleep(3.0)
        for i, t in enumerate(TS, 1):
            r.note("yap.debug.stagepanel", f"{STYLE}|{r.SENTENCE}|1.7|recording|{t}"); time.sleep(0.9)
            pw = r.window_id(280, 620, 420, layer_min=1)
            if not pw: print("no panel"); continue
            r.capture(f"{i:02d}-t{t}", r.rect_of(pw[0]), pw[0])
        r.note("yap.debug.stagepanel", "off"); time.sleep(1.2)
    finally:
        r.stage_end()
    sheet()

def sheet():
    files = sorted(f for f in os.listdir(CAND) if f.endswith(".png") and f[0].isdigit())
    tiles = [Image.open(os.path.join(CAND, f)).convert("RGBA") for f in files]
    w = max(t.width for t in tiles); h = max(t.height for t in tiles)
    cols = 2; rows = (len(tiles) + 1) // cols
    pad = 24; label = 34
    out = Image.new("RGB", (cols * (w + pad) + pad, rows * (h + label + pad) + pad), (36, 30, 52))
    dr = ImageDraw.Draw(out)
    try: font = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", 26)
    except Exception: font = ImageFont.load_default()
    for i, (f, t) in enumerate(zip(files, tiles)):
        x = pad + (i % cols) * (w + pad); y = pad + (i // cols) * (h + label + pad)
        dr.text((x, y), f"#{i + 1}", fill=(255, 255, 255), font=font)
        out.paste(t, (x, y + label), t)
    p = os.path.join(CAND, "SHEET.png"); out.save(p); print("sheet:", p)

def pick(n):
    files = sorted(f for f in os.listdir(CAND) if f.endswith(".png") and f[0].isdigit())
    src = os.path.join(CAND, files[n - 1]); dst = os.path.join(r.MK, "shots-v5", f"panel-{STYLE}.png")
    Image.open(src).save(dst); print("wrote", dst, "from", files[n - 1])

if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--pick": pick(int(sys.argv[2]))
    else: shoot()

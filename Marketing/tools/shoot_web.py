#!/usr/bin/env python3
"""Website UI assets for yaptotext.com, shot with the same system as the 1.5 poster round.

Reuses shoot_v5 wholesale: the marketing look staged IN MEMORY (yap.debug.marketing, writes
suspended so the user's own settings never change on disk), the boosted synthetic wave, the
flat studio desktop, and the byte-for-byte restore at the end.

Difference from the poster shoot: ONE colorway everywhere (blue accent), because the site's
design is a single dark blue system and three colorways would read as three different apps.

Run from Marketing/:   python3 tools/shoot_web.py
Output:                Marketing/shots-web/  (then copy into the site with --install)
"""
import os, sys, time, json, shutil
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
import shoot_v5 as r
from PIL import Image

WEB = os.path.join(r.MK, "shots-web"); os.makedirs(WEB, exist_ok=True)
SITE_UI = os.path.expanduser("~/Desktop/Apps/yaptotext.com/assets/ui")
SENTENCE = "Accessibility made free and beautiful."
BLUE = "accent||0.35|accent|"          # tint style|hex|strength|wave style|hex
BOOST = {"expanded": "2.3", "compact": "1.6", "mini": "1.6"}

# Hold points for the live wave, chosen by eye from tools/shoot_wave.py's contact sheet
# (2026-09-17, expanded = frame 14). A held frame makes the capture the same every run.
HOLD = {"expanded": 8.6, "compact": 6.2, "mini": 6.2}

def panel(name, style, phase="recording", text=SENTENCE, energy="1.7", settle=3.4):
    r.note("yap.debug.waveboost", BOOST[style])
    r.note("yap.debug.panellook", BLUE); time.sleep(0.4)
    hold = f"|{HOLD[style]}" if phase == "recording" and style in HOLD else ""
    r.note("yap.debug.stagepanel", f"{style}|{text}|{energy}|{phase}{hold}"); time.sleep(settle)
    pw = r.window_id(280, 620, 420, layer_min=1)
    if not pw:
        print("  no panel window for", name); return
    r.capture(name, r.rect_of(pw[0]), pw[0])
    r.note("yap.debug.stagepanel", "off"); time.sleep(1.2)

def main():
    r.OUT = WEB
    r.stage_begin()
    try:
        r.quit_app()
        r.sh(f'python3 "{os.path.join(r.TOOLS, "seed_demo_data.py")}" "{r.DATA}"')
        for attempt in range(3):
            r.launch_app(); time.sleep(9)
            r.note("yap.debug.whatsnew", "close"); r.note("yap.debug.welcome", "close"); time.sleep(1.5)
            live = json.load(open(os.path.join(r.DATA, "history.json")))
            if len(live) == 48 and "mockups" in json.dumps(live): break
            print(f"seed not live (records={len(live)}), re-seeding")
            r.quit_app(); time.sleep(2)
            r.sh(f'python3 "{os.path.join(r.TOOLS, "seed_demo_data.py")}" "{r.DATA}"')
        else:
            raise SystemExit("seed did not take - aborting before any capture")
        r.stage_settings()

        # Studio: flat deep-violet desktop, nothing else on screen. A flat ground means the
        # glass shows the panel's own tint instead of wallpaper shapes bleeding through.
        flat = os.path.join(r.BACKUP, "flat-violet.png")
        Image.new("RGB", (640, 400), (18, 22, 24)).save(flat)   # the site's own page ground:
        # yap.css body is rgb(18,22,24), and the hero backdrop blends with mix-blend-mode:
        # screen, where anything near black reads as transparent. Shooting the glass over
        # this exact color is what makes the pop-up sit ON the page instead of in a box.
        r.osa(f'tell application "System Events" to tell every desktop to set picture to "{flat}"')
        r.osa('tell application "System Events" to set visible of (every process whose visible is true and name is not "Finder" and name is not "YapToText") to false')
        time.sleep(6)
        r.note("yap.debug.closeWindow"); time.sleep(1.5)

        # 1. the three layouts, live
        for style in ("expanded", "compact", "mini"):
            panel(f"panel-{style}", style)
        # 2. the same three condensed into the thinking ring
        # The thinking ring: RecordingPanelView condenses EVERY layout to the same 44x40 pill
        # (mini, compact and expanded all call onCondenseShrink with CGSize(44, 40)), so one
        # capture serves all three names. Chasing the expanded layout's longer collapse
        # animation just produced slivers at unpredictable moments.
        panel("ring-compact", "compact", phase="transcribing", energy="0.5", settle=4.0)
        for name in ("ring-expanded.png", "ring-mini.png"):
            shutil.copy2(os.path.join(WEB, "ring-compact.png"), os.path.join(WEB, name))

        # 3. Quick Edit card, each stage
        for stage_name, text, out in (("listening", "make it sound more formal", "qe-listening"),
                                      ("working", "make it sound more formal", "qe-working"),
                                      ("done", "Done", "qe-done")):
            r.note("yap.debug.qestage", f"{stage_name}|{text}"); time.sleep(2.2)
            qw = r.window_id(300, 420, 220, layer_min=1)
            if not qw: print("  no quick edit window for", stage_name); continue
            r.capture(out, r.rect_of(qw[0]), qw[0], solid=True)
        r.note("yap.debug.qestage", "off"); time.sleep(1)

        # 4. mode switcher
        r.note("yap.debug.switcher"); time.sleep(2.2)
        sw = r.window_id(300, 900, 900, layer_min=1)
        if sw: r.capture("switcher", r.rect_of(sw[0]), sw[0], solid=True)
        r.note("yap.debug.switcher"); time.sleep(1)

        # 5. menu bar popover
        r.note("yap.debug.menupopover"); time.sleep(2.2)
        pop = r.window_id(300, 800, 1200, layer_min=1)
        if pop: r.capture("popover", r.rect_of(pop[0]), pop[0])
        r.note("yap.debug.menupopover"); time.sleep(1)
    finally:
        r.stage_end()

def install():
    """Copy the shot set into the website, keeping the filenames the pages already use."""
    n = 0
    for f in sorted(os.listdir(WEB)):
        if not f.endswith(".png") or f.startswith("_"): continue
        shutil.copy2(os.path.join(WEB, f), os.path.join(SITE_UI, f))
        print("installed", f, Image.open(os.path.join(SITE_UI, f)).size); n += 1
    print(f"{n} files -> {SITE_UI}")

if __name__ == "__main__":
    if "--install" in sys.argv: install()
    else: main()

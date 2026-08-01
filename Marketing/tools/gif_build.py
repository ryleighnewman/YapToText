#!/usr/bin/env python3
"""Assemble a feature GIF from transparent window frames (-l captures):
composites each frame onto a soft brand-gradient backdrop, then writes an
optimized looping GIF. Usage: gif_build.py <framesdir> <out.gif> [fps]"""
import os, sys, glob
from PIL import Image, ImageFilter, ImageDraw

frames_dir, out = sys.argv[1], sys.argv[2]
fps = float(sys.argv[3]) if len(sys.argv) > 3 else 9

files = sorted(glob.glob(os.path.join(frames_dir, "*.png")))
assert files, "no frames"
first = Image.open(files[0]).convert("RGBA")
bb = None
for f in files:  # union bbox so the gif never crops motion
    b = Image.open(f).convert("RGBA").getbbox()
    if b:
        bb = b if bb is None else (min(bb[0],b[0]), min(bb[1],b[1]), max(bb[2],b[2]), max(bb[3],b[3]))
pad = 46
bb = (max(0, bb[0]-pad), max(0, bb[1]-pad), min(first.width, bb[2]+pad), min(first.height, bb[3]+pad))
w, h = bb[2]-bb[0], bb[3]-bb[1]

# the backdrop: vertical purple-blue gradient with a blurred glow blob - reads like glass
col = Image.new("RGB", (1, h))
for y in range(h):
    t = y / h
    col.putpixel((0, y), (int(84+40*t), int(70+30*t), int(180-30*t)))
bg = col.resize((w, h))
d = ImageDraw.Draw(bg, "RGBA")
d.ellipse([w*0.15, h*0.05, w*0.85, h*0.9], fill=(140, 120, 255, 90))
bg = bg.filter(ImageFilter.GaussianBlur(60)).convert("RGBA")

out_frames = []
for f in files:
    fr = Image.open(f).convert("RGBA").crop(bb)
    frame = bg.copy()
    frame.alpha_composite(fr)
    if frame.width > 900:
        frame = frame.resize((900, int(frame.height*900/frame.width)), Image.LANCZOS)
    out_frames.append(frame.convert("P", palette=Image.ADAPTIVE, colors=255))
out_frames[0].save(out, save_all=True, append_images=out_frames[1:],
                   duration=int(1000/fps), loop=0, disposal=2)
print("wrote", out, len(out_frames), "frames", out_frames[0].size)

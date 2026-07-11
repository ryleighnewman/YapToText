import subprocess, sys
from PIL import Image, ImageDraw
out, x, y, w, h = sys.argv[1], *map(int, sys.argv[2:6])
subprocess.run(["screencapture","-x","-R",f"{x},{y},{w},{h}",out],check=True)
img = Image.open(out).convert("RGBA")
r = 52
mask = Image.new("L", img.size, 0)
d = ImageDraw.Draw(mask)
d.rounded_rectangle([0,0,img.size[0]-1,img.size[1]-1], radius=r, fill=255)
img.putalpha(mask)
img.save(out)

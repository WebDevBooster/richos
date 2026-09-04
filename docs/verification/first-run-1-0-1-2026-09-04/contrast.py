import sys
from PIL import Image
from collections import Counter

def lin(c):
    c = c/255.0
    return c/12.92 if c <= 0.03928 else ((c+0.055)/1.055)**2.4

def L(rgb):
    r,g,b = rgb[:3]
    return 0.2126*lin(r)+0.7152*lin(g)+0.0722*lin(b)

def ratio(a,b):
    la,lb = L(a),L(b)
    hi,lo = max(la,lb),min(la,lb)
    return (hi+0.05)/(lo+0.05)

path, x0,y0,x1,y1, label = sys.argv[1], *map(int,sys.argv[2:6]), sys.argv[6]
im = Image.open(path).convert("RGB")
# screenshot may be retina-scaled relative to points
sw,sh = im.size
scale = sw/1920.0
box = (int(x0*scale),int(y0*scale),int(x1*scale),int(y1*scale))
crop = im.crop(box)
px = list(crop.getdata())
lum = sorted(px, key=L)
n = len(px)
# background = most common colour; foreground = brightest 2% mean (light text on dark)
bg = Counter(px).most_common(1)[0][0]
fg_pool = lum[int(n*0.98):]
fg = tuple(sum(c[i] for c in fg_pool)//len(fg_pool) for i in range(3))
dark_pool = lum[:max(1,int(n*0.02))]
darkest = tuple(sum(c[i] for c in dark_pool)//len(dark_pool) for i in range(3))
print(f"{label}: box={box} bg(mode)={bg} brightest2%={fg} darkest2%={darkest}")
print(f"  brightest vs bg-mode = {ratio(fg,bg):.2f}:1")
print(f"  brightest vs darkest = {ratio(fg,darkest):.2f}:1")

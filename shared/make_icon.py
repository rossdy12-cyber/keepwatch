from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageChops
import math, sys
# Usage: python3 shared/make_icon.py <letter> <output AppIcon.png> [preview.png]
LETTER, OUT = sys.argv[1], sys.argv[2]
PREVIEW = sys.argv[3] if len(sys.argv) > 3 else None
import os
FONT = os.environ.get('ICON_FONT') or os.path.join(os.path.dirname(os.path.abspath(__file__)), 'GothicKit/Fonts/UnifrakturMaguntia-Book.ttf')
FONT_SIZE = int(os.environ.get('ICON_FONT_SIZE', '500'))
S=1024
img=Image.new('RGB',(S,S),(6,3,4))
glow=Image.new('L',(S,S),0)
gd=ImageDraw.Draw(glow)
for r in range(700,0,-6):
    gd.ellipse((S/2-r,S*0.45-r,S/2+r,S*0.45+r),fill=int(150*(1-r/700)**1.6))
img=Image.composite(Image.new('RGB',(S,S),(150,10,30)),img,glow)
def arch(cx,base,w,top,steps=90):
    r=w; left=cx-w/2; right=cx+w/2
    spring=top + r*math.sqrt(3)/2
    pts=[(left,base),(left,spring)]
    for i in range(steps+1):
        a=math.pi-(math.pi/3)*i/steps
        pts.append((right+r*math.cos(a), spring-r*math.sin(a)))
    for i in range(1,steps+1):
        a=(math.pi/3)*(1-i/steps)
        pts.append((left+r*math.cos(a), spring-r*math.sin(a)))
    pts.append((right,base))
    return pts
top=170
outer=arch(S/2,880,560,top)
inner=arch(S/2,856,512,top+34)
lay=Image.new('RGB',(S,S),(0,0,0))
ImageDraw.Draw(lay).line(outer+[outer[0]],fill=(230,40,60),width=18,joint='curve')
img=ImageChops.add(img,lay.filter(ImageFilter.GaussianBlur(22)))
d=ImageDraw.Draw(img)
d.polygon(outer,fill=(14,5,8))
d.line(outer+[outer[0]],fill=(196,30,58),width=14,joint='curve')
d.line(inner+[inner[0]],fill=(110,10,26),width=5,joint='curve')
font=ImageFont.truetype(FONT,FONT_SIZE)
txt=Image.new('L',(S,S),0); td=ImageDraw.Draw(txt)
bb=td.textbbox((0,0),LETTER,font=font); w=bb[2]-bb[0]; h=bb[3]-bb[1]
td.text((S/2-w/2-bb[0], 590-h/2-bb[1]),LETTER,font=font,fill=255)
img=Image.composite(Image.new('RGB',(S,S),(200,20,45)),img,txt.filter(ImageFilter.GaussianBlur(26)).point(lambda v:int(v*0.8)))
grad=Image.new('RGB',(S,S)); g=ImageDraw.Draw(grad)
for y in range(S):
    t=max(0,min(1,(y-350)/480))
    g.line([(0,y),(S,y)],fill=(int(242*(1-t)+200*t),int(228*(1-t)+40*t),int(212*(1-t)+60*t)))
img=Image.composite(grad,img,txt)
d=ImageDraw.Draw(img); cx=S/2; cy=top-62
d.rectangle((cx-8,cy-38,cx+8,cy+38),fill=(196,30,58))
d.rectangle((cx-27,cy-18,cx+27,cy-4),fill=(196,30,58))
img.save(OUT)
if PREVIEW: img.resize((256,256)).save(PREVIEW)

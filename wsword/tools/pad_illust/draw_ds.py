# An original drawing of a modern two-grip game pad in the style of the game's own controller illustration:
# luminance + alpha, 576x288 (front) and 576x100 (top).
import math, sys
from PIL import Image, ImageDraw, ImageFilter
K=4  # supersampling
def T(x,y): return (x*K,y*K)
def bez(p0,p1,p2,p3,n=24):
    return [((1-t)**3*p0[0]+3*(1-t)**2*t*p1[0]+3*(1-t)*t*t*p2[0]+t**3*p3[0],
             (1-t)**3*p0[1]+3*(1-t)**2*t*p1[1]+3*(1-t)*t*t*p2[1]+t**3*p3[1]) for t in [i/n for i in range(n+1)]]
class C:
    def __init__(s,w,h):
        s.w,s.h=w,h; s.L=Image.new('L',(w*K,h*K),0); s.A=Image.new('L',(w*K,h*K),0)
        s.dl=ImageDraw.Draw(s.L); s.da=ImageDraw.Draw(s.A)
    def poly(s,pts,lum,outline=None,width=2,alpha=True):
        P=[T(*p) for p in pts]
        if alpha: s.da.polygon(P,fill=255)
        s.dl.polygon(P,fill=lum)
        if outline is not None: s.dl.line(P+[P[0]],fill=outline,width=width*K,joint='curve')
    def ell(s,cx,cy,rx,ry,lum,outline=None,width=2,alpha=False):
        b=[T(cx-rx,cy-ry),T(cx+rx,cy+ry)]
        if alpha: s.da.ellipse(b,fill=255)
        s.dl.ellipse(b,fill=lum,outline=outline,width=int(round(width*K)) if outline is not None else 0)
    def rrect(s,x0,y0,x1,y1,r,lum,outline=None,width=2,alpha=False):
        b=[T(x0,y0),T(x1,y1)]
        if alpha: s.da.rounded_rectangle(b,r*K,fill=255)
        s.dl.rounded_rectangle(b,r*K,fill=lum,outline=outline,width=int(round(width*K)) if outline is not None else 0)
    def line(s,pts,lum,width=2):
        s.dl.line([T(*p) for p in pts],fill=lum,width=int(width*K),joint='curve')
    def save(s):
        L=s.L.resize((s.w,s.h),Image.LANCZOS); A=s.A.resize((s.w,s.h),Image.LANCZOS)
        return Image.merge('LA',(L,A))
def mirror(pts,cx=288): return [(2*cx-x,y) for x,y in reversed(pts)]

WHITE,EDGE,PANEL,DARK,BTN,SYM,TOUCH=206,118,66,40,52,178,214
def front(P):
    c=C(576,288)
    # the shell: one outline, left half then mirrored
    left=[]
    left+=bez((288,58),(230,56),(150,58),(92,66))          # the top edge out to the shoulder
    left+=bez((92,66),(48,72),(26,96),(22,140))[1:]        # the shoulder round
    left+=bez((22,140),(18,196),(30,262),(60,282))[1:]     # the grip's outer side
    left+=bez((60,282),(88,294),(132,288),(150,268))[1:]   # the grip's foot
    left+=bez((150,268),(170,252),(206,250),(288,250))[1:] # in under the middle
    shell=left+mirror(left)[1:-1]
    c.poly(shell,WHITE,outline=EDGE,width=3)
    # the dark middle under the touch pad, down between the grips
    mid=[(178,128)]+bez((178,128),(164,176),(166,228),(196,248))[1:]+bez((196,248),(230,246),(260,246),(288,246))[1:]
    mid=mid+mirror(mid)[1:-1]
    c.poly(mid,PANEL,outline=EDGE,width=2,alpha=False)
    # the touch pad and the light bars along it
    c.rrect(200,60,376,130,12,TOUCH,outline=EDGE,width=2)
    c.line([(197,70),(186,124)],250,width=2.5); c.line([(379,70),(390,124)],250,width=2.5)
    # create / options: small pills beside the pad's top corners
    for x in (P['create'][0],P['opt'][0]):
        c.rrect(x-4,P['create'][1]-9,x+4,P['create'][1]+9,4,DARK,outline=EDGE,width=1)
    # d-pad: four separate pads
    dx,dy=P['dpad']; r=17
    for ang in (0,90,180,270):
        a=math.radians(ang); ux,uy=math.cos(a),math.sin(a); vx,vy=-uy,ux
        pts=[(dx+ux*6+vx*7,dy+uy*6+vy*7),(dx+ux*(r+10)+vx*8,dy+uy*(r+10)+vy*8),(dx+ux*(r+12),dy+uy*(r+12)),
             (dx+ux*(r+10)-vx*8,dy+uy*(r+10)-vy*8),(dx+ux*6-vx*7,dy+uy*6-vy*7),(dx+ux*3,dy+uy*3)]
        c.poly(pts,BTN,outline=EDGE,width=1,alpha=False)
        tri=[(dx+ux*(r+6),dy+uy*(r+6)),(dx+ux*(r-2)+vx*4,dy+uy*(r-2)+vy*4),(dx+ux*(r-2)-vx*4,dy+uy*(r-2)-vy*4)]
        c.poly(tri,SYM,alpha=False)
    # face buttons with their symbols
    fx,fy=P['face']; br=11.5; d=21
    for k,(ox,oy) in enumerate(((0,-d),(d,0),(0,d),(-d,0))):
        x,y=fx+ox,fy+oy
        c.ell(x,y,br,br,BTN,outline=EDGE,width=1)
        s=5.8
        if k==0: c.line([(x,y-s),(x+s*0.95,y+s*0.65),(x-s*0.95,y+s*0.65),(x,y-s)],SYM,1.6)   # triangle
        elif k==1: c.ell(x,y,s,s,BTN,outline=SYM,width=1.6)                                    # circle
        elif k==2: c.line([(x-s*0.8,y-s*0.8),(x+s*0.8,y+s*0.8)],SYM,1.6); c.line([(x-s*0.8,y+s*0.8),(x+s*0.8,y-s*0.8)],SYM,1.6)
        else: c.rrect(x-s*0.8,y-s*0.8,x+s*0.8,y+s*0.8,0.5,BTN,outline=SYM,width=1.6)
    # sticks
    for (x,y) in (P['ls'],P['rs']):
        c.ell(x,y,24,24,DARK,outline=EDGE,width=2)
        c.ell(x,y,17,17,90,outline=30,width=1)
        c.ell(x,y,11,11,104)
    # the console button and the mute button
    c.ell(288,214,8,8,DARK,outline=150,width=1)
    c.rrect(280,232,296,238,3,TOUCH,outline=EDGE,width=1)
    # the speaker
    for i in range(-3,4): c.ell(288+i*6,148,1.2,1.2,30)
    return c.save()
def top(P):
    c=C(576,100)
    left=bez((288,54),(200,54),(120,52),(70,50))+bez((70,50),(40,48),(14,60),(14,78))[1:]+bez((14,78),(18,94),(80,96),(288,92))[1:]
    c.poly(left+mirror(left)[1:-1],WHITE,outline=EDGE,width=3)
    c.rrect(200,48,376,60,5,TOUCH,outline=EDGE,width=2)   # the touch pad's edge
    c.line([(186,55),(198,55)],250,2.5); c.line([(378,55),(390,55)],250,2.5)
    c.rrect(276,74,300,82,3,DARK,outline=EDGE,width=1)   # the USB port
    for sx in (1,-1):
        def X(x): return x if sx>0 else 576-x
        # the trigger (top) and the bumper under it
        tr=[(X(20),40),(X(26),18),(X(48),8),(X(78),14),(X(84),34),(X(70),46)]
        c.poly(tr if sx>0 else list(reversed(tr)),DARK,outline=EDGE,width=2)
        bp=[(X(18),56),(X(22),46),(X(70),46),(X(88),52),(X(84),60)]
        c.poly(bp if sx>0 else list(reversed(bp)),90,outline=EDGE,width=2)
    return c.save()
if __name__=='__main__':
    def tex(X,Y): return (288+X/0.67, 144-(Y+10)/0.67)
    P=dict(dpad=tex(-116,-15),face=tex(116,-15),ls=tex(-80,-60),rs=tex(80,-60),create=tex(-66,22),opt=tex(66,22))
    front(P).save(sys.argv[1]); top(P).save(sys.argv[2]); print(P)

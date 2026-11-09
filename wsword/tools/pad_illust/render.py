import sys,math
sys.path.insert(0,'lyt')
from tree import load, walk
from PIL import Image, ImageDraw
def mat_mul(a,b):  # 2x3 affine
    return (a[0]*b[0]+a[1]*b[3], a[0]*b[1]+a[1]*b[4], a[0]*b[2]+a[1]*b[5]+a[2],
            a[3]*b[0]+a[4]*b[3], a[3]*b[1]+a[4]*b[4], a[3]*b[2]+a[4]*b[5]+a[5])
def local(p):
    tx,ty,_=p['t']; rz=math.radians(p['r'][2]); sx,sy=p['s']; c,s=math.cos(rz),math.sin(rz)
    return (c*sx,-s*sy,tx, s*sx,c*sy,ty)
def rect(p):
    w,h=p['wh']; ox=p['origin']&3; oy=(p['origin']>>2)&3
    x0={0:-w/2,1:0,2:-w}[ox]; y0={0:-h/2,1:-h,2:0}[oy]  # y-up: top origin -> rect below
    return [(x0,y0),(x0+w,y0),(x0+w,y0+h),(x0,y0+h)]
def render(path, tab, out, illust=None, illust1=None, skip_tabs=()):
    d,root,txl,mats=load(path)
    W,H=1280,720; im=Image.new('RGB',(W,H),(30,70,60)); dr=ImageDraw.Draw(im,'RGBA')
    def scr(x,y): return (W/2+x, H/2-y)
    def go(p,M,visible):
        M=mat_mul(M,local(p)); vis=True
        if p['name'] in skip_tabs: return
        if vis:
            pts=[scr(M[0]*x+M[1]*y+M[2], M[3]*x+M[4]*y+M[5]) for x,y in rect(p)]
            n=p['name']
            if n=='P_NNillust_00' and illust: 
                img=illust.resize((round(576*p['s'][0]),round(288*p['s'][1])))
                im.paste(img.convert('RGB'),(round(pts[3][0]),round(pts[3][1])),img.split()[-1])
            elif n=='P_NNillust_01' and illust1:
                img=illust1.resize((round(576*p['s'][0]),round(100*p['s'][1])))
                im.paste(img.convert('RGB'),(round(pts[3][0]),round(pts[3][1])),img.split()[-1])
            elif n.startswith('P_Line'):
                m0=((pts[0][0]+pts[3][0])/2,(pts[0][1]+pts[3][1])/2); m1=((pts[1][0]+pts[2][0])/2,(pts[1][1]+pts[2][1])/2)
                if p['wh'][0]<=11: dr.ellipse((sum(q[0] for q in pts)/4-1.5,sum(q[1] for q in pts)/4-1.5,sum(q[0] for q in pts)/4+1.5,sum(q[1] for q in pts)/4+1.5),fill=(40,140,255))
                else: dr.line([m0,m1],fill=(40,140,255),width=2)
            elif n.startswith('Nt_TipsLineCircle'): 
                cx=sum(q[0] for q in pts)/4; cy=sum(q[1] for q in pts)/4; dr.ellipse((cx-3,cy-3,cx+3,cy+3),fill=(40,140,255))
            elif p['kind']=='wnd1': dr.polygon(pts,fill=(20,80,120,150))
            elif p['kind']=='txt1' and not n.endswith(('_JPja','_KR','_CN','_TW')) and 'XB' not in n and 'BX' not in n and 'AX' not in n:
                dr.text((pts[3][0]+2,pts[3][1]+4),n,fill=(255,255,255))
        for k in p['kids']: go(k,M,vis)
    go(root,(1,0,0,0,1,0),True)
    im.save(out)
if __name__=='__main__':
    from PIL import Image
    ill=Image.open('lytdata/NN00_r.png').convert('L'); a=Image.open('lytdata/NN00_g.png').convert('L'); ill=Image.merge('LA',(ill,a))
    ill1=Image.merge('LA',(Image.open('lytdata/NN01_r.png').convert('L'),Image.open('lytdata/NN01_g.png').convert('L')))
    tabs=['N_Kihon_00','N_Uma_00','N_Suna_00']
    for t in tabs:
        render(sys.argv[1],t,f'lytdata/render_{t}.png',ill,ill1,skip_tabs=[x for x in tabs if x!=t])

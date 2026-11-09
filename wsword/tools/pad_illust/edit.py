import sys,math,struct
sys.path.insert(0,'lyt')
from tree import load, walk
from render import mat_mul, local
def inv(M):
    a,b,c,d,e,f=M; det=a*e-b*d
    return (e/det,-b/det,(b*f-c*e)/det, -d/det,a/det,(c*d-a*f)/det)
class Lyt:
    def __init__(s,path):
        s.d=bytearray(open(path,'rb').read())
        _,s.root,_,_=load(path)
        s.by={p['name']:p for p,_ in walk(s.root)}
        s.edits={}
    def world(s,p):
        chain=[]; q=p
        while q: chain.append(q); q=q['parent']
        M=(1,0,0,0,1,0)
        for q in reversed(chain): M=mat_mul(M,local(q))
        return M
    def put(self,p,**kw):
        s=self
        for k,v in kw.items(): p[k]=v
        o=p['off']
        struct.pack_into('<fff',s.d,o+0x2C,*p['t']); struct.pack_into('<fff',s.d,o+0x38,*p['r'])
        struct.pack_into('<ff',s.d,o+0x44,*p['s']); struct.pack_into('<ff',s.d,o+0x4C,*p['wh'])
        s.edits[p['name']]=(p['t'][0],p['t'][1],p['r'][2],p['s'][0],p['s'][1],p['wh'][0],p['wh'][1])
    def move(s,name,dx,dy):
        p=s.by[name]; s.put(p,t=(p['t'][0]+dx,p['t'][1]+dy,p['t'][2]))
    def set_world(s,name,x,y,ang,w=None):
        p=s.by[name]; P=s.world(p['parent'])
        c,sn=math.cos(math.radians(ang)),math.sin(math.radians(ang))
        W=(c,-sn,x, sn,c,y)
        L=mat_mul(inv(P),W)
        sx=math.hypot(L[0],L[3]); th=math.degrees(math.atan2(L[3],L[0])); det=L[0]*L[4]-L[1]*L[3]; sy=det/sx
        th=round(th/90)*90 % 360
        if th>180: th-=360
        wh=(w if w is not None else p['wh'][0], p['wh'][1])
        s.put(p,t=(round(L[2],3),round(L[5],3),p['t'][2]),r=(p['r'][0],p['r'][1],float(th)),s=(round(sx,3),round(sy,3)),wh=wh)
    def pos(s,name):
        M=s.world(s.by[name]); return M[2],M[5]
    def seg(s,name,P,Q):
        # a straight piece from P to Q (its own origin: 2 right / 1 left / 0 centre)
        p=s.by[name]; dx,dy=Q[0]-P[0],Q[1]-P[1]; L=math.hypot(dx,dy); ang=math.degrees(math.atan2(dy,dx))
        org=p['origin']&3
        A={2:Q,1:P,0:((P[0]+Q[0])/2,(P[1]+Q[1])/2)}[org]
        s.set_world(name,A[0],A[1],ang,w=max(L,0.5))
    def route(s,tee,hseg,corner,vseg,end,E,end_kind,stop=0):
        # tee -> horizontal -> corner -> vertical -> end at E (the end piece's centre; stop: its gap before E)
        T=s.pos(tee); ex,ey=E; hd=1 if ex>T[0] else -1
        if corner is None:
            assert abs(ey-T[1])<0.6,(tee,ey,T)
            if end_kind=='circle':
                s.set_world(end,ex,ey,0 if hd<0 else 180)  # stub toward the tee
                s.seg(hseg,(T[0]+5*hd,T[1]),(ex-32*hd,ey))
            else:
                s.set_world(end,ex,ey,0 if hd>0 else 180)
                s.seg(hseg,(T[0]+5*hd,T[1]),(ex-5*hd,ey))
            return
        vd=1 if ey>T[1] else -1
        C=(ex,T[1])
        a=(-hd,0); b=(0,vd)  # corner's stubs: back toward the tee, on toward the end
        for ang in (0,90,180,-90):
            c,sn=round(math.cos(math.radians(ang))),round(math.sin(math.radians(ang)))
            st=[(-c,-sn),(sn,-c)]  # R(ang)(-1,0), R(ang)(0,-1)
            if set(st)=={a,b}: break
        s.set_world(corner,C[0],C[1],ang)
        s.seg(hseg,(T[0]+5*hd,T[1]),(C[0]-5*hd,C[1]))
        if end_kind=='circle':
            s.set_world(end,ex,ey,90 if vd<0 else -90)   # stub (+x) toward the corner
            s.seg(vseg,(C[0],C[1]+5*vd),(ex,ey-32*vd))
        else:
            ey2=ey-stop*vd
            s.set_world(end,ex,ey2,-90 if vd<0 else 90)   # stub (-x) toward the corner
            s.seg(vseg,(C[0],C[1]+5*vd),(ex,ey2-5*vd))

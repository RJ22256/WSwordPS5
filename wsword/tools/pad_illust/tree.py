import struct,sys,math
def load(path):
    d=open(path,'rb').read(); hs,=struct.unpack('<H',d[6:8]); o=hs
    txl=[];mats=[];root=None;stack=[];last=None
    while o+8<=len(d):
        m=d[o:o+4]; sz,=struct.unpack('<I',d[o+4:o+8]); s=d[o:o+sz]
        if m==b'txl1':
            n,=struct.unpack('<H',s[8:10])
            for k in range(n):
                q,=struct.unpack('<I',s[12+4*k:16+4*k]); txl.append(s[12+q:s.index(b'\0',12+q)].decode())
        elif m==b'mat1':
            n,=struct.unpack('<H',s[8:10])
            for k in range(n):
                q,=struct.unpack('<I',s[12+4*k:16+4*k]); e=s[q:]
                name=e[:28].split(b'\0')[0].decode(); flags,=struct.unpack('<I',e[0x30:0x34]) if len(e)>0x34 else (0,)
                # texmap: after name(28)+colors(8)+flags(4)?? variants; read first u16 at 0x34 per Switch v8: name28, black4,white4, flags4, then texmaps(4 bytes each)
                ntex=flags&3; tex=struct.unpack('<H',e[0x34:0x36])[0] if ntex else -1
                mats.append((name,tex))
        elif m in (b'pan1',b'pic1',b'txt1',b'wnd1',b'prt1',b'bnd1'):
            p=dict(kind=m.decode(),off=o,flags=s[8],origin=s[9],alpha=s[10],name=s[0x0C:0x24].split(b'\0')[0].decode(),
                   t=struct.unpack('<fff',s[0x2C:0x38]),r=struct.unpack('<fff',s[0x38:0x44]),s=struct.unpack('<ff',s[0x44:0x4C]),
                   wh=struct.unpack('<ff',s[0x4C:0x54]),kids=[],parent=stack[-1] if stack else None)
            if m==b'pic1': p['mat'],=struct.unpack('<H',s[0x64:0x66])
            if stack: stack[-1]['kids'].append(p)
            else: root=p
            last=p
        elif m==b'pas1': stack.append(last)
        elif m==b'pae1': stack.pop()
        o+=sz
    return d,root,txl,mats
def walk(p,depth=0):
    yield p,depth
    for k in p['kids']: yield from walk(k,depth+1)
if __name__=='__main__':
    d,root,txl,mats=load(sys.argv[1])
    print(txl); print(mats[:60])
    for p,dep in walk(root):
        if sys.argv[2] in p['name'] or (p['parent'] and any(sys.argv[2] in a['name'] for a in [p['parent']])):
            pass
    tgt=[p for p,_ in walk(root) if p['name']==sys.argv[2]][0]
    for p,dep in walk(tgt):
        mt=mats[p['mat']] if 'mat' in p else ''
        print('  '*dep,p['kind'],p['name'],'org',p['origin'],'vis',p['flags']&1,'t',tuple(round(x,1) for x in p['t'][:2]),'rz',round(p['r'][2],1),'s',p['s'],'wh',p['wh'],mt)

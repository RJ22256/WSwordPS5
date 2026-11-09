import struct,sys,os
def yaz0(d):
    assert d[:4]==b'Yaz0'; size=struct.unpack('>I',d[4:8])[0]; out=bytearray(); i=16
    while len(out)<size:
        c=d[i];i+=1
        for b in range(8):
            if len(out)>=size: break
            if c&(0x80>>b): out.append(d[i]);i+=1
            else:
                b1,b2=d[i],d[i+1];i+=2;dist=((b1&15)<<8|b2)+1;n=b1>>4
                if n==0: n=d[i]+0x12;i+=1
                else: n+=2
                for _ in range(n): out.append(out[-dist])
    return bytes(out)
def sarc(d):
    bo='<' if d[6:8]==b'\xff\xfe' else '>'
    hs,=struct.unpack(bo+'H',d[4:6]); doff,=struct.unpack(bo+'I',d[12:16])
    o=hs; assert d[o:o+4]==b'SFAT'; n,=struct.unpack(bo+'H',d[o+6:o+8]); ents=[]
    for k in range(n):
        h,a,s,e=struct.unpack(bo+'IIII',d[o+12+16*k:o+28+16*k]); ents.append((a,s,e))
    t=o+12+16*n; assert d[t:t+4]==b'SFNT'; names=t+8
    r={}
    for a,s,e in ents:
        no=(a&0xffff)*4; nm=d[names+no:d.index(b'\0',names+no)].decode()
        r[nm]=d[doff+s:doff+e]
    return r
p=sarc(open(sys.argv[1],'rb').read())
c=p['Layout/Common.sblarc']; c=yaz0(c) if c[:4]==b'Yaz0' else c
a=sarc(c); out=sys.argv[2]
for k,v in a.items():
    if 'PaDoCommand' in k or 'KeyTex' in k:
        fn=os.path.join(out,k.replace('/','_')); open(fn,'wb').write(v); print(k,len(v))

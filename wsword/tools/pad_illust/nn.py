import struct,sys
from PIL import Image
b=open('lytdata/combined.bntx','rb').read()
def addr_of(x,y,stride,bh):
    gobs_x=(stride+63)//64; gob_y=y//8; blk=gob_y//bh
    return blk*gobs_x*bh*512 + (x//64)*bh*512 + (gob_y%bh)*512 + ((x%64)//32)*256 + ((y%8)//2)*64 + ((x%32)//16)*32 + (y%2)*16 + (x%16)
for off,nm in ((0x73cc0,'00'),(0x73f68,'01')):
    w,h=struct.unpack('<II',b[off+0x24:off+0x2C]); bh=1<<struct.unpack('<I',b[off+0x34:off+0x38])[0]
    size,=struct.unpack('<I',b[off+0x50:off+0x54])
    mipptr,=struct.unpack('<Q',b[off+0x70:off+0x78]); dataoff,=struct.unpack('<Q',b[mipptr:mipptr+8])
    raw=b[dataoff:dataoff+size]; stride=w*2
    r=bytearray(w*h); g=bytearray(w*h)
    for y in range(h):
        for x in range(w):
            a=addr_of(2*x,y,stride,bh); r[y*w+x]=raw[a]; g[y*w+x]=raw[a+1]
    Image.frombytes('L',(w,h),bytes(r)).save(f'lytdata/NN{nm}_r.png'); Image.frombytes('L',(w,h),bytes(g)).save(f'lytdata/NN{nm}_g.png')
    open(f'lytdata/NN{nm}.rg','wb').write(bytes(x for p in zip(r,g) for x in p))
    print(nm,w,h,bh,size,hex(dataoff))

#!/usr/bin/env python3
import math
import struct
import sys
import zlib

W = H = 1024

BG = (13.0, 24.0, 27.0)
GREEN = (77.0, 221.0, 159.0)
GREEN_DARK = (34.0, 125.0, 94.0)
FRONT = (28.0, 35.0, 40.0)
WHITE = (238.0, 246.0, 244.0)

def clamp(v, a=0.0, b=1.0):
    return a if v < a else b if v > b else v

def smooth(a,b,x):
    if a == b: return 0.0
    t=clamp((x-a)/(b-a))
    return t*t*(3-2*t)

def rr_sdf(px,py,cx,cy,hw,hh,r,ang):
    ca=math.cos(ang); sa=math.sin(ang)
    dx=px-cx; dy=py-cy
    lx=abs(dx*ca+dy*sa)-(hw-r)
    ly=abs(-dx*sa+dy*ca)-(hh-r)
    ox=max(lx,0.0); oy=max(ly,0.0)
    return math.hypot(ox,oy)+min(max(lx,ly),0.0)-r

def line_dist(px,py,ax,ay,bx,by):
    vx=bx-ax; vy=by-ay
    wx=px-ax; wy=py-ay
    vv=vx*vx+vy*vy
    if vv == 0: return math.hypot(wx,wy)
    t=clamp((wx*vx+wy*vy)/vv)
    qx=ax+t*vx; qy=ay+t*vy
    return math.hypot(px-qx,py-qy)

def arc_dist(px,py,cx,cy,r,a0,a1):
    dx=px-cx; dy=py-cy
    a=math.atan2(dy,dx)
    while a < a0: a += math.tau
    while a > a1: a -= math.tau
    if a0 <= a <= a1:
        return abs(math.hypot(dx,dy)-r)
    p0=(cx+r*math.cos(a0), cy+r*math.sin(a0))
    p1=(cx+r*math.cos(a1), cy+r*math.sin(a1))
    return min(math.hypot(px-p0[0],py-p0[1]), math.hypot(px-p1[0],py-p1[1]))

buf=bytearray()
for y in range(H):
    row=bytearray()
    for x in range(W):
        # Flat deep background with a very subtle center lift.
        dcenter=math.hypot(x-512,y-500)/720.0
        lift=max(0.0,1.0-dcenter)*5.0
        r,g,b=BG[0]+lift,BG[1]+lift,BG[2]+lift

        # Rear mint card.
        d=rr_sdf(x,y,430,430,245,150,50,math.radians(-10))
        aa=1.0-smooth(-1.3,1.3,d)
        if aa>0:
            t=clamp((y-280)/300)
            rr=GREEN[0]*(1-t)+GREEN_DARK[0]*t
            gg=GREEN[1]*(1-t)+GREEN_DARK[1]*t
            bb=GREEN[2]*(1-t)+GREEN_DARK[2]*t
            r=r*(1-aa)+rr*aa; g=g*(1-aa)+gg*aa; b=b*(1-aa)+bb*aa

        # Front dark card.
        d=rr_sdf(x,y,590,585,270,170,54,math.radians(7))
        aa=1.0-smooth(-1.3,1.3,d)
        if aa>0:
            r=r*(1-aa)+FRONT[0]*aa; g=g*(1-aa)+FRONT[1]*aa; b=b*(1-aa)+FRONT[2]*aa

        # Contactless/NFC mark on front card.
        cx,cy=690,565
        dot=math.hypot(x-(cx-52),y-cy)
        a=1.0-smooth(10,17,dot)
        if a>0:
            r=r*(1-a)+WHITE[0]*a; g=g*(1-a)+WHITE[1]*a; b=b*(1-a)+WHITE[2]*a

        for radius,width in [(40,8),(72,9),(104,10)]:
            dd=arc_dist(x,y,cx-62,cy,radius,-0.78,0.78)
            a=1.0-smooth(width-1,width+1,dd)
            if a>0:
                r=r*(1-a)+WHITE[0]*a; g=g*(1-a)+WHITE[1]*a; b=b*(1-a)+WHITE[2]*a

        row.extend((int(clamp(r/255)*255),int(clamp(g/255)*255),int(clamp(b/255)*255),255))
    buf.extend(b"\x00"+row)

def chunk(kind,data):
    return struct.pack(">I",len(data))+kind+data+struct.pack(">I",zlib.crc32(kind+data)&0xffffffff)

png=b"\x89PNG\r\n\x1a\n"
png+=chunk(b"IHDR",struct.pack(">IIBBBBB",W,H,8,6,0,0,0))
png+=chunk(b"IDAT",zlib.compress(bytes(buf),9))
png+=chunk(b"IEND",b"")

out=sys.argv[1] if len(sys.argv)>1 else "NFCARDIcon.png"
with open(out,"wb") as fh:
    fh.write(png)
print(out)

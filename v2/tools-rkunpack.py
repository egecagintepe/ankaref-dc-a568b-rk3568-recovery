import struct, sys, os
# Read-only RKFW/RKAF unpacker (writes extracted parts to out dir only)
f = open(sys.argv[1], 'rb'); out = sys.argv[2]; os.makedirs(out, exist_ok=True)
h = f.read(0x66)
assert h[:4] == b'RKFW'
year, mon, day, hr, mi, sec = struct.unpack_from('<HBBBBB', h, 14)
lo, ll, io, il = struct.unpack_from('<IIII', h, 25)
print('RKFW date %04d-%02d-%02d %02d:%02d:%02d chip=%r loader@%d+%d image@%d+%d' % (year, mon, day, hr, mi, sec, h[21:25][::-1], lo, ll, io, il))
f.seek(lo); open(os.path.join(out, 'MiniLoaderAll.bin'), 'wb').write(f.read(ll))
f.seek(io); af = f.read(0x800)
assert af[:4] == b'RKAF'
nparts, = struct.unpack_from('<I', af, 0x88)
print('RKAF parts', nparts)
for i in range(nparts):
    e = af[0x8c + i*0x70: 0x8c + (i+1)*0x70]
    name = e[:32].split(b'\0')[0].decode(errors='replace')
    fn = e[32:92].split(b'\0')[0].decode(errors='replace')
    psize, poff, flash, padded, fsize = struct.unpack_from('<IIIII', e, 92)
    print('%-14s %-34s archive_off=%10d size=%10d flash_lba=0x%08x part_size=0x%x' % (name, fn, poff, fsize, flash, psize))
    if fsize and fn and fn not in ('RESERVED', 'package-file'):
        f.seek(io + poff)
        with open(os.path.join(out, os.path.basename(fn)), 'wb') as o:
            left = fsize
            while left:
                b = f.read(min(left, 1 << 24)); o.write(b); left -= len(b)

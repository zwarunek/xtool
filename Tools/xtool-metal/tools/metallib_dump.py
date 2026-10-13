#!/usr/bin/env python3
"""Dump the structure of a .metallib file and optionally extract each function's bitcode."""
import hashlib, os, struct, sys

def tags(buf, off, end):
    out = []
    while off < end:
        name = buf[off:off+4].decode('latin1')
        if name == 'ENDT':
            out.append((name, b''))
            off += 4
            break
        size, = struct.unpack_from('<H', buf, off+4)
        out.append((name, buf[off+6:off+6+size]))
        off += 6 + size
    return out, off

def main(path, extract_dir=None):
    b = open(path, 'rb').read()
    magic, plat, vmaj, vmin, ltype, tos, osmaj, osmin, fsize = struct.unpack_from('<4sHHHBBHHQ', b, 0)
    fl_off, fl_size, pub_off, pub_size, priv_off, priv_size, bc_off, bc_size = struct.unpack_from('<8Q', b, 24)
    print(f'magic={magic} platform={plat:#x} version={vmaj}.{vmin} type={ltype} os={tos:#x} {osmaj}.{osmin} size={fsize} (actual {len(b)})')
    print(f'funclist {fl_off:#x}+{fl_size:#x} public {pub_off:#x}+{pub_size:#x} private {priv_off:#x}+{priv_size:#x} bitcode {bc_off:#x}+{bc_size:#x}')
    n, = struct.unpack_from('<I', b, fl_off)
    off = fl_off + 4
    for i in range(n):
        gsize, = struct.unpack_from('<I', b, off)
        ts, _ = tags(b, off + 4, off + gsize)
        d = {k: v for k, v in ts}
        name = d['NAME'].rstrip(b'\0').decode()
        pub, priv, bco = struct.unpack('<3Q', d['OFFT'])
        mdsz, = struct.unpack('<Q', d['MDSZ'])
        print(f'  fn[{i}] {name} type={d["TYPE"][0]} vers={struct.unpack("<4H", d["VERS"])} offt=({pub:#x},{priv:#x},{bco:#x}) mdsz={mdsz:#x} tags={[k for k, _ in ts]}')
        bc = b[bc_off + bco: bc_off + bco + mdsz]
        ok = hashlib.sha256(bc).digest() == d['HASH']
        print(f'      hash ok={ok} bc[:4]={bc[:4].hex()}')
        pts, _ = tags(b, pub_off + pub + 4, pub_off + pub_size)
        pvs, _ = tags(b, priv_off + priv + 4, priv_off + priv_size)
        print(f'      public={[(k, v.hex()) for k, v in pts]} private={[(k, v) for k, v in pvs]}')
        if extract_dir:
            os.makedirs(extract_dir, exist_ok=True)
            open(os.path.join(extract_dir, name + '.bc'), 'wb').write(bc)
        off += gsize
    ext = fl_off + 4 + fl_size
    if ext != pub_off:
        ts, _ = tags(b, ext, pub_off)
        print('  header extension:', [(k, v.hex()) for k, v in ts])

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)

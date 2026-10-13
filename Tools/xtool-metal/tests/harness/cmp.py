import struct, sys
a = open(sys.argv[1], 'rb').read(); b = open(sys.argv[2], 'rb').read()
fmt = sys.argv[3] if len(sys.argv) > 3 else 'f'
size = {'f': 4, 'e': 2, 'i': 4}.get(fmt, 1)
if len(a) != len(b): print('SIZE MISMATCH', len(a), len(b)); sys.exit(1)
if fmt == 'B':
    x, y = a, b
else:
    n = len(a) // size; x = struct.unpack(f'<{n}{fmt}', a); y = struct.unpack(f'<{n}{fmt}', b)
d = [abs(p - q) for p, q in zip(x, y)]
md = max(d) if d else 0
ndiff = sum(1 for v in d if v > 0)
print(f'n={len(d)} identical={a == b} maxdiff={md:.3g} differing={ndiff}')

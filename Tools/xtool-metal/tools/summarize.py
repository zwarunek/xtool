import glob, os, re, sys, json
d = sys.argv[1]
res = {}
for f in sorted(glob.glob(os.path.join(d, '*.ll'))):
    b = os.path.basename(f)[:-3]
    probe, mode = b.rsplit('.', 1)
    txt = open(f).read()
    decls = sorted(set(re.findall(r'^declare [^@]*@([\w.$]+)\(([^)]*)\)', txt, re.M)))
    defs = [m for m in re.findall(r'^define [^@]*@([\w.$]+)\(', txt, re.M)]
    res.setdefault(probe, {})[mode] = {'decls': [f'{n}({a})' for n, a in decls], 'defs': defs}
for f in sorted(glob.glob(os.path.join(d, '*.err'))):
    b = os.path.basename(f)[:-4]
    probe, mode = b.rsplit('.', 1)
    res.setdefault(probe, {})[mode] = {'error': open(f).read().strip().splitlines()[0][:200] if open(f).read().strip() else ''}
json.dump(res, sys.stdout, indent=0)

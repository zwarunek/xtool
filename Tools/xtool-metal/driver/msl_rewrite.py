"""Rewrite preprocessed Metal Shading Language into C++ for OpenCL that clang 15 accepts.

Only text from user files is changed (regions from the xtmetal include directory are copied as is), and
line structure is preserved so diagnostics point at the original lines.

  [[buffer(0)]]               -> [[clang::annotate("air:buffer", 0)]]
  vertex / fragment / kernel  -> __attribute__((annotate("air:vertex"))) ...
  device / constant / threadgroup / thread -> __global / __constant / __local / (generic)
  float4(a, b)                -> __xt_make<float4>(a, b)     (MSL vector construction)
"""
import re


class RewriteError(Exception):
    pass


TOKEN = re.compile(r'''
    (?P<ws>[ \t\r\f\v]+|\n)
  | (?P<line>^\#[^\n]*)
  | (?P<id>[A-Za-z_][A-Za-z0-9_]*)
  | (?P<num>\.?[0-9](?:[eEpP][+-]|[A-Za-z0-9_.'])*)
  | (?P<str>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')
  | (?P<punct>::|->|\[\[|\]\]|<<=|>>=|\.\.\.|[-+*/%&|^!=<>]=|&&|\|\||\+\+|--|<<|>>|.)
''', re.X | re.M | re.S)

SCALARS = ['bool', 'char', 'uchar', 'short', 'ushort', 'int', 'uint', 'long', 'ulong', 'half', 'float', 'bfloat']
VECTOR_TYPES = set()
for s in SCALARS:
    for n in (2, 3, 4, 8, 16):
        VECTOR_TYPES.add(f'{s}{n}')
        VECTOR_TYPES.add(f'vector_{s}{n}')
        VECTOR_TYPES.add(f'simd_{s}{n}')
STD_ATTRS = {'maybe_unused', 'nodiscard', 'noreturn', 'deprecated', 'fallthrough', 'likely', 'unlikely',
             'carries_dependency', 'no_unique_address'}
QUOTE_ARGS = {'user', 'depth', 'patch', 'raster_order_group'}
QUALIFIERS = {'vertex', 'fragment', 'kernel'}
ADDRESS_SPACES = {'device': '__global', 'constant': '__constant', 'threadgroup': '__local', 'thread': '',
                  'threadgroup_imageblock': '__local', 'object_data': '__global', 'ray_data': ''}


def tokenize(text):
    pos = 0
    out = []
    while pos < len(text):
        m = TOKEN.match(text, pos)
        if not m:
            raise RewriteError(f'cannot tokenize near {text[pos:pos + 20]!r}')
        out.append((m.lastgroup, m.group()))
        pos = m.end()
    return out


def rewrite(text, include_dir):
    toks = tokenize(text)
    vector_names = set(VECTOR_TYPES)
    # user typedefs of vector types: typedef float4 Color; using Color = float4;
    sig = [t for t in toks if t[0] not in ('ws', 'line')]
    for i in range(len(sig) - 3):
        if sig[i][1] == 'typedef' and sig[i + 1][1] in vector_names and sig[i + 2][0] == 'id' and sig[i + 3][1] == ';':
            vector_names.add(sig[i + 2][1])
        if sig[i][1] == 'using' and sig[i + 1][0] == 'id' and sig[i + 2][1] == '=' and sig[i + 3][1] in vector_names:
            if i + 4 < len(sig) and sig[i + 4][1] == ';':
                vector_names.add(sig[i + 1][1])

    out = []           # list of output strings
    in_user = True
    i = 0
    n = len(toks)

    def prev_sig(k=1):
        c = 0
        for j in range(len(out) - 1, -1, -1):
            s = out[j]
            if s.strip() == '' or s.startswith('#'):
                continue
            c += 1
            if c == k:
                return s
        return ''

    def next_sig(j):
        while j < n and toks[j][0] in ('ws',):
            j += 1
        return j

    while i < n:
        kind, val = toks[i]
        if kind == 'line':
            m = re.match(r'#\s*(?:line\s+)?\d+\s+"([^"]*)"', val)
            if m:
                path = m.group(1)
                in_user = not (path.startswith(include_dir + '/') or path == include_dir)
            out.append(val)
            i += 1
            continue
        if not in_user or kind in ('ws', 'num', 'str'):
            out.append(val)
            i += 1
            continue
        if val == '[[':
            # attribute specifier; collect up to the matching ]]
            j = i + 1
            depth = 0
            body = []
            while j < n:
                k2, v2 = toks[j]
                if v2 == ']]' and depth == 0:
                    break
                if v2 in ('(', '['):
                    depth += 1
                elif v2 in (')', ']'):
                    depth -= 1
                elif v2 == ']]':
                    depth -= 2
                body.append((k2, v2))
                j += 1
            if j >= n:
                raise RewriteError('unterminated [[ attribute')
            out.append(rewrite_attrs(body, out))
            i = j + 1
            continue
        if kind == 'id':
            p = prev_sig()
            member = p in ('.', '->', '::')
            if val in QUALIFIERS and not member:
                j = next_sig(i + 1)
                if j < n and (toks[j][0] == 'id' or toks[j][1] in ('[[', '::')):
                    out.append(f'__attribute__((annotate("air:{val}")))')
                    i += 1
                    continue
            if val in ADDRESS_SPACES and not member:
                j = next_sig(i + 1)
                if j < n and toks[j][1] != '(':
                    ptr = is_pointer_decl(toks, i + 1)
                    if val == 'constant':
                        # Objects (program-scope constants) use OpenCL __constant; pointers and references use
                        # the numeric address space, which C++ for OpenCL lets bind to generic references
                        # (implicit copies of buffer structs).
                        out.append('__constant' if not ptr else '__attribute__((address_space(2)))')
                    elif val == 'threadgroup' and not ptr:
                        # threadgroup variables in function bodies become addrspace(3) globals in xtmetal
                        out.append('__attribute__((annotate("air:tg_local")))')
                    else:
                        out.append(ADDRESS_SPACES[val])
                    i += 1
                    continue
            if val in vector_names:
                j = next_sig(i + 1)
                if j < n and toks[j][1] in ('(', '{'):
                    prefix = ''
                    if p == '::' and prev_sig(2) == 'metal':
                        # drop "metal ::" already emitted
                        removed = 0
                        while out and removed < 2:
                            s = out.pop()
                            if s.strip():
                                removed += 1
                        prefix = 'metal::'
                    if p in ('.', '->') or (p == '::' and not prefix):
                        out.append(val)
                        i += 1
                        continue
                    if toks[j][1] == '(':
                        out.append(f'__xt_make<{prefix}{val}>')
                        i += 1
                        continue
                    # brace form: TYPE{ ... } -> __xt_make<TYPE>( ... )
                    k = j + 1
                    depth = 1
                    while k < n and depth:
                        if toks[k][1] in ('{',):
                            depth += 1
                        elif toks[k][1] == '}':
                            depth -= 1
                        k += 1
                    if p in ('typedef', 'using', 'struct', 'class') or prev_sig() in (',',) and False:
                        out.append(val)
                        i += 1
                        continue
                    out.append(f'__xt_make<{prefix}{val}>(')
                    out.extend(t[1] for t in toks[j + 1:k - 1])
                    out.append(')')
                    i = k
                    continue
            if val == 'vec' and not member:
                # vec<T, N>( ... ) -> __xt_make<vec<T, N>>( ... )
                j = next_sig(i + 1)
                if j < n and toks[j][1] == '<':
                    k = j + 1
                    depth = 1
                    while k < n and depth:
                        if toks[k][1] == '<':
                            depth += 1
                        elif toks[k][1] == '>':
                            depth -= 1
                        elif toks[k][1] == '>>':
                            depth -= 2
                        k += 1
                    k2 = next_sig(k)
                    if k2 < n and toks[k2][1] == '(':
                        out.append('__xt_make<vec' + ''.join(t[1] for t in toks[j:k]) + '>')
                        i = k
                        continue
        out.append(val)
        i += 1
    return '#pragma OPENCL EXTENSION cl_khr_fp16 : enable\n' + ''.join(out)


def is_pointer_decl(toks, j):
    depth = 0
    while j < len(toks):
        v = toks[j][1]
        if v in ('<', '('):
            if v == '(' and depth == 0:
                return False
            depth += 1
        elif v in ('>', ')'):
            if depth == 0:
                return False
            depth -= 1
        elif v == '>>':
            depth -= 2
        elif depth == 0 and v in (';', '=', ',', '{', '[[', '['):
            return False
        elif depth == 0 and v in ('*', '&', '&&'):
            return True
        j += 1
    return False


def split_top(body, sep=','):
    parts, cur, depth = [], [], 0
    for k, v in body:
        if v in ('(', '[', '{'):
            depth += 1
        elif v in (')', ']', '}'):
            depth -= 1
        if v == sep and depth == 0:
            parts.append(cur)
            cur = []
        else:
            cur.append((k, v))
    parts.append(cur)
    return parts


def rewrite_attrs(body, out):
    res = []
    fc = False
    for part in split_top(body):
        toks = [t for t in part if t[0] != 'ws']
        if not toks:
            continue
        name = toks[0][1]
        rest = toks[1:]
        if len(toks) >= 3 and toks[1][1] == '::':
            ns, name, rest = toks[0][1], toks[2][1], toks[3:]
            if ns in ('clang', 'gnu', 'metal_internal'):
                res.append(''.join(v for _, v in part).strip())
                continue
            if ns != 'metal':
                continue
        if name in STD_ATTRS:
            res.append(''.join(v for _, v in part).strip())
            continue
        args = []
        if rest and rest[0][1] == '(' and rest[-1][1] == ')':
            inner = [t for t in part if True]
            # find the argument tokens with whitespace preserved
            text = ''.join(v for _, v in part)
            a = text[text.index('(') + 1:text.rindex(')')]
            for arg in split_top(tokenize_simple(a)):
                s = ''.join(v for _, v in arg).strip()
                if not s:
                    continue
                if name in QUOTE_ARGS or (name == 'host_name' and not s.startswith('"')):
                    if not s.startswith('"'):
                        s = '"' + s + '"'
                args.append(s)
        if name == 'function_constant':
            fc = True
        res.append('clang::annotate("air:' + name + '"' + ''.join(', ' + a for a in args) + ')')
    if fc:
        # function constants are globals the compiler redirects; they must not be __constant (which
        # needs an initializer and lets clang fold reads)
        for j in range(len(out) - 1, -1, -1):
            if out[j] in ('__constant', '__attribute__((address_space(2)))'):
                out[j] = '__global'
                break
            if out[j] in (';', '}', '{'):
                break
    if not res:
        return ''
    return '[[' + ', '.join(res) + ']]'


def tokenize_simple(s):
    return tokenize(s)

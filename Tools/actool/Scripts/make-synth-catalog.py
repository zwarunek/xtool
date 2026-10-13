#!/usr/bin/env python3
"""Builds Tests/ActoolKitTests/Fixtures/Synth.xcassets: a catalog covering every feature actool handles, from generated content only. Usage: make-synth-catalog.py <out.xcassets>"""
import json, os, shutil, sys
from PIL import Image, ImageDraw

out = sys.argv[1]
shutil.rmtree(out, ignore_errors=True)
os.makedirs(out)

def contents(d, obj):
    os.makedirs(d, exist_ok=True)
    obj.setdefault('info', {'author': 'xcode', 'version': 1})
    json.dump(obj, open(os.path.join(d, 'Contents.json'), 'w'), indent=2)

contents(out, {})

def png(path, w, h, color, alpha=255, mode='RGBA', shape=True):
    im = Image.new(mode, (w, h), (0, 0, 0, 0) if mode == 'RGBA' else 0)
    d = ImageDraw.Draw(im)
    if mode == 'RGBA':
        d.rectangle([0, 0, w - 1, h - 1], fill=color + (alpha,))
        if shape:
            d.ellipse([w // 4, h // 4, 3 * w // 4, 3 * h // 4], fill=(255 - color[0], 255 - color[1], 255 - color[2], 255))
    else:
        d.rectangle([0, 0, w - 1, h - 1], fill=color)
    im.save(path)

# Colors in every color space and component notation.
colors = {
    'c-srgb': {'color-space': 'srgb', 'components': {'red': '0.100', 'green': '0.200', 'blue': '0.300', 'alpha': '1.000'}},
    'c-srgb-hex': {'color-space': 'srgb', 'components': {'red': '0xFF', 'green': '0x80', 'blue': '0x00', 'alpha': '0.500'}},
    'c-srgb-int': {'color-space': 'srgb', 'components': {'red': '255', 'green': '128', 'blue': '0', 'alpha': '1.000'}},
    'c-p3': {'color-space': 'display-p3', 'components': {'red': '1.000', 'green': '0.000', 'blue': '0.000', 'alpha': '1.000'}},
    'c-ext-srgb': {'color-space': 'extended-srgb', 'components': {'red': '1.200', 'green': '-0.100', 'blue': '0.500', 'alpha': '1.000'}},
    'c-ext-lin-srgb': {'color-space': 'extended-linear-srgb', 'components': {'red': '0.500', 'green': '0.500', 'blue': '0.500', 'alpha': '1.000'}},
    'c-gray22': {'color-space': 'gray-gamma-22', 'components': {'white': '0.400', 'alpha': '1.000'}},
    'c-ext-gray': {'color-space': 'extended-gray', 'components': {'white': '0.600', 'alpha': '0.800'}},
    'c-system': {'platform': 'ios', 'reference': 'systemBlueColor'},
}
os.makedirs(os.path.join(out, 'Colors'))
contents(os.path.join(out, 'Colors'), {'properties': {'provides-namespace': True}})
for name, c in colors.items():
    contents(os.path.join(out, 'Colors', name + '.colorset'), {'colors': [{'idiom': 'universal', 'color': c}]})

# Appearance variants on a color, including high contrast.
contents(os.path.join(out, 'c-appearances.colorset'), {'colors': [
    {'idiom': 'universal', 'color': {'color-space': 'srgb', 'components': {'red': '1.000', 'green': '1.000', 'blue': '1.000', 'alpha': '1.000'}}},
    {'idiom': 'universal', 'appearances': [{'appearance': 'luminosity', 'value': 'light'}], 'color': {'color-space': 'srgb', 'components': {'red': '0.900', 'green': '0.900', 'blue': '0.900', 'alpha': '1.000'}}},
    {'idiom': 'universal', 'appearances': [{'appearance': 'luminosity', 'value': 'dark'}], 'color': {'color-space': 'srgb', 'components': {'red': '0.000', 'green': '0.000', 'blue': '0.000', 'alpha': '1.000'}}},
    {'idiom': 'universal', 'appearances': [{'appearance': 'contrast', 'value': 'high'}], 'color': {'color-space': 'srgb', 'components': {'red': '1.000', 'green': '0.000', 'blue': '1.000', 'alpha': '1.000'}}},
    {'idiom': 'universal', 'appearances': [{'appearance': 'luminosity', 'value': 'dark'}, {'appearance': 'contrast', 'value': 'high'}], 'color': {'color-space': 'srgb', 'components': {'red': '0.000', 'green': '1.000', 'blue': '0.000', 'alpha': '1.000'}}},
    {'idiom': 'iphone', 'color': {'color-space': 'srgb', 'components': {'red': '0.000', 'green': '0.000', 'blue': '1.000', 'alpha': '1.000'}}},
]})

# Data sets.
d = os.path.join(out, 'd-json.dataset')
os.makedirs(d)
open(os.path.join(d, 'config.json'), 'w').write('{"hello": "world", "n": 1}\n')
contents(d, {'data': [{'idiom': 'universal', 'filename': 'config.json', 'universal-type-identifier': 'public.json'}]})
d = os.path.join(out, 'd-raw.dataset')
os.makedirs(d)
open(os.path.join(d, 'blob.bin'), 'wb').write(bytes(range(256)) * 3)
contents(d, {'data': [{'idiom': 'universal', 'filename': 'blob.bin'}]})

# Raster image variants.
def imageset(name, images, props=None, files=()):
    d = os.path.join(out, name + '.imageset')
    os.makedirs(d, exist_ok=True)
    for f, w, h, color, kw in files:
        png(os.path.join(d, f), w, h, color, **kw)
    obj = {'images': images}
    if props:
        obj['properties'] = props
    contents(d, obj)

imageset('i-template', [{'idiom': 'universal', 'filename': 't@2x.png', 'scale': '2x'}], {'template-rendering-intent': 'template'},
         [('t@2x.png', 20, 20, (10, 10, 10), {})])
imageset('i-original', [{'idiom': 'universal', 'filename': 'o@2x.png', 'scale': '2x'}], {'template-rendering-intent': 'original'},
         [('o@2x.png', 20, 20, (200, 10, 10), {})])
imageset('i-single-scale', [{'idiom': 'universal', 'filename': 's.png'}], None, [('s.png', 30, 10, (0, 200, 0), {})])
imageset('i-opaque', [{'idiom': 'universal', 'filename': 'op@2x.png', 'scale': '2x'}], None, [('op@2x.png', 16, 16, (0, 0, 200), {'shape': False})])
imageset('i-gray', [{'idiom': 'universal', 'filename': 'g@2x.png', 'scale': '2x'}], None, [('g@2x.png', 16, 16, 128, {'mode': 'L'})])
imageset('i-idioms', [
    {'idiom': 'universal', 'filename': 'u@2x.png', 'scale': '2x'},
    {'idiom': 'iphone', 'filename': 'p@2x.png', 'scale': '2x'},
    {'idiom': 'ipad', 'filename': 'a@2x.png', 'scale': '2x'},
    {'idiom': 'mac', 'filename': 'm@2x.png', 'scale': '2x'},
], None, [('u@2x.png', 8, 8, (1, 2, 3), {}), ('p@2x.png', 8, 8, (4, 5, 6), {}), ('a@2x.png', 8, 8, (7, 8, 9), {}), ('m@2x.png', 8, 8, (10, 11, 12), {})])
imageset('i-sizeclass', [
    {'idiom': 'universal', 'filename': 'any@2x.png', 'scale': '2x'},
    {'idiom': 'universal', 'filename': 'cc@2x.png', 'scale': '2x', 'width-class': 'compact', 'height-class': 'regular'},
], None, [('any@2x.png', 8, 8, (50, 50, 50), {}), ('cc@2x.png', 8, 8, (60, 60, 60), {})])
imageset('i-appearance', [
    {'idiom': 'universal', 'filename': 'l@2x.png', 'scale': '2x'},
    {'idiom': 'universal', 'filename': 'dk@2x.png', 'scale': '2x', 'appearances': [{'appearance': 'luminosity', 'value': 'dark'}]},
    {'idiom': 'universal', 'filename': 'hc@2x.png', 'scale': '2x', 'appearances': [{'appearance': 'contrast', 'value': 'high'}]},
], None, [('l@2x.png', 8, 8, (240, 240, 240), {}), ('dk@2x.png', 8, 8, (20, 20, 20), {}), ('hc@2x.png', 8, 8, (255, 0, 0), {})])
imageset('i-locale', [
    {'idiom': 'universal', 'filename': 'en@2x.png', 'scale': '2x'},
    {'idiom': 'universal', 'filename': 'fr@2x.png', 'scale': '2x', 'locale': 'fr'},
], {'localizable': True}, [('en@2x.png', 8, 8, (0, 0, 255), {}), ('fr@2x.png', 8, 8, (255, 255, 255), {})])
imageset('i-9part', [{'idiom': 'universal', 'filename': 'n@2x.png', 'scale': '2x', 'resizing': {
    'mode': '9-part', 'center': {'mode': 'tile', 'width': 2, 'height': 2},
    'cap-insets': {'top': 4, 'left': 5, 'bottom': 6, 'right': 7}}}], None, [('n@2x.png', 30, 30, (0, 100, 0), {})])
imageset('i-3h', [{'idiom': 'universal', 'filename': 'h@2x.png', 'scale': '2x', 'resizing': {
    'mode': '3-part-horizontal', 'center': {'mode': 'stretch', 'width': 1},
    'cap-insets': {'left': 5, 'right': 7}}}], None, [('h@2x.png', 30, 10, (0, 100, 100), {})])
imageset('i-alignment', [{'idiom': 'universal', 'filename': 'al@2x.png', 'scale': '2x', 'alignment-insets': {'top': 1, 'left': 2, 'bottom': 3, 'right': 4}}],
         None, [('al@2x.png', 20, 20, (90, 0, 90), {})])

# Vector sources, all generated here.
SVG_ICON = """<svg width="24" height="24" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
<path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm-1 15l-5-5 1.41-1.41L11 14.17l7.59-7.59L20 8l-9 9z"/>
</svg>
"""
SVG_MASK = """<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 512 512"><mask id="a"><circle cx="256" cy="256" r="256" fill="#fff"/></mask><g mask="url(#a)"><path fill="#0052b4" d="M0 0h512v170H0z"/><path fill="#eee" d="M0 170h512v172H0z"/><path fill="#d80027" d="M0 342h512v170H0z"/></g></svg>
"""
SVG_FRACTIONAL = """<svg width="7.32816" height="11.82816" viewBox="0 0 7.32816 11.82816" xmlns="http://www.w3.org/2000/svg">
<path d="M7.32816 5.91406L1.41406 11.82816L0 10.41406L4.49996 5.91406L0 1.41406L1.41406 0L7.32816 5.91406Z"/>
</svg>
"""
SVG_GRADIENT = """<svg width="32" height="20" viewBox="0 0 32 20" xmlns="http://www.w3.org/2000/svg">
<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#ff0000"/><stop offset="1" stop-color="#0000ff"/></linearGradient></defs>
<rect x="1" y="1" width="30" height="18" rx="4" fill="url(#g)" stroke="#000" stroke-width="2"/>
<circle cx="16" cy="10" r="5" fill="#fff" fill-opacity=".3"/>
</svg>
"""

def make_pdf(path):
    import zlib
    content = (b"q 0.2 0.4 0.8 rg 10 10 m 90 10 l 90 90 l 10 90 l h f "
               b"1 0 0 RG 4 w 1 J 1 j 50 50 m 70 30 90 70 50 90 c S "
               b"/GS1 gs 0 1 0 rg 30 30 40 40 re f "
               b"q 0.5 0 0 0.5 25 25 cm /Fm1 Do Q Q")
    form = b"0 0 0 rg 0 0 m 40 0 l 20 40 l h f"
    objs = []
    objs.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    objs.append(b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    objs.append(b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100.5 100.5] /Contents 4 0 R /Resources << /ExtGState << /GS1 << /ca 0.5 >> >> /XObject << /Fm1 5 0 R >> >> >>")
    z = zlib.compress(content)
    objs.append(b"<< /Length %d /Filter /FlateDecode >>\nstream\n" % len(z) + z + b"\nendstream")
    objs.append(b"<< /Type /XObject /Subtype /Form /BBox [0 0 40 40] /Length %d >>\nstream\n" % len(form) + form + b"\nendstream")
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for i, o in enumerate(objs):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % (i + 1) + o + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
    for off in offsets:
        out += b"%010d 00000 n \n" % off
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
    open(path, "wb").write(out)

def vector_set(name, filename, writer, props=None, scale=None):
    d = os.path.join(out, name + '.imageset')
    os.makedirs(d)
    writer(os.path.join(d, filename))
    img = {'idiom': 'universal', 'filename': filename}
    if scale:
        img['scale'] = scale
    obj = {'images': [img]}
    if props:
        obj['properties'] = props
    contents(d, obj)

def text_writer(text):
    return lambda p: open(p, 'w').write(text)

vector_set('v-pdf-preserve', 'shape.pdf', make_pdf, {'preserves-vector-representation': True})
vector_set('v-pdf', 'shape.pdf', make_pdf)
vector_set('v-pdf-2x', 'shape.pdf', make_pdf, None, '2x')
vector_set('v-svg-preserve-template', 'icon.svg', text_writer(SVG_ICON), {'preserves-vector-representation': True, 'template-rendering-intent': 'template'})
vector_set('v-svg', 'icon.svg', text_writer(SVG_ICON))
vector_set('v-svg-mask', 'flag.svg', text_writer(SVG_MASK))
vector_set('v-svg-fractional', 'chevron.svg', text_writer(SVG_FRACTIONAL), {'preserves-vector-representation': True, 'template-rendering-intent': 'template'})
vector_set('v-svg-gradient', 'badge.svg', text_writer(SVG_GRADIENT), {'preserves-vector-representation': True, 'template-rendering-intent': 'original'})

d = os.path.join(out, 'j-jpeg.imageset')
os.makedirs(d)
im = Image.new('RGB', (120, 80), (200, 120, 40))
ImageDraw.Draw(im).ellipse([20, 10, 100, 70], fill=(30, 90, 160))
im.save(os.path.join(d, 'r@2x.jpg'), quality=90)
contents(d, {'images': [{'idiom': 'universal', 'filename': 'r@2x.jpg', 'scale': '2x'}]})

# Indexed PNG with partial transparency.
d = os.path.join(out, 'i-indexed.imageset')
os.makedirs(d)
pim = Image.new('P', (16, 16), 0)
pim.putpalette([255, 255, 255, 0, 0, 0] + [0] * 762)
ImageDraw.Draw(pim).rectangle([4, 4, 11, 11], fill=1)
pim.save(os.path.join(d, 'idx@2x.png'), transparency=bytes([80, 255]))
contents(d, {'images': [{'idiom': 'universal', 'filename': 'idx@2x.png', 'scale': '2x'}]})

def symbol_template():
    guides = []
    groups = []
    for size, base in (('S', 696), ('M', 1126), ('L', 1556)):
        guides.append('<line id="Baseline-%s" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="%d" y2="%d"/>' % (size, base, base))
        guides.append('<line id="Capline-%s" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="%.3f" y2="%.3f"/>' % (size, base - 70.459, base - 70.459))
    for weight, x, r in (('Ultralight', 513.711, 4), ('Regular', 1403.84, 6), ('Black', 2887.4, 9)):
        guides.append('<line id="left-margin-%s-S" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="%s" x2="%s" y1="600.785" y2="720.121"/>' % (weight, x, x))
        guides.append('<line id="right-margin-%s-S" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" x1="%.3f" x2="%.3f" y1="600.785" y2="720.121"/>' % (weight, x + 80, x + 80))
        paths = []
        for i, (cx, cy) in enumerate([(20, -20), (40, -20), (60, -20), (20, -50), (40, -50), (60, -50)]):
            paths.append('<path class="monochrome-%d multicolor-%d:tintColor hierarchical-%d:primary" d="M%d %dm-%d 0a%d %d 0 1 0 %d 0a%d %d 0 1 0 -%d 0z"/>' % (i, i, i, cx, cy, r, r, r, 2 * r, r, r, 2 * r))
        groups.append('<g id="%s-S" transform="matrix(1 0 0 1 %s 696)">%s</g>' % (weight, x, ''.join(paths)))
    styles = '.defaults {-sfsymbols-draw-reverses-motion-groups:true}\n' + ''.join(
        '.monochrome-%d {-sfsymbols-motion-group:%d}\n.multicolor-%d:tintColor {-sfsymbols-motion-group:%d}\n.hierarchical-%d:primary {-sfsymbols-motion-group:%d}\n' % (i, 5 - i, i, 5 - i, i, 5 - i) for i in range(6))
    return ('<?xml version="1.0" encoding="UTF-8"?>\n<svg version="1.1" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 3300 2200">\n'
            '<style>%s</style>\n<g id="Notes"><text id="template-version" transform="matrix(1 0 0 1 3036 1933)">Template v.7.0</text>'
            '<text transform="matrix(1 0 0 1 3036 1951)">Requires Xcode 17 or greater</text><text id="descriptive-name" transform="matrix(1 0 0 1 3036 1969)">Generated from sym</text>'
            '<text transform="matrix(1 0 0 1 3036 1987)">Typeset at 100.0 points</text></g>\n'
            '<g id="Guides">%s</g>\n<g id="Symbols">%s</g>\n</svg>\n') % (styles, ''.join(guides), ''.join(groups))

d = os.path.join(out, 'sym-custom.symbolset')
os.makedirs(d)
open(os.path.join(d, 'sym.svg'), 'w').write(symbol_template())
contents(d, {'symbols': [{'idiom': 'universal', 'filename': 'sym.svg'}]})

# A multi-size app icon with every iPhone/iPad slot, and a single-size one with appearances.
d = os.path.join(out, 'AppIcon.appiconset')
os.makedirs(d)
imgs = []
for idiom, size, scales in [('iphone', 20, (2, 3)), ('iphone', 29, (2, 3)), ('iphone', 40, (2, 3)), ('iphone', 60, (2, 3)),
                            ('ipad', 20, (1, 2)), ('ipad', 29, (1, 2)), ('ipad', 40, (1, 2)), ('ipad', 76, (1, 2)), ('ipad', 83.5, (2,)),
                            ('ios-marketing', 1024, (1,))]:
    for s in scales:
        px = int(size * s)
        fn = 'icon-%s-%s@%dx.png' % (idiom, size, s)
        png(os.path.join(d, fn), px, px, (30, 60, 90), shape=False)
        imgs.append({'idiom': idiom, 'size': ('%gx%g' % (size, size)), 'scale': '%dx' % s, 'filename': fn})
contents(d, {'images': imgs})

d = os.path.join(out, 'AltIcon.appiconset')
os.makedirs(d)
png(os.path.join(d, 'any.png'), 1024, 1024, (200, 30, 30), shape=False)
png(os.path.join(d, 'dark.png'), 1024, 1024, (20, 20, 20), shape=False)
png(os.path.join(d, 'tinted.png'), 1024, 1024, (128, 128, 128), shape=False)
contents(d, {'images': [
    {'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024', 'filename': 'any.png'},
    {'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024', 'filename': 'dark.png', 'appearances': [{'appearance': 'luminosity', 'value': 'dark'}]},
    {'idiom': 'universal', 'platform': 'ios', 'size': '1024x1024', 'filename': 'tinted.png', 'appearances': [{'appearance': 'luminosity', 'value': 'tinted'}]},
]})
print('ok')

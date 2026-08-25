import re
import sys

src_path = sys.argv[1]
dst_path = sys.argv[2]

src = open(src_path, encoding='utf-8').read()
markers = [(m.start(), m.end()) for m in re.finditer(r'/\* \d+ 0x[0-9a-fA-F]{2} ', src)]
data = []
for i, (s, e) in enumerate(markers):
    end = markers[i + 1][0] if i + 1 < len(markers) else len(src)
    chunk = src[e:end]
    vals = re.findall(r'0x([0-9a-fA-F]{2})', chunk)
    if len(vals) >= 8:
        data.append([int(v, 16) for v in vals[:8]])

if len(data) != 256:
    print('ERROR: expected 256 glyphs, got %d' % len(data))
    sys.exit(1)

out = []
out.append('// CP437 8x8 bitmap font (256 glyphs), extracted from the Linux kernel VGA font.')
out.append('// SPDX-License-Identifier: GPL-2.0')
out.append('#ifndef NEXTDOS_FONT8X8_H')
out.append('#define NEXTDOS_FONT8X8_H')
out.append('')
out.append('static const unsigned char font8x8_cp437[256][8] = {')
for i, g in enumerate(data):
    hexs = ', '.join('0x%02x' % v for v in g)
    out.append('    { %s }, /* %3d 0x%02x */' % (hexs, i, i))
out.append('};')
out.append('')
out.append('#endif')
open(dst_path, 'w', encoding='utf-8').write('\n'.join(out) + '\n')
print('wrote %s (%d glyphs)' % (dst_path, len(data)))

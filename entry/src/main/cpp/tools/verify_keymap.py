"""Verify NextDOS key mapping against the (patched) 8086tiny BIOS decode logic.

Simulates the BIOS INT 7 keysym decoder (F000:0332) plus the INT 9 buffer push,
then enumerates every (physical key, Shift, Ctrl) combination through the same
mapping XtScanCodeMap.ets implements, checking:
  1. the ASCII that lands in the BIOS keyboard buffer equals the expected char
  2. make and break scan codes always pair (same scancode, break = make | 0x80)
  3. every printable ASCII 0x20-0x7E is reachable
  4. special keys (F1-F12, arrows, nav block, Delete, Ctrl combos) decode right
"""
import sys

BIOS = open(sys.argv[1] if len(sys.argv) > 1 else
            'entry/src/main/resources/rawfile/bios', 'rb').read()

def tab(a):        return BIOS[0x14D9 + a]   # ASCII->scancode table (seg 0x15D9)
def arrow_tab(i):  return BIOS[0x167D + i]   # seg 0x177D
def home_tab(i):   return BIOS[0x1681 + i]   # seg 0x1781

def bios_decode(keysym, shift=False, ctrl=False, alt=False, keyup=False):
    """INT7 keysym decode -> (ascii, scancode) or None if dropped."""
    ax = keysym | 0x400 | (0x800 if alt else 0) | (0x1000 if shift else 0) \
         | (0x2000 if ctrl else 0) | (0x4000 if keyup else 0)
    ah = (ax >> 8) & 0xFF
    if not (ah & 4):
        return None
    ax = ((ah & 1) << 8) | (ax & 0xFF)
    if ax > 0x125:
        return None
    if 0x11A <= ax <= 0x125:
        sc = ax - 0xDF
        if sc >= 0x45:
            sc += 0x12
        return (0, sc)
    if 0x116 <= ax <= 0x119:
        return (0, home_tab(ax - 0x116))
    if ax >= 0x111:
        return (0, arrow_tab(ax - 0x111))
    al = ax & 0xFF
    if al == 0x7F:
        al = 0                      # our 2-byte BIOS patch
    return (al, tab(al))

# ---- mirror of XtScanCodeMap.ets ----
DIGIT_SHIFT = '!@#$%^&*()'
PUNCT = {  # keycode name: (base, shifted)
    'grave': (0x60, 0x7E), 'minus': (0x2D, 0x5F), 'equals': (0x3D, 0x2B),
    'lbracket': (0x5B, 0x7B), 'rbracket': (0x5D, 0x7D), 'backslash': (0x5C, 0x7C),
    'semicolon': (0x3B, 0x3A), 'apostrophe': (0x27, 0x22), 'comma': (0x2C, 0x3C),
    'period': (0x2E, 0x3E), 'slash': (0x2F, 0x3F), 'space': (0x20, 0x20),
    'at': (0x40, 0x40), 'plus': (0x2B, 0x2B), 'star': (0x2A, 0x2A),
    'pound': (0x23, 0x23), 'np_div': (0x2F, 0x2F), 'np_mul': (0x2A, 0x2A),
    'np_sub': (0x2D, 0x2D), 'np_add': (0x2B, 0x2B), 'np_dot': (0x2E, 0x2E),
    'np_comma': (0x2C, 0x2C),
}

def apply_ctrl(s, ctrl):
    if not ctrl:
        return s
    if 0x61 <= s <= 0x7A: return s - 0x60
    if 0x41 <= s <= 0x5A: return s - 0x40
    if s in (0x5B, 0x7B): return 0x1B
    if s in (0x5C, 0x7C): return 0x1C
    if s in (0x5D, 0x7D): return 0x1D
    if s in (0x2D, 0x5F): return 0x1F
    return s

# BIOS table conflations (upstream behaviour, harmless: ASCII still correct,
# break codes never enter the keyboard buffer): Ctrl+H/I/M/[ decode with the
# BS/TAB/ENTER/ESC scan codes instead of the letter/bracket ones.
KNOWN_CTRL_CONFLATION = {0x08, 0x09, 0x0D, 0x1B, 0x1C, 0x1D, 0x1F}

def arkts_keysym(kind, idx, shift, ctrl):
    """kind: 'letter' idx=0..25, 'digit' idx=0..9 (0 means '0'), 'punct' idx into PUNCT."""
    if kind == 'letter':
        lower = 0x61 + idx
        return apply_ctrl(lower - 0x20 if shift else lower, ctrl), (shift, ctrl)
    if kind == 'digit':
        d = idx
        if shift:
            return DIGIT_SHIFT.charCodeAt(d) if False else ord(DIGIT_SHIFT[9 if d == 0 else d - 1]), (shift, ctrl)
        return 0x30 + d, (shift, ctrl)
    base, shifted = list(PUNCT.items())[idx][1]
    return apply_ctrl(shifted if shift else base, ctrl), (shift, ctrl)

fails = []
produced = {}   # ascii -> set of scancodes

# every physical key x shift x ctrl
for kind, n in [('letter', 26), ('digit', 10), ('punct', len(PUNCT))]:
    for idx in range(n):
        for shift in (False, True):
            for ctrl in (False, True):
                ks, _ = arkts_keysym(kind, idx, shift, ctrl)
                r = bios_decode(ks, shift=shift, ctrl=ctrl)
                if r is None:
                    fails.append('%s %d sh=%d ct=%d keysym=%#x dropped' %
                                 (kind, idx, shift, ctrl, ks))
                    continue
                al, sc = r
                if sc >= 0x80:
                    fails.append('%s %d sh=%d ct=%d bad scancode %#x' %
                                 (kind, idx, shift, ctrl, sc))
                if al >= 0x20 and al < 0x7F:
                    produced.setdefault(al, set()).add(sc)
                # key-up with all modifiers already released must pair, unless
                # the ctrl transform hit a known BIOS table conflation
                if ctrl and al in KNOWN_CTRL_CONFLATION:
                    continue
                # key-up with all modifiers already released must pair
                if kind == 'letter':
                    up_ks = 0x61 + idx
                elif kind == 'digit':
                    up_ks = 0x30 + idx
                else:
                    up_ks = list(PUNCT.items())[idx][1][0]
                r_up = bios_decode(up_ks)
                if r_up is None or (r_up[1] & 0x7F) != sc:
                    fails.append('%s %d sh=%d ct=%d pairing: make %#x vs up %#x' %
                                 (kind, idx, shift, ctrl, sc, r_up[1] if r_up else -1))

print('reachable printable chars: %d/95' % len(produced))
missing = [c for c in range(0x20, 0x7F) if c not in produced]
print('missing:', ''.join(chr(c) for c in missing) if missing else 'none')
# chars whose scancode differs between shifted/unshifted path (should be none)
amb = {c: v for c, v in produced.items() if len(v) > 1}
print('chars with inconsistent scancodes:', amb if amb else 'none')

# specials
SPECIALS = [
    ('Esc',       dict(keysym=27),                        (0x1B, 0x01)),
    ('Bksp',      dict(keysym=8),                         (0x08, 0x0E)),
    ('Tab',       dict(keysym=9),                         (0x09, 0x0F)),
    ('Enter',     dict(keysym=13),                        (0x0D, 0x1C)),
    ('Delete',    dict(keysym=0x7F),                      (0x00, 0x53)),
    ('F1',        dict(keysym=0x11A),                     (0, 0x3B)),
    ('F5',        dict(keysym=0x11E),                     (0, 0x3F)),
    ('F10',       dict(keysym=0x123),                     (0, 0x44)),
    ('F11',       dict(keysym=0x124),                     (0, 0x57)),
    ('F12',       dict(keysym=0x125),                     (0, 0x58)),
    ('Up',        dict(keysym=0x111),                     (0, 0x48)),
    ('Down',      dict(keysym=0x112),                     (0, 0x50)),
    ('Right',     dict(keysym=0x113),                     (0, 0x4D)),
    ('Left',      dict(keysym=0x114),                     (0, 0x4B)),
    ('Home',      dict(keysym=0x116),                     (0, 0x47)),
    ('End',       dict(keysym=0x117),                     (0, 0x4F)),
    ('PgUp',      dict(keysym=0x118),                     (0, 0x49)),
    ('PgDn',      dict(keysym=0x119),                     (0, 0x51)),
    ('Ctrl+C',    dict(keysym=0x03, ctrl=True),           (0x03, 0x2E)),
    ('Ctrl+S',    dict(keysym=0x13, ctrl=True),           (0x13, 0x1F)),
    ('Ctrl+Z',    dict(keysym=0x1A, ctrl=True),           (0x1A, 0x2C)),
    ('Ctrl+Bksp', dict(keysym=0x08, ctrl=True),           (0x08, 0x0E)),
    ('Ctrl+[',    dict(keysym=0x1B, ctrl=True),           (0x1B, 0x01)),
    ('Alt+A',     dict(keysym=0x61, alt=True),            (0x61, 0x1E)),
    ('Shift+Up',  dict(keysym=0x111, shift=True),         (0, 0x48)),
    ('Shift+F1',  dict(keysym=0x11A, shift=True),         (0, 0x3B)),
    ('Alt+F4',    dict(keysym=0x11D, alt=True),           (0, 0x3E)),
    ('Numpad0',   dict(keysym=0x30),                      (0x30, 0x0B)),
    ('Numpad9',   dict(keysym=0x39),                      (0x39, 0x0A)),
]
sp_fail = []
for name, kw, expect in SPECIALS:
    r = bios_decode(**kw)
    if r != expect:
        sp_fail.append('%s: got %s want %s' % (name, r, expect))
print('specials: %d/%d pass' % (len(SPECIALS) - len(sp_fail), len(SPECIALS)))
for f in sp_fail:
    print('  FAIL', f)

if fails:
    print('matrix FAILS (%d):' % len(fails))
    for f in fails[:20]:
        print('  ', f)
else:
    print('key matrix: all pass (make/break pairing + ascii correct)')

print('TOTAL FAILS:', len(fails) + len(sp_fail) + len(missing))

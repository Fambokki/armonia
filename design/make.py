"""Icone di Armonia: SVG disegnati a mano, renderizzati con Chromium a 1024 px."""
import json, math, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SVG_DIR = os.path.join(HERE, "svg")
os.makedirs(SVG_DIR, exist_ok=True)

CX, CY = 426, 694  # centro della testa della nota


def arc(r, a0, a1):
    p = lambda a: (CX + r * math.cos(math.radians(a)), CY + r * math.sin(math.radians(a)))
    (x0, y0), (x1, y1) = p(a0), p(a1)
    large = 1 if abs(a1 - a0) > 180 else 0
    return f"M{x0:.1f} {y0:.1f} A{r} {r} 0 {large} 1 {x1:.1f} {y1:.1f}"


FLAG = "M516 236 C 562 250, 700 300, 722 410 C 736 480, 700 540, 650 574 C 690 510, 688 440, 640 400 C 600 368, 560 360, 538 356 Z"


def mark(fill="#fff", rings="#fff", ring_op=(0.42, 0.2), shadow=True, extra=""):
    """Il simbolo: nota con onde sonore che escono dalla testa."""
    flt = 'filter="url(#sh)"' if shadow else ""
    return f'''
<g transform="translate(36 -22)" {extra}>
  <g fill="none" stroke="{rings}" stroke-linecap="round">
    <path d="{arc(182, 112, 228)}" stroke-width="26" stroke-opacity="{ring_op[0]}"/>
    <path d="{arc(250, 118, 222)}" stroke-width="22" stroke-opacity="{ring_op[1]}"/>
  </g>
  <g fill="{fill}" {flt}>
    <circle cx="{CX}" cy="{CY}" r="118"/>
    <rect x="492" y="232" width="46" height="440" rx="23"/>
    <path d="{FLAG}"/>
  </g>
</g>'''


def mark_outline(color, width):
    return f'''
<g transform="translate(36 -22)" fill="none" stroke="{color}" stroke-width="{width}" stroke-linejoin="round" stroke-linecap="round">
  <circle cx="{CX}" cy="{CY}" r="112"/>
  <path d="M515 590 V 244"/>
  <path d="{FLAG}"/>
  <path d="{arc(182, 112, 228)}"/>
  <path d="{arc(250, 118, 222)}" stroke-opacity=".6"/>
</g>'''


COMMON_DEFS = '''
<filter id="sh" x="-30%" y="-30%" width="160%" height="160%">
  <feDropShadow dx="0" dy="22" stdDeviation="26" flood-color="#000" flood-opacity=".28"/>
</filter>
<filter id="grain" x="0" y="0" width="100%" height="100%">
  <feTurbulence type="fractalNoise" baseFrequency=".85" numOctaves="2" stitchTiles="stitch"/>
  <feColorMatrix values="0 0 0 0 .5  0 0 0 0 .5  0 0 0 0 .5  0 0 0 .55 0"/>
</filter>
<filter id="blur120" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="120"/></filter>
<filter id="blur60" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="60"/></filter>
<filter id="blur24" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="24"/></filter>
<filter id="blur10" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="10"/></filter>
<radialGradient id="shine" cx="22%" cy="12%" r="80%">
  <stop offset="0" stop-color="#fff" stop-opacity=".34"/><stop offset=".55" stop-color="#fff" stop-opacity="0"/>
</radialGradient>
<radialGradient id="vign" cx="50%" cy="45%" r="75%">
  <stop offset=".6" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity=".35"/>
</radialGradient>
'''

GRAIN = '<rect width="1024" height="1024" filter="url(#grain)" opacity=".35" style="mix-blend-mode:overlay"/>'


def svg(defs, body, grain=True):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>{COMMON_DEFS}{defs}</defs>{body}{GRAIN if grain else ""}</svg>'''


ICONS = {}

# 1. Classica — magenta/viola con luce dall'alto
ICONS["AppIcon"] = svg('''
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#ff3b6b"/><stop offset=".5" stop-color="#d21f9b"/><stop offset="1" stop-color="#5b2bd9"/>
</linearGradient>''', f'''
<rect width="1024" height="1024" fill="url(#bg)"/>
<circle cx="860" cy="900" r="420" fill="#3a1fb0" opacity=".55" filter="url(#blur120)"/>
<circle cx="140" cy="120" r="380" fill="#ff7a59" opacity=".5" filter="url(#blur120)"/>
<rect width="1024" height="1024" fill="url(#shine)"/>
{mark()}''')

# 2. Aurora — notte con aurora boreale
ICONS["AppIcon-Aurora"] = svg('''
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#050816"/><stop offset="1" stop-color="#0b0f2a"/></linearGradient>''', f'''
<rect width="1024" height="1024" fill="url(#bg)"/>
<g filter="url(#blur120)">
  <ellipse cx="260" cy="260" rx="380" ry="230" fill="#00e5b0" opacity=".85" transform="rotate(-25 260 260)"/>
  <ellipse cx="780" cy="420" rx="340" ry="260" fill="#6a3cff" opacity=".9"/>
  <ellipse cx="520" cy="900" rx="420" ry="220" fill="#ff3d8b" opacity=".7"/>
</g>
<rect width="1024" height="1024" fill="url(#vign)"/>
{mark(ring_op=(.5, .25))}''')

# 3. Tramonto — sole, cielo caldo e righe retrò
sun_lines = "".join(f'<rect x="0" y="{700 + i*44 + i*i*2}" width="1024" height="{10 + i*3}" fill="#3a1458" opacity=".9"/>' for i in range(7))
ICONS["AppIcon-Tramonto"] = svg('''
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#ffd27a"/><stop offset=".45" stop-color="#ff7a59"/><stop offset=".8" stop-color="#c2306e"/><stop offset="1" stop-color="#3a1458"/>
</linearGradient>
<linearGradient id="sun" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff4c2"/><stop offset="1" stop-color="#ff9a5a"/></linearGradient>
<clipPath id="sunclip"><circle cx="512" cy="560" r="330"/></clipPath>''', f'''
<rect width="1024" height="1024" fill="url(#bg)"/>
<circle cx="512" cy="560" r="360" fill="#ffd27a" opacity=".45" filter="url(#blur60)"/>
<g clip-path="url(#sunclip)"><rect width="1024" height="1024" fill="url(#sun)" opacity=".75"/>{sun_lines}</g>
{mark(fill="#fff8ef", rings="#fff8ef")}''')

# 4. Oceano — profondità blu con onde di vetro
ICONS["AppIcon-Oceano"] = svg('''
<radialGradient id="bg" cx="50%" cy="10%" r="100%"><stop offset="0" stop-color="#2fd0ff"/><stop offset=".55" stop-color="#0a6fd6"/><stop offset="1" stop-color="#06205e"/></radialGradient>''', f'''
<rect width="1024" height="1024" fill="url(#bg)"/>
<path d="M0 760 C 200 700, 360 820, 540 770 S 860 690, 1024 740 V1024 H0Z" fill="#fff" opacity=".10"/>
<path d="M0 840 C 220 790, 380 900, 580 850 S 880 780, 1024 830 V1024 H0Z" fill="#fff" opacity=".10"/>
<path d="M0 920 C 240 880, 420 970, 620 930 S 900 880, 1024 910 V1024 H0Z" fill="#fff" opacity=".12"/>
<rect width="1024" height="1024" fill="url(#shine)"/>
{mark()}''')

# 5. Notte — nero profondo, simbolo in sfumatura calda luminosa
ICONS["AppIcon-Notte"] = svg('''
<radialGradient id="bg" cx="50%" cy="40%" r="80%"><stop offset="0" stop-color="#1c1426"/><stop offset="1" stop-color="#050507"/></radialGradient>
<linearGradient id="gl" x1="0" y1="1" x2="1" y2="0"><stop offset="0" stop-color="#ff3b6b"/><stop offset=".6" stop-color="#ff7a59"/><stop offset="1" stop-color="#ffc46b"/></linearGradient>''', f'''
<rect width="1024" height="1024" fill="url(#bg)"/>
<g filter="url(#blur60)" opacity=".75">{mark(fill="url(#gl)", rings="#ff6b6b", shadow=False)}</g>
{mark(fill="url(#gl)", rings="#ff8a6b", ring_op=(.7, .35), shadow=False)}''')

# 6. Vetro — vetro smerigliato sopra macchie di colore
blobs = '''
<circle cx="250" cy="260" r="260" fill="#ff3b6b"/>
<circle cx="800" cy="300" r="240" fill="#ffb84d"/>
<circle cx="720" cy="820" r="300" fill="#5b2bd9"/>
<circle cx="220" cy="820" r="230" fill="#00c2ff"/>'''
ICONS["AppIcon-Vetro"] = svg('''
<clipPath id="card"><rect x="182" y="182" width="660" height="660" rx="150"/></clipPath>
<linearGradient id="edge" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".9"/><stop offset=".5" stop-color="#fff" stop-opacity=".15"/><stop offset="1" stop-color="#fff" stop-opacity=".5"/></linearGradient>''', f'''
<rect width="1024" height="1024" fill="#1a1030"/>
<g filter="url(#blur60)">{blobs}</g>
<g clip-path="url(#card)"><g filter="url(#blur120)">{blobs}</g><rect width="1024" height="1024" fill="#fff" opacity=".22"/></g>
<rect x="182" y="182" width="660" height="660" rx="150" fill="none" stroke="url(#edge)" stroke-width="5"/>
<g transform="translate(512 512) scale(.62) translate(-512 -512)">{mark(ring_op=(.55, .3))}</g>''')

# 7. Vinile — disco con solchi e riflessi
grooves = "".join(f'<circle cx="512" cy="512" r="{r}" fill="none" stroke="#fff" stroke-opacity="{.05 if i%3 else .09}" stroke-width="3"/>' for i, r in enumerate(range(200, 405, 9)))
ICONS["AppIcon-Vinile"] = svg('''
<radialGradient id="bg" cx="50%" cy="30%" r="90%"><stop offset="0" stop-color="#2a2433"/><stop offset="1" stop-color="#0b0a0e"/></radialGradient>
<radialGradient id="disc" cx="50%" cy="50%" r="50%"><stop offset="0" stop-color="#1b1b1f"/><stop offset="1" stop-color="#0d0d10"/></radialGradient>
<linearGradient id="lab" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ff3b6b"/><stop offset="1" stop-color="#5b2bd9"/></linearGradient>
<linearGradient id="sheen" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset=".5" stop-color="#fff" stop-opacity=".22"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
<clipPath id="dc"><circle cx="512" cy="512" r="420"/></clipPath>''', f'''
<rect width="1024" height="1024" fill="url(#bg)"/>
<circle cx="512" cy="540" r="420" fill="#000" opacity=".5" filter="url(#blur60)"/>
<circle cx="512" cy="512" r="420" fill="url(#disc)"/>
{grooves}
<g clip-path="url(#dc)">
  <path d="M512 512 L 90 160 A 560 560 0 0 1 300 70 Z" fill="url(#sheen)" opacity=".9"/>
  <path d="M512 512 L 934 864 A 560 560 0 0 1 724 954 Z" fill="url(#sheen)" opacity=".6"/>
</g>
<circle cx="512" cy="512" r="170" fill="url(#lab)"/>
<circle cx="512" cy="512" r="170" fill="url(#shine)"/>
<g transform="translate(512 512) scale(.28) translate(-512 -512)">{mark(shadow=False, ring_op=(.6, .35))}</g>
<circle cx="512" cy="512" r="14" fill="#0b0a0e"/>''')

# 8. Onda — equalizzatore luminoso con riflesso
heights = [150, 260, 380, 300, 460, 340, 230, 140]
bw, gap = 64, 30
x0 = 512 - (len(heights) * bw + (len(heights) - 1) * gap) / 2
bars = refl = ""
for i, h in enumerate(heights):
    x = x0 + i * (bw + gap)
    bars += f'<rect x="{x:.0f}" y="{600 - h}" width="{bw}" height="{h}" rx="32" fill="url(#bar)"/>'
    refl += f'<rect x="{x:.0f}" y="624" width="{bw}" height="{h*0.45:.0f}" rx="32" fill="url(#bar)"/>'
ICONS["AppIcon-Onda"] = svg('''
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1d0f3a"/><stop offset="1" stop-color="#07040f"/></linearGradient>
<linearGradient id="bar" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#5b2bd9"/><stop offset=".5" stop-color="#ff3b8b"/><stop offset="1" stop-color="#ffb36b"/></linearGradient>
<linearGradient id="fade" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".35"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient>
<mask id="rm"><rect x="0" y="624" width="1024" height="260" fill="url(#fade)"/></mask>''', f'''
<rect width="1024" height="1024" fill="url(#bg)"/>
<ellipse cx="512" cy="520" rx="380" ry="260" fill="#ff3b8b" opacity=".35" filter="url(#blur120)"/>
<g filter="url(#blur24)" opacity=".6">{bars}</g>
{bars}
<g mask="url(#rm)">{refl}</g>''')

# 9. Neon — tubo al neon su griglia scura
grid = "".join(f'<path d="M{x} 1024 L 512 620" stroke="#ff3df0" stroke-opacity=".18" stroke-width="3"/>' for x in range(-600, 1700, 160))
grid += "".join(f'<path d="M0 {y} H1024" stroke="#ff3df0" stroke-opacity="{.06 + i*.03:.2f}" stroke-width="3"/>' for i, y in enumerate([680, 720, 780, 860, 960]))
ICONS["AppIcon-Neon"] = svg('''
<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#0d0620"/><stop offset="1" stop-color="#160a2e"/></linearGradient>''', f'''
<rect width="1024" height="1024" fill="url(#bg)"/>
{grid}
<g filter="url(#blur24)">{mark_outline("#ff3df0", 40)}</g>
<g filter="url(#blur10)">{mark_outline("#ff7af5", 22)}</g>
{mark_outline("#ffe6ff", 10)}''', grain=True)

# 10. Carta — carta avorio, inchiostro e un tocco di colore
ICONS["AppIcon-Carta"] = svg('''
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#faf6ee"/><stop offset="1" stop-color="#ece4d4"/></linearGradient>
<filter id="soft" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="14" stdDeviation="18" flood-color="#6b5a3a" flood-opacity=".22"/></filter>''', f'''
<rect width="1024" height="1024" fill="url(#bg)"/>
<g transform="translate(36 -22)">
  <g fill="none" stroke="#1b1b1f" stroke-linecap="round">
    <path d="{arc(182, 112, 228)}" stroke-width="26" stroke-opacity=".22"/>
    <path d="{arc(250, 118, 222)}" stroke-width="22" stroke-opacity=".1"/>
  </g>
  <g filter="url(#soft)">
    <rect x="492" y="232" width="46" height="440" rx="23" fill="#1b1b1f"/>
    <path d="{FLAG}" fill="#1b1b1f"/>
    <circle cx="{CX}" cy="{CY}" r="118" fill="#ff4d5e"/>
  </g>
</g>''')

# 11. Oro — oro spazzolato su nero
ICONS["AppIcon-Oro"] = svg('''
<radialGradient id="bg" cx="50%" cy="35%" r="85%"><stop offset="0" stop-color="#2a2318"/><stop offset="1" stop-color="#070605"/></radialGradient>
<linearGradient id="gold" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#fff1b8"/><stop offset=".3" stop-color="#e8bf5a"/><stop offset=".55" stop-color="#a87424"/><stop offset=".75" stop-color="#f3d27a"/><stop offset="1" stop-color="#8a5d1c"/>
</linearGradient>''', f'''
<rect width="1024" height="1024" fill="url(#bg)"/>
<circle cx="512" cy="480" r="340" fill="#c9973b" opacity=".18" filter="url(#blur120)"/>
{mark(fill="url(#gold)", rings="#e8bf5a", ring_op=(.55, .25))}''')

# 12. Menta — pastello fresco
ICONS["AppIcon-Menta"] = svg('''
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#e3fff1"/><stop offset=".55" stop-color="#9ff0c9"/><stop offset="1" stop-color="#4fcf9f"/></linearGradient>
<filter id="soft" x="-30%" y="-30%" width="160%" height="160%"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#0b4a37" flood-opacity=".25"/></filter>''', f'''
<rect width="1024" height="1024" fill="url(#bg)"/>
<circle cx="860" cy="160" r="300" fill="#fff" opacity=".55" filter="url(#blur120)"/>
<g transform="translate(36 -22)">
  <g fill="none" stroke="#0f5a43" stroke-linecap="round">
    <path d="{arc(182, 112, 228)}" stroke-width="26" stroke-opacity=".3"/>
    <path d="{arc(250, 118, 222)}" stroke-width="22" stroke-opacity=".15"/>
  </g>
  <g fill="#0f5a43" filter="url(#soft)">
    <circle cx="{CX}" cy="{CY}" r="118"/>
    <rect x="492" y="232" width="46" height="440" rx="23"/>
    <path d="{FLAG}"/>
  </g>
</g>''')

for name, content in ICONS.items():
    open(os.path.join(SVG_DIR, name + ".svg"), "w").write(content)
json.dump(list(ICONS.keys()), open(os.path.join(SVG_DIR, "names.json"), "w"))
print(len(ICONS), "svg")

"""UNO Glass brand assets — single source of truth.

Writes every logo / icon / marketing SVG from shared components:
    python tools/gen_branding.py          # SVGs into branding/ and client/branding/
    python tools/gen_branding.py --ico    # pack branding/png/icon-*.png into icon.ico
PNG renders are made by tools/render_branding.gd (Godot, headless).
"""
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "branding")
GAME = os.path.join(ROOT, "client", "branding")

# ---------------------------------------------------------------- palette
RUBY = "#FF4D6D"
AMBER = "#FFC23D"
JADE = "#22C983"
AZURE = "#3D8BFF"
VIOLET = "#8B6CFF"
MIDNIGHT = "#0B0D22"
INDIGO = "#2A1B5E"
NIGHT = "#161624"
PALETTE = [
    ("Ruby", RUBY, "Red cards, alerts, energy"),
    ("Amber", AMBER, "Yellow cards, highlights, UNO calls"),
    ("Jade", JADE, "Green cards, success"),
    ("Azure", AZURE, "Blue cards, links, calm"),
    ("Violet", VIOLET, "Primary accent, buttons, XP"),
    ("Midnight", MIDNIGHT, "Backgrounds"),
    ("Indigo", INDIGO, "Background gradients"),
    ("Frost", "#FFFFFF", "Glass at 6–30% opacity, text"),
]


def lighten(hex_color, amt):
    h = hex_color.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) for i in (0, 2, 4))
    r, g, b = (int(c + (255 - c) * amt) for c in (r, g, b))
    return "#%02X%02X%02X" % (r, g, b)


def darken(hex_color, amt):
    h = hex_color.lstrip("#")
    r, g, b = (int(int(h[i:i + 2], 16) * (1 - amt)) for i in (0, 2, 4))
    return "#%02X%02X%02X" % (r, g, b)


# ---------------------------------------------------------------- components

def defs_tile(uid):
    return f"""
  <linearGradient id="{uid}bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="{INDIGO}"/><stop offset="1" stop-color="{MIDNIGHT}"/>
  </linearGradient>
  <radialGradient id="{uid}gr"><stop offset="0" stop-color="{RUBY}" stop-opacity="0.75"/><stop offset="1" stop-color="{RUBY}" stop-opacity="0"/></radialGradient>
  <radialGradient id="{uid}gb"><stop offset="0" stop-color="{AZURE}" stop-opacity="0.8"/><stop offset="1" stop-color="{AZURE}" stop-opacity="0"/></radialGradient>
  <radialGradient id="{uid}gg"><stop offset="0" stop-color="{JADE}" stop-opacity="0.45"/><stop offset="1" stop-color="{JADE}" stop-opacity="0"/></radialGradient>
  <clipPath id="{uid}clip"><rect x="16" y="16" width="480" height="480" rx="112"/></clipPath>
  <linearGradient id="{uid}gloss" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
  </linearGradient>"""


def card(x, y, w, h, color, angle, px, py, face=None, shadow=True):
    """A rounded UNO card rotated by angle around (px, py)."""
    r = w * 0.16
    bw = w * 0.07
    s = f'<g transform="rotate({angle} {px} {py})">'
    if shadow:
        s += f'<rect x="{x + w * 0.04}" y="{y + h * 0.05}" width="{w}" height="{h}" rx="{r}" fill="#000" fill-opacity="0.28"/>'
    s += f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{color}" stroke="#FFFFFF" stroke-width="{bw}"/>'
    cx, cy = x + w / 2, y + h / 2
    # glossy diagonal sheen
    s += (f'<path d="M {x + bw} {y + r} Q {x + bw} {y + bw} {x + r} {y + bw} L {x + w - bw * 1.5} {y + bw} '
          f'L {x + bw} {y + h * 0.55} Z" fill="#FFFFFF" fill-opacity="0.12"/>')
    if face == "oval":
        s += f'<ellipse cx="{cx}" cy="{cy}" rx="{w * 0.30}" ry="{h * 0.33}" transform="rotate(-24 {cx} {cy})" fill="#FFFFFF"/>'
    elif face == "U":
        s += f'<ellipse cx="{cx}" cy="{cy}" rx="{w * 0.30}" ry="{h * 0.33}" transform="rotate(-24 {cx} {cy})" fill="#FFFFFF"/>'
        k = w / 118
        s += (f'<path d="M {cx - 22 * k} {cy - 34 * k} V {cy + 4 * k} A {22 * k} {22 * k} 0 0 0 {cx + 22 * k} {cy + 4 * k} '
              f'V {cy - 34 * k}" fill="none" stroke="{color}" stroke-width="{17 * k}" stroke-linecap="round" stroke-linejoin="round"/>')
    s += "</g>"
    return s


def fan(cx, cy, size=1.0, faces=True):
    """Four cards fanned around a pivot below (cx, cy) — the brand emblem."""
    w, h = 140 * size, 210 * size
    px, py = cx, cy + 165 * size
    out = ""
    for color, ang in ((RUBY, -27), (AMBER, -9), (JADE, 9), (AZURE, 27)):
        face = "U" if (faces and color == AZURE) else None
        out += card(cx - w / 2, cy - h / 2, w, h, color, ang, px, py, face)
    return out


def emblem_svg(tile=True, size=512):
    uid = "e"
    body = ""
    if tile:
        body += f"""
  <rect x="16" y="16" width="480" height="480" rx="112" fill="url(#{uid}bg)"/>
  <g clip-path="url(#{uid}clip)">
  <circle cx="120" cy="110" r="270" fill="url(#{uid}gr)"/>
  <circle cx="430" cy="440" r="280" fill="url(#{uid}gb)"/>
  <circle cx="420" cy="120" r="190" fill="url(#{uid}gg)"/>
  </g>
  <rect x="16" y="16" width="480" height="480" rx="112" fill="url(#{uid}gloss)"/>
  <rect x="17.5" y="17.5" width="477" height="477" rx="110.5" fill="none" stroke="#FFFFFF" stroke-opacity="0.32" stroke-width="3"/>"""
    body += fan(256, 238, 1.0)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 512 512">
<defs>{defs_tile(uid)}
</defs>{body}
</svg>
"""


# Wordmark: "UNO" as glossy glass tubes + a blue card "dot", "GLASS" monoline.
UNO_LETTERS = [
    ("M 80 70 V 190 A 75 75 0 0 0 230 190 V 70", RUBY),
    ("M 330 270 V 70 L 480 270 V 70", AMBER),
    ("M 655 70 A 95 100 0 1 1 654.9 70 Z", JADE),
]
GLASS_LETTERS = [
    "M 332 318 A 17 22 0 1 0 334 340 H 320",
    "M 376 310 V 354 H 404",
    "M 446 354 L 463 310 L 480 354 M 453 339 H 473",
    "M 550 316 C 544 309 524 308 522 320 C 520 332 552 330 552 344 C 552 357 528 357 520 348",
    "M 624 316 C 618 309 598 308 596 320 C 594 332 626 330 626 344 C 626 357 602 357 594 348",
]


def wordmark_group(mono=None, subtitle=True, sub_color="#FFFFFF"):
    """mono: None for full color, or a single hex color."""
    g = ""
    for d, col in UNO_LETTERS:
        c = mono or col
        g += f'<path d="{d}" fill="none" stroke="#000" stroke-opacity="0.25" stroke-width="74" stroke-linecap="round" stroke-linejoin="round" transform="translate(0 9)"/>'
        g += f'<path d="{d}" fill="none" stroke="{c}" stroke-width="70" stroke-linecap="round" stroke-linejoin="round"/>'
        if not mono:
            g += f'<path d="{d}" fill="none" stroke="{lighten(col, 0.28)}" stroke-opacity="0.55" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/>'
            g += f'<path d="{d}" fill="none" stroke="#FFFFFF" stroke-opacity="0.55" stroke-width="9" stroke-linecap="round" stroke-linejoin="round" transform="translate(-9 -11)"/>'
    # the blue card dot
    if mono:
        g += (f'<g transform="rotate(14 845 205)"><rect x="800" y="140" width="90" height="130" rx="15" fill="{mono}"/>'
              f'</g>')
    else:
        g += card(800, 140, 90, 130, AZURE, 14, 845, 205, "oval")
    if subtitle:
        for d in GLASS_LETTERS:
            g += f'<path d="{d}" transform="translate(30 34)" fill="none" stroke="{sub_color}" stroke-opacity="0.88" stroke-width="9" stroke-linecap="round" stroke-linejoin="round"/>'
    return g


def wordmark_svg(mono=None, subtitle=True, sub_color="#FFFFFF"):
    h = 410 if subtitle else 300
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="{h}" viewBox="0 0 1000 {h}">
{wordmark_group(mono, subtitle, sub_color)}
</svg>
"""


def background(w, h, uid="b", intensity=1.0):
    return f"""<defs>
  <linearGradient id="{uid}bg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#090A1A"/><stop offset="1" stop-color="#170B29"/>
  </linearGradient>
  <radialGradient id="{uid}r"><stop offset="0" stop-color="{RUBY}" stop-opacity="{0.55 * intensity}"/><stop offset="1" stop-color="{RUBY}" stop-opacity="0"/></radialGradient>
  <radialGradient id="{uid}b2"><stop offset="0" stop-color="{AZURE}" stop-opacity="{0.6 * intensity}"/><stop offset="1" stop-color="{AZURE}" stop-opacity="0"/></radialGradient>
  <radialGradient id="{uid}g"><stop offset="0" stop-color="{JADE}" stop-opacity="{0.4 * intensity}"/><stop offset="1" stop-color="{JADE}" stop-opacity="0"/></radialGradient>
  <radialGradient id="{uid}y"><stop offset="0" stop-color="{AMBER}" stop-opacity="{0.35 * intensity}"/><stop offset="1" stop-color="{AMBER}" stop-opacity="0"/></radialGradient>
  <radialGradient id="{uid}v"><stop offset="0" stop-color="{VIOLET}" stop-opacity="{0.35 * intensity}"/><stop offset="1" stop-color="{VIOLET}" stop-opacity="0"/></radialGradient>
  <radialGradient id="{uid}vig"><stop offset="0.55" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity="0.55"/></radialGradient>
</defs>
<rect width="{w}" height="{h}" fill="url(#{uid}bg)"/>
<ellipse cx="{w * 0.18}" cy="{h * 0.25}" rx="{w * 0.42}" ry="{h * 0.62}" fill="url(#{uid}r)"/>
<ellipse cx="{w * 0.84}" cy="{h * 0.22}" rx="{w * 0.40}" ry="{h * 0.60}" fill="url(#{uid}b2)"/>
<ellipse cx="{w * 0.72}" cy="{h * 0.88}" rx="{w * 0.42}" ry="{h * 0.55}" fill="url(#{uid}g)"/>
<ellipse cx="{w * 0.25}" cy="{h * 0.92}" rx="{w * 0.36}" ry="{h * 0.45}" fill="url(#{uid}y)"/>
<ellipse cx="{w * 0.5}" cy="{h * 0.5}" rx="{w * 0.45}" ry="{h * 0.5}" fill="url(#{uid}v)"/>
<ellipse cx="{w * 0.5}" cy="{h * 0.5}" rx="{w * 0.75}" ry="{h * 0.8}" fill="url(#{uid}vig)"/>"""


def glass_panel(x, y, w, h, r=28):
    return (f'<rect x="{x}" y="{y + 10}" width="{w}" height="{h}" rx="{r}" fill="#000" fill-opacity="0.25"/>'
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="#FFFFFF" fill-opacity="0.09"/>'
            f'<rect x="{x}" y="{y}" width="{w}" height="{h * 0.5}" rx="{r}" fill="#FFFFFF" fill-opacity="0.04"/>'
            f'<rect x="{x + 0.75}" y="{y + 0.75}" width="{w - 1.5}" height="{h - 1.5}" rx="{r}" fill="none" stroke="#FFFFFF" stroke-opacity="0.3" stroke-width="1.5"/>')


def scatter_cards(w, h, seed=3, n=9, alpha=0.5):
    import random
    rnd = random.Random(seed)
    colors = [RUBY, AMBER, JADE, AZURE, NIGHT]
    s = f'<g opacity="{alpha}">'
    for i in range(n):
        x = rnd.uniform(-0.05, 0.95) * w
        y = rnd.uniform(-0.1, 0.9) * h
        sz = rnd.uniform(0.5, 0.9) * h / 900
        cw, ch = 140 * sz, 210 * sz
        # keep the center clear
        if abs(x + cw / 2 - w / 2) < w * 0.36 and abs(y + ch / 2 - h / 2) < h * 0.46:
            continue
        col = colors[i % len(colors)]
        s += card(x, y, cw, ch, col, rnd.uniform(-40, 40), x + cw / 2, y + ch / 2, "oval" if col != NIGHT else None)
    return s + "</g>"


def lockup_horizontal(mono=None, sub_color="#FFFFFF"):
    """Emblem + wordmark side by side, 1600x512."""
    emb = emblem_svg(True).split(">", 1)[1].rsplit("</svg>", 1)[0]
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="512" viewBox="0 0 1600 512">
<g>{emb}</g>
<g transform="translate(580 55) scale(1.0)">{wordmark_group(mono, True, sub_color)}</g>
</svg>
"""


def lockup_stacked(sub_color="#FFFFFF"):
    emb = fan(500, 230, 1.15)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="900" viewBox="0 0 1000 900">
{emb}
<g transform="translate(40 470) scale(0.95)">{wordmark_group(None, True, sub_color)}</g>
</svg>
"""


def poster(w, h, uid, scale=1.0, cards=True, with_panel=False):
    """Background + centered emblem fan + wordmark — splash, social, capsules."""
    k = min(w / 1600, h / 900) * scale
    body = background(w, h, uid)
    if cards:
        body += scatter_cards(w, h, seed=w + h, n=12, alpha=0.35)
    if with_panel:
        pw, ph = 1100 * k, 640 * k
        body += glass_panel(w / 2 - pw / 2, h / 2 - ph / 2 - 10 * k, pw, ph, 40 * k)
    # Keep in sync with client/scripts/loading_screen.gd _layout().
    body += f'<g transform="translate({w / 2} {h / 2 - 175 * k}) scale({k * 0.78}) translate(-256 -238)">{fan(256, 238, 1.0)}</g>'
    body += f'<g transform="translate({w / 2 - 490 * k * 0.8} {h / 2 - 5 * k}) scale({k * 0.8})">{wordmark_group()}</g>'
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">\n{body}\n</svg>\n'


def installer_side(w=328, h=628):
    """Tall wizard image (Inno Setup WizardImageFile, 164x314 @2x)."""
    body = background(w, h, "is", 1.2)
    body += f'<g transform="translate({w / 2} {h * 0.34}) scale(0.5) translate(-256 -238)">{fan(256, 238, 1.0)}</g>'
    body += f'<g transform="translate({w / 2 - 490 * 0.3} {h * 0.62}) scale(0.3)">{wordmark_group()}</g>'
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">\n{body}\n</svg>\n'


def installer_back(w=1200, h=900):
    """Soft aurora behind the wizard pages (WizardBackImageFile)."""
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">\n{background(w, h, "ib", 0.55)}\n</svg>\n'


def brand_board():
    """A guidelines board (uses SVG text — view in a browser / on GitHub)."""
    w, h = 1800, 1200
    s = background(w, h, "bb", 0.8)
    font = "font-family=\"Inter, 'Segoe UI', Helvetica, Arial, sans-serif\""
    s += f'<text x="80" y="110" {font} font-size="56" font-weight="800" fill="#fff">UNO Glass — Brand board</text>'
    s += f'<text x="80" y="155" {font} font-size="22" fill="#fff" fill-opacity="0.65">Frosted glass, four bright cards, deep night backgrounds. Playful, clean, modern.</text>'
    # logo panel
    s += glass_panel(80, 200, 1000, 470, 36)
    s += f'<g transform="translate(120 260) scale(0.62)">{emblem_svg(True).split(">", 1)[1].rsplit("</svg>", 1)[0]}</g>'
    s += f'<g transform="translate(470 330) scale(0.58)">{wordmark_group()}</g>'
    s += f'<text x="120" y="640" {font} font-size="18" fill="#fff" fill-opacity="0.6">Primary lockup · emblem + wordmark · clear space = height of the blue card dot</text>'
    # app icon sizes
    s += glass_panel(1120, 200, 600, 470, 36)
    x = 1160
    for size in (256, 128, 64, 32):
        sc = size / 512
        s += f'<g transform="translate({x} {300 + (256 - size) / 2}) scale({sc})">{emblem_svg(True).split(">", 1)[1].rsplit("</svg>", 1)[0]}</g>'
        s += f'<text x="{x + size / 2}" y="600" text-anchor="middle" {font} font-size="16" fill="#fff" fill-opacity="0.6">{size}px</text>'
        x += size + 28
    s += f'<text x="1160" y="250" {font} font-size="24" font-weight="700" fill="#fff">App icon</text>'
    # palette
    s += f'<text x="80" y="740" {font} font-size="28" font-weight="800" fill="#fff">Palette</text>'
    x = 80
    for name, col, use in PALETTE:
        s += f'<rect x="{x}" y="770" width="190" height="150" rx="22" fill="{col}" fill-opacity="{0.2 if name == "Frost" else 1}" stroke="#fff" stroke-opacity="0.3"/>'
        s += f'<text x="{x + 14}" y="950" {font} font-size="20" font-weight="700" fill="#fff">{name}</text>'
        s += f'<text x="{x + 14}" y="976" {font} font-size="16" fill="#fff" fill-opacity="0.7">{col}</text>'
        s += f'<text x="{x + 14}" y="1000" {font} font-size="13" fill="#fff" fill-opacity="0.5">{use}</text>'
        x += 205
    # type + glass recipe
    s += glass_panel(80, 1030, 1640, 120, 28)
    s += f'<text x="120" y="1080" {font} font-size="30" font-weight="800" fill="#fff">Inter / Segoe UI — Heavy 800 for titles, 500 for body</text>'
    s += f'<text x="120" y="1122" {font} font-size="18" fill="#fff" fill-opacity="0.65">Glass: white 6–12% fill · 30% white 1.5px rim (brighter at top) · background blur · soft 25% black shadow · 22–28px corners</text>'
    return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">\n{s}\n</svg>\n'


# ---------------------------------------------------------------- outputs

def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf8", newline="\n") as f:
        f.write(text)
    print("wrote", os.path.relpath(path, ROOT))


def build_svgs():
    files = {
        "emblem.svg": emblem_svg(True),
        "emblem-transparent.svg": emblem_svg(False),
        "wordmark.svg": wordmark_svg(),
        "wordmark-white.svg": wordmark_svg(mono="#FFFFFF"),
        "wordmark-dark.svg": wordmark_svg(mono=MIDNIGHT, sub_color=MIDNIGHT),
        "lockup-horizontal.svg": lockup_horizontal(),
        "lockup-stacked.svg": lockup_stacked(),
        "lockup-horizontal-light.svg": lockup_horizontal(sub_color=MIDNIGHT),
        "lockup-stacked-light.svg": lockup_stacked(sub_color=MIDNIGHT),
        "wordmark-light.svg": wordmark_svg(sub_color=MIDNIGHT),
        "splash.svg": poster(1600, 900, "sp", 1.0, cards=False),
        "social-preview.svg": poster(1280, 640, "so", 1.0, cards=True),
        "key-art-1920x1080.svg": poster(1920, 1080, "ka", 1.0, cards=True, with_panel=True),
        "capsule-630x500.svg": poster(630, 500, "c1", 1.45, cards=True),
        "capsule-460x215.svg": poster(460, 215, "c2", 1.25, cards=False),
        "brand-board.svg": brand_board(),
        "installer-side.svg": installer_side(),
        "installer-back.svg": installer_back(),
    }
    for name, svg in files.items():
        write(os.path.join(OUT, "svg", name), svg)
    # assets the game uses
    write(os.path.join(GAME, "emblem.svg"), files["emblem.svg"])
    write(os.path.join(GAME, "emblem-transparent.svg"), files["emblem-transparent.svg"])
    write(os.path.join(GAME, "wordmark.svg"), files["wordmark.svg"])
    write(os.path.join(ROOT, "client", "icon.svg"), files["emblem.svg"])


def build_ico():
    """Packs PNG renders into a multi-size Windows .ico (PNG-compressed entries)."""
    sizes = [16, 24, 32, 48, 64, 128, 256]
    images = []
    for s in sizes:
        with open(os.path.join(OUT, "png", f"icon-{s}.png"), "rb") as f:
            images.append((s, f.read()))
    header = struct.pack("<HHH", 0, 1, len(images))
    offset = 6 + 16 * len(images)
    entries, blobs = b"", b""
    for s, data in images:
        entries += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(data), offset)
        blobs += data
        offset += len(data)
    ico = header + entries + blobs
    for path in (os.path.join(OUT, "icon.ico"), os.path.join(GAME, "icon.ico")):
        with open(path, "wb") as f:
            f.write(ico)
        print("wrote", os.path.relpath(path, ROOT))


if __name__ == "__main__":
    if "--ico" in sys.argv:
        build_ico()
    else:
        build_svgs()

"""Synthesizes every sound effect and music loop for UNO Glass.

Pure Python (no dependencies). Run from the repo root:
    python tools/gen_audio.py
Outputs WAV files into client/audio/sfx and client/audio/music.
"""
import math
import os
import random
import struct
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SFX_DIR = os.path.join(ROOT, "client", "audio", "sfx")
MUSIC_DIR = os.path.join(ROOT, "client", "audio", "music")
SR = 44100
MUSIC_SR = 22050
TAU = math.tau
rng = random.Random(1337)


def note(n):
    """MIDI note number -> Hz."""
    return 440.0 * 2 ** ((n - 69) / 12)


def write(path, buf, sr):
    peak = max(1e-9, max(abs(x) for x in buf))
    gain = min(1.0, 0.92 / peak)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, x * gain)) * 32767)) for x in buf))


def osc(kind, phase):
    p = phase % 1.0
    if kind == "sine":
        return math.sin(TAU * p)
    if kind == "tri":
        return 4 * abs(p - 0.5) - 1
    if kind == "saw":
        return 2 * p - 1
    if kind == "square":
        return 1.0 if p < 0.5 else -1.0
    if kind == "soft":  # sine with a little 2nd/3rd harmonic
        return math.sin(TAU * p) * 0.8 + math.sin(2 * TAU * p) * 0.15 + math.sin(3 * TAU * p) * 0.05
    return 0.0


def env(t, dur, a, d, s, r):
    if t < a:
        return t / a if a > 0 else 1
    if t < a + d:
        return 1 - (1 - s) * (t - a) / d
    if t < dur - r:
        return s
    if t < dur:
        return s * max(0.0, (dur - t) / r) if r > 0 else 0
    return 0.0


def tone(buf, sr, start, dur, f0, f1=None, kind="sine", amp=0.5, a=0.005, d=0.05, s=0.6, r=0.05,
         vib=0.0, lp=None, detune=0.0, wrap=False):
    """Adds a (optionally swept) tone into buf. lp = one-pole lowpass cutoff in Hz."""
    f1 = f0 if f1 is None else f1
    n = int(dur * sr)
    i0 = int(start * sr)
    ph = rng.random()
    ph2 = rng.random()
    y = 0.0
    k = 1 - math.exp(-TAU * lp / sr) if lp else 1.0
    for i in range(n):
        t = i / sr
        f = f0 + (f1 - f0) * (t / dur)
        if vib:
            f *= 1 + vib * math.sin(TAU * 5.5 * t)
        ph += f / sr
        v = osc(kind, ph)
        if detune:
            ph2 += f * (1 + detune) / sr
            v = (v + osc(kind, ph2)) * 0.5
        y += k * (v - y)
        j = i0 + i
        if wrap:
            j %= len(buf)
        elif j >= len(buf):
            break
        buf[j] += y * amp * env(t, dur, a, d, s, r)


def noise(buf, sr, start, dur, amp=0.3, a=0.002, d=0.05, s=0.0, r=0.02, lp=None, hp=None, lp_end=None, wrap=False):
    n = int(dur * sr)
    i0 = int(start * sr)
    y = 0.0
    yh = 0.0
    prev = 0.0
    for i in range(n):
        t = i / sr
        x = rng.uniform(-1, 1)
        if lp:
            cut = lp if lp_end is None else lp + (lp_end - lp) * t / dur
            k = 1 - math.exp(-TAU * cut / sr)
            y += k * (x - y)
            x = y
        if hp:
            a_hp = math.exp(-TAU * hp / sr)
            yh = a_hp * (yh + x - prev)
            prev = x
            x = yh
        j = i0 + i
        if wrap:
            j %= len(buf)
        elif j >= len(buf):
            break
        buf[j] += x * amp * env(t, dur, a, d, s, r)


def blank(seconds, sr=SR):
    return [0.0] * int(seconds * sr)


# ----------------------------------------------------------------- sfx

def sfx():
    os.makedirs(SFX_DIR, exist_ok=True)
    out = {}

    b = blank(0.06)
    tone(b, SR, 0, 0.05, 1900, 1500, "sine", 0.6, 0.001, 0.02, 0.0, 0.01)
    noise(b, SR, 0, 0.01, 0.15, lp=6000)
    out["click"] = b

    b = blank(0.04)
    tone(b, SR, 0, 0.03, 2600, 2400, "sine", 0.25, 0.001, 0.015, 0.0, 0.01)
    out["hover"] = b

    b = blank(0.16)
    noise(b, SR, 0, 0.09, 0.5, 0.005, 0.07, 0.0, 0.02, lp=1500, lp_end=6500, hp=300)
    tone(b, SR, 0.07, 0.07, 260, 180, "sine", 0.7, 0.001, 0.05, 0.0, 0.02)
    noise(b, SR, 0.07, 0.02, 0.35, lp=3500)
    out["card_play"] = b

    b = blank(0.2)
    noise(b, SR, 0, 0.17, 0.45, 0.01, 0.15, 0.0, 0.02, lp=4500, lp_end=1200, hp=200)
    out["card_draw"] = b

    b = blank(0.9)
    for k in range(10):
        noise(b, SR, k * 0.075 + rng.uniform(0, 0.02), 0.05, 0.4, 0.002, 0.04, 0.0, 0.01, lp=5000, hp=500)
    out["shuffle"] = b

    b = blank(0.9)
    for f, amp in ((note(81), 0.5), (note(88), 0.25), (note(93), 0.12)):
        tone(b, SR, 0, 0.85, f, kind="sine", amp=amp, a=0.002, d=0.6, s=0.0, r=0.2)
    out["turn"] = b

    b = blank(1.0)
    for i, n in enumerate((84, 88, 91, 96)):
        tone(b, SR, i * 0.06, 0.7, note(n), kind="soft", amp=0.45, a=0.003, d=0.5, s=0.1, r=0.2)
        tone(b, SR, i * 0.06, 0.5, note(n + 12), kind="sine", amp=0.15, a=0.003, d=0.3, s=0.0, r=0.1)
    out["uno"] = b

    b = blank(0.6)
    for i in range(2):
        tone(b, SR, i * 0.22, 0.1, 740, kind="square", amp=0.2, a=0.003, d=0.05, s=0.6, r=0.03, lp=2500)
        tone(b, SR, i * 0.22 + 0.1, 0.1, 494, kind="square", amp=0.2, a=0.003, d=0.05, s=0.6, r=0.03, lp=2500)
    out["catch"] = b

    b = blank(0.2)
    tone(b, SR, 0, 0.16, 950, 280, "tri", 0.5, 0.002, 0.1, 0.3, 0.04)
    out["skip"] = b

    b = blank(0.35)
    tone(b, SR, 0, 0.15, 450, 1100, "tri", 0.45, 0.005, 0.1, 0.6, 0.02)
    tone(b, SR, 0.15, 0.17, 1100, 420, "tri", 0.45, 0.002, 0.1, 0.5, 0.05)
    out["reverse"] = b

    b = blank(0.5)
    tone(b, SR, 0, 0.3, 150, 45, "sine", 0.9, 0.002, 0.25, 0.0, 0.05)
    noise(b, SR, 0, 0.12, 0.4, lp=2500)
    tone(b, SR, 0.05, 0.4, 300, 900, "saw", 0.12, 0.05, 0.3, 0.3, 0.05, lp=1800)
    out["plus2"] = b

    b = blank(0.8)
    tone(b, SR, 0, 0.45, 120, 35, "sine", 1.0, 0.002, 0.4, 0.0, 0.05)
    noise(b, SR, 0, 0.2, 0.5, lp=3000)
    for i, f in enumerate((220, 277, 330, 440)):
        tone(b, SR, 0.08 + i * 0.07, 0.3, f, f * 1.02, "saw", 0.1, 0.01, 0.2, 0.2, 0.08, lp=2200)
    out["plus4"] = b

    b = blank(2.2)
    seq = (72, 76, 79, 84)
    for i, n in enumerate(seq):
        tone(b, SR, i * 0.12, 0.3, note(n), kind="tri", amp=0.4, a=0.005, d=0.15, s=0.4, r=0.1)
    for n in (72, 76, 79, 84, 88):
        tone(b, SR, 0.5, 1.6, note(n), kind="soft", amp=0.22, a=0.02, d=0.6, s=0.35, r=0.6, vib=0.003)
    for k in range(14):
        tone(b, SR, 0.5 + k * 0.08, 0.25, note(96 + rng.choice((0, 4, 7, 12))), kind="sine", amp=0.08, a=0.002, d=0.2, s=0.0, r=0.05)
    out["win"] = b

    b = blank(1.3)
    for i, n in enumerate((67, 65, 62, 60)):
        tone(b, SR, i * 0.2, 0.45 if i < 3 else 0.9, note(n), kind="tri", amp=0.35, a=0.01, d=0.2, s=0.4, r=0.2, lp=2000)
    out["lose"] = b

    b = blank(1.6)
    for i, n in enumerate((72, 76, 79, 84, 88, 91, 96)):
        tone(b, SR, i * 0.07, 0.6, note(n), kind="soft", amp=0.35, a=0.002, d=0.4, s=0.1, r=0.15)
    noise(b, SR, 0.4, 1.0, 0.08, 0.2, 0.6, 0.0, 0.2, hp=6000)
    out["level_up"] = b

    b = blank(0.35)
    tone(b, SR, 0, 0.12, 150, kind="square", amp=0.25, a=0.003, d=0.05, s=0.6, r=0.03, lp=900)
    tone(b, SR, 0.16, 0.14, 120, kind="square", amp=0.25, a=0.003, d=0.05, s=0.6, r=0.04, lp=900)
    out["error"] = b

    b = blank(0.12)
    tone(b, SR, 0, 0.04, 1300, kind="sine", amp=0.4, a=0.001, d=0.03, s=0.0, r=0.01)
    tone(b, SR, 0.05, 0.05, 1750, kind="sine", amp=0.4, a=0.001, d=0.03, s=0.0, r=0.01)
    out["toggle"] = b

    b = blank(0.1)
    tone(b, SR, 0, 0.08, 380, 980, "sine", 0.6, 0.002, 0.05, 0.2, 0.02)
    out["pop"] = b

    b = blank(0.06)
    tone(b, SR, 0, 0.04, 1250, 1100, "tri", 0.5, 0.001, 0.03, 0.0, 0.01)
    noise(b, SR, 0, 0.008, 0.2, hp=3000)
    out["tick"] = b

    b = blank(1.0)
    for i, n in enumerate((88, 95, 100)):
        tone(b, SR, i * 0.09, 0.7, note(n), kind="sine", amp=0.35, a=0.002, d=0.5, s=0.0, r=0.2)
    out["star"] = b

    b = blank(0.5)
    tone(b, SR, 0, 0.45, 520, 780, "soft", 0.35, 0.01, 0.2, 0.4, 0.15)
    tone(b, SR, 0.06, 0.4, 780, 1040, "sine", 0.2, 0.01, 0.2, 0.3, 0.15)
    out["notify"] = b

    for name, buf in out.items():
        write(os.path.join(SFX_DIR, name + ".wav"), buf, SR)
        print("sfx", name)


# ----------------------------------------------------------------- music

def kick(buf, sr, t, amp=0.8, wrap=True):
    tone(buf, sr, t, 0.28, 110, 42, "sine", amp, 0.001, 0.22, 0.0, 0.05, wrap=wrap)


def snare(buf, sr, t, amp=0.35, wrap=True):
    noise(buf, sr, t, 0.16, amp, 0.001, 0.12, 0.0, 0.03, lp=5000, hp=900, wrap=wrap)
    tone(buf, sr, t, 0.08, 220, 170, "tri", amp * 0.6, 0.001, 0.06, 0.0, 0.02, wrap=wrap)


def hat(buf, sr, t, amp=0.12, wrap=True):
    noise(buf, sr, t, 0.04, amp, 0.001, 0.03, 0.0, 0.01, hp=7000, wrap=wrap)


def menu_track():
    """Calm lo-fi loop: Fmaj7 - Em7 - Dm7 - Cmaj7 at 78 BPM, 16 bars."""
    bpm = 78
    beat = 60 / bpm
    bar = beat * 4
    bars = 16
    buf = blank(bar * bars, MUSIC_SR)
    chords = [(53, 57, 60, 64), (52, 55, 59, 62), (50, 53, 57, 60), (48, 52, 55, 59)]
    for bi in range(bars):
        ch = chords[(bi // 2) % 4]
        t0 = bi * bar
        if bi % 2 == 0:
            for n in ch:
                tone(buf, MUSIC_SR, t0, bar * 2 + 0.6, note(n), kind="tri", amp=0.11, a=0.6, d=0.8, s=0.7, r=0.9,
                     lp=1100, detune=0.004, wrap=True)
            tone(buf, MUSIC_SR, t0, bar * 2, note(ch[0] - 12), kind="sine", amp=0.22, a=0.05, d=0.5, s=0.6, r=0.4, wrap=True)
        # electric-piano arpeggio, 8ths with gentle swing
        pattern = [0, 2, 1, 3, 2, 1, 3, 2] if bi % 4 < 2 else [3, 2, 0, 1, 2, 3, 1, 0]
        for k in range(8):
            if rng.random() < 0.18:
                continue
            swing = 0.06 * beat if k % 2 else 0
            n = ch[pattern[k]] + 12
            tone(buf, MUSIC_SR, t0 + k * beat / 2 + swing, 0.9, note(n), kind="soft", amp=0.07 + rng.uniform(0, 0.03),
                 a=0.004, d=0.5, s=0.15, r=0.3, wrap=True)
        # soft drums
        kick(buf, MUSIC_SR, t0, 0.5)
        kick(buf, MUSIC_SR, t0 + beat * 2.5, 0.35)
        snare(buf, MUSIC_SR, t0 + beat, 0.12)
        snare(buf, MUSIC_SR, t0 + beat * 3, 0.12)
        for k in range(8):
            hat(buf, MUSIC_SR, t0 + k * beat / 2 + (0.06 * beat if k % 2 else 0), 0.05 if k % 2 else 0.035)
    # vinyl crackle
    for _ in range(int(len(buf) / MUSIC_SR * 6)):
        noise(buf, MUSIC_SR, rng.uniform(0, len(buf) / MUSIC_SR), 0.004, 0.04, 0.0005, 0.003, 0.0, 0.001, hp=2000, wrap=True)
    return buf


def game_track():
    """Upbeat synth-pop loop: Am - F - C - G at 112 BPM, 16 bars."""
    bpm = 112
    beat = 60 / bpm
    bar = beat * 4
    bars = 16
    buf = blank(bar * bars, MUSIC_SR)
    chords = [(57, 60, 64), (53, 57, 60), (48, 52, 55), (55, 59, 62)]
    for bi in range(bars):
        ch = chords[bi % 4]
        t0 = bi * bar
        section = bi // 4  # 0 intro-ish, 1-3 fuller
        for n in ch:
            tone(buf, MUSIC_SR, t0, bar + 0.2, note(n), kind="saw", amp=0.045, a=0.08, d=0.3, s=0.7, r=0.25,
                 lp=1400, detune=0.006, wrap=True)
        # bass: root on 8ths with octave pops
        for k in range(8):
            n = ch[0] - 24 + (12 if k in (3, 7) else 0)
            tone(buf, MUSIC_SR, t0 + k * beat / 2, beat / 2 * 0.9, note(n), kind="square", amp=0.13, a=0.003, d=0.1,
                 s=0.5, r=0.03, lp=700, wrap=True)
        # pluck arpeggio, 16ths
        if section >= 1:
            arp = [0, 1, 2, 1, 2, 0, 1, 2]
            for k in range(16):
                n = ch[arp[k % 8]] + 12 + (12 if k % 8 == 6 and section >= 2 else 0)
                tone(buf, MUSIC_SR, t0 + k * beat / 4, 0.18, note(n), kind="tri", amp=0.06, a=0.002, d=0.12, s=0.0,
                     r=0.04, lp=3500, wrap=True)
        # lead hook in the last section
        if section == 3:
            hook = [(0, 76), (1.5, 74), (2, 72), (3, 74)]
            for off, n in hook:
                tone(buf, MUSIC_SR, t0 + off * beat, beat * 0.9, note(n + (-3 if bi % 4 == 1 else 0)), kind="soft",
                     amp=0.09, a=0.01, d=0.2, s=0.5, r=0.1, vib=0.004, wrap=True)
        # drums
        for k in range(4):
            kick(buf, MUSIC_SR, t0 + k * beat, 0.6)
        if section >= 1:
            snare(buf, MUSIC_SR, t0 + beat, 0.22)
            snare(buf, MUSIC_SR, t0 + beat * 3, 0.22)
        for k in range(8):
            hat(buf, MUSIC_SR, t0 + k * beat / 2 + beat / 4 * 0, 0.06 if k % 2 else 0.03)
    return buf


def music():
    os.makedirs(MUSIC_DIR, exist_ok=True)
    write(os.path.join(MUSIC_DIR, "menu.wav"), menu_track(), MUSIC_SR)
    print("music menu")
    write(os.path.join(MUSIC_DIR, "game.wav"), game_track(), MUSIC_SR)
    print("music game")


if __name__ == "__main__":
    sfx()
    music()

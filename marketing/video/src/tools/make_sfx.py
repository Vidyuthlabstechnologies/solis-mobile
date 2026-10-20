"""Synthesized UI sound effects (no samples): whoosh, tap, pop, chime, alert,
stamp, tick, scan. Writes one stereo stem with every event placed.

python make_sfx.py <timeline.json> <out.wav>
"""
import json
import sys
import wave

import numpy as np

SR = 44100
rng = np.random.default_rng(11)


def t_(d):
    return np.arange(int(d * SR)) / SR


def bandnoise(d, lo, hi):
    n = int(d * SR)
    X = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / SR)
    X[(f < lo) | (f > hi)] = 0
    x = np.fft.irfft(X, n)
    return x / (np.abs(x).max() + 1e-9)


def whoosh(d=0.55):
    t = t_(d)
    # noise through a sweeping band: crossfade 3 bands for a cheap sweep
    a, b, c = bandnoise(d, 300, 1200), bandnoise(d, 1200, 4000), bandnoise(d, 4000, 9000)
    p = t / d
    x = a * (1 - p) + b * (1 - abs(p - 0.5) * 2) + c * p
    env = np.sin(np.pi * p) ** 1.6
    return x * env * 0.5


def tap():
    t = t_(0.09)
    return (np.sin(2 * np.pi * 1800 * t) * np.exp(-t / 0.012) * 0.5 + bandnoise(0.09, 2000, 8000) * np.exp(-t / 0.004) * 0.3)


def pop(f=880):
    t = t_(0.18)
    fr = f * (1 + 0.6 * np.exp(-t / 0.02))
    return np.sin(2 * np.pi * np.cumsum(fr) / SR) * np.exp(-t / 0.05) * 0.45


def chime():
    t = t_(1.2)
    x = np.zeros_like(t)
    for f, dl, g in ((1046.5, 0.0, 0.5), (1318.5, 0.08, 0.4), (1568.0, 0.16, 0.35)):
        tt = np.clip(t - dl, 0, None)
        x += (t >= dl) * g * (np.sin(2 * np.pi * f * tt) + 0.2 * np.sin(4 * np.pi * f * tt)) * np.exp(-tt / 0.35)
    return x * 0.5


def alert():
    t = t_(0.5)
    x = np.zeros_like(t)
    for f, dl in ((440, 0.0), (349.2, 0.16)):
        tt = np.clip(t - dl, 0, None)
        x += (t >= dl) * np.sign(np.sin(2 * np.pi * f * tt)) * 0.18 * np.exp(-tt / 0.09)
    x = np.convolve(x, np.ones(12) / 12, mode="same")  # soften the square
    return x * 1.4


def stamp():
    t = t_(0.45)
    thud = np.sin(2 * np.pi * np.cumsum(70 + 90 * np.exp(-t / 0.03)) / SR) * np.exp(-t / 0.12)
    slap = bandnoise(0.45, 400, 3500) * np.exp(-t / 0.03)
    return (thud * 0.9 + slap * 0.5) * 0.8


def tick():
    t = t_(0.06)
    return bandnoise(0.06, 3000, 9000) * np.exp(-t / 0.006) * 0.5


def scan():
    d = 0.6
    t = t_(d)
    f = 600 + 1400 * (t / d)
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.sin(np.pi * t / d) * 0.18


KIND = {"whoosh": whoosh, "tap": tap, "pop": pop, "pop2": lambda: pop(1175), "chime": chime,
        "alert": alert, "stamp": stamp, "tick": tick, "scan": scan}

if __name__ == "__main__":
    tl = json.load(open(sys.argv[1]))
    n = int(tl["length"] * SR)
    L = np.zeros(n)
    R = np.zeros(n)
    for t0, kind, *rest in tl["sfx"]:
        g = rest[0] if rest else 1.0
        pan = rest[1] if len(rest) > 1 else 0.0
        x = KIND[kind]() * g
        i = int(t0 * SR)
        j = min(n, i + len(x))
        L[i:j] += x[: j - i] * (1 - max(0, pan))
        R[i:j] += x[: j - i] * (1 + min(0, pan))
    st = np.stack([L, R], 1)
    st = np.clip(st, -1, 1)
    with wave.open(sys.argv[2], "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((st * 32767).astype(np.int16).tobytes())
    print("wrote", sys.argv[2])

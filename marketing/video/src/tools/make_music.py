"""SOLIS launch bed: a fully synthesized, original electronic-pop track.

Every sound is generated here from sine/saw/noise with numpy, so the track has
no third-party samples or recordings and no license strings attached.

Usage:
  python make_music.py <out.wav> <json-arrangement>

Arrangement JSON (seconds):
  {"length": 80, "drop": 13.4, "break": [31.0, 46.0], "hit": 74.2,
   "intro_soft": true}
"""
import json
import sys
import wave

import numpy as np

SR = 44100
BPM = 116.0
BEAT = 60.0 / BPM
STEP = BEAT / 4  # 16th note

rng = np.random.default_rng(7)  # fixed seed: same track every run


def midi_hz(m):
    return 440.0 * 2 ** ((m - 69) / 12.0)


def fft_filter(x, lo=None, hi=None, slope=4.0):
    """Smooth band filter in the frequency domain (whole-buffer)."""
    n = len(x)
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(n, 1 / SR)
    g = np.ones_like(f)
    if hi is not None:
        g *= 1.0 / (1.0 + (f / hi) ** (2 * slope))
    if lo is not None:
        g *= 1.0 / (1.0 + (lo / np.maximum(f, 1e-3)) ** (2 * slope))
    return np.fft.irfft(X * g, n)


def env_adsr(n, a, d, s, r, sus_len):
    a_n, d_n, r_n = int(a * SR), int(d * SR), int(r * SR)
    s_n = max(0, int(sus_len * SR) - a_n - d_n)
    e = np.concatenate([
        np.linspace(0, 1, max(a_n, 1)),
        np.linspace(1, s, max(d_n, 1)),
        np.full(s_n, s),
        np.linspace(s, 0, max(r_n, 1)),
    ])
    if len(e) < n:
        e = np.concatenate([e, np.zeros(n - len(e))])
    return e[:n]


def additive(freq, dur, harmonics=12, bright_decay=None, detune=0.0, odd_only=False):
    """Band-limited saw-ish tone. bright_decay (s) makes upper partials die
    faster, which is what gives a pluck its 'filter sweep' sound."""
    n = int(dur * SR)
    t = np.arange(n) / SR
    out = np.zeros(n)
    for k in range(1, harmonics + 1):
        if odd_only and k % 2 == 0:
            continue
        fk = freq * k * (1 + detune)
        if fk > SR / 2.2:
            break
        amp = 1.0 / k
        if bright_decay is not None:
            amp = amp * np.exp(-t * (k - 1) / bright_decay)
        out += amp * np.sin(2 * np.pi * fk * t + k * 0.37)
    return out


def place(buf, sig, t0, gain=1.0):
    i = int(round(t0 * SR))
    if i >= len(buf):
        return
    if i < 0:  # starts before 0: keep only the audible tail
        sig = sig[-i:]
        i = 0
        if len(sig) == 0:
            return
    j = min(len(buf), i + len(sig))
    buf[i:j] += sig[: j - i] * gain


def kick():
    n = int(0.42 * SR)
    t = np.arange(n) / SR
    f = 48 + 110 * np.exp(-t / 0.035)
    ph = 2 * np.pi * np.cumsum(f) / SR
    body = np.sin(ph) * np.exp(-t / 0.16)
    click = rng.standard_normal(n) * np.exp(-t / 0.004) * 0.25
    return np.tanh(1.6 * (body + click)) * 0.9


def clap():
    n = int(0.3 * SR)
    t = np.arange(n) / SR
    noise = rng.standard_normal(n)
    e = np.zeros(n)
    for off in (0.0, 0.011, 0.022):
        tt = np.clip(t - off, 0, None)
        e += (t >= off) * np.exp(-tt / 0.012)
    e += (t >= 0.03) * np.exp(-np.clip(t - 0.03, 0, None) / 0.09) * 0.8
    sig = fft_filter(noise * e, lo=900, hi=5200, slope=2)
    tone = np.sin(2 * np.pi * 190 * t) * np.exp(-t / 0.05) * 0.3
    return (sig / (np.abs(sig).max() + 1e-9) + tone) * 0.55


def hat(open_=False):
    dur = 0.22 if open_ else 0.06
    n = int(dur * SR)
    t = np.arange(n) / SR
    sig = fft_filter(rng.standard_normal(n), lo=7000, slope=3)
    sig *= np.exp(-t / (0.07 if open_ else 0.014))
    return sig / (np.abs(sig).max() + 1e-9) * (0.22 if open_ else 0.2)


# I - V - vi - IV in D major: D, A, Bm, G (one chord per bar)
CHORDS = [
    (50, [62, 66, 69, 74]),  # D
    (45, [61, 64, 69, 73]),  # A
    (47, [62, 66, 71, 74]),  # Bm
    (43, [62, 67, 71, 74]),  # G
]


def build(arr):
    L = float(arr["length"])
    drop = float(arr["drop"])
    brk = arr.get("break") or [L + 1, L + 2]
    hit = float(arr["hit"])
    n = int(L * SR) + SR
    stems = {k: np.zeros(n) for k in ("kick", "clap", "hat", "bass", "pluck", "padL", "padR", "fx")}
    K, C, H, Ho = kick(), clap(), hat(False), hat(True)

    bar = 4 * BEAT
    # Align the downbeat grid so a bar starts exactly at the drop.
    grid0 = drop - np.ceil(drop / bar) * bar
    bars = int(np.ceil((L - grid0) / bar)) + 1
    kick_times = []
    for b in range(bars):
        t_bar = grid0 + b * bar
        if t_bar > L:
            break
        root, notes = CHORDS[b % 4]
        in_break = brk[0] <= t_bar < brk[1]
        after_drop = t_bar >= drop - 1e-6
        near_hit = hit - 2 * bar <= t_bar < hit  # riser bars: thin out
        post_hit = t_bar >= hit - 1e-6

        # Pad: always, softer in the intro
        pad_gain = 0.10 if not after_drop else 0.075
        for m in notes:
            for side, det in (("padL", -0.004), ("padR", 0.004)):
                tone = additive(midi_hz(m - 12), bar + 0.6, harmonics=10, detune=det)
                tone *= env_adsr(len(tone), 0.35, 0.4, 0.8, 0.6, bar)
                place(stems[side], tone, t_bar, pad_gain)

        if t_bar + bar < 0:
            continue

        for s in range(16):
            ts = t_bar + s * STEP
            if ts < 0 or ts > L:
                continue
            beat_i, sub = divmod(s, 4)
            # Intro (before the drop): a soft heartbeat pluck only, every beat
            if not after_drop:
                if sub == 0 and ts > 0.2:
                    m = notes[(beat_i + b) % 4] + 12
                    p = additive(midi_hz(m), 0.6, harmonics=14, bright_decay=0.05)
                    p *= np.exp(-np.arange(len(p)) / SR / 0.25)
                    place(stems["pluck"], p, ts, 0.10)
                continue
            if post_hit:
                continue
            # Drums
            if sub == 0 and not (near_hit and beat_i in (1, 3)):
                place(stems["kick"], K, ts, 1.0 if not in_break else 0.55)
                kick_times.append(ts)
            if sub == 0 and beat_i in (1, 3) and not in_break and not near_hit:
                place(stems["clap"], C, ts, 1.0)
            if sub == 2:
                place(stems["hat"], Ho, ts, 0.8 if not in_break else 0.4)
            elif not in_break:
                place(stems["hat"], H, ts, 0.55 if sub != 0 else 0.35)
            # Bass: offbeat 8ths, octave jump on the last 8th of the bar
            if sub == 2 or (s == 14):
                m = root + (12 if s == 14 else 0)
                bl = additive(midi_hz(m - 12), STEP * 2, harmonics=8, bright_decay=0.08)
                bl *= env_adsr(len(bl), 0.004, 0.08, 0.7, 0.03, STEP * 1.8)
                place(stems["bass"], bl, ts, 0.55 if not in_break else 0.35)
            # Pluck arp, 16ths, pattern up-down over the chord
            pat = [0, 1, 2, 3, 2, 1, 2, 3]
            if (s % 2 == 0) or not in_break:
                m = notes[pat[s % 8]] + 12
                p = additive(midi_hz(m), 0.4, harmonics=16, bright_decay=0.035)
                p *= np.exp(-np.arange(len(p)) / SR / 0.13)
                place(stems["pluck"], p, ts, 0.075 if not in_break else 0.05)

    # Riser into the CTA hit: rising noise + sine sweep over 2 bars
    r_len = 2 * bar
    r0 = hit - r_len
    nr = int(r_len * SR)
    t = np.arange(nr) / SR
    sweep = np.sin(2 * np.pi * np.cumsum(200 + 1400 * (t / r_len) ** 2) / SR)
    noise = fft_filter(rng.standard_normal(nr), lo=1500, hi=9000, slope=1)
    noise /= np.abs(noise).max()
    riser = (0.6 * noise + 0.25 * sweep) * (t / r_len) ** 2.2
    place(stems["fx"], riser, r0, 0.35)
    # CTA hit: full chord + kick + long reverb-ish tail
    root, notes = CHORDS[0]
    hit_sig = np.zeros(int(5.5 * SR))
    for m in notes + [root, root + 12]:
        tone = additive(midi_hz(m), 5.5, harmonics=14, bright_decay=0.9)
        tone *= np.exp(-np.arange(len(tone)) / SR / 1.6)
        hit_sig += tone
    hit_sig /= np.abs(hit_sig).max()
    place(stems["fx"], hit_sig, hit, 0.32)
    place(stems["kick"], K, hit, 1.1)
    # Sparkle tail after the hit: slow plucks
    for i, m in enumerate([74, 78, 81, 86]):
        p = additive(midi_hz(m), 1.2, harmonics=10, bright_decay=0.12)
        p *= np.exp(-np.arange(len(p)) / SR / 0.5)
        place(stems["pluck"], p, hit + 0.5 + i * BEAT, 0.07)

    # Sidechain pump on pad + bass from the kick grid
    pump = np.ones(n)
    for kt in kick_times:
        i = int(kt * SR)
        m = int(0.28 * SR)
        seg = 1 - 0.6 * np.exp(-np.arange(m) / SR / 0.07)
        j = min(n, i + m)
        pump[i:j] = np.minimum(pump[i:j], seg[: j - i])
    for k in ("bass", "padL", "padR"):
        stems[k] *= pump

    # Gentle tone shaping
    stems["padL"] = fft_filter(stems["padL"], hi=2600, slope=2)
    stems["padR"] = fft_filter(stems["padR"], hi=2600, slope=2)
    stems["bass"] = fft_filter(stems["bass"], hi=900, slope=2)

    mono = stems["kick"] * 0.9 + stems["clap"] * 0.5 + stems["bass"] * 0.9 + stems["fx"]
    left = mono + stems["padL"] + stems["hat"] * 0.8 + stems["pluck"] * 1.1
    right = mono + stems["padR"] + stems["hat"] * 1.0 + stems["pluck"] * 0.9
    # Simple stereo echo on the pluck (dotted 8th)
    d = int(BEAT * 0.75 * SR)
    echo = np.zeros(n)
    echo[d:] = stems["pluck"][:-d] * 0.35
    left += echo * 0.5
    right[d // 2:] += echo[: n - d // 2] * 0.7
    # Fades
    fade_in = int(0.4 * SR)
    for ch in (left, right):
        ch[:fade_in] *= np.linspace(0, 1, fade_in)
    end = int(L * SR)
    fo = int(1.2 * SR)
    for ch in (left, right):
        ch[end - fo:end] *= np.linspace(1, 0, fo)
        ch[end:] = 0
    st = np.stack([left[:end], right[:end]], axis=1)
    st = np.tanh(st / (np.abs(st).max() + 1e-9) * 1.2) * 0.9
    return st


def write_wav(path, st):
    data = (np.clip(st, -1, 1) * 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())


if __name__ == "__main__":
    out, arr = sys.argv[1], json.loads(sys.argv[2])
    write_wav(out, build(arr))
    print("wrote", out)

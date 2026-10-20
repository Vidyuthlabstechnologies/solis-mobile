"""Turn the Parakeet word timings (hyperframes transcribe) + the written script
into caption data for the compositions.

The ASR timings drive *when* each word shows; the script supplies the exact
spelling (e.g. ASR hears "Soles" for SOLIS, "940" for nine forty).

python build_data.py <timeline.json> <transcript.words.json> <out.js>
"""
import json
import os
import re
import sys

ASR_OFFSET = 0.12  # Parakeet onsets land ~0.1-0.25 s early on this TTS

tl = json.load(open(sys.argv[1]))
asr = json.load(open(sys.argv[2]))
out = sys.argv[3]
here = os.path.dirname(os.path.abspath(__file__))
lines = {}
speaker = {}
for row in open(os.path.join(here, "..", "data", "lines.tsv"), encoding="utf-8"):
    lid, voice, text = row.rstrip("\n").split("\t")
    lines[lid] = text
    speaker[lid] = "doctor" if voice == "am_michael" else ("patient" if voice == "af_bella" else "narrator")

# Display spellings for words the TTS needed spelled out
DISPLAY = {
    "nine forty": "9:40",
    "a hundred and one point five": "101.5",
}

dur_cache = {}


def line_dur(lid):
    import wave
    p = os.path.join(here, "..", "assets", "audio", "trim", lid + ".wav")
    with wave.open(p) as w:
        return w.getnframes() / w.getframerate()


words_out = []
starts = [t for _, t in tl["lines"]]
for idx, (lid, t0) in enumerate(tl["lines"]):
    t1 = t0 + line_dur(lid)
    text = lines[lid]
    for k, v in DISPLAY.items():
        text = text.replace(k, v)
    toks = text.split()
    win = [w for w in asr if t0 - 0.45 <= w["start"] < t1 + 0.1]
    if len(win) == len(toks):
        times = [(w["start"] + ASR_OFFSET, w["end"] + ASR_OFFSET) for w in win]
    else:
        # Fall back: spread the ASR span proportionally to word length
        a = (win[0]["start"] + ASR_OFFSET) if win else t0
        b = (win[-1]["end"] + ASR_OFFSET) if win else t1
        wts = [len(re.sub(r"\W", "", x)) + 1 for x in toks]
        tot = sum(wts)
        times, c = [], a
        for wt in wts:
            d = (b - a) * wt / tot
            times.append((c, c + d))
            c += d
        print(f"  {lid}: {len(toks)} script words vs {len(win)} asr words -> proportional", file=sys.stderr)
    for tok, (s, e) in zip(toks, times):
        s = max(s, t0 - 0.05)
        words_out.append({"w": tok, "s": round(s, 3), "e": round(min(e, t1 + 0.1), 3), "line": lid, "spk": speaker[lid]})

# Caption groups: break on sentence punctuation, speaker change, or 6 words
sentences, cur = [], []
for w in words_out:
    if cur and (w["line"] != cur[-1]["line"] or re.search(r"[.?!]$", cur[-1]["w"])):
        sentences.append(cur)
        cur = []
    cur.append(w)
if cur:
    sentences.append(cur)
groups = []
for sen in sentences:
    n = len(sen)
    if n <= 7:
        groups.append(sen)
        continue
    k = -(-n // 6)  # number of chunks
    # prefer to cut after a comma near the balanced point
    size = n / k
    cuts, last = [], 0
    for c in range(1, k):
        target = round(c * size)
        best = target
        for d in (0, 1, -1, 2, -2):
            j = target + d
            if last + 2 <= j <= n - 2 and re.search(r",$", sen[j - 1]["w"]):
                best = j
                break
        cuts.append(best)
        last = best
    prev = 0
    for c in cuts + [n]:
        groups.append(sen[prev:c])
        prev = c
caps = []
for gi, g in enumerate(groups):
    s = g[0]["s"] - 0.08
    nxt = groups[gi + 1][0]["s"] - 0.08 if gi + 1 < len(groups) else g[-1]["e"] + 0.8
    e = min(g[-1]["e"] + 0.7, nxt) if g[-1]["line"] == (groups[gi + 1][0]["line"] if gi + 1 < len(groups) else None) else min(g[-1]["e"] + 0.5, nxt)
    caps.append({"s": round(s, 3), "e": round(e, 3), "spk": g[0]["spk"], "words": [{"w": x["w"], "s": x["s"]} for x in g]})

data = {"lines": [{"id": l, "t": t, "d": round(line_dur(l), 3), "spk": speaker[l]} for l, t in tl["lines"]],
        "words": words_out, "captions": caps, "length": tl["length"]}
with open(out, "w", encoding="utf-8") as f:
    f.write("window.SOLIS_DATA = " + json.dumps(data, separators=(",", ":")) + ";\n")
print("wrote", out, len(words_out), "words", len(caps), "caption groups")

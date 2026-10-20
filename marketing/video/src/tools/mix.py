"""Mix VO/dialogue lines + synthesized bed into one soundtrack with ffmpeg.

python mix.py <timeline.json> <bed_raw.wav> <sfx.wav> <out.wav>
Steps: lines placed at their start times -> VO stem normalized to -14 LUFS;
bed normalized to -16 LUFS; bed ducked under speech (sidechain); summed;
final loudness -14 LUFS integrated, true peak -1.5 dBTP.
"""
import json, subprocess, sys, os
tl = json.load(open(sys.argv[1])); bed = sys.argv[2]; sfx = sys.argv[3]; out = sys.argv[4]
here = os.path.dirname(os.path.abspath(sys.argv[1]))
lines_dir = os.path.join(here, "..", "assets", "audio", "trim")
L = tl["length"]
inputs, parts = [], []
for i, (lid, t) in enumerate(tl["lines"]):
    inputs += ["-i", os.path.join(lines_dir, lid + ".wav")]
    ms = int(round(t * 1000))
    parts.append(f"[{i}:a]aformat=sample_rates=44100:channel_layouts=mono,adelay={ms}:all=1[v{i}]")
n = len(tl["lines"])
inputs += ["-i", bed, "-i", sfx]
mix_in = "".join(f"[v{i}]" for i in range(n))
fc = ";".join(parts) + ";"
fc += f"{mix_in}amix=inputs={n}:normalize=0,apad=whole_dur={L},atrim=0:{L},loudnorm=I=-14:TP=-2:LRA=11,aresample=44100,pan=stereo|c0=c0|c1=c0,asplit=2[vo][key];"
fc += f"[{n}:a]loudnorm=I=-16:TP=-2:LRA=11,aresample=44100[bedn];"
fc += "[bedn][key]sidechaincompress=threshold=0.02:ratio=8:attack=25:release=420:makeup=1:knee=4[duck];"
fc += f"[{n+1}:a]volume=0.55,aresample=44100[fx];"
fc += f"[vo][duck][fx]amix=inputs=3:normalize=0,atrim=0:{L},loudnorm=I=-14:TP=-1.5:LRA=11,aresample=44100[out]"
cmd = ["ffmpeg", "-y", "-loglevel", "error", *inputs, "-filter_complex", fc, "-map", "[out]", "-ar", "44100", "-ac", "2", out]
subprocess.run(cmd, check=True)
print("wrote", out)

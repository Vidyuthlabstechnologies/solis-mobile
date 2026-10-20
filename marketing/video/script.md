# SOLIS launch film: script, scenes, voices

Built with HyperFrames 0.8.162 (HeyGen, open source): HTML + GSAP compositions rendered to MP4.
Every product claim comes from `marketing/FACTS.md`. The one statistic comes from the source cited under it.

## Voices (Kokoro-82M, through `hyperframes tts`)

| Role | Voice | Why |
| --- | --- | --- |
| Narrator | `af_heart` (American English, female) | Picked from an audition of `af_heart`, `am_michael` and `am_adam` on the same hook line. It has the highest grade in Kokoro's published voice table (A), with a natural pace. Parakeet ASR transcribed it word for word, both alone and over the music. |
| Doctor (dialogue) | `am_michael` (American English, male) | The highest-graded American male voice of the three auditioned. `am_adam` has a much lower grade and audible artifacts. |
| Patient (dialogue) | `af_bella` (American English, female) | Clearly different from the narrator, with Kokoro's second-highest grade (A-). |

Auditions: `af_heart` 7.9 s, `am_michael` 8.7 s, `am_adam` 7.6 s on the line "It's nine forty at night, and you're still charting. SOLIS turns the visit into a signed note and a clean claim, before the patient leaves."

The dialogue is scripted. The patient (Elena Rostova, 52F) is the fictional demo patient from the app's demo data, and the claim screenshot in the film shows the same visit.

## Voiceover and dialogue (16:9, 79.5 s; start time in seconds)

| t | Who | Line |
| --- | --- | --- |
| 0.5 | Narrator | It's nine forty at night. And you're still charting. |
| 3.55 | Narrator | For every hour with patients, doctors spend nearly two more on the EHR and desk work. |
| 8.75 | Narrator | Then one to two more hours at night. And the claim can still come back denied. |
| 13.8 | Narrator | SOLIS listens to the visit, writes the note, and builds a clean claim, on your phone. |
| 19.25 | Narrator | Consent comes first. The patient hears a short script, in English or Spanish, and agrees out loud, or signs on the screen. |
| 27.3 | Narrator | Then you just talk. SOLIS tells your voice from the patient's. |
| 31.05 | Doctor | So, what brings you in today? |
| 32.95 | Patient | I have this deep cough. I'm coughing up thick green phlegm, and my fever spiked to a hundred and one point five last night. |
| 40.6 | Doctor | Any pain when you breathe? |
| 42.35 | Patient | Yes. A sharp pain, on the right side. |
| 45.4 | Narrator | When you finish, the note writes itself. Nothing invented. Every diagnosis links to the words it came from. |
| 52.35 | Narrator | Codes come from the patient's own words. Then every claim is checked against the official CMS code sets, so a denial gets caught before it goes out. |
| 61.7 | Narrator | Scan the insurance card. Send the claim in one tap. |
| 65.35 | Narrator | Need the audio to stay on the phone? Use on-device mode. And a BAA is available for your practice. |
| 72.9 | Narrator | SOLIS. Your visit, documented and billed. Request early access. |

That is about 170 narrated words across the roughly 66 s the narrator has (the dialogue fills the rest), so about 150 words per minute overall, with pauses between lines. Kokoro speaks each line itself a little quicker than that.

## Scenes (16:9)

| Time | Scene | On screen |
| --- | --- | --- |
| 0 to 3.3 | Hook | The clock rolls from 9:39 to 9:40 PM over a dim, unsigned progress note. "You're still charting." builds in word by word. |
| 3.3 to 13.1 | Pain | Bar chart: 1 hr with patients, nearly 2 hrs of EHR and desk work, then 1 to 2 hrs each night. A source line sits under the chart. A claim card gets a DENIED stamp. |
| 13.1 to 19 | Meet SOLIS | Orchid flash on the music drop. The Split Sun mark starts as one disc and splits into its two halves. The wordmark wipes in. "Listens / Writes the note / Builds a clean claim" appear in time with the voice. "On your phone." |
| 19 to 27 | Consent | An Android phone mockup (built in HTML/CSS with a punch-hole camera, side buttons and a 3D tilt) shows the real consent screenshot. English and Español chips appear, a ring highlights "Patient agreed, start recording" and a tap ripple follows. |
| 27 to 45.2 | Ambient capture and dialogue | Recording screen with a live timer. One waveform splits into DOCTOR (orchid) and PATIENT (teal) lanes, each driven by that speaker's word timings. The live transcript types in word by word, in sync with the dialogue audio. |
| 45.2 to 52 | The note | The note screen types in the Subjective lines and pops in the diagnosis codes R05.9, R50.9 and R07.81, each with its quote. A "Nothing invented" chip appears. A line draws from the patient quote card to the R05.9 row. |
| 52 to 61.4 | Codes and checks | The real claim screenshot (09). An enlarged crop of the R05.9 "Patient reported" row lifts out. Chips name the CMS code sets, and a counter runs from 0 to 59 ("59 official coding rules enforced. 4 more need the AMA license."). Then a ring around "1 issue to fix before billing", a check card reading "Note not signed" that shakes, and a switch to a green "Note signed". |
| 61.4 to 65.1 | Scan and send | A sample insurance card (JORDAN A RIVERA, marked demo data) flies in, a scan line passes over it, and it drops into the scan screenshot. A tap on "Send claim" turns it into "Claim sent", and a claim token flies to a "Clearinghouse, 837P" node. |
| 65.1 to 72.3 | Privacy | Engine screen: the On-device option is selected, with "No audio leaves the phone. Works offline." Three checked rows: Works offline, Card photos deleted after reading, BAA available for your practice. |
| 72.3 to 79.5 | CTA | The phone drops away and the music hits its final chord. The mark splits again, followed by the SOLIS wordmark, "Your visit, documented and billed.", a "Request early access" button and "Now in pilot on Android". |

Burned-in captions run the whole film. Spoken words brighten as they are said, and dialogue lines carry DOCTOR or PATIENT tags. Caption timing comes from `hyperframes transcribe` (Parakeet), and the spelling comes from the script.

## 9:16 reel (42.5 s)

Hook (0 to 3.3), Meet SOLIS (3.3 to 8.8), Just talk and the dialogue with the lanes split (8.8 to 26.5), the note writes itself (26.6 to 33), the check catches "Note not signed" and turns green, shown with music and SFX only (33.2 to 36), then the CTA (36.1 to 42.5). It uses the narrator lines L01, L04, L06, L07 and L11 and the full dialogue.

## Statistic and source

"For every hour with patients, nearly 2 more hours of EHR and desk work; then 1 to 2 hours each night":
Sinsky C, Colligan L, Li L, et al. Allocation of Physician Time in Ambulatory Practice: A Time and Motion Study in 4 Specialties. Ann Intern Med. 2016;165(11):753-760. doi:10.7326/M16-0961 (PMID 27595430). The abstract was checked on PubMed (NCBI E-utilities) at build time. It covers 57 US physicians in office hours, and after-hours figures come from self-reported diaries (21 physicians).

The film shows no claim-denial statistic, because no primary source was verified for one.

## Music and sound

The music is an original track synthesized for this film by `src/tools/make_music.py`. It uses numpy only, with no samples, recordings or third-party loops. It runs at 116 BPM in D major on a I-V-vi-IV progression (D, A, Bm, G), with kick, clap, hats, sidechained bass, pluck arpeggio, pad, a riser and a final chord hit. The same script builds the bed for each cut, timed to that cut's drop, dialogue breakdown and CTA hit.
The sound effects (whoosh, tap, pop, chime, alert, stamp, tick, scan) are also synthesized, in `src/tools/make_sfx.py`.
The mix comes from `src/tools/mix.py` (ffmpeg): voice stem at -14 LUFS, music at -16 LUFS ducked under speech with a sidechain compressor, then the full mix normalized to -14 LUFS integrated, -1.5 dBTP.

## Rebuild

Run these from `marketing/video/src`. FFmpeg must be on PATH. TTS needs a Python with `kokoro-onnx` and `soundfile`, passed to HyperFrames through `HYPERFRAMES_PYTHON`. The music, SFX and caption tools need numpy.

```
npx hyperframes tts "<line>" -v af_heart -o assets/audio/lines/L01.wav          # one per line in data/lines.tsv
npx hyperframes transcribe <vo-only.wav> --engine parakeet --json                 # word timings -> data/transcripts/
python tools/build_data.py data/timeline_16x9.json data/transcripts/vo_16x9.words.json assets/data_16x9.js
python tools/make_music.py assets/audio/music/bed_16x9_raw.wav '{"length":79.5,"drop":13.25,"break":[30.8,45.2],"hit":72.6}'
python tools/make_sfx.py data/timeline_16x9.json assets/audio/music/sfx_16x9.wav
python tools/mix.py data/timeline_16x9.json assets/audio/music/bed_16x9_raw.wav assets/audio/music/sfx_16x9.wav assets/audio/soundtrack_16x9.wav
npx hyperframes lint
npx hyperframes render --quality high --crf 18 --workers 1 -o ../solis-launch-16x9.mp4
npx hyperframes render -c compositions/reel.html --quality high --crf 18 --workers 1 -o ../solis-reel-9x16.mp4
```

To build the reel inputs, run the same steps with `timeline_9x16.json` and the bed arrangement `{"length":42.5,"drop":3.4,"break":[12.4,26.4],"hit":36.3}`.

# On-device speech and speaker separation (Android)

SOLIS can transcribe a visit and tell the voices apart entirely on the phone.
Audio is captured, recognized and attributed to speakers locally; no audio,
text or embeddings leave the device. The only network traffic is the one-time
model download from the official release URLs listed below.

The engine is built on [k2-fsa sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
1.13.8 (Apache-2.0) and is exposed to Dart as `NativeSpeechProvider`, which
implements the same `TranscriptionProvider` interface as the Deepgram provider.

## Files

| Path | Role |
| --- | --- |
| `android/app/src/main/kotlin/com/solis/clinical/solis_mobile/speech/NativeSpeechPlugin.kt` | MethodChannel and EventChannel bridge, lifecycle cleanup |
| `.../speech/SpeechSession.kt` | Microphone capture, VAD, recognition, live speaker labels, final pass |
| `.../speech/SpeakerClustering.kt` | Online voice clustering, re-clustering, label alignment |
| `.../speech/DiarizationMerger.kt` | Lays final diarization turns over recognized utterances, splits mixed ones |
| `.../speech/AudioStore.kt` | In-memory PCM buffer of the recording and a 10 s ring for partial text |
| `.../speech/ModelFiles.kt` | SHA-256 and .tar.bz2 extraction (off the main thread) |
| `.../speech/SpeechConfig.kt` | Session options and model paths |
| `android/app/libs/sherpa-onnx-static-link-onnxruntime-1.13.8.aar` | Official sherpa-onnx release AAR (vendored) |
| `lib/services/transcription/native_speech_provider.dart` | `NativeSpeechProvider` (Dart side of the engine) |
| `lib/services/transcription/model_manager.dart` | Model catalog, download, resume, retry, verification |
| `test/native_speech_test.dart` | Dart tests with fake channels and a fake downloader |

`MainActivity.configureFlutterEngine` registers the bridge with one line:
`NativeSpeechPlugin.register(this, flutterEngine)`.

## Architecture

```
AudioRecord (VOICE_RECOGNITION, 16 kHz mono PCM16, NoiseSuppressor + AGC when available)
  | 100 ms blocks, thread "solis-speech-mic" (URGENT_AUDIO priority)
  v
worker thread "solis-speech-N" (single-threaded; owns every native object)
  |-- AudioStore: keeps the recording as PCM16 in memory (1.9 MB per minute, capped)
  |-- Silero VAD (512-sample windows): cuts speech at 0.4 s pauses, max 7 s per utterance
  |      |-- while someone talks: decode the open utterance every 0.5 to 3 s  -> "partial"
  |      `-- utterance ends: split to <= 8 s, Moonshine decode, CAM++ embedding,
  |          online clustering assigns a voice index                         -> "segment"
  `-- stop(): flush VAD, then the final pass:
         recording <= finalPassMaxSeconds (default 600 s):
             pyannote segmentation 3.0 + CAM++ embeddings + clustering over the whole
             recording; DiarizationMerger relabels each utterance and re-decodes the
             parts of utterances that contain two voices; labels are aligned to the
             live numbers so the screen does not reshuffle                 -> "final" (method pyannote)
         longer recordings: re-cluster the per-utterance embeddings
             (average-linkage up to 400 utterances, centroid refinement beyond) -> "final" (method recluster)
  results are posted to the main thread and sent over the EventChannel
```

Design notes:

- Recognition is "simulated streaming": an offline model decodes each VAD
  utterance, and the utterance in progress is decoded periodically for live
  text. One model serves both, which keeps the download small, and offline
  decoding of whole utterances is more accurate than the small streaming
  transducers. Partial decoding backs off automatically (to at most once every
  3 s) when the phone is slow, so it never falls behind real time.
- Capture starts before the models finish loading (about 1 to 2 s); audio
  queues on the worker, so the first words are not lost.
- All native objects live on one worker thread, so no locks are needed and
  nothing heavy runs on the main thread.
- Native resources (recognizer, VAD, extractor, diarizer, audio buffer) are
  released at the end of `stop`, on `cancel`, and when the activity is
  destroyed (via `Application.ActivityLifecycleCallbacks`).
- Timestamps are seconds of captured audio from the start of the recording.
  Paused time is not counted.
- Moonshine v2 in sherpa-onnx 1.13.8 returns an empty result for inputs longer
  than about 9 s (measured: 9.0 s works, 9.5 s fails). The VAD caps utterances
  at 7 s and anything longer is split at its quietest 20 ms frame to stay
  under 8 s.

## Platform API

Channels (both registered by `NativeSpeechPlugin`):

- MethodChannel `com.solis.clinical/native_speech`
- EventChannel `com.solis.clinical/native_speech/events`

Methods:

| Method | Arguments | Result |
| --- | --- | --- |
| `getCapabilities` | none | `{supported, reason?, abi, modelRoot, engineVersion, noiseSuppressor, autoGain, cores, sdk, freeBytes, maxMemoryBytes}` |
| `getModelRoot` | none | absolute path of `noBackupFilesDir/speech_models` |
| `isReady` | `{models}` | `true` when the native library loads and every model file exists |
| `sha256` | `{path}` | lowercase hex digest (background thread) |
| `extractArchive` | `{archive, destDir, entries: {pathInArchive: fileName}}` | `{fileName: {path, size, sha256}}` |
| `start` | `{models: {vad, encoder, decoder, tokens, segmentation, embedding}, numSpeakers?, maxSpeakers?, finalPassMaxSeconds?, noiseSuppression?, autoGain?, asrThreads?, emitPartials?, newSpeakerThreshold?, clusterThreshold?}` | `{sessionId}` |
| `pause`, `resume` | none | `bool` |
| `stop` | none | `{segments, method, numSpeakers, durationSec}` after the final pass |
| `cancel` | none | drops the session without a final pass |

Error codes from `start`: `unsupported` (no native library for this CPU),
`models_missing`, `bad_args`, `busy`.

Events (maps, every session event carries `sessionId`):

| type | Payload |
| --- | --- |
| `status` | `status`: `loading`, `listening`, `paused`, `behind`, `finalizing`, `stopped`, `failed`; `progress` (0 to 1) while finalizing |
| `start` | `sampleRate`, `loadMs` |
| `partial` | `text` (empty clears it), `start`, `end`, `speakerIndex` (last known voice) |
| `segment` | `segment: {id, speakerIndex, text, start, end, isFinal: true}` |
| `final` | `segments`, `method` (`pyannote`, `recluster`, `online`, `none`), `numSpeakers`, `durationSec` |
| `end` | none |
| `error` | `code`, `message`, `fatal` |
| `modelProgress` | `stage: extract`, `file`, `done`, `total` (compressed bytes) |

Runtime error codes: `permission_denied`, `mic_unavailable`, `mic_busy`,
`mic_read_failed`, `mic_resume_failed`, `model_load_failed` (all fatal) and
`diarization_failed`, `final_pass_failed` (non-fatal; live labels are kept).

## Dart API

```dart
// Once, at app start (and again after a download completes):
await NativeSpeechProvider.register(); // sets SpeechEngines.onDeviceFactory when ready

// Model download UI:
final models = ModelManager(); // SpeechModelSet.standard by default
if (!await models.isReady()) {
  await for (final p in models.prepare()) {
    // p.stage, p.fraction, p.receivedBytes, p.totalBytes, p.attempt, p.error
  }
}

// Recording:
final engine = NativeSpeechProvider(models: models, options: const NativeSpeechOptions(numSpeakers: 2));
engine.start().listen((u) { /* u.transcript, u.interim, u.segments, u.roles, u.status, u.error */ });
await engine.pause();
await engine.resume();
final labeled = await engine.stop(); // "Doctor: ...\nPatient: ..."
```

- Status mapping: `loading` to `connecting`, `listening` and `behind` to
  `listening`, `paused` to `paused`, `finalizing` to `closing`, `stopped` to
  `stopped`, `failed` to `failed`. Errors arrive as data (`TranscriptUpdate.error`).
- Roles come from `SpeakerRoleMapper.assign` over the final segments and the
  transcript from `buildLabeledTranscript`, exactly as for Deepgram.
  `setRole(index, role)` pins a role; overrides are cleared when the final pass
  renumbers voices.
- `finalizingProgress`, `diarizationMethod` and `lagging` are extra fields for
  the UI.
- `NativeSpeechProvider.checkAvailability()` reports `supported`,
  `modelsReady` and `downloadBytes` without starting anything.

## Models

All files come from the official sherpa-onnx GitHub releases (k2-fsa), are
downloaded over HTTPS on first use into `Context.noBackupFilesDir/speech_models`
(app-private and excluded from Android backup), and are verified against the
SHA-256 values below before use. A `verified.json` manifest records each
verified file so later launches only check sizes. Interrupted downloads resume
with HTTP Range requests; each source is retried up to 4 times with backoff.
Archives are verified as a whole, unpacked natively, and every extracted file
is verified again.

| Model | Release file | Download | SHA-256 of download | License |
| --- | --- | --- | --- | --- |
| Silero VAD v5 | [asr-models/silero_vad.onnx](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx) | 643,854 B | `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6` | MIT (snakers4/silero-vad) |
| pyannote segmentation 3.0 | [speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2](https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2) | 6,958,444 B | `24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488` | MIT (pyannote/segmentation-3.0) |
| 3D-Speaker CAM++ (English, VoxCeleb) | [speaker-recongition-models/3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx](https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx) | 29,596,978 B | `357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b` | Apache-2.0 (modelscope/3D-Speaker) |
| Moonshine Tiny English v2, int8 (compact set) | [asr-models/sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2) | 29,858,559 B | `9ec31b342d8fa3240c3b81b8f82e1cf7e3ac467c93ca5a999b741d5887164f8d` | MIT (English models of moonshine-ai/moonshine) |
| Moonshine Base English v2, int8 (standard set) | [asr-models/sherpa-onnx-moonshine-base-en-quantized-2026-02-27.tar.bz2](https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-moonshine-base-en-quantized-2026-02-27.tar.bz2) | 111,266,225 B | `43232c1d13013d37317163baec3135bd771a186a4356f28c889bab453bb0e891` | MIT (English models of moonshine-ai/moonshine) |

Files kept on the phone after extraction:

| File | Size | SHA-256 |
| --- | --- | --- |
| `silero_vad.onnx` | 643,854 | `9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6` |
| `pyannote-segmentation-3-0.onnx` (archive `model.onnx`) | 5,992,913 | `220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079` |
| `pyannote-segmentation-LICENSE.txt` | 1,061 | `14d7016ad68e7394d6e6b78d96cc2ae431c905287b89674cfdf021e79e62b8ba` |
| `3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx` | 29,596,978 | `357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b` |
| `moonshine-tiny-en-encoder.ort` | 13,281,600 | `94e90a4654fc45cdfedb77c4c08e1739f48862998e58fada384b25118134f221` |
| `moonshine-tiny-en-decoder-merged.ort` | 30,412,256 | `cf524c4862d36e9e5ab032eddc73637efd822d70e868ac575cf1a46e1e4708a0` |
| `moonshine-base-en-encoder.ort` | 31,326,816 | `7c66495948d0d08ec1af454cd4b5514862ae6511e94712a60e6d83eaec8dc8cf` |
| `moonshine-base-en-decoder-merged.ort` | 109,424,400 | `d9d7b333af34bc552580576ddcf248a1c6c839e0d3b43b09afb9376ed009899d` |
| `moonshine-en-tokens.txt` (same for tiny and base) | 549,350 | `2870d843e14c1e187bf1913a521562a63b53933814bd7f2145120468f494a049` |
| `moonshine-LICENSE.txt` | 13,344 | `6148d7574a6554b7379b633cfd4c4fe5840c3f548d13bc83e00b52dc6fa00abd` |

Totals:

| Set | Download | On disk | Peak during install |
| --- | --- | --- | --- |
| `standard` (default, Moonshine Base) | 148.5 MB | 177.5 MB | about 290 MB (archive and extracted files together) |
| `compact` (Moonshine Tiny) | 67.1 MB | 80.5 MB | about 110 MB |

The manager checks free space before downloading.

### Why these models

- Recognition: Moonshine v2 English (MIT) is the best accuracy per megabyte
  available in sherpa-onnx for English, emits punctuation and casing (the role
  mapper relies on question marks and sentence breaks), and runs at a real-time
  factor of 0.11 (base) and 0.06 (tiny) with 2 threads on a desktop CPU. On a
  mid-range phone expect 3 to 5 times slower, still well under real time per
  utterance. Base is the default because it is clearly better on clinical
  words (in testing, tiny wrote "Genetic AI" where base wrote "Generative AI").
  Alternatives considered:
  - Google MedASR (sherpa-onnx `medasr-ctc-en-int8`): trained on medical
    dictation, but 154 MB for the model alone (over budget with diarization)
    and released under the Health AI Developer Foundations terms rather than
    an open-source license. Worth evaluating if the budget grows.
  - Parakeet TDT 110M int8 (CC-BY-4.0): strong accuracy, but about 126 MB
    and only published as an archive.
  - Streaming Zipformer English (2023): true streaming, but trained on
    LibriSpeech read speech, no punctuation, weaker on conversation.
  - Whisper tiny.en: hallucinates on silence and has no clear size advantage.
- Speaker embeddings: CAM++ English VoxCeleb (Apache-2.0, 29.6 MB) is the
  smallest English embedding model that sherpa-onnx documents for
  diarization; TitaNet small (40 MB) and ResNet34 (26.5 MB, CC-BY) are drop-in
  alternatives (same API, change the catalog entry).
- Segmentation: pyannote segmentation 3.0 (MIT, 6 MB), the model sherpa-onnx
  uses for its diarization pipeline.
- VAD: Silero v5 (MIT, 0.6 MB).

### Native library

- AAR: `sherpa-onnx-static-link-onnxruntime-1.13.8.aar` from
  https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-static-link-onnxruntime-1.13.8.aar,
  38,691,998 B, SHA-256 `b22c3fc1b6a45666d28892bb2f7694beeb77a8362d7ebd77c1a5431ec9435471`
  (matches the digest GitHub publishes for the asset). Apache-2.0. It contains
  the Kotlin API (`com.k2fsa.sherpa.onnx`) and one self-contained JNI library
  per ABI with onnxruntime linked in (only system libraries are needed). The
  arm64 library is 16 KB page aligned, as Google Play requires for Android 15+.
- sherpa-onnx is not published to Maven Central by k2-fsa (JitPack only
  carries the JVM artifacts), so the official AAR is vendored in
  `android/app/libs` and referenced with `implementation(files(...))`.
- `org.apache.commons:commons-compress:1.28.0` (Apache-2.0) supplies the
  bzip2 decoder for model archives; a small tar reader lives in `ModelFiles.kt`.
- x86 and x86_64 copies of the JNI library are excluded in
  `packaging.jniLibs` (they would add about 60 MB uncompressed). On those
  devices (emulators, some Chromebooks) `getCapabilities` reports
  `supported: false` and the app keeps using Android speech recognition.

### APK size

Measured with `flutter build apk --release` (universal APK):

- `lib/arm64-v8a/libsherpa-onnx-jni.so`: +24.2 MB
- `lib/armeabi-v7a/libsherpa-onnx-jni.so`: +16.4 MB
- `classes.dex`: about +0.2 MB compressed (sherpa-onnx Kotlin API kept whole,
  bzip2 decoder)
- Total from this engine: about +40.8 MB. The release APK went from
  102.5 MB to 147.8 MB; the remaining 4.5 MB came from code-set assets and
  Dart changes made by others in the same period.

Native libraries are stored uncompressed in the APK (the AGP default, so they
can be mapped directly). Ways to cut the download if needed:

- `flutter build apk --split-per-abi` or an App Bundle: arm64 phones then get
  only +24.2 MB.
- `packaging.jniLibs.useLegacyPackaging = true` compresses every native
  library in the APK (smaller download, larger install, applies to all
  plugins' libraries too).

### R8

`proguard-rules.pro` keeps `com.k2fsa.sherpa.onnx.**` whole (the JNI code
reads config fields and constructs result classes by name) and keeps
`DiarizationProgress.invoke(IIJ)Ljava/lang/Integer;`, which the diarization JNI
calls back by name. Without that rule R8 inlined the typed `invoke` of a
lambda and renamed `Function3.invoke`, which would silently disable progress
reporting. The rules were verified with `dexdump` on the release APK.

## Accuracy expectations and limits

- Words: Moonshine Base is a general English model. Expect good accuracy on
  conversational speech in a quiet exam room and errors on rare drug names,
  dosages spoken quickly, and accented speech. It does not know a clinic's
  vocabulary; there is no hotword biasing for this model type in sherpa-onnx.
  The note engine and the clinician's review remain the safety net.
- Voices, live: each utterance (speech between pauses of at least 0.4 s) gets
  one voice. A new voice is created only for an utterance of at least 1.5 s
  that matches no known voice (cosine similarity under 0.45); short replies
  ("yes", "okay") join the nearest known voice, which is sometimes wrong.
  Live labels in the first 20 to 30 seconds are the least reliable.
- Voices, final: the pyannote pass on stop looks at the whole recording,
  catches turn changes inside one utterance and re-decodes those parts
  separately. Passing `numSpeakers: 2` when only clinician and patient are
  present gives the most reliable result. With automatic counting the
  clustering threshold is 0.85; on the reference two-speaker recordings 0.5
  to 0.7 produced 3 to 4 voices and 0.85 to 0.9 produced 2.
- Overlapping speech: when two people talk at once, the words are attributed
  to whoever holds the longer turn; the other person's words are usually
  lost or merged. Moonshine transcribes the dominant voice only.
- Two similar voices (same sex, age, accent; or a parent and adult child):
  embeddings may not separate them. On a test recording with two speakers of
  similar voice, both pyannote and live clustering merged most of the
  conversation into one voice. The role mapper then labels by content, and
  the clinician can swap roles with `setRole`.
- Three or more people: supported (`maxSpeakers` 4 by default). The extra
  voices are labeled `Other` by the role mapper and written as `Caregiver`.
- Recordings longer than `finalPassMaxSeconds` (default 10 minutes) skip the
  pyannote pass (it would take minutes on a phone) and instead re-cluster the
  utterance embeddings, which fixes order effects of live clustering but cannot
  split turns inside an utterance. Audio beyond that length is not kept in
  memory.
- Pause/resume: the open utterance is finalized on pause; timestamps exclude
  paused time.

## Battery, CPU and memory

- Idle listening (silence) costs only the VAD: about 1 to 2 percent of one
  core. Recognition runs at the end of each utterance plus periodic partial
  decoding while someone talks (2 threads), so CPU use follows the amount of
  speech. Expect roughly 20 to 40 percent of a mid-range CPU during
  continuous talking with Moonshine Base, less with Tiny. Turn partials off
  (`emitPartials: false`) to save about half of the decoding work.
- The final pass takes roughly 5 to 15 percent of the recording length on a
  mid-range phone (desktop measurement: 55 s of audio in 2.2 s with 2 threads;
  phones are 3 to 5 times slower). Progress is reported as
  `finalizingProgress`.
- Memory: models in RAM are about 180 MB (standard) or 80 MB (compact) of
  native memory while recording, plus the diarizer (about 40 MB) during the
  final pass. The recording buffer is 1.9 MB per minute (19 MB at the 10-minute
  cap) on the Java heap, and the final pass makes one float copy of it.
- Use the `compact` set on phones with 3 GB of RAM or less.

## Testing on a device with two people

1. Use an ARM phone (any arm64 or armv7 Android 7.0+ device; emulators are
   x86_64 and unsupported). Build and install:
   `flutter build apk --release` then `adb install -r build/app/outputs/flutter-apk/app-release.apk`.
2. Grant the microphone permission. Call `NativeSpeechProvider.register()` and
   run `ModelManager().prepare()` on Wi-Fi; check that progress reaches
   `ready`. Kill the app mid-download once and restart it to confirm resume.
   Airplane mode during download should end in `failed` with a clear error,
   and a retry later should continue from where it stopped.
3. Place the phone on the desk between the two people, about 0.5 to 1 m from
   each. Avoid speakerphone audio, fans and open windows for the first run.
4. Script a 3 to 5 minute visit:
   - Doctor opens with questions ("What brings you in today?").
   - Patient answers with symptoms in first person.
   - Include quick exchanges ("Any allergies?" "No.") and one interruption.
   - Include drug names and doses ("metformin 500 milligrams twice a day").
   - Pause and resume once.
5. Watch the live transcript: lines should appear within about a second of
   each pause, with the interim text greyed while someone talks.
6. Stop. The status shows finalizing with progress, then the final transcript.
   Check that quick exchanges are split into the right voices and that the
   labels read `Doctor:` and `Patient:`.
7. Repeat with `numSpeakers: 2`, with two people of similar voice, with a
   third person (family member), with the `compact` set, and with a
   15-minute recording (re-cluster path).
8. Record with `adb logcat -s sherpa-onnx` open for native errors, and watch
   `adb shell top -H -p $(adb shell pidof com.solis.clinical.solis_mobile)` for
   the `solis-speech-*` threads' CPU use.
9. Rotate the screen, lock the phone, receive a call, and back out of the
   screen while recording: the app must not crash, and the microphone
   indicator must turn off after stop or when the activity is destroyed.

## Known gaps

- Not yet run on a physical device: the native pipeline was validated on a
  desktop with the same sherpa-onnx 1.13.8 core (Python package) and the same
  models and parameters, the pure Kotlin logic (extraction of the real model
  archive with SHA-256 checks, clustering, merging, buffers) was run on the
  JVM, and the release build compiles, links and passes R8. Device latency,
  CPU, battery and memory numbers above are estimates until measured.
- Background recording with the screen off depends on the existing wake lock;
  Android 11+ may stop microphone access for a backgrounded app unless a
  foreground service of type `microphone` is running. The app declares the
  permission but has no such service yet.
- Speaker voices are not enrolled, so voice 0 is not guaranteed to be the
  clinician; roles come from what is said (SpeakerRoleMapper) and from
  `setRole`.

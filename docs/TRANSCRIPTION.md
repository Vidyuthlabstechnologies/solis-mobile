# Live transcription and speaker separation

SOLIS has two ways to turn the visit into text:

| Path | When it is used | Who said what |
| --- | --- | --- |
| On-device (speech_to_text, Android recognizer) | Default, and fallback whenever no cloud key is set or the cloud stream fails | Guessed from wording by `ClinicalCoder.diarize` |
| Deepgram streaming (`DeepgramStreamingProvider`) | When a Deepgram API key is configured | Separated by voice (diarization), then roles mapped from what each voice says |

Code lives in `lib/services/transcription/`:

- `transcription_provider.dart`: `TranscriptionProvider` interface, `DiarizedSegment`, `TranscriptUpdate`, `TranscriptionStatus`.
- `deepgram_provider.dart`: `DeepgramStreamingProvider`, `DeepgramOptions`, `DeepgramTranscriptAssembler` (pure message parsing), injectable `TranscriptionSocket` and `AudioCaptureSource`.
- `speaker_roles.dart`: `SpeakerRoleMapper` (voice number to Doctor / Patient / Other) and `buildLabeledTranscript`.

Tests: `test/transcription_test.dart` (fake socket and fake microphone, no network).

## How the Deepgram provider works

1. `start()` checks the key and microphone permission, opens a websocket to Deepgram, then starts the microphone with the record package: `AudioRecorder.startStream(RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1))`, Android audio source `voiceRecognition`. Every PCM chunk is sent as a binary frame.
2. Deepgram replies with `Results` messages about once a second. Each word carries `speaker` (0, 1, 2...), `start`, `end` and `punctuated_word`.
   - `is_final: false` is an interim guess for the current audio window. Each new interim replaces the previous one. It is exposed as `TranscriptUpdate.interim` and is never written into the transcript.
   - `is_final: true` fixes those words. They are appended to the finalized turns and the interim is cleared. `speech_final: true` additionally means the speaker paused (endpointing).
   - `UtteranceEnd` (after 1000 ms of no words) is used as a turn boundary signal only; words are still taken from the final result so nothing is duplicated.
3. Consecutive words from the same voice are merged into one `DiarizedSegment`. `SpeakerRoleMapper` maps voices to roles from the conversation itself: the voice that asks the most questions and uses clinical language (exam, vitals, prescribe, mg, follow up, order, refer) is the Doctor; the voice using first-person symptom language (I have, I feel, my chest, it hurts, since yesterday) is the Patient; any further voice is Other. Scores are per sentence, so the most talkative person does not win by volume. Ties go to the voice heard first. Roles are recomputed as the visit goes on; `provider.setRole(index, role)` pins a correction from the clinician.
4. `TranscriptUpdate.transcript` is `buildLabeledTranscript(...)`: lines like `Doctor: ...` and `Patient: ...`, the format `ClinicalCoder.diarize` and the note engine already parse. Other speakers are written as `Caregiver:` because the note engine does not know an `Other:` tag (it knows Doctor, Patient, Nurse, Caregiver, Family).
5. `pause()` pauses the microphone, sends `{"type":"Finalize"}` so pending words are finalized, and sends `{"type":"KeepAlive"}` every 4 s (Deepgram closes a socket after 10 s with no audio and no KeepAlive, error NET-0001). `resume()` stops KeepAlive and resumes the microphone.
6. `stop()` stops the microphone, sends `{"type":"CloseStream"}`, waits up to 3 s for Deepgram to flush the last results and close, keeps any words still interim, and returns the labeled transcript. The stream then closes.
7. If the socket closes unexpectedly, the provider reconnects once. Audio captured during the reconnect (up to 10 s) is buffered and sent when the new socket opens. Deepgram restarts its clock and voice numbers on a new connection, so times are offset to continue from the last word and voice numbers from the new connection are offset by 100 (`speakerSessionStride`); each connection gets its own Doctor/Patient mapping. A second unexpected close, a failed connect, a bad key or missing microphone permission is reported as a `TranscriptUpdate` with `status: failed` and `error` set. Errors are never thrown into the stream, so a listener without `onError` cannot crash the app. A non-fatal Deepgram `Error` message (for example a rejected keyterm) is reported with `error` set and the session continues.

### Exact request

```
wss://api.deepgram.com/v1/listen?model=nova-3-medical&language=en-US&encoding=linear16&sample_rate=16000&channels=1
  &diarize_model=latest&punctuate=true&smart_format=true&interim_results=true&endpointing=300
  &utterance_end_ms=1000&vad_events=true[&keyterm=...]
Authorization: Token <DEEPGRAM_API_KEY>
```

- `diarize_model=latest` is the current parameter; `diarize=true` is deprecated (it still works and routes to diarization v1). Sending both is rejected. `DeepgramOptions(legacyDiarizeFlag: true)` switches to `diarize=true`. Streaming supports diarization v1 only; streaming words carry `speaker` but not `speaker_confidence`.
- `utterance_end_ms` must be 1000 or more and requires `interim_results=true`.
- `keyterm` (up to 100, Nova-3 only) can boost drug names and clinic vocabulary: `DeepgramOptions(keyterms: [...])`.

Sources:
- Live streaming API reference: https://developers.deepgram.com/reference/speech-to-text-api/listen-streaming
- Diarization: https://developers.deepgram.com/docs/diarization
- KeepAlive: https://developers.deepgram.com/docs/audio-keep-alive
- End of speech, interim results, UtteranceEnd: https://developers.deepgram.com/docs/understanding-end-of-speech-detection
- Authentication (`Authorization: Token <key>`): https://developers.deepgram.com/docs/authenticating
- Nova-3 Medical streaming: https://deepgram.com/learn/nova-3-medical-streaming-update

Note: Deepgram's diarization page lists Nova batch models and does not mention `nova-3-medical` by name. Before go-live, record one real two-person test visit and confirm the words come back with more than one `speaker` value. If they do not, switch `DeepgramOptions(model: 'nova-3')`.

## Android permissions

Already declared in `android/app/src/main/AndroidManifest.xml`:

- `android.permission.RECORD_AUDIO` (runtime permission; `AudioRecorder.hasPermission()` shows the system prompt the first time).
- `android.permission.INTERNET` (the websocket).
- `android.permission.FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_MICROPHONE` (only matter if capture must continue with the screen off; Android 14 requires a foreground service of type microphone for that).

Nothing else is needed. The connection is `wss://`, so no cleartext network config change.

## API key handling

- Store the key with flutter_secure_storage, never in source or in the APK. Read it at the start of each recording and pass it to `DeepgramStreamingProvider(apiKey)`.
- A key in the app can be extracted by anyone with the device. For production, have a backend issue short-lived tokens from Deepgram's token-based Auth API (linked from the authentication page above) and pass that instead of a long-lived project key. The authentication page documents the `Token` scheme for API keys; check the header scheme for short-lived tokens there before switching.

## HIPAA and the BAA

- Deepgram states it is a Business Associate under HIPAA and provides its BAA to customers who are Covered Entities on request: https://developers.deepgram.com/docs/data-privacy-compliance
- The pricing page lists the BAA under the Enterprise plan only (not Pay As You Go or Growth): https://deepgram.com/pricing . Do not send real patient audio until an Enterprise agreement and signed BAA are in place. Development and testing must use synthetic or consented, de-identified audio.
- Also ask Deepgram for the data retention setting on the account (and consider `mip_opt_out=true`, which opts the request out of the Model Improvement Program).

## Cost per audio hour (Deepgram)

From https://deepgram.com/pricing, read 2026-10-16. The page lists Nova-3 monolingual streaming and a separate diarization add-on; it has no separate line for Nova-3 Medical.

| Plan | Nova-3 streaming | Diarization add-on | Per audio hour |
| --- | --- | --- | --- |
| Pay As You Go | $0.0048/min | $0.0020/min | $0.288 + $0.120 = **$0.408** |
| Growth | $0.0042/min | $0.0017/min | $0.252 + $0.102 = **$0.354** |
| Enterprise (needed for the BAA) | custom | custom | quote from Deepgram sales |

Third-party price trackers have listed higher Nova-3 streaming rates (for example $0.0077/min Pay As You Go), so confirm the Nova-3 Medical rate in the Deepgram console or with sales. Audio is billed while the socket receives it; paused time with only KeepAlive messages sends no audio.

## Alternative: Amazon Transcribe Medical streaming (not implemented)

- API: `StartMedicalStreamTranscription` over HTTP/2, or a WebSocket to `wss://transcribestreaming.<region>.amazonaws.com:8443/medical-stream-transcription-websocket` with a SigV4 pre-signed URL.
- Speaker labels: `ShowSpeakerLabel=true` (HTTP/2) or `show-speaker-label=true` (WebSocket). Set `type=CONVERSATION` (or `DICTATION`), `specialty` (PRIMARYCARE, CARDIOLOGY, NEUROLOGY, ONCOLOGY, RADIOLOGY or UROLOGY; confirm the current list in the API reference), `language-code=en-US` (US English only), `media-encoding=pcm|flac|ogg-opus`, `sample-rate=16000`. Best with 2 to 5 speakers.
- Output: `Transcript.Results[].Alternatives[].Items[]` with `Content`, `StartTime`, `EndTime`, `Type` (`pronunciation`, `punctuation`, `speaker-change`) and `Speaker` ("0", "1"). `IsPartial` plays the role of Deepgram's `is_final`. Speaker labels appear only on complete (non-partial) segments, so live display lags more than Deepgram.
- Compliance: HIPAA eligible under the standard AWS BAA (accepted in AWS Artifact), available on any paid account; no enterprise contract needed.
- Price: $0.075 per minute ($4.50 per audio hour) from the examples on https://aws.amazon.com/transcribe/pricing/ (free tier 60 minutes per month for 12 months). That is roughly 11 times Deepgram's listed Pay As You Go rate.
- Trade-offs: needs AWS credentials on the device (use Cognito identity pools or a backend signer, never static keys), SigV4 signing, and AWS's binary event-stream framing over the websocket. No Dart SDK for this API, so it is more code than Deepgram. To add it, implement `TranscriptionProvider` and map `Items` into `DiarizedSegment`; `SpeakerRoleMapper` and `buildLabeledTranscript` work unchanged.
- Docs: https://docs.aws.amazon.com/transcribe/latest/dg/conversation-diarization-streaming-med.html and https://docs.aws.amazon.com/transcribe/latest/APIReference/API_streaming_StartMedicalStreamTranscription.html

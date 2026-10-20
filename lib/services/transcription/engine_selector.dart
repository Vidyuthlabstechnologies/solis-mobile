import 'package:flutter/foundation.dart';

import '../integrations.dart';
import '../solis_backend.dart';
import 'deepgram_provider.dart';
import 'transcription_provider.dart';

/// Which engine separates the doctor's voice from the patient's.
enum SpeechEngine {
  /// On-device neural engine (no audio leaves the phone).
  onDevice('Voices separated on this phone'),

  /// Deepgram medical model, through the SOLIS server or a key on this phone.
  cloud('Voices separated by Deepgram'),

  /// Android speech recognition only; speakers are inferred from the words.
  basic('Speakers guessed from the words');

  final String label;
  const SpeechEngine(this.label);
}

/// The languages the recorder can listen for. Each one changes a real
/// recognizer setting; nothing here is cosmetic.
enum SpeechLanguage {
  /// US English on every engine.
  english('English (US)', 'en-US'),

  /// Spanish and English in one visit: Deepgram Nova-3 multilingual
  /// (language=multi) or Android recognition in US Spanish (es-US). The
  /// on-device engine's models are English only, so it is not used.
  spanishEnglish('Spanish and English', 'es-US');

  final String label;

  /// Locale for Android speech recognition.
  final String androidLocale;
  const SpeechLanguage(this.label, this.androidLocale);
}

/// Microphone and language settings for one recording.
class CaptureSettings {
  /// Android's noise suppressor on the microphone (on-device and Deepgram
  /// engines; basic recognition uses the system's own processing).
  final bool noiseSuppression;
  final SpeechLanguage language;

  const CaptureSettings({this.noiseSuppression = true, this.language = SpeechLanguage.english});

  /// Deepgram query options for these settings.
  DeepgramOptions get deepgramOptions => language == SpeechLanguage.spanishEnglish
      // Nova-3 medical is English only; the general Nova-3 model handles
      // code-switching between Spanish and English.
      ? const DeepgramOptions(model: 'nova-3', language: 'multi')
      : const DeepgramOptions();
}

/// Picks the best available engine for the chosen mode. Returns null when
/// only basic speech recognition is available.
class SpeechEngines {
  SpeechEngines._();

  /// Set by the native engine once its models are on the phone.
  static TranscriptionProvider? Function({bool noiseSuppression})? onDeviceFactory;

  /// Test hook.
  @visibleForTesting
  static TranscriptionProvider? Function({required bool onDevice})? override;

  static (TranscriptionProvider, SpeechEngine)? pick({required bool onDevice, CaptureSettings settings = const CaptureSettings()}) {
    final o = override;
    if (o != null) {
      final p = o(onDevice: onDevice);
      return p == null ? null : (p, onDevice ? SpeechEngine.onDevice : SpeechEngine.cloud);
    }
    // The on-device models are English only.
    final english = settings.language == SpeechLanguage.english;
    TranscriptionProvider? native() => english ? onDeviceFactory?.call(noiseSuppression: settings.noiseSuppression) : null;
    // On-device mode never sends audio out; it uses the native engine or
    // falls back to basic recognition.
    if (onDevice) {
      final n = native();
      return n == null ? null : (n, SpeechEngine.onDevice);
    }

    final audio = RecordAudioSource(noiseSuppress: settings.noiseSuppression);
    final key = Integrations.settings.deepgramApiKey;
    if (key != null && key.isNotEmpty) {
      return (DeepgramStreamingProvider(key, options: settings.deepgramOptions, audioSource: audio), SpeechEngine.cloud);
    }
    final backend = SolisBackend.instance;
    if (backend.isConfigured) {
      return (
        DeepgramStreamingProvider.withTokens(() => backend.deepgramToken(ttlSeconds: 120), options: settings.deepgramOptions, audioSource: audio),
        SpeechEngine.cloud,
      );
    }
    final n = native();
    return n == null ? null : (n, SpeechEngine.onDevice);
  }
}

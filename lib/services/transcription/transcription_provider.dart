/// Common interface for live transcription engines that can tell speakers
/// apart (cloud diarization). The on-device speech_to_text path in the
/// encounter screen stays the fallback when no provider is configured.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// An engine that reports the loudness of the audio it is actually
/// capturing, 0 (silence) to 1 (loud speech), about ten times a second.
/// The recording screen's level meter and "no sound" warning use it.
abstract class AudioLevelSource {
  ValueListenable<double> get audioLevel;
}

/// Maps a level in dBFS to 0..1: -60 dBFS and below is silence, -10 dBFS
/// and above is full scale.
double dbfsToLevel(double dbfs) => ((dbfs + 60) / 50).clamp(0.0, 1.0);

/// Loudness of 16-bit little-endian PCM as 0..1 (RMS in dBFS, mapped by
/// [dbfsToLevel]). Empty or all-zero audio is 0.
double pcm16Level(Uint8List bytes) {
  final n = bytes.length ~/ 2;
  if (n == 0) return 0;
  final data = ByteData.sublistView(bytes);
  var sum = 0.0;
  for (var i = 0; i < n; i++) {
    final s = data.getInt16(i * 2, Endian.little).toDouble();
    sum += s * s;
  }
  final rms = math.sqrt(sum / n);
  if (rms <= 0) return 0;
  return dbfsToLevel(20 * math.log(rms / 32768) / math.ln10);
}

/// A run of words spoken by one voice, as reported by the engine.
///
/// [speakerIndex] is the engine's anonymous voice number (0, 1, 2, ...). It
/// says nothing about who the person is; speaker_roles.dart maps it to
/// Doctor, Patient or Other from what was said. [start] and [end] are seconds
/// from the start of the recording.
class DiarizedSegment {
  final int speakerIndex;
  final String text;
  final double start;
  final double end;
  final bool isFinal;

  const DiarizedSegment({
    required this.speakerIndex,
    required this.text,
    required this.start,
    required this.end,
    required this.isFinal,
  });

  DiarizedSegment copyWith({int? speakerIndex, String? text, double? start, double? end, bool? isFinal}) => DiarizedSegment(
        speakerIndex: speakerIndex ?? this.speakerIndex,
        text: text ?? this.text,
        start: start ?? this.start,
        end: end ?? this.end,
        isFinal: isFinal ?? this.isFinal,
      );

  /// Joins [other] (same speaker, later in time) onto this segment.
  DiarizedSegment mergedWith(DiarizedSegment other) => DiarizedSegment(
        speakerIndex: speakerIndex,
        text: _joinWords(text, other.text),
        start: start,
        end: other.end > end ? other.end : end,
        isFinal: isFinal && other.isFinal,
      );

  Map<String, dynamic> toJson() => {
        'speakerIndex': speakerIndex,
        'text': text,
        'start': start,
        'end': end,
        'isFinal': isFinal,
      };

  @override
  String toString() => 'DiarizedSegment($speakerIndex, "$text", $start-$end, final: $isFinal)';
}

String _joinWords(String a, String b) {
  final left = a.trimRight();
  final right = b.trimLeft();
  if (left.isEmpty) return right;
  if (right.isEmpty) return left;
  return '$left $right';
}

/// Connection state reported alongside each update so the UI can show
/// "Connecting", "Reconnecting" and so on.
enum TranscriptionStatus { connecting, listening, paused, reconnecting, closing, stopped, failed }

/// One snapshot of the live transcript, emitted every time it changes.
class TranscriptUpdate {
  /// Finalized conversation as "Doctor: ...\nPatient: ..." lines. Safe to put
  /// straight into the transcript field; the note engine parses these labels.
  final String transcript;

  /// Words the engine has heard but may still revise. Show it greyed after
  /// [transcript]; never store it as part of the record.
  final String interim;

  /// Finalized turns followed by any interim turns (isFinal false), in time
  /// order, consecutive words from one voice merged into a single turn.
  final List<DiarizedSegment> segments;

  /// The role chosen for each speaker index ("Doctor", "Patient", "Other").
  final Map<int, String> roles;

  final TranscriptionStatus status;

  /// Set when something went wrong (bad key, network drop, provider error).
  /// Errors are delivered as data on the stream, never thrown, so a listener
  /// without onError cannot crash the app.
  final String? error;

  const TranscriptUpdate({
    required this.transcript,
    required this.interim,
    required this.segments,
    this.roles = const {},
    this.status = TranscriptionStatus.listening,
    this.error,
  });

  List<DiarizedSegment> get finalSegments => segments.where((s) => s.isFinal).toList();
  List<DiarizedSegment> get interimSegments => segments.where((s) => !s.isFinal).toList();
  bool get hasError => error != null;
}

/// A live transcription engine.
///
/// Call [start] once and listen to the returned stream; then [pause],
/// [resume] and finally [stop], which returns the finalized labeled
/// transcript. The stream closes after [stop].
abstract class TranscriptionProvider {
  Stream<TranscriptUpdate> start();
  Future<void> pause();
  Future<void> resume();
  Future<String> stop();
}

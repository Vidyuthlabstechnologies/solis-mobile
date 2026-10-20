import '../coding/clinical_coder.dart';
import 'transcription_provider.dart';

/// Role names used in labeled transcripts.
class SpeakerRole {
  static const doctor = 'Doctor';
  static const patient = 'Patient';
  static const other = 'Other';
}

/// Per-speaker evidence used to pick roles. Exposed for tests and debugging.
class SpeakerProfile {
  final int speakerIndex;
  int sentences = 0;
  int words = 0;
  int questions = 0;
  int clinicalTerms = 0;
  int symptomTerms = 0;

  SpeakerProfile(this.speakerIndex);

  /// Positive leans physician, negative leans patient. Normalized by sentence
  /// count so the person who talks most does not win by volume alone.
  double get doctorLean => sentences == 0 ? 0 : (questions + clinicalTerms - symptomTerms) / sentences;
  double get patientLean => -doctorLean;

  @override
  String toString() =>
      'SpeakerProfile($speakerIndex: sentences $sentences, words $words, questions $questions, clinical $clinicalTerms, symptoms $symptomTerms)';
}

RegExp _re(String p) => RegExp(p, caseSensitive: false);

/// Maps anonymous engine speakers (0, 1, 2) to Doctor, Patient and Other from
/// the conversation itself:
///
/// - The Doctor asks the most questions and uses clinical language (exam,
///   vitals, prescribe, mg, follow up, order, refer).
/// - The Patient uses first-person symptom language (I have, I feel, my
///   chest, it hurts, since yesterday).
/// - Anyone else (a family member, interpreter, nurse) is Other.
///
/// Roles are recomputed as the conversation grows, so an early guess can
/// change once more has been said. Pass [overrides] to pin a role the
/// clinician corrected by hand.
class SpeakerRoleMapper {
  static final _clinical = _re(
    r'\b(exam\w*|vitals?|blood pressure|heart rate|pulse|oxygen|saturation|temperature|prescrib\w*|prescription|\d+\s?mg|mg\b|milligrams?|'
    r'dose|dosage|tablets?|capsules?|twice a day|once a day|daily|at bedtime|follow[- ]?up|diagnos\w*|order\w*|refer\w*|labs?|blood work|'
    r'x-ray|mri|ct scan|ultrasound|ekg|ecg|auscultat\w*|lungs sound|tenderness|range of motion|reflexes|recommend\w*|'
    r"let'?s|let me|i'?m going to|i want you to|we'?ll|we will|we need to|take a deep breath|on a scale)",
  );

  static final _symptom = _re(
    r"\b(i have|i've had|i've been|i had|i feel|i felt|i'?m feeling|i can'?t|i couldn'?t|i get|i keep|i was|i noticed|i think|"
    r'my (head|chest|feet|foot|knee|back|stomach|throat|ear|eye|arm|leg|neck|shoulder|hip|sugar|pressure|heart|skin|wife|husband|son|daughter)|'
    r'it hurts|hurts|it started|started (yesterday|last|this|two|three|a few)|it feels|it gets worse|keeps me up|since (yesterday|last|monday|tuesday|wednesday|thursday|friday|saturday|sunday|this))',
  );

  /// A question that a patient asks the doctor does not count toward the
  /// doctor score.
  static final _patientQuestion = _re(r"^(is (that|it) (bad|serious)|should i|can i|do i|will i|am i|what if i|how long (will|until)|doc|doctor)");

  static Map<int, SpeakerProfile> profile(Iterable<DiarizedSegment> segments) {
    final profiles = <int, SpeakerProfile>{};
    for (final seg in segments) {
      final p = profiles.putIfAbsent(seg.speakerIndex, () => SpeakerProfile(seg.speakerIndex));
      for (final sentence in ClinicalCoder.splitSentences(seg.text)) {
        final s = sentence.trim();
        if (s.isEmpty) continue;
        p.sentences++;
        p.words += s.split(RegExp(r'\s+')).length;
        if (s.endsWith('?') && !_patientQuestion.hasMatch(s)) p.questions++;
        p.clinicalTerms += _clinical.allMatches(s).length;
        p.symptomTerms += _symptom.allMatches(s).length;
      }
    }
    return profiles;
  }

  /// Returns a role for every speaker index found in [segments].
  ///
  /// Speaker indices are grouped into sessions of [speakerSessionStride]
  /// (0-99 first connection, 100-199 after a reconnect, ...), because a
  /// streaming engine renumbers voices on every new connection. Each session
  /// gets its own Doctor and Patient.
  static Map<int, String> assign(Iterable<DiarizedSegment> segments, {Map<int, String> overrides = const {}}) {
    final profiles = profile(segments);
    final roles = <int, String>{...overrides};
    final sessions = <int, Map<int, SpeakerProfile>>{};
    profiles.forEach((k, v) => sessions.putIfAbsent(k ~/ speakerSessionStride, () => {})[k] = v);
    for (final group in sessions.values) {
      final groupOverrides = {
        for (final e in overrides.entries)
          if (group.containsKey(e.key)) e.key: e.value,
      };
      roles.addAll(_assignGroup(group, groupOverrides));
    }
    return roles;
  }

  static Map<int, String> _assignGroup(Map<int, SpeakerProfile> profiles, Map<int, String> overrides) {
    final roles = <int, String>{};
    final unassigned = profiles.keys.where((k) => !overrides.containsKey(k)).toList();
    final doctorTaken = overrides.containsValue(SpeakerRole.doctor);
    final patientTaken = overrides.containsValue(SpeakerRole.patient);

    // Ties go to the speaker who spoke first (lower index), which in a
    // clinic is usually the clinician opening the visit.
    int byLean(int a, int b, double Function(SpeakerProfile) lean) {
      final c = lean(profiles[b]!).compareTo(lean(profiles[a]!));
      return c != 0 ? c : a.compareTo(b);
    }

    if (unassigned.length == 1 && !doctorTaken && !patientTaken) {
      // One voice: a dictation is the doctor unless it reads like a patient.
      final p = profiles[unassigned.first]!;
      roles[unassigned.first] = p.symptomTerms > p.questions + p.clinicalTerms ? SpeakerRole.patient : SpeakerRole.doctor;
      return roles;
    }

    if (!doctorTaken && unassigned.isNotEmpty) {
      unassigned.sort((a, b) => byLean(a, b, (p) => p.doctorLean));
      roles[unassigned.removeAt(0)] = SpeakerRole.doctor;
    }
    if (!patientTaken && unassigned.isNotEmpty) {
      // Among the rest, the patient is the one who describes symptoms most;
      // if nobody does, the one who said the most words.
      unassigned.sort((a, b) {
        if (profiles[a]!.symptomTerms == 0 && profiles[b]!.symptomTerms == 0) {
          final w = profiles[b]!.words.compareTo(profiles[a]!.words);
          return w != 0 ? w : a.compareTo(b);
        }
        return byLean(a, b, (p) => p.patientLean);
      });
      roles[unassigned.removeAt(0)] = SpeakerRole.patient;
    }
    for (final k in unassigned) {
      roles[k] = SpeakerRole.other;
    }
    return roles;
  }
}

/// Speaker indices from the Nth connection of one recording are offset by
/// N times this value, so voices from different connections never collide.
const int speakerSessionStride = 100;

/// Label written for [SpeakerRole.other] in transcript text. The note engine
/// (ClinicalCoder.diarize) recognizes Doctor, Patient, Nurse, Caregiver and
/// Family tags but not "Other", so Other speakers are written as Caregiver
/// by default; their words are then treated as patient-side history.
const String defaultOtherTranscriptLabel = 'Caregiver';

/// Builds "Doctor: ...\nPatient: ..." text from diarized segments.
///
/// Consecutive segments that map to the same role are merged into one line.
/// Only final segments are used unless [includeInterim] is true. When [roles]
/// is null the roles are inferred with [SpeakerRoleMapper.assign].
String buildLabeledTranscript(
  Iterable<DiarizedSegment> segments, {
  Map<int, String>? roles,
  bool includeInterim = false,
  String otherLabel = defaultOtherTranscriptLabel,
}) {
  final list = segments.where((s) => includeInterim || s.isFinal).where((s) => s.text.trim().isNotEmpty).toList();
  if (list.isEmpty) return '';
  final map = roles ?? SpeakerRoleMapper.assign(list);

  String label(int speaker) {
    final role = map[speaker] ?? SpeakerRole.other;
    return role == SpeakerRole.other ? otherLabel : role;
  }

  final lines = <String>[];
  String? currentLabel;
  final buffer = StringBuffer();
  void flush() {
    if (currentLabel == null || buffer.isEmpty) return;
    lines.add('$currentLabel: ${buffer.toString().trim()}');
    buffer.clear();
  }

  for (final seg in list) {
    final l = label(seg.speakerIndex);
    if (l != currentLabel) {
      flush();
      currentLabel = l;
    } else if (buffer.isNotEmpty) {
      buffer.write(' ');
    }
    buffer.write(seg.text.trim());
  }
  flush();
  return lines.join('\n');
}

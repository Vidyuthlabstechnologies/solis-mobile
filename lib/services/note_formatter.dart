import '../models/clinical_models.dart';
import '../models/note_style.dart';

/// Shapes a written note to the clinician's template, length and
/// abbreviation choice. It only rearranges, trims, labels and quotes what is
/// already in the note or the transcript; anything a template asks for that
/// was not said is written as "not discussed", never guessed.
class NoteFormatter {
  NoteFormatter._();

  /// Applies [style] to [e]. [ruledOut] (code to description) are the
  /// diagnoses the clinician ruled out for this patient; the coder already
  /// leaves them out, and the psych template lists them as ruled out.
  static ClinicalEncounter apply(ClinicalEncounter e, NoteStyle style, {Map<String, String> ruledOut = const {}}) {
    var s = e.subjective;
    var o = e.objective;
    var a = e.assessment;
    var p = e.plan;
    final turns = e.transcript;

    switch (style.template) {
      case NoteTemplate.soap:
        break;
      case NoteTemplate.primaryCare:
        s = _chiefComplaint(s);
      case NoteTemplate.urgentCare:
        s = _chiefComplaint(s);
        p = _withReturnPrecautions(p, turns);
      case NoteTemplate.psych:
        s = s.trim().isEmpty ? s : 'Interval history: ${s.trim()}';
        o = _mentalStatus(o, turns);
        if (ruledOut.isNotEmpty) {
          a = [if (a.trim().isNotEmpty) a.trim(), 'Ruled out (kept ruled out): ${ruledOut.entries.map((x) => '${x.key} ${x.value}').join('; ')}'].join('\n');
        }
    }

    switch (style.length) {
      case NoteLength.brief:
        s = _firstSentences(s, 2);
        o = _firstLines(o, 3);
      case NoteLength.standard:
        break;
      case NoteLength.detailed:
        final quote = _patientWords(turns);
        if (quote != null) s = '${s.trim()}\nIn the patient\'s words: "$quote"';
    }

    if (style.abbreviations != AbbreviationMode.asWritten) {
      final abbreviate = style.abbreviations == AbbreviationMode.abbreviate;
      s = abbreviations(s, abbreviate: abbreviate);
      o = abbreviations(o, abbreviate: abbreviate);
      a = abbreviations(a, abbreviate: abbreviate);
      p = abbreviations(p, abbreviate: abbreviate);
    }

    return e.copyWith(subjective: s, objective: o, assessment: a, plan: p);
  }

  // Long form and abbreviation, matched as whole words.
  static const _pairs = [
    ('blood pressure', 'BP'),
    ('heart rate', 'HR'),
    ('respiratory rate', 'RR'),
    ('oxygen saturation', 'SpO2'),
    ('three times daily', 'TID'),
    ('twice daily', 'BID'),
    ('at bedtime', 'QHS'),
    ('as needed', 'PRN'),
    ('by mouth', 'PO'),
    ('shortness of breath', 'SOB'),
    ('history of', 'h/o'),
    ('follow up', 'f/u'),
    ('without', 'w/o'),
  ];

  /// Spells common abbreviations out, or abbreviates their long forms.
  static String abbreviations(String text, {required bool abbreviate}) {
    var out = text;
    for (final (long, short) in _pairs) {
      if (abbreviate) {
        out = out.replaceAllMapped(RegExp('(?<![A-Za-z])${RegExp.escape(long)}(?![A-Za-z])', caseSensitive: false), (m) {
          // Keep a capital at the start of a sentence for lower-case forms.
          final first = m.group(0)![0];
          return short == short.toLowerCase() && first == first.toUpperCase() ? '${short[0].toUpperCase()}${short.substring(1)}' : short;
        });
      } else {
        out = out.replaceAllMapped(
          RegExp('(?<![A-Za-z0-9/])${RegExp.escape(short)}(?![A-Za-z0-9/])', caseSensitive: short != short.toLowerCase() ? true : false),
          (m) {
            final first = m.group(0)![0];
            return first == first.toUpperCase() && first != first.toLowerCase() && short == short.toLowerCase()
                ? '${long[0].toUpperCase()}${long.substring(1)}'
                : long;
          },
        );
      }
    }
    return out;
  }

  static final _sentenceEnd = RegExp(r'(?<=[.!?])\s+');

  static String _firstSentences(String text, int n) {
    final parts = text.trim().split(_sentenceEnd);
    return parts.length <= n ? text.trim() : parts.take(n).join(' ');
  }

  static String _firstLines(String text, int n) {
    final lines = text.trim().split('\n').where((l) => l.trim().isNotEmpty).toList();
    return lines.length <= n ? text.trim() : lines.take(n).join('\n');
  }

  /// "Chief complaint: (first sentence)", then "HPI: (the rest)".
  static String _chiefComplaint(String s) {
    final parts = s.trim().split(_sentenceEnd);
    if (parts.isEmpty || parts.first.isEmpty) return s;
    final cc = parts.first.replaceFirst(RegExp(r'^Patient presents with\s+', caseSensitive: false), '');
    final ccText = cc.isEmpty ? parts.first : '${cc[0].toUpperCase()}${cc.substring(1)}';
    return parts.length == 1 ? 'Chief complaint: $ccText' : 'Chief complaint: $ccText\nHPI: ${parts.skip(1).join(' ')}';
  }

  static final _returnWords = RegExp(r'emergency|\bER\b|\bE\.R\.|911|come back|return (here|to (the )?clinic)|gets? worse|worsen', caseSensitive: false);

  /// Urgent care: the return precautions that were given, or "not discussed".
  static String _withReturnPrecautions(String plan, List<SpeakerTurn> turns) {
    final said = <String>[];
    for (final t in turns.where((t) => t.speaker == 'Doctor' || t.speaker == 'Nurse')) {
      for (final s in t.text.split(_sentenceEnd)) {
        if (_returnWords.hasMatch(s) && !said.contains(s.trim())) said.add(s.trim());
      }
    }
    final line = said.isEmpty ? 'Return precautions: not discussed.' : 'Return precautions: ${said.join(' ')}';
    return [if (plan.trim().isNotEmpty) plan.trim(), line].join('\n');
  }

  static final _mse = <(String, RegExp)>[
    ('Mood', RegExp(r"\b(mood|feel(ing)?|felt)\b.*\b(down|sad|depressed|low|anxious|nervous|worried|okay|ok|good|better|worse|irritable|hopeless|empty)\b", caseSensitive: false)),
    ('Sleep', RegExp(r'\b(sleep|sleeping|insomnia|nightmares?)\b', caseSensitive: false)),
    ('Appetite', RegExp(r'\b(appetite|eating|weight)\b', caseSensitive: false)),
    ('Concentration', RegExp(r'\b(concentrat\w*|focus\w*)\b', caseSensitive: false)),
  ];

  static final _si = RegExp(r'suicid\w*|kill (myself|himself|herself)|end (my|his|her) life|hurt (myself|himself|herself)|self[- ]harm', caseSensitive: false);
  static final _hi = RegExp(r'homicid\w*|hurt (someone|anyone|others|somebody)|kill (someone|anyone|somebody)', caseSensitive: false);
  static final _negated = RegExp(r"\b(no|not|never|denies|deny|don't|dont|haven't|havent|without)\b", caseSensitive: false);

  /// Psych: mood, sleep, appetite and concentration in the patient's words,
  /// and suicidal and homicidal ideation as said, quoted for review.
  static String _mentalStatus(String objective, List<SpeakerTurn> turns) {
    final patient = [for (final t in turns.where((t) => t.speaker != 'Doctor' && t.speaker != 'Nurse')) ...t.text.split(_sentenceEnd)];
    final everyone = [for (final t in turns) ...t.text.split(_sentenceEnd)];
    final lines = <String>[];
    for (final (label, re) in _mse) {
      final hit = patient.where((s) => re.hasMatch(s)).firstOrNull;
      lines.add('$label: ${hit == null ? 'not discussed' : '"${hit.trim()}"'}');
    }
    String safety(String label, RegExp re) {
      final hit = everyone.where((s) => re.hasMatch(s)).toList();
      if (hit.isEmpty) return '$label: not discussed';
      final answer = _answerAfter(turns, re);
      if (answer != null) return '$label: asked; patient answered "$answer" (review)';
      final s = hit.first.trim();
      return _negated.hasMatch(s) ? '$label: denied ("$s")' : '$label: discussed, "$s" (review)';
    }

    lines.add(safety('Suicidal ideation', _si));
    lines.add(safety('Homicidal ideation', _hi));
    return [
      'Mental status (from the conversation):',
      ...lines,
      if (objective.trim().isNotEmpty) objective.trim(),
    ].join('\n');
  }

  /// The patient's reply to a clinician question matching [re].
  static String? _answerAfter(List<SpeakerTurn> turns, RegExp re) {
    for (var i = 0; i + 1 < turns.length; i++) {
      final asker = turns[i].speaker == 'Doctor' || turns[i].speaker == 'Nurse';
      if (asker && re.hasMatch(turns[i].text) && turns[i].text.trim().endsWith('?')) {
        final reply = turns[i + 1];
        if (reply.speaker != 'Doctor' && reply.speaker != 'Nurse') return reply.text.trim();
      }
    }
    return null;
  }

  /// The patient's first substantive statement, for detailed notes.
  static String? _patientWords(List<SpeakerTurn> turns) {
    for (final t in turns) {
      if (t.speaker == 'Doctor' || t.speaker == 'Nurse') continue;
      final text = t.text.trim();
      if (text.split(RegExp(r'\s+')).length >= 6) return text.length > 240 ? '${text.substring(0, 237)}...' : text;
    }
    return null;
  }
}

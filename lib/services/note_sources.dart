import '../models/clinical_models.dart';

/// One sentence of a note and the conversation turn that supports it.
class SentenceSource {
  final String sentence;

  /// Where the sentence sits in the section text.
  final int start;
  final int end;

  /// Index into the transcript of the best supporting turn, or null.
  final int? turnIndex;

  /// Share of the sentence's content words found in that turn, 0 to 1.
  final double score;

  /// False for sentences that make no claim worth sourcing ("Not
  /// discussed.", headings, very short fragments).
  final bool needsSource;

  const SentenceSource({
    required this.sentence,
    required this.start,
    required this.end,
    required this.turnIndex,
    required this.score,
    required this.needsSource,
  });

  /// A sentence that states something no turn of the conversation supports.
  bool get unsupported => needsSource && turnIndex == null;
}

/// Links each sentence of a note to the transcript turn it most likely came
/// from, so the clinician can check any sentence against what was said and
/// see at once which sentences have no source at all.
///
/// The match is word overlap with light normalization (plurals, numbers
/// split from units, common clinical abbreviations). It is a reviewing aid:
/// "no source" means "check this", not "this is wrong".
class NoteSources {
  NoteSources._();

  /// Share of content words a turn must contain to count as the source.
  static const double threshold = 0.3;

  static final _sentenceEnd = RegExp(r'(?<=[.!?])\s+|\n+');
  static final _token = RegExp(r'[a-z]+|\d+(?:\.\d+)?');

  static const _stop = {
    'the', 'and', 'for', 'with', 'was', 'were', 'has', 'have', 'had', 'his', 'her', 'she', 'him', 'they', 'them',
    'this', 'that', 'these', 'those', 'are', 'not', 'but', 'from', 'into', 'over', 'per', 'any', 'all', 'also',
    'been', 'being', 'will', 'would', 'should', 'can', 'could', 'does', 'did', 'patient', 'pt', 'reports', 'reported',
    'states', 'stated', 'notes', 'noted', 'denies', 'endorses', 'describes', 'today', 'currently', 'continue',
    'recommended', 'discussed', 'plan', 'which', 'who', 'about', 'there', 'their', 'then', 'than', 'you', 'your',
    'our', 'its', 'mrs', 'mr', 'ms', 'dr', 'doctor', 'yes', 'okay',
  };

  /// Abbreviations a note uses for words said out loud.
  static const _expand = {
    'bp': ['blood', 'pressure'],
    'hr': ['pulse', 'heart'],
    'spo2': ['oxygen'],
    'o2': ['oxygen'],
    'htn': ['blood', 'pressure', 'hypertension'],
    'dm': ['diabetes'],
    't2dm': ['diabetes'],
    'bid': ['twice'],
    'tid': ['three'],
    'qhs': ['bedtime', 'night'],
    'hs': ['bedtime'],
    'prn': ['needed'],
    'po': ['mouth'],
    'f': ['follow'],
    'fu': ['follow'],
    'wks': ['week'],
    'wk': ['week'],
    'mo': ['month'],
    'hx': ['history'],
    'sob': ['breath'],
    'cp': ['chest'],
    'n': ['nausea'],
    'abd': ['stomach', 'belly', 'abdomen'],
    // Clinical terms for words patients use.
    'diaphoresis': ['sweat', 'sweating'],
    'diaphoretic': ['sweat', 'sweating'],
    'paresthesia': ['tingling', 'needles', 'numb'],
    'paresthesias': ['tingling', 'needles', 'numb'],
    'dyspnea': ['breath'],
    'emesis': ['vomit', 'vomiting', 'threw'],
    'febrile': ['fever'],
    'pyrexia': ['fever'],
    'edema': ['swelling', 'swollen'],
    'syncope': ['faint', 'passed'],
    'myalgia': ['ache', 'aching', 'muscle'],
    'myalgias': ['ache', 'aching', 'muscle'],
    'pruritus': ['itch', 'itchy', 'itching'],
    'insomnia': ['sleep'],
  };

  /// Phrases that say nothing was found; they need no source.
  static final _noClaim = RegExp(
    r"^(nothing documented|not discussed|none( reported| discussed)?|n/?a|no (data|information)( available)?)\.?$|^coded as ",
    caseSensitive: false,
  );

  static String _stem(String w) {
    if (w.length > 4 && w.endsWith('ies')) return '${w.substring(0, w.length - 3)}y';
    if (w.length > 3 && w.endsWith('s') && !w.endsWith('ss')) return w.substring(0, w.length - 1);
    return w;
  }

  /// Content words of [text], normalized.
  static Set<String> words(String text) {
    final out = <String>{};
    for (final m in _token.allMatches(text.toLowerCase())) {
      final w = m.group(0)!;
      final expanded = _expand[w];
      if (expanded != null) {
        out.addAll(expanded.map(_stem));
        continue;
      }
      final isNumber = RegExp(r'^\d').hasMatch(w);
      if (!isNumber && (w.length < 3 || _stop.contains(w))) continue;
      out.add(isNumber ? w : _stem(w));
    }
    return out;
  }

  /// Splits [text] into sentences with their positions.
  static List<(String, int, int)> sentences(String text) {
    final out = <(String, int, int)>[];
    var from = 0;
    void add(int to) {
      final raw = text.substring(from, to);
      final lead = raw.length - raw.trimLeft().length;
      final s = raw.trim();
      if (s.isNotEmpty) out.add((s, from + lead, from + lead + s.length));
    }

    for (final m in _sentenceEnd.allMatches(text)) {
      add(m.start);
      from = m.end;
    }
    add(text.length);
    return out;
  }

  /// Links every sentence of [text] to its best supporting turn.
  static List<SentenceSource> link(String text, List<SpeakerTurn> turns) {
    final turnWords = [for (final t in turns) words(t.text)];
    return [
      for (final (s, start, end) in sentences(text)) _linkOne(s, start, end, turnWords),
    ];
  }

  static SentenceSource _linkOne(String s, int start, int end, List<Set<String>> turnWords) {
    final w = words(s);
    // Bullets and headings like "Vitals:" or "- Diabetes" make no claim worth flagging on their own.
    final needsSource = !_noClaim.hasMatch(s.replaceFirst(RegExp(r'^[-*\u2022\d.)\s]+'), '')) && w.length >= 2;
    int? best;
    var bestScore = 0.0;
    var bestHits = 0;
    if (w.isNotEmpty) {
      for (var i = 0; i < turnWords.length; i++) {
        // A question and its answer together ("Any sweating?" "Yes.") count
        // as one source, shown by the turn with more of the words.
        final pair = i + 1 < turnWords.length ? {...turnWords[i], ...turnWords[i + 1]} : turnWords[i];
        final hit = w.where(pair.contains).length;
        final score = hit / w.length;
        if (score > bestScore) {
          bestScore = score;
          bestHits = hit;
          final own = w.where(turnWords[i].contains).length;
          final next = i + 1 < turnWords.length ? w.where(turnWords[i + 1].contains).length : -1;
          best = next > own ? i + 1 : i;
        }
      }
    }
    final supported = best != null && (bestScore >= threshold || bestHits >= 4);
    return SentenceSource(
      sentence: s,
      start: start,
      end: end,
      turnIndex: supported ? best : null,
      score: bestScore,
      needsSource: needsSource,
    );
  }

  /// Number of sentences across [sections] with no source in [turns].
  static int unsupportedCount(Iterable<String> sections, List<SpeakerTurn> turns) {
    if (turns.isEmpty) return 0;
    return sections.expand((s) => link(s, turns)).where((x) => x.unsupported).length;
  }
}

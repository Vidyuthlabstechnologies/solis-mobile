// Suggests ICD-10-CM codes from free text using the official ICD-10-CM
// Alphabetic Index (Index to Diseases and Injuries).
//
// Each asset row is an index path such as "Pain|chest" with the code the
// index assigns to it. A path matches a sentence when every content word of
// every path segment appears in the sentence. Main terms written with commas
// ("Abdomen, abdominal") are treated as alternative spellings. The most
// specific matching path wins, and lone generic words ("pain") or negated
// findings ("denies chest pain") produce nothing.

import 'code_set_loader.dart';

/// One suggestion from [IcdIndex.suggest].
class IndexSuggestion {
  const IndexSuggestion(this.code, this.path, this.score);

  /// ICD-10-CM code with dot, as assigned by the index. May be a header that
  /// still needs more characters; check it against IcdCatalog.isBillable.
  final String code;

  /// Matched index path, segments joined by "|", for example "Pain|chest".
  final String path;

  /// Higher is better: matched content words times ten plus path depth.
  final int score;

  @override
  String toString() => '$code <- $path ($score)';
}

class _IndexEntry {
  _IndexEntry(this.path, this.code, this.segments, this.depth);

  final String path;
  final String code;

  /// Per path segment, the alternative word sets that satisfy it.
  final List<List<List<String>>> segments;
  final int depth;
}

class IcdIndex {
  IcdIndex._(this._entries, this._byKey, this.fiscalYear);

  /// Parses icd10cm_index_FY.tsv (path, code). [fiscalYear] labels the
  /// edition; 0 means unknown.
  factory IcdIndex.parse(String tsv, {int fiscalYear = 0}) {
    final entries = <_IndexEntry>[];
    final byKey = <String, List<int>>{};
    for (final row in tsvRows(tsv)) {
      if (row.length < 2) continue;
      final parts = row[0].split('|');
      // A final subterm with no content words ("specified NEC",
      // "unspecified") cannot be confirmed from text, so it is never treated
      // as more specific than its parent.
      if (parts.length > 1 && _contentWords(parts.last).isEmpty) continue;
      final segments = <List<List<String>>>[];
      for (var i = 0; i < parts.length; i++) {
        final alternatives = i == 0
            ? _mainTermAlternatives(parts[i])
            : [_contentWords(parts[i])];
        alternatives.removeWhere((a) => a.isEmpty);
        if (alternatives.isNotEmpty) segments.add(alternatives);
      }
      if (segments.isEmpty) continue;
      final idx = entries.length;
      entries.add(_IndexEntry(row[0], row[1], segments, parts.length));
      // Key on the first word of every alternative of the main term, so a
      // candidate lookup only needs the words present in the text.
      for (final alt in segments.first) {
        (byKey[alt.first] ??= <int>[]).add(idx);
      }
    }
    return IcdIndex._(entries, byKey, fiscalYear);
  }

  /// The index edition in effect today. Same as `forDate(DateTime.now())`.
  static Future<IcdIndex> load() => forDate(DateTime.now());

  /// The index edition for a date of service, switching on October 1 (see
  /// [IcdEditions.resolve]). Each edition is loaded once and cached.
  static Future<IcdIndex> forDate(DateTime dateOfService) =>
      forFiscalYear(IcdEditions.resolve(dateOfService));

  /// A specific bundled fiscal-year edition, loaded once and cached.
  static Future<IcdIndex> forFiscalYear(int fiscalYear) async {
    final file = CodeSetFiles.icd10cmIndex(fiscalYear);
    final index = await CodeSetLoader.load(
      file,
      (String tsv) => IcdIndex.parse(tsv, fiscalYear: fiscalYear),
    );
    if (index == null) {
      throw StateError('Missing code-set asset $file');
    }
    return index;
  }

  /// ICD-10-CM fiscal year of this edition (0 when parsed without one).
  final int fiscalYear;

  final List<_IndexEntry> _entries;
  final Map<String, List<int>> _byKey;

  int get length => _entries.length;

  Map<String, List<String>>? _pathsByCode;
  Map<String, List<(String, String)>>? _children;

  /// Every index path that assigns [code] (with dot), for example
  /// "Pain|chest" for R07.9.
  List<String> pathsFor(String code) {
    final map = _pathsByCode ??= () {
      final m = <String, List<String>>{};
      for (final e in _entries) {
        (m[e.code.toUpperCase()] ??= []).add(e.path);
      }
      return m;
    }();
    return map[code.trim().toUpperCase()] ?? const [];
  }

  /// Direct subterms of [path] that assign a code: (subterm, code) pairs.
  List<(String, String)> childrenOf(String path) {
    final map = _children ??= () {
      final m = <String, List<(String, String)>>{};
      for (final e in _entries) {
        final bar = e.path.lastIndexOf('|');
        if (bar <= 0) continue;
        (m[e.path.substring(0, bar)] ??= []).add((e.path.substring(bar + 1), e.code));
      }
      return m;
    }();
    return map[path] ?? const [];
  }

  static const Set<String> _stopWords = {
    'a',
    'an',
    'the',
    'of',
    'in',
    'on',
    'to',
    'at',
    'by',
    'for',
    'from',
    'with',
    'and',
    'or',
    'as',
    'due',
    'nec',
    'nos',
    'other',
    'unspecified',
    'specified',
    'classified',
    'elsewhere',
    'see',
    'also',
    'code',
    'codes',
    'condition',
    'site',
    'sites',
    'any',
    'type',
    'into',
    'than',
    'is',
    'are',
  };

  /// Single words too broad to justify a code on their own.
  static const Set<String> _genericWords = {
    'pain',
    'ache',
    'disease',
    'disorder',
    'syndrome',
    'history',
    'problem',
    'injury',
    'abnormal',
    'abnormality',
    'finding',
    'complication',
    'infection',
    'lesion',
    'mass',
    'deformity',
    'failure',
    'symptom',
    'sign',
    'examination',
    'exam',
    'observation',
    'status',
    'care',
    'admission',
    'encounter',
    'use',
    'test',
    'screening',
    'follow',
    'routine',
    'visit',
    'patient',
    'person',
    'factor',
    'change',
    'loss',
    'defect',
    'state',
    'reaction',
    'effect',
    'level',
    'presence',
    'absence',
    'counseling',
    'contact',
    'exposure',
    'need',
    'difficulty',
    'acute',
    'chronic',
    'left',
    'right',
    'severe',
    'mild',
    'moderate',
    'normal',
    'low',
    'high',
    'body',
    'head',
    'back',
    'well',
    'good',
    'poor',
    'rate',
    'cell',
    'growth',
    'fall',
    'cold',
    'stress',
    'tired',
    'feeling',
    'heart',
    'blood',
    'pressure',
    'diet',
    'weight',
    'tension',
    'family',
    'work',
    'social',
    'life',
    'drug',
    'medication',
    'nurse',
    'doctor',
    'disability',
    'dependence',
    'sick',
    'ill',
    'illness',
  };

  static const Set<String> _negations = {
    'no',
    'not',
    'denies',
    'denied',
    'deny',
    'without',
    'negative',
    'never',
    'free',
    'absent',
    'resolved',
  };

  static String _stem(String w) {
    if (w.length > 4 &&
        w.endsWith('s') &&
        !w.endsWith('ss') &&
        !w.endsWith('us') &&
        !w.endsWith('is')) {
      return w.substring(0, w.length - 1);
    }
    return w;
  }

  static final RegExp _clauseBreak = RegExp(r'[.;:,\n]|\bbut\b');

  static List<String> _clauses(String text) =>
      text.toLowerCase().split(_clauseBreak);

  /// Main terms such as "Abdomen, abdominal" or "Infection, infected" list
  /// spelling variants of one word, which are alternatives. Other commas
  /// ("Tenderness, abdominal") qualify the term, so their words are required.
  static List<List<String>> _mainTermAlternatives(String mainTerm) {
    final pieces = mainTerm.split(',').map(_contentWords).toList()
      ..removeWhere((p) => p.isEmpty);
    if (pieces.isEmpty) return [];
    final base = pieces.first;
    final head = base.first;
    final stem = head.length >= 4 ? head.substring(0, 4) : head;
    final variants = <List<String>>[];
    final required = <String>[...base];
    for (final piece in pieces.skip(1)) {
      if (piece.length == 1 && piece.first.startsWith(stem)) {
        variants.add(piece);
      } else {
        required.addAll(piece.where((w) => !required.contains(w)));
      }
    }
    return [
      required,
      for (final v in variants) [v.first, ...required.skip(1)],
    ];
  }

  static List<String> _contentWords(String text) {
    final cleaned = text.replaceAll(RegExp(r'\([^)]*\)'), ' ');
    return wordsOf(
      cleaned,
    ).where((w) => !_stopWords.contains(w)).map(_stem).toSet().toList();
  }

  /// Suggests codes for conditions named in [text], best first.
  ///
  /// Conservative by design: returns an empty list rather than guessing when
  /// only a generic word ("pain") matches, and ignores findings that follow a
  /// negation cue within three words ("no chest pain", "denies fever").
  List<IndexSuggestion> suggest(String text, {int limit = 5}) {
    // Negation applies within a clause only, and a word mentioned without
    // negation anywhere in the text is not treated as negated.
    final present = <String>{};
    final negated = <String>{};
    final affirmed = <String>{};
    for (final clause in _clauses(text)) {
      final raw = wordsOf(clause);
      final tokens = raw.map(_stem).toList();
      present.addAll(tokens);
      var window = 0;
      for (var i = 0; i < tokens.length; i++) {
        if (_negations.contains(raw[i])) {
          window = 3;
          continue;
        }
        if (window > 0) {
          negated.add(tokens[i]);
          window--;
        } else {
          affirmed.add(tokens[i]);
        }
      }
    }
    if (present.isEmpty || limit <= 0) return const [];
    negated.removeAll(affirmed);

    final matches = <_IndexEntry, Set<String>>{};
    final checked = <int>{};
    for (final w in present) {
      final candidates = _byKey[w];
      if (candidates == null) continue;
      for (final idx in candidates) {
        if (!checked.add(idx)) continue;
        final entry = _entries[idx];
        final used = _match(entry, present);
        if (used == null) continue;
        if (used.any(negated.contains)) continue;
        if (used.length == 1) {
          final only = used.first;
          if (_genericWords.contains(only) || only.length < 4) continue;
        }
        if (used.length <= 2 && used.every(_genericWords.contains)) continue;
        matches[entry] = used;
      }
    }
    if (matches.isEmpty) return const [];

    // Prefer the most specific path: drop any match whose path is a strict
    // prefix of another matched path.
    final paths = matches.keys.map((e) => e.path).toList();
    final specific = matches.entries.where((m) {
      final prefix = '${m.key.path}|';
      return !paths.any((p) => p.startsWith(prefix));
    });

    final best = <String, IndexSuggestion>{};
    for (final m in specific) {
      final score = m.value.length * 10 + m.key.depth;
      final current = best[m.key.code];
      if (current == null || current.score < score) {
        best[m.key.code] = IndexSuggestion(m.key.code, m.key.path, score);
      }
    }
    final out = best.values.toList()
      ..sort((a, b) {
        final c = b.score.compareTo(a.score);
        return c != 0 ? c : a.path.length.compareTo(b.path.length);
      });
    return out.take(limit).toList();
  }

  /// Returns the words used to satisfy [entry], or null when it does not match.
  static Set<String>? _match(_IndexEntry entry, Set<String> present) {
    final used = <String>{};
    for (final segment in entry.segments) {
      List<String>? hit;
      for (final alt in segment) {
        if (alt.every(present.contains)) {
          if (hit == null || alt.length > hit.length) hit = alt;
        }
      }
      if (hit == null) return null;
      used.addAll(hit);
    }
    return used;
  }
}

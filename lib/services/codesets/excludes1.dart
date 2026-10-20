// ICD-10-CM Excludes1 notes from the Tabular List, one asset per fiscal
// year (icd10cm_excludes1_<FY>.tsv.gz).
//
// Row format: the code, category, block range or chapter range the note sits
// at, then the excluded reference. Both columns are either a code (which
// covers every code below it), a prefix ending in "-" or ".-", or an
// inclusive range "A-B" (which covers every code below B as well). A note
// applies to every code below the place it sits (Guidelines I.A.12.a).

import 'code_set_loader.dart';

/// An inclusive span of ICD-10-CM codes in normalized form (no dot,
/// uppercase). A single code or prefix has [from] == [to].
class _Span {
  const _Span(this.from, this.to);

  factory _Span.parse(String ref) {
    var r = ref.trim().toUpperCase().replaceAll('.', '');
    // "A05-" and "A04.7-" are prefixes; "A04.0-A04.4" and "T61-T62" are ranges.
    if (r.endsWith('-')) r = r.substring(0, r.length - 1);
    final dash = r.indexOf('-');
    if (dash > 0) return _Span(r.substring(0, dash), r.substring(dash + 1));
    return _Span(r, r);
  }

  final String from;
  final String to;

  bool covers(String code) => code.compareTo(from) >= 0 && (code.startsWith(to) || code.compareTo(to) <= 0);

  @override
  String toString() {
    String dot(String c) => c.length <= 3 ? c : '${c.substring(0, 3)}.${c.substring(3)}';
    return from == to ? dot(from) : '${dot(from)}-${dot(to)}';
  }
}

class _Note {
  const _Note(this.at, this.excluded);

  final _Span at;
  final _Span excluded;
}

/// Two diagnoses on the same claim that an Excludes1 note says are not coded
/// together.
class Excludes1Conflict {
  const Excludes1Conflict(this.code, this.excluded, this.noteAt, this.excludedRef);

  /// The claim code the note applies to.
  final String code;

  /// The other claim code, which the note excludes.
  final String excluded;

  /// Where the note sits in the Tabular List (the code itself or an ancestor).
  final String noteAt;

  /// The excluded reference as written in the note.
  final String excludedRef;
}

class Excludes1 {
  Excludes1._(this._byLetter, this.length);

  factory Excludes1.parse(String tsv) {
    final byLetter = <String, List<_Note>>{};
    var count = 0;
    for (final row in tsvRows(tsv)) {
      if (row.length < 2 || row[0].startsWith('#')) continue;
      final note = _Note(_Span.parse(row[0]), _Span.parse(row[1]));
      if (note.at.from.isEmpty || note.excluded.from.isEmpty) continue;
      count++;
      // Index under every first letter the note's span covers (chapter
      // ranges such as A00-B99 cover more than one letter).
      final a = note.at.from.codeUnitAt(0), b = note.at.to.codeUnitAt(0);
      for (var l = a; l <= b; l++) {
        byLetter.putIfAbsent(String.fromCharCode(l), () => []).add(note);
      }
    }
    return Excludes1._(byLetter, count);
  }

  /// The notes, or null when the asset is not bundled.
  static Future<Excludes1?> load() => CodeSetLoader.load(CodeSetFiles.excludes1, Excludes1.parse);

  /// The Excludes1 notes of ICD-10-CM fiscal year [fy], or null when that
  /// edition's notes are not available.
  static Future<Excludes1?> forFiscalYear(int fy) => CodeSetLoader.load(CodeSetFiles.excludes1For(fy), Excludes1.parse);

  final Map<String, List<_Note>> _byLetter;

  /// Number of notes.
  final int length;

  static String _norm(String code) => code.trim().toUpperCase().replaceAll('.', '');

  /// Every Excludes1 conflict among [codes]. Each unordered pair is reported
  /// once, for the first code (in claim order) whose note excludes the other.
  List<Excludes1Conflict> conflicts(List<String> codes) {
    final norm = [for (final c in codes) _norm(c)];
    final out = <Excludes1Conflict>[];
    final seen = <String>{};
    for (var i = 0; i < codes.length; i++) {
      final c = norm[i];
      if (c.isEmpty) continue;
      for (final note in _byLetter[c[0]] ?? const <_Note>[]) {
        if (!note.at.covers(c)) continue;
        for (var j = 0; j < codes.length; j++) {
          if (i == j || norm[j] == c || !note.excluded.covers(norm[j])) continue;
          final key = i < j ? '$i:$j' : '$j:$i';
          if (!seen.add(key)) continue;
          out.add(Excludes1Conflict(codes[i], codes[j], note.at.toString(), note.excluded.toString()));
        }
      }
    }
    return out;
  }
}

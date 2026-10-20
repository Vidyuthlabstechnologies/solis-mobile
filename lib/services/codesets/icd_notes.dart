// ICD-10-CM Tabular List instructional notes, one asset per fiscal year
// (icd_notes_<FY>.tsv.gz): Excludes1, Excludes2, Code first, Use additional
// code, Code also and other notes, with the codes each note line refers to.
//
// Row format: node, kind, note text, comma separated references. The node is
// a code or category (with dot), or a block or chapter range such as
// "A15-A19". Kinds: E1 Excludes1, E2 Excludes2, CF code first, UA use
// additional code, CA code also, N note. A note applies to every code below
// the place it sits (Guidelines I.A.12 and I.A.13).

import 'code_set_loader.dart';

/// An inclusive span of ICD-10-CM codes in normalized form (no dot,
/// uppercase), parsed from a Tabular reference: a code or prefix ("E11",
/// "E11.-", "O24.4-") or a range ("C00-C96", "E00-E03.-").
class IcdSpan {
  const IcdSpan(this.from, this.to);

  factory IcdSpan.parse(String ref) {
    var r = ref.trim().toUpperCase().replaceAll('.', '');
    while (r.endsWith('-')) {
      r = r.substring(0, r.length - 1);
    }
    final dash = r.indexOf('-');
    if (dash > 0) return IcdSpan(r.substring(0, dash), r.substring(dash + 1));
    return IcdSpan(r, r);
  }

  final String from;
  final String to;

  bool get isEmpty => from.isEmpty;

  /// True when [code] (normalized or not) falls in the span, including every
  /// code below its upper end.
  bool covers(String code) {
    final c = code.trim().toUpperCase().replaceAll('.', '');
    if (c.isEmpty || from.isEmpty) return false;
    return c.compareTo(from) >= 0 && (c.startsWith(to) || c.compareTo(to) <= 0);
  }

  @override
  String toString() {
    String dot(String c) => c.length <= 3 ? c : '${c.substring(0, 3)}.${c.substring(3)}';
    return from == to ? dot(from) : '${dot(from)}-${dot(to)}';
  }
}

/// Kinds of Tabular instructional notes, in the order they are shown.
enum NoteKind { excludes1, excludes2, codeFirst, useAdditional, codeAlso, note }

String noteKindLabel(NoteKind k) => switch (k) {
      NoteKind.excludes1 => 'Excludes1',
      NoteKind.excludes2 => 'Excludes2',
      NoteKind.codeFirst => 'Code first',
      NoteKind.useAdditional => 'Use additional code',
      NoteKind.codeAlso => 'Code also',
      NoteKind.note => 'Note',
    };

/// One line of a Tabular note.
class TabularNote {
  const TabularNote(this.at, this.kind, this.text, this.refs, {required this.isRange});

  /// Where the note sits: the code itself, an ancestor category, or a block
  /// or chapter range.
  final String at;
  final NoteKind kind;
  final String text;

  /// Codes or ranges the line names.
  final List<IcdSpan> refs;

  /// True for notes at a block or chapter range (broad notes that apply to a
  /// whole group of categories).
  final bool isRange;

  /// True when [code] is one of the codes this line names.
  bool names(String code) => refs.any((r) => r.covers(code));

  /// True when the line qualifies its codes ("with .42", "with fifth
  /// character 1"), so the bare references are wider than the note.
  bool get isQualified => RegExp(r'\bwith (\.|fifth|sixth|5th|6th|\d)', caseSensitive: false).hasMatch(text);
}

class IcdNotes {
  IcdNotes._(this._byNode, this._ranges, this.length);

  factory IcdNotes.parse(String tsv) {
    final byNode = <String, List<TabularNote>>{};
    final ranges = <(IcdSpan, String)>[];
    var count = 0;
    for (final row in tsvRows(tsv)) {
      if (row.length < 3) continue;
      final kind = switch (row[1]) {
        'E1' => NoteKind.excludes1,
        'E2' => NoteKind.excludes2,
        'CF' => NoteKind.codeFirst,
        'UA' => NoteKind.useAdditional,
        'CA' => NoteKind.codeAlso,
        'N' => NoteKind.note,
        _ => null,
      };
      if (kind == null) continue;
      final node = row[0].trim().toUpperCase();
      final isRange = node.contains('-');
      final key = node.replaceAll('.', '');
      final refs = row.length > 3 && row[3].isNotEmpty
          ? [for (final r in row[3].split(',')) IcdSpan.parse(r)].where((s) => !s.isEmpty).toList()
          : const <IcdSpan>[];
      final list = byNode.putIfAbsent(key, () {
        if (isRange) ranges.add((IcdSpan.parse(node), key));
        return [];
      });
      list.add(TabularNote(node, kind, row[2], refs, isRange: isRange));
      count++;
    }
    return IcdNotes._(byNode, ranges, count);
  }

  /// The notes, or null when the asset is not bundled.
  static Future<IcdNotes?> load() => CodeSetLoader.load(CodeSetFiles.icdNotes, IcdNotes.parse);

  /// The Tabular notes of ICD-10-CM fiscal year [fy], or null when that
  /// edition's notes are not available.
  static Future<IcdNotes?> forFiscalYear(int fy) => CodeSetLoader.load(CodeSetFiles.icdNotesFor(fy), IcdNotes.parse);

  final Map<String, List<TabularNote>> _byNode;
  final List<(IcdSpan, String)> _ranges;

  /// Number of note lines.
  final int length;

  /// Every note line that applies to [code]: chapter and block notes first,
  /// then the category and each subcategory down to the code itself.
  /// [ranges] false leaves out block and chapter notes.
  List<TabularNote> notesFor(String code, {bool ranges = true}) {
    final c = code.trim().toUpperCase().replaceAll('.', '');
    if (c.length < 3) return const [];
    final out = <TabularNote>[];
    if (ranges) {
      final category = c.substring(0, 3);
      for (final (span, key) in _ranges) {
        if (span.covers(category)) out.addAll(_byNode[key]!);
      }
    }
    for (var n = 3; n <= c.length; n++) {
      out.addAll(_byNode[c.substring(0, n)] ?? const []);
    }
    return out;
  }

  /// Notes of one [kind] that apply to [code].
  List<TabularNote> of(String code, NoteKind kind, {bool ranges = true}) =>
      [for (final n in notesFor(code, ranges: ranges)) if (n.kind == kind) n];
}

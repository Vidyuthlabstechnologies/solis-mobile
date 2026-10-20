// NCCI Medically Unlikely Edits for practitioner services (CMS quarterly
// table). Each code has a maximum number of units per line or per day and an
// MUE adjudication indicator (MAI):
//   1 = line edit, 2 = date of service edit (policy),
//   3 = date of service edit (clinical).

import 'code_set_loader.dart';

class MueEntry {
  const MueEntry(this.code, this.maxUnits, this.adjudicationIndicator);

  final String code;
  final int maxUnits;
  final int adjudicationIndicator;
}

class Mue {
  Mue._(this._entries);

  /// Parses mue_practitioner.tsv (code, max units, adjudication indicator).
  factory Mue.parse(String tsv) {
    final entries = <String, MueEntry>{};
    for (final row in tsvRows(tsv)) {
      if (row.length < 3) continue;
      final units = int.tryParse(row[1]);
      final mai = int.tryParse(row[2]);
      if (units == null || mai == null) continue;
      final code = row[0].toUpperCase();
      entries[code] = MueEntry(code, units, mai);
    }
    return Mue._(entries);
  }

  static Future<Mue> load() async {
    final mue = await CodeSetLoader.load(
      CodeSetFiles.muePractitioner,
      Mue.parse,
    );
    if (mue == null) {
      throw StateError(
        'Missing code-set asset ${CodeSetFiles.muePractitioner}',
      );
    }
    return mue;
  }

  final Map<String, MueEntry> _entries;

  int get length => _entries.length;

  MueEntry? lookup(String code) => _entries[code.trim().toUpperCase()];

  /// Maximum units of service, or null when the code has no MUE.
  int? maxUnits(String code) => lookup(code)?.maxUnits;

  /// MUE adjudication indicator (1, 2 or 3), or null when there is no MUE.
  int? adjudicationIndicator(String code) =>
      lookup(code)?.adjudicationIndicator;

  /// True when [units] exceeds the MUE for [code].
  bool exceeds(String code, int units) {
    final max = maxUnits(code);
    return max != null && units > max;
  }
}

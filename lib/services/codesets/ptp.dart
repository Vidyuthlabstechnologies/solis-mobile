// NCCI procedure-to-procedure (PTP) edits for practitioner services.
//
// The asset ptp_practitioner.tsv.gz is optional: CMS publishes the full PTP
// tables only behind an AMA CPT license click-through, so the build script
// includes them only when the license has been accepted and the files placed
// next to the other downloads. When the asset is missing, [Ptp.load] returns
// an empty table whose [Ptp.available] is false.
//
// Row format: column1 code, then a comma separated list where each item is a
// column 2 code followed by its modifier indicator digit, in the shape
// "AAAAA<TAB>BBBBB0,CCCCC1".

import 'code_set_loader.dart';

class PtpEdit {
  const PtpEdit(this.column1, this.column2, this.modifierIndicator);

  final String column1;
  final String column2;

  /// 0 = modifier not allowed, 1 = modifier allowed, 9 = not applicable.
  final int modifierIndicator;

  /// True when an NCCI-associated modifier can bypass the edit.
  bool get modifierAllowed => modifierIndicator == 1;
}

class Ptp {
  Ptp._(this._rows, this.available);

  /// Parses ptp_practitioner.tsv. Rows stay as raw strings and are only split
  /// when queried, which keeps memory low for a table of this size.
  factory Ptp.parse(String tsv) {
    final rows = <String, String>{};
    for (final row in tsvRows(tsv)) {
      if (row.length < 2) continue;
      rows[row[0].toUpperCase()] = row[1];
    }
    return Ptp._(rows, true);
  }

  /// An empty table, used when the optional asset is not bundled.
  factory Ptp.empty() => Ptp._(const {}, false);

  static Future<Ptp> load() async {
    final ptp = await CodeSetLoader.load(
      CodeSetFiles.ptpPractitioner,
      Ptp.parse,
    );
    return ptp ?? Ptp.empty();
  }

  final Map<String, String> _rows;

  /// False when the PTP asset is not bundled; every lookup then returns null.
  final bool available;

  int get column1Count => _rows.length;

  /// The active edit for the pair, or null when there is none. Order matters:
  /// [column1] is the comprehensive code and [column2] the component code.
  PtpEdit? edit(String column1, String column2) {
    final c1 = column1.trim().toUpperCase();
    final c2 = column2.trim().toUpperCase();
    final list = _rows[c1];
    if (list == null || c2.length != 5) return null;
    var start = 0;
    while (start < list.length) {
      final end = list.indexOf(',', start);
      final item = list.substring(start, end < 0 ? list.length : end);
      if (item.length == 6 && item.startsWith(c2)) {
        return PtpEdit(c1, c2, int.parse(item.substring(5)));
      }
      if (end < 0) break;
      start = end + 1;
    }
    return null;
  }

  /// True when an active edit exists for the pair in either order.
  bool conflicts(String a, String b) =>
      edit(a, b) != null || edit(b, a) != null;
}

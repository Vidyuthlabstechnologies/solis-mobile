// NCCI add-on code (AOC) edits active on 2026-10-01 (CMS quarterly file
// add-code-edits-medicare-effective-10012026), asset ncci_addon.tsv.gz.
// Codes are bare HCPCS/CPT numbers as CMS publishes them; no descriptors.
//
// Row format: add-on code, AOC type, comma separated primary codes.
//   Type 1: only the listed primary codes are acceptable.
//   Type 2: the Medicare contractor defines the primary codes (none listed).
//   Type 3: the listed primary codes plus contractor-defined ones.
// Medicare NCCI Policy Manual, Chapter I, Sections R and W.

import 'code_set_loader.dart';

class AddOnEdit {
  const AddOnEdit(this.addOn, this.type, this.primaries);

  final String addOn;
  final int type;
  final Set<String> primaries;
}

class AddOnCodes {
  AddOnCodes._(this._edits);

  factory AddOnCodes.parse(String tsv) {
    final edits = <String, AddOnEdit>{};
    for (final row in tsvRows(tsv)) {
      if (row.length < 2) continue;
      final type = int.tryParse(row[1]);
      if (type == null) continue;
      final code = row[0].trim().toUpperCase();
      final primaries = row.length > 2 ? row[2].split(',').map((c) => c.trim().toUpperCase()).where((c) => c.isNotEmpty).toSet() : <String>{};
      edits[code] = AddOnEdit(code, type, primaries);
    }
    return AddOnCodes._(edits);
  }

  /// The add-on edits, or null when the asset is not bundled.
  static Future<AddOnCodes?> load() => CodeSetLoader.load(CodeSetFiles.addOnCodes, AddOnCodes.parse);

  final Map<String, AddOnEdit> _edits;

  int get length => _edits.length;

  /// The edit for [code] when it is an add-on code, otherwise null.
  AddOnEdit? lookup(String code) => _edits[code.trim().toUpperCase()];
}

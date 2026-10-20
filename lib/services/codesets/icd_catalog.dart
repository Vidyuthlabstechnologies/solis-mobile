// ICD-10-CM code catalog built from the official CMS code descriptions file
// (icd10cm_order_YYYY.txt). Every code in the tabular list is present, both
// headers (categories and subcategories that are not valid for submission)
// and billable codes (valid for HIPAA-covered transactions).

import 'code_set_loader.dart';

/// One ICD-10-CM code from the official tabular order file.
class IcdEntry {
  const IcdEntry(this.code, this.billable, this.description);

  /// Code with a dot after the category, for example "I21.19".
  final String code;

  /// True when the code is valid for submission (a leaf code). Headers such as
  /// "I21.1" are false.
  final bool billable;

  /// Official long description.
  final String description;

  @override
  String toString() => '$code ${billable ? '' : '(header) '}$description';
}

class IcdCatalog {
  IcdCatalog._(
    this._entries,
    this._order,
    this._lowerDescriptions,
    this.fiscalYear,
  );

  /// Parses icd10cm_FY.tsv (code, billable flag, description). [fiscalYear]
  /// labels the edition; 0 means unknown.
  factory IcdCatalog.parse(String tsv, {int fiscalYear = 0}) {
    final entries = <String, IcdEntry>{};
    final order = <String>[];
    final lower = <String>[];
    for (final row in tsvRows(tsv)) {
      if (row.length < 3) continue;
      final entry = IcdEntry(row[0], row[1] == '1', row[2]);
      final key = normalize(row[0]);
      entries[key] = entry;
      order.add(key);
      lower.add(row[2].toLowerCase());
    }
    return IcdCatalog._(entries, order, lower, fiscalYear);
  }

  /// The edition in effect today. Same as `forDate(DateTime.now())`.
  static Future<IcdCatalog> load() => forDate(DateTime.now());

  /// The edition for a date of service, switching on October 1 (see
  /// [IcdEditions.resolve]). Each edition is loaded once and cached.
  static Future<IcdCatalog> forDate(DateTime dateOfService) =>
      forFiscalYear(IcdEditions.resolve(dateOfService));

  /// A specific bundled fiscal-year edition, loaded once and cached.
  static Future<IcdCatalog> forFiscalYear(int fiscalYear) async {
    final file = CodeSetFiles.icd10cm(fiscalYear);
    final catalog = await CodeSetLoader.load(
      file,
      (String tsv) => IcdCatalog.parse(tsv, fiscalYear: fiscalYear),
    );
    if (catalog == null) {
      throw StateError('Missing code-set asset $file');
    }
    return catalog;
  }

  /// ICD-10-CM fiscal year of this edition (0 when parsed without one).
  final int fiscalYear;

  final Map<String, IcdEntry> _entries;
  final List<String> _order;
  final List<String> _lowerDescriptions;

  /// Number of codes (headers plus billable codes).
  int get length => _entries.length;

  /// Uppercase code without dot or spaces: "i21.19" -> "I2119".
  static String normalize(String code) =>
      code.trim().toUpperCase().replaceAll('.', '').replaceAll(' ', '');

  /// Formats a code with the dot after the third character: "I2119" -> "I21.19".
  static String format(String code) {
    final n = normalize(code);
    return n.length <= 3 ? n : '${n.substring(0, 3)}.${n.substring(3)}';
  }

  /// Entry for [code] (with or without dot), or null when it is not in the
  /// official code set.
  IcdEntry? lookup(String code) => _entries[normalize(code)];

  /// Official description, or null when the code does not exist.
  String? description(String code) => lookup(code)?.description;

  /// True when [code] exists in the official tabular list (header or leaf).
  bool isValid(String code) => _entries.containsKey(normalize(code));

  /// True when [code] is a leaf code valid for submission on a claim.
  bool isBillable(String code) => lookup(code)?.billable ?? false;

  /// Billable child codes under a header, for example "M54.5" ->
  /// [M54.50, M54.51, M54.59]. Empty when the code is unknown or billable.
  List<IcdEntry> billableChildren(String code, {int limit = 50}) {
    final key = normalize(code);
    final out = <IcdEntry>[];
    for (final k in _order) {
      if (k.length > key.length && k.startsWith(key)) {
        final e = _entries[k]!;
        if (e.billable) out.add(e);
        if (out.length >= limit) break;
      }
    }
    return out;
  }

  /// Searches by code prefix first, then by description words.
  ///
  /// Code-prefix hits come first (exact match, then shorter codes), followed by
  /// entries whose description contains every query word as a word prefix,
  /// ranked by billable first, then by fewer extra words.
  List<IcdEntry> search(String query, {int limit = 20}) {
    final q = query.trim();
    if (q.isEmpty || limit <= 0) return const [];
    final results = <IcdEntry>[];
    final seen = <String>{};

    final codeKey = normalize(q);
    if (RegExp(r'^[A-Z][0-9][0-9A-Z]{0,5}$').hasMatch(codeKey)) {
      final exact = _entries[codeKey];
      if (exact != null) {
        results.add(exact);
        seen.add(codeKey);
      }
      final prefixed =
          <String>[
            for (final k in _order)
              if (k != codeKey && k.startsWith(codeKey)) k,
          ]..sort((a, b) {
            final byLen = a.length.compareTo(b.length);
            return byLen != 0 ? byLen : a.compareTo(b);
          });
      for (final k in prefixed) {
        if (results.length >= limit) break;
        results.add(_entries[k]!);
        seen.add(k);
      }
      if (results.length >= limit) return results;
    }

    final terms = wordsOf(q);
    if (terms.isEmpty) return results;
    final scored = <(int, String)>[];
    for (var i = 0; i < _order.length; i++) {
      final key = _order[i];
      if (seen.contains(key)) continue;
      final desc = _lowerDescriptions[i];
      // Cheap substring filter before tokenizing.
      if (!terms.every(desc.contains)) continue;
      final words = wordsOf(desc);
      var all = true;
      for (final t in terms) {
        if (!words.any((w) => w.startsWith(t))) {
          all = false;
          break;
        }
      }
      if (!all) continue;
      final entry = _entries[key]!;
      final extra = words.length - terms.length;
      final exactWords = terms.where(words.contains).length;
      final score = (entry.billable ? 0 : 1000) + extra * 2 - exactWords * 5;
      scored.add((score, key));
    }
    scored.sort((a, b) {
      final c = a.$1.compareTo(b.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    });
    for (final s in scored) {
      if (results.length >= limit) break;
      results.add(_entries[s.$2]!);
    }
    return results;
  }
}

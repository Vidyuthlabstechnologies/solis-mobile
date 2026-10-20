// HCPCS Level II catalog from the CMS quarterly alpha-numeric HCPCS file.
// Only active Level II codes (letter plus four digits) are included; CPT
// (Level I) codes and descriptors are not part of this asset.

import 'code_set_loader.dart';

class HcpcsEntry {
  const HcpcsEntry(this.code, this.shortDescription, this.longDescription);

  final String code;
  final String shortDescription;
  final String longDescription;

  @override
  String toString() => '$code $shortDescription';
}

class HcpcsCatalog {
  HcpcsCatalog._(this._entries, this._order);

  /// Parses hcpcs.tsv (code, short description, long description).
  factory HcpcsCatalog.parse(String tsv) {
    final entries = <String, HcpcsEntry>{};
    final order = <String>[];
    for (final row in tsvRows(tsv)) {
      if (row.length < 2) continue;
      final code = row[0].toUpperCase();
      entries[code] = HcpcsEntry(
        code,
        row[1],
        row.length > 2 ? row[2] : row[1],
      );
      order.add(code);
    }
    return HcpcsCatalog._(entries, order);
  }

  static Future<HcpcsCatalog> load() async {
    final catalog = await CodeSetLoader.load(
      CodeSetFiles.hcpcs,
      HcpcsCatalog.parse,
    );
    if (catalog == null) {
      throw StateError('Missing code-set asset ${CodeSetFiles.hcpcs}');
    }
    return catalog;
  }

  final Map<String, HcpcsEntry> _entries;
  final List<String> _order;

  int get length => _entries.length;

  static String normalize(String code) => code.trim().toUpperCase();

  HcpcsEntry? lookup(String code) => _entries[normalize(code)];

  /// True when [code] is an active HCPCS Level II code.
  bool isValid(String code) => _entries.containsKey(normalize(code));

  /// Code-prefix matches first, then entries whose short or long description
  /// contains every query word as a word prefix.
  List<HcpcsEntry> search(String query, {int limit = 20}) {
    final q = query.trim();
    if (q.isEmpty || limit <= 0) return const [];
    final results = <HcpcsEntry>[];
    final seen = <String>{};
    final key = normalize(q);
    if (RegExp(r'^[A-Z][0-9]{0,4}$').hasMatch(key)) {
      for (final code in _order) {
        if (results.length >= limit) return results;
        if (code.startsWith(key)) {
          results.add(_entries[code]!);
          seen.add(code);
        }
      }
    }
    final terms = wordsOf(q);
    if (terms.isEmpty) return results;
    final scored = <(int, String)>[];
    for (final code in _order) {
      if (seen.contains(code)) continue;
      final e = _entries[code]!;
      final text = '${e.shortDescription} ${e.longDescription}'.toLowerCase();
      if (!terms.every(text.contains)) continue;
      final words = wordsOf(text);
      if (!terms.every((t) => words.any((w) => w.startsWith(t)))) continue;
      scored.add((wordsOf(e.longDescription).length, code));
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

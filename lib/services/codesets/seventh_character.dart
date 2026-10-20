// ICD-10-CM 7th character definitions from the Tabular List
// ("sevenChrDef" notes), one asset per fiscal year (icd_7th_<FY>.tsv.gz).
//
// Row format: category or subcategory prefix (with dot), then the allowed
// 7th characters as "A=initial encounter|D=subsequent encounter|S=sequela".
// A code under a prefix needs a 7th character from that list; the longest
// matching prefix wins (Guidelines I.A.5). Codes shorter than 6 characters are
// padded with the placeholder X first (Guidelines I.A.4).

import 'code_set_loader.dart';

class SeventhCharacterRule {
  const SeventhCharacterRule(this.prefix, this.characters);

  /// The category or subcategory the 7th character note sits at, e.g. S83.
  final String prefix;

  /// Allowed 7th characters and what they mean, in Tabular order.
  final Map<String, String> characters;

  bool allows(String character) => characters.containsKey(character.toUpperCase());

  /// "A initial encounter, D subsequent encounter, S sequela".
  String describe() => characters.entries.map((e) => '${e.key} ${e.value}').join(', ');
}

class SeventhCharacters {
  SeventhCharacters._(this._rules);

  factory SeventhCharacters.parse(String tsv) {
    final rules = <String, SeventhCharacterRule>{};
    for (final row in tsvRows(tsv)) {
      if (row.length < 2) continue;
      final chars = <String, String>{};
      for (final part in row[1].split('|')) {
        final eq = part.indexOf('=');
        if (eq <= 0) continue;
        chars[part.substring(0, eq).trim().toUpperCase()] = part.substring(eq + 1).trim();
      }
      if (chars.isEmpty) continue;
      final prefix = row[0].trim().toUpperCase();
      rules[_norm(prefix)] = SeventhCharacterRule(prefix, chars);
    }
    return SeventhCharacters._(rules);
  }

  /// The definitions, or null when the asset is not bundled.
  static Future<SeventhCharacters?> load() => CodeSetLoader.load(CodeSetFiles.seventhCharacter, SeventhCharacters.parse);

  /// The 7th character definitions of ICD-10-CM fiscal year [fy], or null
  /// when that edition's definitions are not available.
  static Future<SeventhCharacters?> forFiscalYear(int fy) =>
      CodeSetLoader.load(CodeSetFiles.seventhCharacterFor(fy), SeventhCharacters.parse);

  final Map<String, SeventhCharacterRule> _rules;

  int get length => _rules.length;

  static String _norm(String code) => code.trim().toUpperCase().replaceAll('.', '');

  /// The 7th character rule for [code] (longest matching prefix), or null when
  /// codes there have no 7th character.
  SeventhCharacterRule? ruleFor(String code) {
    final c = _norm(code);
    for (var n = c.length < 6 ? c.length : 6; n >= 3; n--) {
      final rule = _rules[c.substring(0, n)];
      if (rule != null) return rule;
    }
    return null;
  }
}

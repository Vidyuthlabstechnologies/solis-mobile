// Definitions of Medicare Code Edits (MCE) v44.0, effective 2026-10-01
// (FY2027), from the CMS FY2027 final rule MCE definitions. Only the code
// lists the claim edits use are bundled (asset mce_v44.tsv.gz):
//
//   age_newborn       edit 4A, age 0 only
//   age_pediatric     edit 4B, age 0 through 17
//   age_maternity     edit 4C, age 9 through 64
//   age_adult         edit 4D, age 15 through 124
//   manifestation_not_principal          edit 6
//   unacceptable_principal               edit 9 (inpatient)
//   unacceptable_principal_requires_secondary  edit 9 codes that are
//                     acceptable when a secondary diagnosis is present
//   unspecified_with_laterality_available      edit 20, unspecified-side
//                     codes for which a code with laterality exists
//
// Row format: list name, age min, age max, comma separated codes (with dots).

import 'code_set_loader.dart';

/// An MCE age list a diagnosis belongs to.
class MceAge {
  const MceAge(this.list, this.min, this.max);

  /// MCE list name, for example "age_adult".
  final String list;
  final int min;
  final int max;

  /// Plain-English label, for example "adult (age 15 to 124)".
  String get label {
    final kind = switch (list) {
      'age_newborn' => 'newborn',
      'age_pediatric' => 'pediatric',
      'age_maternity' => 'maternity',
      'age_adult' => 'adult',
      _ => list,
    };
    return min == max ? '$kind (age $min)' : '$kind (age $min to $max)';
  }

  bool contains(int age) => age >= min && age <= max;
}

class Mce {
  Mce._(this._age, this._manifestation, this._unacceptable, this._requiresSecondary, this._unspecifiedLaterality);

  factory Mce.parse(String tsv) {
    final age = <String, MceAge>{};
    final manifestation = <String>{};
    final unacceptable = <String>{};
    final requiresSecondary = <String>{};
    final unspecifiedLaterality = <String>{};
    for (final row in tsvRows(tsv)) {
      if (row.length < 4) continue;
      final name = row[0];
      final codes = row[3].split(',').where((c) => c.isNotEmpty).map(_norm);
      if (name.startsWith('age_')) {
        final min = int.tryParse(row[1]);
        final max = int.tryParse(row[2]);
        if (min == null || max == null) continue;
        final a = MceAge(name, min, max);
        for (final c in codes) {
          age.putIfAbsent(c, () => a);
        }
      } else if (name == 'manifestation_not_principal') {
        manifestation.addAll(codes);
      } else if (name == 'unacceptable_principal') {
        unacceptable.addAll(codes);
      } else if (name == 'unacceptable_principal_requires_secondary') {
        requiresSecondary.addAll(codes);
      } else if (name == 'unspecified_with_laterality_available') {
        unspecifiedLaterality.addAll(codes);
      }
    }
    return Mce._(age, manifestation, unacceptable, requiresSecondary, unspecifiedLaterality);
  }

  /// The MCE lists, or null when the asset is not bundled.
  static Future<Mce?> load() => CodeSetLoader.load(CodeSetFiles.mce, Mce.parse);

  final Map<String, MceAge> _age;
  final Set<String> _manifestation;
  final Set<String> _unacceptable;
  final Set<String> _requiresSecondary;
  final Set<String> _unspecifiedLaterality;

  static String _norm(String code) => code.trim().toUpperCase().replaceAll('.', '');

  /// Number of codes on the four age lists.
  int get ageCodeCount => _age.length;

  /// The MCE age list [code] is on, or null when it has no age edit.
  MceAge? ageFor(String code) => _age[_norm(code)];

  /// True for manifestation codes that are never the principal or
  /// first-listed diagnosis (MCE edit 6).
  bool isManifestation(String code) => _manifestation.contains(_norm(code));

  /// True for codes MCE edit 9 does not accept as the principal diagnosis of
  /// an inpatient claim.
  bool isUnacceptablePrincipal(String code) => _unacceptable.contains(_norm(code));

  /// True for edit 9 codes that are acceptable when a secondary diagnosis
  /// is also reported.
  bool acceptableWithSecondary(String code) => _requiresSecondary.contains(_norm(code));

  /// True for unspecified-side codes for which ICD-10-CM has a code with
  /// laterality (MCE edit 20).
  bool isUnspecifiedLaterality(String code) => _unspecifiedLaterality.contains(_norm(code));

  /// Number of codes on the edit 20 list (0 when the list is not bundled).
  int get unspecifiedLateralityCount => _unspecifiedLaterality.length;
}

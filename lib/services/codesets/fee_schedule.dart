// Medicare Physician Fee Schedule (national, unadjusted) from the CMS 2026
// PFS relative value file (PPRRVU2026, RVU26D October release, nonQPP file).
// Only rows without a modifier are kept, and no CPT descriptors are stored.
//
// The amounts are national: they do not apply locality GPCIs, the multiple
// procedure, bilateral, assistant or other payment policy adjustments, or
// beneficiary cost sharing.

import 'code_set_loader.dart';

class PfsEntry {
  const PfsEntry(
    this.code,
    this.status,
    this.nonFacilityTotalRvu,
    this.facilityTotalRvu,
    this.globalDays, {
    this.workRvu = 0,
    this.pctc = '',
    this.bilateral = '',
  });

  final String code;

  /// PFS status indicator, for example "A" active, "B" bundled, "I" not
  /// valid for Medicare, "N" non-covered, "C" carrier priced.
  final String status;
  final double nonFacilityTotalRvu;
  final double facilityTotalRvu;

  /// Global surgery period: "000", "010", "090", "XXX", "YYY", "ZZZ", "MMM".
  final String globalDays;

  /// Physician work RVU.
  final double workRvu;

  /// Professional/technical component indicator: "0" physician service, "1"
  /// diagnostic test with professional and technical components, "2"
  /// professional component only, "3" technical only, "4" global test only,
  /// "5" incident to, "6" lab physician interpretation, "7" physical
  /// therapy, "8" physician interpretation, "9" not applicable.
  final String pctc;

  /// Bilateral surgery indicator: "0" 150% adjustment does not apply, "1"
  /// 150% applies (report once with modifier 50), "2" already bilateral, "3"
  /// each side paid at 100% (radiology and diagnostic), "9" not applicable.
  final String bilateral;

  /// True for status codes paid from the RVUs on the fee schedule.
  bool get isPayable => status == 'A' || status == 'R' || status == 'T';
}

class FeeSchedule {
  FeeSchedule._(this._entries);

  /// CY 2026 PFS conversion factor for clinicians who are not qualifying APM
  /// participants: 33.4009 dollars per RVU.
  ///
  /// Source: CMS CY 2026 Medicare Physician Fee Schedule final rule
  /// (CMS-1832-F, fact sheet 2025-10-31, "$33.40"), and the exact value in the
  /// CONV FACTOR column of PPRRVU2026_Oct_nonQPP.csv in RVU26D
  /// (https://www.cms.gov/files/zip/rvu26d-updated-08-26-2026.zip).
  static const double conversionFactor2026 = 33.4009;

  /// CY 2026 PFS conversion factor for qualifying APM participants: 33.5675.
  ///
  /// Source: CMS-1832-F fact sheet ("$33.57") and the CONV FACTOR column of
  /// PPRRVU2026_Oct_QPP.csv in RVU26D.
  static const double conversionFactor2026QualifyingApm = 33.5675;

  /// Parses pfs_rvu.tsv (code, status, non-facility total, facility total,
  /// global days, and when present work RVU, PC/TC and bilateral indicator).
  factory FeeSchedule.parse(String tsv) {
    final entries = <String, PfsEntry>{};
    for (final row in tsvRows(tsv)) {
      if (row.length < 5) continue;
      final code = row[0].toUpperCase();
      entries[code] = PfsEntry(
        code,
        row[1],
        double.tryParse(row[2]) ?? 0,
        double.tryParse(row[3]) ?? 0,
        row[4],
        workRvu: row.length > 5 ? double.tryParse(row[5]) ?? 0 : 0,
        pctc: row.length > 6 ? row[6] : '',
        bilateral: row.length > 7 ? row[7] : '',
      );
    }
    return FeeSchedule._(entries);
  }

  static Future<FeeSchedule> load() async {
    final schedule = await CodeSetLoader.load(
      CodeSetFiles.pfsRvu,
      FeeSchedule.parse,
    );
    if (schedule == null) {
      throw StateError('Missing code-set asset ${CodeSetFiles.pfsRvu}');
    }
    return schedule;
  }

  final Map<String, PfsEntry> _entries;

  int get length => _entries.length;

  PfsEntry? lookup(String code) => _entries[code.trim().toUpperCase()];

  /// National Medicare amount in dollars, rounded to cents: total RVU times
  /// the 2026 conversion factor. Null when the code is not on the fee schedule
  /// or has no RVUs (bundled, carrier priced and similar). Codes whose status
  /// is not paid under the PFS (for example "N" non-covered preventive
  /// visits, which still list RVUs) return null unless [includeNonPayable].
  double? medicareAmount(
    String code, {
    bool facility = false,
    bool qualifyingApm = false,
    bool includeNonPayable = false,
  }) {
    final e = lookup(code);
    if (e == null) return null;
    if (!e.isPayable && !includeNonPayable) return null;
    final rvu = facility ? e.facilityTotalRvu : e.nonFacilityTotalRvu;
    if (rvu <= 0) return null;
    final cf = qualifyingApm
        ? conversionFactor2026QualifyingApm
        : conversionFactor2026;
    return (rvu * cf * 100).roundToDouble() / 100;
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'addon_codes.dart';
import 'code_set_loader.dart';
import 'excludes1.dart';
import 'fee_schedule.dart';
import 'hcpcs_catalog.dart';
import 'icd_catalog.dart';
import 'icd_index.dart';
import 'icd_notes.dart';
import 'knowledge_base.dart';
import 'mce.dart';
import 'mue.dart';
import 'ptp.dart';
import 'seventh_character.dart';

/// Synchronous access to the official code sets once they are loaded.
///
/// Coding and claim checks run synchronously on the UI thread, so the sets
/// are loaded at startup (in background isolates) and read from here. Every
/// getter is nullable: callers must still work, with fewer checks, if a set
/// is not loaded yet.
class ReferenceData {
  ReferenceData._();

  static final Map<int, IcdCatalog> _icd = {};
  static final Map<int, IcdIndex> _index = {};
  static HcpcsCatalog? hcpcs;
  static FeeSchedule? fees;
  static Mue? mue;

  /// NCCI procedure-to-procedure edits. Only present when the table is
  /// bundled (which needs an AMA CPT distribution license) or injected.
  static Ptp? ptp;

  /// MCE v44 code lists (age, manifestation, unacceptable principal).
  static Mce? mce;

  // Tabular List data per ICD-10-CM fiscal year. Key 0 holds a set injected
  // without an edition (tests), which then applies to every date.
  static final Map<int, Excludes1> _excludes1 = {};
  static final Map<int, SeventhCharacters> _seventh = {};
  static final Map<int, IcdNotes> _notes = {};

  static const Symbol _fiscalYearKey = #solisIcdFiscalYear;

  /// Runs [body] with the Tabular List data ([excludes1], [seventh],
  /// [notes]) of the ICD-10-CM edition in effect on [dateOfService]: FY2026
  /// through 2026-09-30, FY2027 from 2026-10-01. Claim checks and coding run
  /// inside it, so every note and Excludes1 pair follows the visit's date of
  /// service, never today's date. A null date leaves the latest edition.
  static T atDateOfService<T>(DateTime? dateOfService, T Function() body) {
    if (dateOfService == null) return body();
    return runZoned(body, zoneValues: {_fiscalYearKey: IcdEditions.resolve(dateOfService)});
  }

  /// The ICD-10-CM fiscal year the Tabular getters use right now (set by
  /// [atDateOfService]), or null outside it (latest edition).
  static int? get activeFiscalYear => Zone.current[_fiscalYearKey] as int?;

  /// The set for [fy] (null: [activeFiscalYear], else the latest). A year
  /// without its own set uses the nearest earlier edition, then the oldest.
  static T? _edition<T>(Map<int, T> byYear, [int? fy]) {
    if (byYear.isEmpty) return null;
    final years = byYear.keys.toList()..sort();
    final want = fy ?? activeFiscalYear;
    if (want == null) return byYear[years.last];
    final exact = byYear[want];
    if (exact != null) return exact;
    final earlier = years.where((y) => y <= want);
    return byYear[earlier.isEmpty ? years.first : earlier.last];
  }

  static void _setSingle<T>(Map<int, T> byYear, T? value) {
    byYear.clear();
    if (value != null) byYear[0] = value;
  }

  /// ICD-10-CM Excludes1 notes of the edition for the active date of service
  /// (see [atDateOfService]); the latest edition outside it.
  static Excludes1? get excludes1 => _edition(_excludes1);
  static set excludes1(Excludes1? v) => _setSingle(_excludes1, v);

  /// ICD-10-CM 7th character definitions of the active edition.
  static SeventhCharacters? get seventh => _edition(_seventh);
  static set seventh(SeventhCharacters? v) => _setSingle(_seventh, v);

  /// ICD-10-CM Tabular notes (code first, use additional code, code also,
  /// Excludes1/2) of the active edition, for every code.
  static IcdNotes? get notes => _edition(_notes);
  static set notes(IcdNotes? v) => _setSingle(_notes, v);

  /// The Tabular data of the edition in effect on [dateOfService].
  static Excludes1? excludes1For(DateTime dateOfService) => _edition(_excludes1, IcdEditions.resolve(dateOfService));
  static SeventhCharacters? seventhFor(DateTime dateOfService) => _edition(_seventh, IcdEditions.resolve(dateOfService));
  static IcdNotes? notesFor(DateTime dateOfService) => _edition(_notes, IcdEditions.resolve(dateOfService));

  /// NCCI add-on code edits.
  static AddOnCodes? addOns;

  /// Rule catalog and guideline text that explain each check.
  static KnowledgeBase? knowledge;

  static bool get isLoaded => _icd.isNotEmpty;

  /// Loads every available ICD-10-CM edition (bundled plus downloaded, see
  /// [IcdEditions.available]) and the other sets. Calling it again (after a
  /// code-set rollback) replaces what was loaded.
  static Future<void> load() async {
    final icd = <int, IcdCatalog>{};
    final index = <int, IcdIndex>{};
    for (final fy in IcdEditions.available) {
      try {
        icd[fy] = await IcdCatalog.forFiscalYear(fy);
        index[fy] = await IcdIndex.forFiscalYear(fy);
      } catch (e) {
        debugPrint('ICD-10-CM FY$fy could not be loaded: $e');
      }
    }
    _icd
      ..clear()
      ..addAll(icd);
    _index
      ..clear()
      ..addAll(index);
    try {
      hcpcs = await HcpcsCatalog.load();
      fees = await FeeSchedule.load();
      mue = await Mue.load();
      final p = await Ptp.load();
      ptp = p.available ? p : null;
    } catch (e) {
      debugPrint('Reference code sets could not be loaded: $e');
    }
    // The coding-edit lists are optional: a missing asset leaves the getter
    // null and its checks are skipped.
    mce = await _optional(Mce.load);
    final excl = <int, Excludes1>{};
    final sev = <int, SeventhCharacters>{};
    final nts = <int, IcdNotes>{};
    for (final fy in IcdEditions.available) {
      final e = await _optional(() => Excludes1.forFiscalYear(fy));
      final s = await _optional(() => SeventhCharacters.forFiscalYear(fy));
      final n = await _optional(() => IcdNotes.forFiscalYear(fy));
      if (e != null) excl[fy] = e;
      if (s != null) sev[fy] = s;
      if (n != null) nts[fy] = n;
    }
    _excludes1..clear()..addAll(excl);
    _seventh..clear()..addAll(sev);
    _notes..clear()..addAll(nts);
    addOns = await _optional(AddOnCodes.load);
    knowledge = await _optional(KnowledgeBase.load);
  }

  static Future<T?> _optional<T>(Future<T?> Function() load) async {
    try {
      return await load();
    } catch (e) {
      debugPrint('Coding-edit list could not be loaded: $e');
      return null;
    }
  }

  /// The ICD-10-CM edition in effect on [dateOfService].
  static IcdCatalog? icdFor(DateTime dateOfService) => _icd[IcdEditions.resolve(dateOfService)];

  static IcdIndex? indexFor(DateTime dateOfService) => _index[IcdEditions.resolve(dateOfService)];

  /// True when [code] is a CPT or HCPCS code we recognize from the
  /// physician fee schedule or the HCPCS Level II file.
  static bool? isKnownProcedure(String code) {
    final f = fees, h = hcpcs;
    if (f == null && h == null) return null;
    if (f?.lookup(code) != null) return true;
    if (h?.isValid(code) == true) return true;
    return false;
  }

  @visibleForTesting
  static void inject({
    Map<int, IcdCatalog>? icd,
    Map<int, IcdIndex>? index,
    HcpcsCatalog? hcpcsCatalog,
    FeeSchedule? feeSchedule,
    Mue? mueTable,
    Ptp? ptpTable,
    Mce? mceLists,
    Excludes1? excludes1Notes,
    SeventhCharacters? seventhCharacters,
    AddOnCodes? addOnCodes,
    IcdNotes? icdNotes,
    KnowledgeBase? knowledgeBase,
    Map<int, Excludes1>? excludes1ByYear,
    Map<int, SeventhCharacters>? seventhByYear,
    Map<int, IcdNotes>? notesByYear,
  }) {
    if (icd != null) _icd..clear()..addAll(icd);
    if (index != null) _index..clear()..addAll(index);
    hcpcs = hcpcsCatalog ?? hcpcs;
    fees = feeSchedule ?? fees;
    mue = mueTable ?? mue;
    ptp = ptpTable ?? ptp;
    mce = mceLists ?? mce;
    if (excludes1Notes != null) excludes1 = excludes1Notes;
    if (seventhCharacters != null) seventh = seventhCharacters;
    addOns = addOnCodes ?? addOns;
    if (icdNotes != null) notes = icdNotes;
    if (excludes1ByYear != null) _excludes1..clear()..addAll(excludes1ByYear);
    if (seventhByYear != null) _seventh..clear()..addAll(seventhByYear);
    if (notesByYear != null) _notes..clear()..addAll(notesByYear);
    knowledge = knowledgeBase ?? knowledge;
  }

  @visibleForTesting
  static void clear() {
    _icd.clear();
    _index.clear();
    hcpcs = null;
    fees = null;
    mue = null;
    ptp = null;
    mce = null;
    _excludes1.clear();
    _seventh.clear();
    addOns = null;
    _notes.clear();
    knowledge = null;
  }
}

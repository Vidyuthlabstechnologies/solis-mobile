// Claim checks driven by the FY2027 coding knowledge base (knowledge/):
// Tabular notes, the Alphabetic Index, MCE v44 lists, the ICD-10-CM Official
// Guidelines and the Medicare NCCI Policy Manual. Each check names its rule id
// (knowledge/rules/rule_catalog.json) in a comment and on the ClaimIssue, and
// is skipped silently when the data it needs is not loaded.

import '../../models/claim_models.dart';
import '../../models/patient_account.dart';
import '../codesets/icd_catalog.dart';
import '../codesets/icd_index.dart';
import '../codesets/icd_notes.dart';
import '../codesets/reference_data.dart';
import 'code_rules.dart';
import 'place_of_service.dart';
import 'rule_citations.g.dart';

/// A ClaimIssue tagged with its knowledge-base rule and short citation.
ClaimIssue ruleIssue(String ruleId, IssueSeverity severity, String title, String detail, {String? code}) =>
    ClaimIssue(severity, title, detail, code: code, ruleId: ruleId, citation: ruleCitations[ruleId]);

String _norm(String code) => code.trim().toUpperCase().replaceAll('.', '');

bool _between(String code, String from, String to) {
  final c = _norm(code), f = _norm(from), t = _norm(to);
  return c.compareTo(f) >= 0 && (c.startsWith(t) || c.compareTo(t) <= 0);
}

bool _isMalignancy(String code) => _between(code, 'C00', 'C96') && !_between(code, 'C77', 'C79');
bool _isSymptomCode(String code) => _norm(code).startsWith('R');
bool _isObstetric(String code) => _norm(code).startsWith('O');
bool _isDiabetes(String code) => RegExp(r'^E(08|09|10|11|13)').hasMatch(_norm(code));

/// True when [code] is first-listed-only Z01.81- (preoperative evaluation).
bool isPreopCode(String code) => _norm(code).startsWith('Z0181');

class KnowledgeChecks {
  KnowledgeChecks._();

  // ---------------------------------------------------------------------------
  // Diagnosis list
  // ---------------------------------------------------------------------------

  /// ICD-DUP-01 (guideline I.B.12; MCE edit 3). Each code once per encounter.
  static List<ClaimIssue> duplicateIssues(List<String> codes) {
    final seen = <String>{};
    final dup = <String>{};
    for (final c in codes) {
      if (!seen.add(_norm(c))) dup.add(c);
    }
    return [
      for (final c in dup)
        ruleIssue('ICD-DUP-01', IssueSeverity.error, 'Diagnosis listed twice: $c',
            '$c appears more than once. Each ICD-10-CM code is reported only once per encounter, even for a bilateral condition without a bilateral code. Remove the extra $c.',
            code: c),
    ];
  }

  /// ICD-CODEFIRST-01 (guidelines I.A.13, I.B.7) and the etiology part of
  /// ICD-MANIF-01. When a code's "Code first" note names a condition that is
  /// on the claim but listed after it, the named condition goes first.
  static List<ClaimIssue> codeFirstIssues(List<String> codes, {IcdCatalog? icd}) {
    final notes = ReferenceData.notes;
    if (notes == null) return const [];
    final issues = <ClaimIssue>[];
    for (var i = 0; i < codes.length; i++) {
      final c = codes[i];
      if (_norm(c).startsWith('Z3A')) continue; // CH15-OB-04 covers Z3A.
      final lines = notes.of(c, NoteKind.codeFirst).where((n) => n.refs.isNotEmpty && !n.isQualified).toList();
      if (lines.isEmpty) continue;
      for (var j = i + 1; j < codes.length; j++) {
        final other = codes[j];
        if (_norm(other) == _norm(c)) continue;
        final hit = lines.where((n) => n.names(other)).firstOrNull;
        if (hit == null) continue;
        final manifestation = (ReferenceData.mce?.isManifestation(c) ?? false) ||
            (icd?.description(c)?.toLowerCase().contains('in diseases classified elsewhere') ?? false);
        issues.add(manifestation
            ? ruleIssue('ICD-MANIF-01', IssueSeverity.warning, 'Underlying disease listed after its manifestation: $other',
                '$c is a manifestation code. Its "Code first" note (at ${hit.at}) names $other, so list $other before $c (guideline I.A.13).',
                code: other)
            : ruleIssue('ICD-CODEFIRST-01', IssueSeverity.warning, 'List $other before $c',
                'The Tabular "Code first" note at ${hit.at} says to sequence ${hit.text.replaceFirst(RegExp(r'^[,\s]+'), '')} before $c. '
                    '$other is on the claim, so move it ahead of $c.',
                code: other));
        break;
      }
    }
    return issues;
  }

  /// Groups note lines under their header line ("code to identify:"), so a
  /// group is satisfied when the claim has any one of its codes.
  static List<List<TabularNote>> _groups(List<TabularNote> lines) {
    final groups = <List<TabularNote>>[];
    var current = <TabularNote>[];
    String? at;
    var underHeader = false;
    for (final n in lines) {
      final header = n.refs.isEmpty && n.text.trim().endsWith(':');
      if (n.at != at) underHeader = false;
      at = n.at;
      if (header) {
        current = [];
        groups.add(current);
        underHeader = true;
        continue;
      }
      if (!underHeader) {
        current = [];
        groups.add(current);
      }
      if (n.refs.isNotEmpty && !n.isQualified) current.add(n);
    }
    return groups.where((g) => g.isNotEmpty).toList();
  }

  /// ICD-USEADD-01 (guidelines I.B.7, I.A.13) and CH4-DM-01 for diabetes.
  /// Category and code level "Use additional code" notes whose codes are not
  /// on the claim. A suggestion: add the code only when it is documented.
  static List<ClaimIssue> useAdditionalIssues(List<String> codes) {
    final notes = ReferenceData.notes;
    if (notes == null) return const [];
    final issues = <ClaimIssue>[];
    for (final c in codes) {
      final unmet = <TabularNote>[];
      for (final g in _groups(notes.of(c, NoteKind.useAdditional, ranges: false))) {
        if (g.any((n) => codes.any(n.names))) continue;
        unmet.addAll(g);
      }
      if (unmet.isEmpty) continue;
      final list = unmet.take(4).map((n) => n.text.replaceFirst(RegExp(r'^code\s*,?\s*', caseSensitive: false), '')).join('; ');
      final more = unmet.length > 4 ? ' (${unmet.length - 4} more in the code notes)' : '';
      if (_isDiabetes(c)) {
        // CH4-DM-01 (guidelines I.C.4.a, I.C.4.a.3).
        issues.add(ruleIssue('CH4-DM-01', IssueSeverity.info, 'Long-term diabetes drug code: $c',
            'If the patient takes insulin, oral or injectable non-insulin antidiabetic drugs long term, add the matching Z79 code with $c: '
                '$list$more. Do not add Z79.4 when insulin is given only temporarily during the encounter (guideline I.C.4.a.3).',
            code: c));
      } else {
        issues.add(ruleIssue('ICD-USEADD-01', IssueSeverity.info, 'Use additional code with $c',
            'The Tabular says to add, when documented: $list$more.', code: c));
      }
    }
    return issues;
  }

  /// ICD-CODEALSO-01 (guideline I.A.17). "Code also" notes whose codes are
  /// not on the claim. Informational; sequencing is discretionary.
  static List<ClaimIssue> codeAlsoIssues(List<String> codes) {
    final notes = ReferenceData.notes;
    if (notes == null) return const [];
    final issues = <ClaimIssue>[];
    for (final c in codes) {
      final unmet = [
        for (final g in _groups(notes.of(c, NoteKind.codeAlso, ranges: false)))
          if (!g.any((n) => codes.any(n.names))) ...g,
      ];
      if (unmet.isEmpty) continue;
      issues.add(ruleIssue('ICD-CODEALSO-01', IssueSeverity.info, 'Code also with $c',
          'A second code may be needed if the condition is present: ${unmet.take(3).map((n) => n.text.replaceFirst(RegExp(r'^[,\s]+'), '')).join('; ')}. Either code may be listed first.',
          code: c));
    }
    return issues;
  }

  /// ICD-SEQUELA-01 (guidelines I.B.10, I.C.19.a). A 7th character S code
  /// follows the residual condition it caused.
  static List<ClaimIssue> sequelaIssues(List<String> codes) {
    final seventh = ReferenceData.seventh;
    if (seventh == null || codes.isEmpty) return const [];
    bool isSequela(String c) {
      final n = _norm(c);
      if (n.length != 7 || n[6] != 'S') return false;
      final meaning = seventh.ruleFor(c)?.characters['S'] ?? '';
      return meaning.toLowerCase().contains('sequela');
    }

    final issues = <ClaimIssue>[];
    final sequelae = codes.where(isSequela).toList();
    if (sequelae.isEmpty) return issues;
    final residual = codes.where((c) => !isSequela(c) && !isExternalCauseCode(c)).toList();
    for (final s in sequelae) {
      if (residual.isEmpty) {
        issues.add(ruleIssue('ICD-SEQUELA-01', IssueSeverity.warning, 'Sequela code without the residual condition: $s',
            '$s says the problem is a late effect of an earlier injury. Code the residual condition being treated (for example the scar or the pain) and list it first, then $s.',
            code: s));
      } else if (codes.first == s) {
        issues.add(ruleIssue('ICD-SEQUELA-01', IssueSeverity.warning, 'Sequela code listed first: $s',
            'List the residual condition first (${residual.first}) and $s after it (guideline I.B.10).', code: s));
      }
    }
    return issues;
  }

  static final _side = RegExp(r'\b(right|left)\b');
  static const _stop = {'of', 'side', 'and', 'or', 'the', 'in', 'with', 'unspecified', 'unilateral', 'bilateral', 'right', 'left'};

  static String? _bodyAfterSide(String description) {
    final words = description.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty).toList();
    for (var i = 0; i < words.length - 1; i++) {
      if (words[i] == 'right' || words[i] == 'left') {
        for (var k = i + 1; k < words.length; k++) {
          if (!_stop.contains(words[k])) return words[k];
        }
      }
    }
    return null;
  }

  static Set<String> _core(String description, String? body) {
    String sing(String w) => w.length > 3 && w.endsWith('s') ? w.substring(0, w.length - 1) : w;
    return {
      for (final w in description.toLowerCase().split(RegExp(r'[^a-z0-9]+')))
        if (w.isNotEmpty && !_stop.contains(w) && sing(w) != body) sing(w),
    };
  }

  /// ICD-LAT-01 (guidelines I.B.13, I.C.13.a). Right and left codes of the
  /// same condition when the classification has a bilateral code.
  static List<ClaimIssue> bilateralIssues(List<String> codes, IcdCatalog? icd) {
    if (icd == null) return const [];
    final issues = <ClaimIssue>[];
    for (final a in codes) {
      final da = icd.description(a);
      if (da == null || !_side.hasMatch(da.toLowerCase()) || !da.toLowerCase().contains('right')) continue;
      final body = _bodyAfterSide(da);
      final ca = _core(da, body);
      for (final b in codes) {
        if (a == b || _norm(a).substring(0, 3) != _norm(b).substring(0, 3)) continue;
        final db = icd.description(b);
        if (db == null || !RegExp(r'\bleft\b').hasMatch(db.toLowerCase()) || !_setEq(_core(db, _bodyAfterSide(db)), ca)) continue;
        final na = _norm(a);
        final bilateral = icd.billableChildren(na.substring(0, 3), limit: 2000).where((e) {
          final d = e.description.toLowerCase();
          if (!RegExp(r'\bbilateral\b').hasMatch(d)) return false;
          final ne = _norm(e.code);
          if (na.length == 7 && ne.length == 7 && ne[6] != na[6]) return false;
          return _setEq(_core(e.description, body), ca);
        }).firstOrNull;
        if (bilateral == null) continue;
        issues.add(ruleIssue('ICD-LAT-01', IssueSeverity.warning, 'Use the bilateral code: ${bilateral.code}',
            '$a (right) and $b (left) describe the same condition on both sides, and ICD-10-CM has a bilateral code: ${bilateral.code} '
                '${bilateral.description}. Report ${bilateral.code} instead of the two sided codes (guideline I.B.13).',
            code: b));
      }
    }
    return issues;
  }

  static bool _setEq(Set<String> a, Set<String> b) => a.length == b.length && a.containsAll(b);

  /// ICD-LAT-02 (MCE edit 20; guidelines I.B.13, I.B.18). Unspecified side
  /// when ICD-10-CM has a code for the side.
  static List<ClaimIssue> unspecifiedSideIssues(List<String> codes) {
    final mce = ReferenceData.mce;
    if (mce == null || mce.unspecifiedLateralityCount == 0) return const [];
    return [
      for (final c in codes)
        if (mce.isUnspecifiedLaterality(c))
          ruleIssue('ICD-LAT-02', IssueSeverity.warning, 'Side not specified: $c',
              '$c is an unspecified-side code, and ICD-10-CM has codes for the right, left (and often bilateral) side. Use the sided code when '
                  'the record states the side; laterality may come from any clinician\'s documentation. Keep $c only if the side is truly not documented.',
              code: c),
    ];
  }

  /// ICD-SYMPTOM-02 (guidelines I.B.4, IV.D) and CH2-NEO-02 (guidelines
  /// I.C.2.g, I.C.2.l). A symptom is not first-listed when a related
  /// confirmed diagnosis, or a malignancy, is on the claim.
  static List<ClaimIssue> symptomFirstIssues(List<String> codes) {
    if (codes.length < 2 || !_isSymptomCode(codes.first)) return const [];
    final first = codes.first;
    final cancer = codes.skip(1).where(_isMalignancy).firstOrNull;
    if (cancer != null) {
      return [
        ruleIssue('CH2-NEO-02', IssueSeverity.warning, 'Symptom listed before the malignancy: $first',
            '$first is a symptom and $cancer a malignancy on the same claim. A symptom of an existing malignancy does not replace it as the '
                'first-listed diagnosis: list $cancer first, unless the visit was for an unrelated problem.',
            code: first),
      ];
    }
    final systems = icdSystems(first);
    final related = codes.skip(1).where((c) {
      final n = _norm(c);
      if (n.startsWith('R') || n.startsWith('Z') || isExternalCauseCode(c)) return false;
      final s = icdSystems(c);
      return !s.contains(BodySystem.general) && s.intersection(systems).isNotEmpty;
    }).firstOrNull;
    if (related == null) return const [];
    return [
      ruleIssue('ICD-SYMPTOM-02', IssueSeverity.warning, 'Symptom listed before its diagnosis: $first',
          '$related is a confirmed diagnosis in the same body system as the symptom $first. When a related definitive diagnosis is established, '
              'it is listed first (guideline IV.D); if $first is part of $related, remove $first (guideline I.B.5).',
          code: first),
    ];
  }

  /// OP-FIRSTLISTED-01 (guidelines IV.A, IV.J). History codes Z80-Z87 are
  /// secondary information, not the reason for the visit.
  static List<ClaimIssue> historyFirstIssues(List<String> codes) {
    if (codes.length < 2 || !_between(codes.first, 'Z80', 'Z87')) return const [];
    return [
      ruleIssue('OP-FIRSTLISTED-01', IssueSeverity.warning, 'History code listed first: ${codes.first}',
          '${codes.first} is a personal or family history code. List first the condition chiefly responsible for this visit (${codes[1]} or another), '
              'and keep ${codes.first} as additional information.',
          code: codes.first),
    ];
  }

  /// ICD-EXTCAUSE-02 (guidelines I.C.20.b, I.C.20.k). Place of occurrence
  /// Y92 and status Y99 are used once, with another external cause code, and
  /// not as "unspecified".
  static List<ClaimIssue> externalCauseStatusIssues(List<String> codes) {
    final issues = <ClaimIssue>[];
    final y92 = codes.where((c) => _norm(c).startsWith('Y92')).toList();
    final y99 = codes.where((c) => _norm(c).startsWith('Y99')).toList();
    if (y99.length > 1) {
      issues.add(ruleIssue('ICD-EXTCAUSE-02', IssueSeverity.warning, 'More than one external cause status: ${y99.join(', ')}',
          'Only one Y99 code is reported per record (guideline I.C.20.k). Keep the one that applies and remove the others.', code: y99[1]));
    }
    if (y92.length > 1) {
      issues.add(ruleIssue('ICD-EXTCAUSE-02', IssueSeverity.warning, 'More than one place of occurrence: ${y92.join(', ')}',
          'Only one Y92 code is reported, for the place where the injury happened (guideline I.C.20.b).', code: y92[1]));
    }
    for (final c in [...y92, ...y99]) {
      if (_norm(c) == 'Y929' || _norm(c) == 'Y999') {
        issues.add(ruleIssue('ICD-EXTCAUSE-02', IssueSeverity.warning, 'Unspecified place or status: $c',
            'Do not report $c when the place or activity status is not stated. Remove it, or use the specific code the record supports.', code: c));
      }
    }
    final otherCause = codes.any((c) => isExternalCauseCode(c) && !_norm(c).startsWith('Y92') && !_norm(c).startsWith('Y99') && !_norm(c).startsWith('Y93'));
    if ((y92.isNotEmpty || y99.isNotEmpty) && !otherCause) {
      final c = [...y92, ...y99].first;
      issues.add(ruleIssue('ICD-EXTCAUSE-02', IssueSeverity.warning, 'Place or status code without its external cause: $c',
          '$c is used together with an external cause code that says how the injury happened (V00-Y38). Add that code or remove $c.', code: c));
    }
    return issues;
  }

  /// OP-THERAPY-01 (guidelines IV.L, I.C.2.a, I.C.2.e.2). An encounter for
  /// chemotherapy, immunotherapy or radiation therapy lists Z51.0 or Z51.1-
  /// first.
  static List<ClaimIssue> therapyEncounterIssues(List<String> codes, List<ServiceLine> lines) {
    bool chemo(String code) {
      final n = int.tryParse(code) ?? 0;
      return n >= 96401 && n <= 96549;
    }

    bool radiation(String code) {
      final n = int.tryParse(code) ?? 0;
      return n >= 77401 && n <= 77525;
    }

    final therapy = lines.where((l) => chemo(l.code) || radiation(l.code)).toList();
    if (therapy.isEmpty || codes.isEmpty) return const [];
    final want = radiation(therapy.first.code) ? 'Z51.0' : 'Z51.11 (or Z51.12 for immunotherapy)';
    final first = _norm(codes.first);
    if (first == 'Z510' || first.startsWith('Z511')) return const [];
    return [
      ruleIssue('OP-THERAPY-01', IssueSeverity.warning, 'Therapy encounter: list $want first',
          '${therapy.first.code} is billed. When the visit is chiefly to give antineoplastic chemotherapy, immunotherapy or radiation therapy, '
              'the first-listed diagnosis is $want and the malignancy follows it.',
          code: therapy.first.code),
    ];
  }

  /// CH2-NEO-01 (guidelines I.C.2.m, I.C.2.d). A current malignancy and the
  /// personal history Z85 code of the same site are not reported together.
  static List<ClaimIssue> neoplasmHistoryIssues(List<String> codes, IcdIndex? index, IcdCatalog? icd) {
    if (index == null || icd == null) return const [];
    final issues = <ClaimIssue>[];
    for (final z in codes.where((c) => _norm(c).startsWith('Z85') && _norm(c) != 'Z8589' && _norm(c) != 'Z859')) {
      final sites = <Set<String>>[];
      for (final p in index.pathsFor(z)) {
        final parts = p.split('|');
        final at = parts.indexWhere((s) => s.toLowerCase().startsWith('malignant neoplasm'));
        if (at < 0 || at + 1 >= parts.length) continue;
        final w = _words(parts[at + 1])..removeAll({'carcinoid', 'specified', 'site', 'organ', 'organs'});
        if (w.isNotEmpty) sites.add(w);
      }
      for (final c in codes.where(_isMalignancy)) {
        final d = _words(icd.description(c) ?? '');
        if (sites.any((s) => d.containsAll(s))) {
          issues.add(ruleIssue('CH2-NEO-01', IssueSeverity.warning, 'Current cancer and history of the same site: $c and $z',
              'Use $c while treatment is directed at the site; use $z only when the malignancy was excised or eradicated, no treatment is '
                  'directed to the site and there is no evidence of disease. Keep the one the record supports.',
              code: z));
          break;
        }
      }
    }
    return issues;
  }

  /// CH15-OB-02, CH15-OB-03 and CH15-OB-04 (guidelines I.C.15.a.1,
  /// I.C.15.b.1, IV.O, I.C.15.a.7).
  static List<ClaimIssue> obstetricIssues(List<String> codes) {
    final issues = <ClaimIssue>[];
    final ob = codes.where(_isObstetric).toList();
    final z34 = codes.where((c) => _norm(c).startsWith('Z34')).toList();
    final z3a = codes.where((c) => _norm(c).startsWith('Z3A')).toList();
    if (z34.isNotEmpty && ob.isNotEmpty) {
      issues.add(ruleIssue('CH15-OB-03', IssueSeverity.error, 'Routine prenatal code with a pregnancy complication: ${z34.first}',
          '${z34.first} is for routine prenatal visits without complications and is never reported with Chapter 15 codes such as ${ob.first}. '
              'Remove ${z34.first} and list the obstetric condition first.',
          code: z34.first));
    }
    if (ob.isNotEmpty && !_isObstetric(codes.first) && !(z34.isNotEmpty) && !isFirstListedOnly(codes.first)) {
      issues.add(ruleIssue('CH15-OB-02', IssueSeverity.warning, 'Pregnancy code not listed first: ${ob.first}',
          'Chapter 15 codes have sequencing priority over codes from other chapters. List ${ob.first} first. If the provider documents that the '
              'pregnancy is incidental to this visit, use Z33.1 instead of the Chapter 15 codes.',
          code: ob.first));
    }
    for (final z in z3a) {
      if (ob.isEmpty) {
        issues.add(ruleIssue('CH15-OB-04', IssueSeverity.warning, 'Weeks of gestation without an obstetric code: $z',
            '$z is used only on the maternal record, after the obstetric condition or delivery code (O09-O60, O80-O82, O94-O9A). Add that code first.',
            code: z));
      } else if (codes.first == z) {
        issues.add(ruleIssue('CH15-OB-04', IssueSeverity.warning, 'Weeks of gestation listed first: $z',
            'Code first the obstetric condition (${ob.first}), then $z.', code: z));
      }
    }
    return issues;
  }

  /// CH19-POIS-01 (guidelines I.C.19.e.5, I.C.19.e.5.c). Underdosing is never
  /// first-listed; an adverse effect follows the effect it caused; a poisoning
  /// code comes before its manifestations.
  static List<ClaimIssue> poisoningIssues(List<String> codes) {
    if (codes.isEmpty) return const [];
    String? intent(String c) {
      final n = _norm(c);
      if (!_between(c, 'T36', 'T50') || n.length < 6) return null;
      return n[5];
    }

    final issues = <ClaimIssue>[];
    final first = codes.first;
    final i = intent(first);
    if (i == '6') {
      issues.add(ruleIssue('CH19-POIS-01', IssueSeverity.error, 'Underdosing code listed first: $first',
          'Underdosing codes are never the first-listed diagnosis. List the relapse or exacerbation of the condition being treated first, then $first.',
          code: first));
    } else if (i == '5' && codes.length > 1) {
      issues.add(ruleIssue('CH19-POIS-01', IssueSeverity.warning, 'Adverse effect code listed first: $first',
          'For an adverse effect of a correctly prescribed drug, list the nature of the effect first (for example ${codes[1]}), then $first for the drug.',
          code: first));
    }
    bool poisoning(String c) => (_between(c, 'T36', 'T50') && const {'1', '2', '3', '4'}.contains(intent(c))) || _between(c, 'T51', 'T65');
    final pois = codes.where(poisoning).toList();
    if (pois.isNotEmpty && !poisoning(first) && intent(first) == null && !isFirstListedOnly(first)) {
      issues.add(ruleIssue('CH19-POIS-01', IssueSeverity.warning, 'Poisoning code not listed first: ${pois.first}',
          'For a poisoning or toxic effect, list the poisoning code (${pois.first}) first, then the conditions it caused such as $first.',
          code: pois.first));
    }
    return issues;
  }

  /// CH21-Z-02 (guideline I.C.21.c.3). A status code is not used with a code
  /// that already includes the status: transplant complications include the
  /// transplant status, and attention to an artificial opening includes the
  /// opening status.
  static const statusPairs = {
    'Z94.0': 'T86.1', // kidney
    'Z94.1': 'T86.2', // heart (the guideline's example)
    'Z94.2': 'T86.81', // lung
    'Z94.3': 'T86.3', // heart and lungs
    'Z94.4': 'T86.4', // liver
    'Z94.81': 'T86.0', // bone marrow
    'Z94.82': 'T86.85', // intestine
    'Z94.84': 'T86.5', // stem cells
    'Z93.0': 'Z43.0', // tracheostomy (the guideline's aftercare example)
    'Z93.1': 'Z43.1', // gastrostomy
    'Z93.2': 'Z43.2', // ileostomy
    'Z93.3': 'Z43.3', // colostomy
    'Z93.5': 'Z43.5', // cystostomy
  };

  static List<ClaimIssue> statusIssues(List<String> codes) {
    final issues = <ClaimIssue>[];
    for (final e in statusPairs.entries) {
      final status = codes.where((c) => _norm(c).startsWith(_norm(e.key))).firstOrNull;
      if (status == null) continue;
      final including = codes.where((c) => _norm(c).startsWith(_norm(e.value))).firstOrNull;
      if (including == null) continue;
      issues.add(ruleIssue('CH21-Z-02', IssueSeverity.warning, 'Status code not needed: $status',
          '$including already says the patient has this status, so $status adds no information. Remove $status (guideline I.C.21.c.3).',
          code: status));
    }
    return issues;
  }

  static const _indexStop = {
    'of', 'the', 'and', 'or', 'with', 'in', 'to', 'due', 'a', 'an', 'nos', 'nec', 'other', 'unspecified', 'specified', 'see', 'by', 'as', //
    'for', 'on', 'without',
  };
  static const _generic = {
    'disorder', 'disorders', 'disease', 'diseases', 'complication', 'complications', 'condition', 'conditions', 'syndrome', //
    'manifestation', 'manifestations', 'crisis', 'involvement', 'symptoms', 'sequelae', 'late', 'effect',
  };

  static Set<String> _words(String s) => {
        for (final w in s.toLowerCase().split(RegExp(r'[^a-z0-9]+')))
          if (w.isNotEmpty && !_indexStop.contains(w)) w,
      };

  /// ICD-COMBO-01 (guidelines I.B.9, I.A.15). Two claim codes that the
  /// Alphabetic Index joins with "with" into one combination code.
  static List<ClaimIssue> combinationIndexIssues(List<String> codes, IcdIndex? index, IcdCatalog? icd) {
    if (index == null || codes.length < 2) return const [];
    final issues = <ClaimIssue>[];
    final done = <String>{};
    for (final a in codes) {
      for (final b in codes) {
        final na = _norm(a), nb = _norm(b);
        if (na == nb || na.substring(0, 3) == nb.substring(0, 3)) continue;
        if (na.startsWith('I10')) continue; // CH9-HTN-01/02/03 cover hypertension.
        if (!(na[0] == nb[0] || _isDiabetes(a) || nb.startsWith('R'))) continue;
        final key = ([na, nb]..sort()).join('|');
        if (done.contains(key)) continue;
        final hit = combinationFor(a, b, index);
        if (hit == null) continue;
        final (path, combo) = hit;
        if (codes.any((c) => _norm(c) == _norm(combo))) continue;
        done.add(key);
        final billable = icd?.isBillable(combo) ?? true;
        issues.add(ruleIssue('ICD-COMBO-01', IssueSeverity.warning, 'Combination code available: $a with $b',
            'The ICD-10-CM Index lists "${path.replaceAll('|', ', ')}" as ${billable ? combo : 'a code under $combo'}. When the record links the two '
                'conditions, report the combination code instead of $a and $b, and keep $b only if the combination code lacks its detail (guideline I.B.9).',
            code: b));
      }
    }
    return issues;
  }

  /// The Index path and combination code for [a] "with" [b], or null.
  static (String, String)? combinationFor(String a, String b, IcdIndex index) {
    final bPaths = <(Set<String>, Set<String>)>[];
    for (final p in index.pathsFor(b)) {
      final parts = p.split('|');
      if (parts.length > 3 || parts.any((s) => s.toLowerCase() == 'with')) continue;
      final main = _words(parts.first);
      bPaths.add((main, {...main, if (parts.length > 1) ..._words(parts[1])}));
    }
    if (bPaths.isEmpty) return null;
    (int, String, String)? best;
    for (final p in index.pathsFor(a)) {
      for (final (seg, combo) in index.childrenOf('$p|with')) {
        if (_norm(combo) == _norm(a) || _norm(combo) == _norm(b)) continue;
        final sw = _words(seg)..removeAll(_generic);
        if (sw.isEmpty) continue;
        for (final (main, all) in bPaths) {
          if (all.containsAll(sw) && sw.any(main.contains) && (best == null || sw.length > best.$1)) {
            best = (sw.length, '$p|with|$seg', combo);
          }
        }
      }
    }
    return best == null ? null : (best.$2, best.$3);
  }

  static const _acute = {'acute', 'acute or subacute', 'subacute'};

  /// ICD-ACUTECHRONIC-01 (guideline I.B.8). Acute and chronic forms with
  /// separate Index subentries are both coded, acute first; when the Index
  /// has an "acute and chronic" combination, that one code is used
  /// (ICD-COMBO-01).
  static List<ClaimIssue> acuteChronicIssues(List<String> codes, IcdIndex? index) {
    if (index == null || codes.length < 2) return const [];
    final issues = <ClaimIssue>[];
    for (var i = 0; i < codes.length; i++) {
      for (var j = 0; j < codes.length; j++) {
        if (i == j) continue;
        final acute = codes[i], chronic = codes[j];
        String? prefix;
        String? acuteSeg;
        for (final pa in index.pathsFor(acute)) {
          final parts = pa.split('|');
          for (var k = 1; k < parts.length && prefix == null; k++) {
            if (!_acute.contains(parts[k].toLowerCase())) continue;
            final pre = parts.sublist(0, k).join('|');
            final match = index.pathsFor(chronic).any((pc) => pc.startsWith('$pre|') && pc.substring(pre.length + 1).split('|').first.toLowerCase() == 'chronic');
            if (match) {
              prefix = pre;
              acuteSeg = parts[k];
            }
          }
          if (prefix != null) break;
        }
        if (prefix == null) continue;
        String? combo;
        for (final (seg, code) in index.childrenOf(prefix)) {
          final s = seg.toLowerCase();
          if (s.startsWith('acute and chronic') || s.startsWith('acute on chronic')) combo = code;
        }
        for (final (seg, code) in index.childrenOf('$prefix|$acuteSeg')) {
          final s = seg.toLowerCase();
          if (s.startsWith('and chronic') || s.startsWith('on chronic')) combo ??= code;
        }
        for (final (seg, code) in index.childrenOf('$prefix|chronic')) {
          if (seg.toLowerCase().startsWith('with acute')) combo ??= code;
        }
        final where = prefix.replaceAll('|', ', ');
        if (combo != null && !codes.any((c) => _norm(c) == _norm(combo!))) {
          if (i < j || !issues.any((x) => x.code == chronic && x.ruleId == 'ICD-COMBO-01')) {
            issues.add(ruleIssue('ICD-COMBO-01', IssueSeverity.warning, 'Acute and chronic combination code: $combo',
                '$acute (acute) and $chronic (chronic) are both "$where". The Index has a single code for the acute and chronic form: '
                    'report $combo instead of the two codes (guidelines I.B.8 and I.B.9).',
                code: chronic));
          }
        } else if (combo == null && j < i) {
          issues.add(ruleIssue('ICD-ACUTECHRONIC-01', IssueSeverity.warning, 'List the acute code first: $acute',
              '$acute (acute) and $chronic (chronic) are separate Index subentries of "$where". Code both, with the acute code $acute before $chronic.',
              code: acute));
        }
      }
    }
    return issues;
  }

  /// OP-DIAGSERVICES-01 (guideline IV.K). For diagnostic services, code the
  /// confirmed diagnosis from the interpreted result, not the symptoms.
  static List<ClaimIssue> diagnosticServiceIssues(List<String> codes, List<ServiceLine> lines) {
    final fees = ReferenceData.fees;
    if (fees == null || codes.isEmpty || !_isSymptomCode(codes.first)) return const [];
    final test = lines.where((l) => const {'1', '2', '4', '6', '8'}.contains(fees.lookup(l.code)?.pctc)).firstOrNull;
    if (test == null) return const [];
    return [
      ruleIssue('OP-DIAGSERVICES-01', IssueSeverity.info, 'Diagnostic test with a symptom code: ${test.code}',
          'When the test was interpreted and the report is available, code the confirmed diagnosis from the interpretation instead of the '
              'symptom ${codes.first}. If the result is normal or not yet interpreted, keep the reason for the test.',
          code: test.code),
    ];
  }

  // ---------------------------------------------------------------------------
  // Injury follow-up (needs the visit history)
  // ---------------------------------------------------------------------------

  /// CH19-INJ-01 (guidelines I.C.19.a, I.C.19.c.1, I.C.21.c.7). Aftercare
  /// Z codes are not used for injuries (the injury code with 7th character D
  /// is), and a follow-up visit for an injury coded on an earlier visit with
  /// A is usually the healing phase.
  static List<ClaimIssue> injuryEncounterIssues(List<String> codes, PatientAccount account, Visit visit) {
    final seventh = ReferenceData.seventh;
    final issues = <ClaimIssue>[];
    bool injury(String c) => (_norm(c).startsWith('S') || _between(c, 'T07', 'T34')) && _norm(c).length == 7;
    final injuries = codes.where(injury).toList();
    final aftercare = codes.where((c) => _norm(c).startsWith('Z47') || _norm(c).startsWith('Z48')).toList();
    if (injuries.isNotEmpty && aftercare.isNotEmpty) {
      issues.add(ruleIssue('CH19-INJ-01', IssueSeverity.warning, 'Aftercare code with an injury: ${aftercare.first}',
          'Aftercare Z codes are not used for injuries. For routine care while ${injuries.first} heals, report the injury code with the '
              'subsequent-encounter 7th character (D for most injuries) and remove ${aftercare.first}.',
          code: aftercare.first));
    }
    if (seventh == null) return issues;
    final dos = DateTime.tryParse(visit.dateOfService);
    final earlier = [
      for (final v in account.visits)
        if (v.number != visit.number && v.claim != null && (dos == null || (DateTime.tryParse(v.dateOfService)?.isBefore(dos) ?? v.number < visit.number)))
          for (final d in v.claim!.billable) _norm(d.code),
    ];
    for (final c in injuries) {
      final n = _norm(c);
      if (n[6] != 'A') continue;
      final rule = seventh.ruleFor(c);
      if (rule == null || !rule.allows('D')) continue;
      final stem = n.substring(0, 6);
      if (!earlier.any((e) => e.length == 7 && e.startsWith(stem))) continue;
      final d = withSeventhCharacter(n.substring(0, 6), 'D');
      issues.add(ruleIssue('CH19-INJ-01', IssueSeverity.warning, 'Follow-up visit coded as initial: $c',
          'This injury was already coded on an earlier visit. 7th character A is only for encounters with active treatment (for example surgery '
              'or a new evaluation); routine care during healing or recovery uses ${rule.characters['D']} ($d).',
          code: c));
    }
    return issues;
  }

  // ---------------------------------------------------------------------------
  // Services (NCCI Policy Manual)
  // ---------------------------------------------------------------------------

  static bool _isEm(ServiceLine l) => emSettingOf(l.code) != null;
  static bool _hasMod(ServiceLine l, String m) => l.modifiers.any((x) => x.trim().toUpperCase() == m);

  /// NCCI-EM-02 (NCCI Policy Manual Ch. I, Sec. D). An E/M on the day of or
  /// the day before a major procedure (global 090) is part of the surgical
  /// package unless it is the decision for surgery, which modifier 57 marks.
  static List<ClaimIssue> majorProcedureEmIssues(List<ServiceLine> lines, {PatientAccount? account, Visit? visit}) {
    final fees = ReferenceData.fees;
    if (fees == null) return const [];
    final major = [for (final l in lines) if (!_isEm(l) && fees.lookup(l.code)?.globalDays == '090') l.code];
    final dos = visit == null ? null : DateTime.tryParse(visit.dateOfService);
    if (major.isEmpty && account != null && dos != null) {
      for (final v in account.visits) {
        final d = DateTime.tryParse(v.dateOfService);
        if (d == null || v.number == visit!.number || d.difference(dos).inDays != 1) continue;
        major.addAll([for (final l in v.claim?.lines ?? const <ServiceLine>[]) if (fees.lookup(l.code)?.globalDays == '090') l.code]);
      }
    }
    if (major.isEmpty) return const [];
    return [
      for (final em in lines)
        if (_isEm(em) && !_hasMod(em, '57'))
          ruleIssue('NCCI-EM-02', IssueSeverity.warning, 'E/M with a major procedure needs modifier 57: ${em.code}',
              '${em.code} is on the day of, or the day before, ${major.toSet().join(', ')}, a major procedure (90 day global period). '
                  'If this visit is where you decided to operate, add modifier 57 to ${em.code}; otherwise the visit is part of the surgical package. Remove it.',
              code: em.code),
    ];
  }

  /// NCCI-EM-03 (NCCI Policy Manual Ch. I, Sec. D). An E/M with a procedure
  /// outside the global surgery rules (XXX) that has physician work: its own
  /// pre- and post-service work is not a separate E/M, so a separately
  /// identifiable E/M needs modifier 25. Diagnostic tests with professional or
  /// technical components (PC/TC indicators 1 to 4, 6 to 8) are not
  /// procedures in this sense and are left out.
  static List<ClaimIssue> xxxProcedureEmIssues(List<ServiceLine> lines) {
    final fees = ReferenceData.fees;
    if (fees == null) return const [];
    final procs = [
      for (final l in lines)
        if (!_isEm(l) && !(int.tryParse(l.code) != null && int.parse(l.code) >= 99000))
          if (fees.lookup(l.code) case final e? when e.globalDays == 'XXX' && e.workRvu > 0 && (e.pctc == '0' || e.pctc == '5')) l.code,
    ];
    if (procs.isEmpty) return const [];
    return [
      for (final em in lines)
        if (_isEm(em) && !_hasMod(em, '25'))
          ruleIssue('NCCI-EM-03', IssueSeverity.warning, 'E/M with a procedure needs modifier 25: ${em.code}',
              '${procs.join(', ')} has its own pre- and post-service work, which is not billed as an E/M. If you also provided a significant, '
                  'separately identifiable E/M service, add modifier 25 to ${em.code} and document it; otherwise remove ${em.code}.',
              code: em.code),
    ];
  }

  /// NCCI-GLOBAL-01 (NCCI Policy Manual Ch. I, Sec. D). E/M visits in the
  /// postoperative period of an earlier 010 or 090 procedure are part of the
  /// global package; an unrelated visit carries modifier 24.
  static List<ClaimIssue> globalPeriodIssues(List<ServiceLine> lines, PatientAccount account, Visit visit) {
    final fees = ReferenceData.fees;
    final dos = DateTime.tryParse(visit.dateOfService);
    if (fees == null || dos == null) return const [];
    final ems = lines.where((l) => _isEm(l) && !_hasMod(l, '24') && !_hasMod(l, '57')).toList();
    if (ems.isEmpty) return const [];
    for (final v in account.visits) {
      if (v.number == visit.number) continue;
      final d = DateTime.tryParse(v.dateOfService);
      if (d == null) continue;
      final after = DateTime(dos.year, dos.month, dos.day).difference(DateTime(d.year, d.month, d.day)).inDays;
      if (after < 1) continue;
      for (final l in v.claim?.lines ?? const <ServiceLine>[]) {
        final days = switch (fees.lookup(l.code)?.globalDays) {
          '010' => 10,
          '090' => 90,
          _ => 0,
        };
        if (days == 0 || after > days) continue;
        return [
          for (final em in ems)
            ruleIssue('NCCI-GLOBAL-01', IssueSeverity.warning, 'Visit in a postoperative period: ${em.code}',
                'This visit is $after days after ${l.code} (visit ${v.number}, ${v.dateOfService}), which has a $days day global period. '
                    'Visits for recovery from that procedure, including complications, are included in it. If this visit is for an unrelated problem, '
                    'add modifier 24 to ${em.code} and link the unrelated diagnosis; otherwise remove ${em.code}.',
                code: em.code),
        ];
      }
    }
    return const [];
  }

  /// NCCI-MOD-02 (NCCI Policy Manual Ch. I, Sec. E). Modifier 59 and
  /// XE/XS/XP/XU mark a distinct procedural service; they are not used on
  /// E/M codes (modifier 25 is), and XE/XS/XP/XU are preferred to 59 when one
  /// describes the situation.
  static List<ClaimIssue> distinctServiceModifierIssues(List<ServiceLine> lines) {
    const distinct = {'59', 'XE', 'XS', 'XP', 'XU'};
    final issues = <ClaimIssue>[];
    for (final l in lines) {
      final used = l.modifiers.map((m) => m.trim().toUpperCase()).where(distinct.contains).toList();
      if (used.isEmpty) continue;
      if (_isEm(l)) {
        issues.add(ruleIssue('NCCI-MOD-02', IssueSeverity.error, 'Modifier ${used.first} on an E/M code: ${l.code}',
            '${used.join(', ')} is for a distinct procedure or service and is not appended to E/M codes. For a significant, separately '
                'identifiable E/M on the day of a procedure, use modifier 25.',
            code: l.code));
      } else if (used.contains('59') && l.code == '77427') {
        issues.add(ruleIssue('NCCI-MOD-02', IssueSeverity.error, 'Modifier 59 on 77427',
            'Modifier 59 is not used with 77427 (radiation treatment management). Remove it.', code: l.code));
      } else if (used.contains('59') && !used.any((m) => m.startsWith('X'))) {
        issues.add(ruleIssue('NCCI-MOD-02', IssueSeverity.warning, 'Prefer XE, XS, XP or XU to 59: ${l.code}',
            'Use modifier 59 only when no more descriptive modifier applies: XE separate encounter, XS separate structure or organ, XP separate '
                'practitioner, XU unusual non-overlapping service. A different diagnosis alone does not justify 59.',
            code: l.code));
      }
    }
    return issues;
  }

  /// NCCI-MUE-03 (NCCI Policy Manual Ch. I, Sec. V). Units and modifier 50
  /// follow the PFS bilateral surgery indicator.
  static List<ClaimIssue> bilateralServiceIssues(List<ServiceLine> lines) {
    final fees = ReferenceData.fees;
    if (fees == null) return const [];
    final issues = <ClaimIssue>[];
    final reported = <String>{};
    for (final l in lines) {
      final ind = fees.lookup(l.code)?.bilateral ?? '';
      if (ind.isEmpty) continue;
      final has50 = _hasMod(l, '50');
      if (has50 && const {'0', '2', '9'}.contains(ind)) {
        issues.add(ruleIssue('NCCI-MUE-03', IssueSeverity.warning, 'Modifier 50 not allowed: ${l.code}',
            ind == '2'
                ? '${l.code} already describes a bilateral procedure (bilateral indicator 2). Report one unit without modifier 50.'
                : '${l.code} has bilateral indicator $ind: the bilateral adjustment does not apply, so modifier 50 is not used. Report the units performed without 50.',
            code: l.code));
      } else if (has50 && l.units > 1) {
        issues.add(ruleIssue('NCCI-MUE-03', IssueSeverity.warning, 'Bilateral procedure with more than one unit: ${l.code}',
            'A bilateral procedure with modifier 50 is reported on one line with one unit. Change the units of ${l.code} to 1.', code: l.code));
      } else if (ind == '2' && l.units > 1) {
        issues.add(ruleIssue('NCCI-MUE-03', IssueSeverity.warning, 'Bilateral code with more than one unit: ${l.code}',
            '${l.code} already includes both sides (bilateral indicator 2). Report one unit.', code: l.code));
      }
      if (ind == '1' && reported.add(l.code)) {
        final same = lines.where((x) => x.code == l.code).toList();
        final sides = same.expand((x) => x.modifiers.map((m) => m.trim().toUpperCase())).toSet();
        if (same.length > 1 && sides.contains('RT') && sides.contains('LT')) {
          issues.add(ruleIssue('NCCI-MUE-03', IssueSeverity.warning, 'Bilateral procedure on two lines: ${l.code}',
              '${l.code} has bilateral indicator 1. When it is done on both sides, report it on one line with modifier 50 and one unit, not as RT and LT lines.',
              code: l.code));
        }
      }
    }
    return issues;
  }

  /// NCCI-LAB-01 (NCCI Policy Manual Ch. I, Sec. N; Ch. X, Sec. C). A
  /// medically necessary repeat of the same laboratory test on the same day
  /// is reported with modifier 91. (Panel composition is CPT content and
  /// is enforced through the PTP edits when they are loaded.)
  static List<ClaimIssue> labRepeatIssues(List<ServiceLine> lines) {
    final issues = <ClaimIssue>[];
    final seen = <String>{};
    for (final l in lines) {
      final n = int.tryParse(l.code) ?? 0;
      if (n < 80047 || n > 89398) continue;
      if (seen.add(l.code)) continue;
      if (_hasMod(l, '91')) continue;
      issues.add(ruleIssue('NCCI-LAB-01', IssueSeverity.warning, 'Repeat lab test without modifier 91: ${l.code}',
          '${l.code} is billed more than once. A medically necessary repeat of the same test on the same day is reported with modifier 91 on the '
              'repeat; a test repeated to confirm a result or because of a testing problem is not billed again.',
          code: l.code));
    }
    return issues;
  }
}

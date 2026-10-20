import '../../models/claim_models.dart';
import '../../models/patient_account.dart';
import '../../models/provider_profile.dart';
import '../billing/cms_edi_edits.dart';
import '../billing/x12_837p.dart' show isAmbulanceMileageCode, isAmbulancePos, isAmbulanceServiceCode, isOriginDestinationModifier;
import '../codesets/icd_catalog.dart';
import '../codesets/reference_data.dart';
import 'code_rules.dart';
import 'knowledge_checks.dart';
import 'place_of_service.dart';

/// Pre-submission claim edits. Errors block the claim; warnings are likely
/// denials or payer-specific; info is for the record.
class ClaimScrubber {
  /// NCCI-associated modifiers that may bypass a PTP edit whose modifier
  /// indicator is 1 (Medicare NCCI Policy Manual, Chapter I, Section E).
  static const ncciModifiers = {
    'E1', 'E2', 'E3', 'E4', 'FA', 'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', //
    'LC', 'LD', 'LM', 'LT', 'RC', 'RI', 'RT', 'TA', 'T1', 'T2', 'T3', 'T4', 'T5', 'T6', 'T7', 'T8', 'T9', //
    '24', '25', '27', '57', '58', '59', '78', '79', '91', 'XE', 'XP', 'XS', 'XU',
  };

  /// Pairs of services on the same claim that NCCI says are not billed
  /// together. Column 2 is the component code that would be denied.
  static List<ClaimIssue> ptpIssues(List<ServiceLine> lines) {
    final ptp = ReferenceData.ptp;
    if (ptp == null) return const [];
    final issues = <ClaimIssue>[];
    for (var i = 0; i < lines.length; i++) {
      for (var j = 0; j < lines.length; j++) {
        if (i == j) continue;
        final c1 = lines[i], c2 = lines[j];
        final e = ptp.edit(c1.code, c2.code);
        if (e == null || e.modifierIndicator == 9) continue;
        if (e.modifierIndicator == 0) {
          issues.add(ruleIssue('NCCI-PTP-01', 
            IssueSeverity.error,
            'Billed together: ${c1.code} includes ${c2.code}',
            'NCCI does not pay ${c2.code} with ${c1.code} on the same day, even with a modifier. Remove ${c2.code}.',
            code: c2.code,
          ));
        } else if (!c2.modifiers.any((m) => ncciModifiers.contains(m.toUpperCase())) &&
            !c1.modifiers.any((m) => ncciModifiers.contains(m.toUpperCase()))) {
          issues.add(ruleIssue('NCCI-MOD-01', 
            IssueSeverity.error,
            'Needs a modifier: ${c2.code} with ${c1.code}',
            'NCCI bundles ${c2.code} into ${c1.code}. If it was a separate service (different site, session or encounter), add 59 or XE/XS/XP/XU to ${c2.code} and document why. Otherwise remove it.',
            code: c2.code,
          ));
        }
      }
    }
    return issues;
  }

  /// ICD-7TH-01 and ICD-PLACEHOLDER-01 (guidelines I.A.4, I.A.5). For a
  /// code that is not billable and falls under a 7th character definition,
  /// says which 7th characters apply and gives the corrected code. Null when
  /// the 7th character table is not loaded, the code has no 7th character
  /// rule, or it is short of characters other than the 7th.
  static ClaimIssue? seventhCharacterIssue(String code, IcdCatalog icd) {
    final rule = ReferenceData.seventh?.ruleFor(code);
    if (rule == null) return null;
    final n = code.trim().toUpperCase().replaceAll('.', '');
    if (n.length >= 7) {
      final c7 = n[6];
      if (rule.allows(c7)) return null;
      final fixed = [for (final k in rule.characters.keys) withSeventhCharacter(n, k)].where(icd.isBillable).take(3).toList();
      return ruleIssue('ICD-7TH-01', 
        IssueSeverity.error,
        'Invalid 7th character: $code',
        '"$c7" is not a 7th character for codes in ${rule.prefix}. Use one of: ${rule.describe()}.'
            '${fixed.isEmpty ? '' : ' For example ${fixed.join(', ')}.'}',
        code: code,
      );
    }
    // A 7th character entered without the placeholder X (T74.4A for T74.4XXA).
    if (n.length >= 4 && rule.allows(n[n.length - 1])) {
      final padded = withSeventhCharacter(n.substring(0, n.length - 1), n[n.length - 1]);
      if (icd.isBillable(padded)) {
        return ruleIssue('ICD-PLACEHOLDER-01', 
          IssueSeverity.error,
          'Missing placeholder X: $code',
          '$code needs the placeholder X in the empty positions before its 7th character (guideline I.A.4). Report it as $padded.',
          code: code,
        ).withFix(IssueFix(FixKind.replaceDiagnosis, 'Use ${_dotted(padded)}', code: code, replacement: _dotted(padded)));
      }
    }
    final options = [
      for (final k in rule.characters.keys)
        if (icd.isBillable(withSeventhCharacter(n, k))) k,
    ];
    if (options.isEmpty) return null;
    final example = withSeventhCharacter(n, options.first);
    return ruleIssue('ICD-7TH-01', 
      IssueSeverity.error,
      'Missing 7th character: $code',
      '$code needs a 7th character${n.length < 6 ? ', with placeholder X before it' : ''} (guideline I.A.5): ${rule.describe()}. '
          'For example $example for ${rule.characters[options.first]}.',
      code: code,
    );
  }

  /// First-listed diagnosis rules, on the diagnosis codes in claim order.
  static List<ClaimIssue> sequencingIssues(List<String> codes, {bool inpatient = false, IcdCatalog? icdCatalog}) {
    if (codes.isEmpty) return const [];
    final issues = <ClaimIssue>[];
    final first = codes.first;
    final mce = ReferenceData.mce;
    final group = secondaryOnlyGroup(first);
    if (isExternalCauseCode(first)) {
      // ICD-EXTCAUSE-01 (guidelines I.C.20.a.6 and IV.B; MCE edit 2).
      issues.add(ruleIssue('ICD-EXTCAUSE-01', 
        IssueSeverity.error,
        'External cause listed first: $first',
        '$first tells how or where an injury or health problem happened (external cause codes V00-Y99) and is never the '
            'first-listed diagnosis. Move the injury or condition to the first position and keep $first after it.',
        code: first,
      ));
    } else if (group != null) {
      // ICD-SECONDARY-ONLY-01 (guidelines I.B.14, I.C.18.e.1, I.C.18.i, I.C.21.c.17).
      issues.add(ruleIssue('ICD-SECONDARY-ONLY-01', 
        IssueSeverity.error,
        'Secondary-only code listed first: $first',
        '$group codes such as $first are reported only as secondary diagnoses. List the condition it relates to first, then $first.',
        code: first,
      ));
    } else if (isSevereSepsisCode(first)) {
      // CH1-SEPSIS-01 (guideline I.C.1.d; MCE edit 9).
      issues.add(ruleIssue('CH1-SEPSIS-01', 
        IssueSeverity.error,
        'Severe sepsis listed first: $first',
        'R65.2- is never the first-listed diagnosis. List the underlying systemic infection first (for example A41.9 '
            'Sepsis, unspecified organism), then $first.',
        code: first,
      ));
    } else if ((mce?.isManifestation(first) ?? false) ||
        (icdCatalog?.description(first)?.toLowerCase().contains('in diseases classified elsewhere') ?? false)) {
      // ICD-MANIF-01 (guideline I.A.13; MCE edit 6).
      issues.add(ruleIssue('ICD-MANIF-01', 
        IssueSeverity.error,
        'Manifestation code listed first: $first',
        '$first describes a manifestation of another disease and is never the first-listed diagnosis. List the underlying '
            'disease first, then $first.',
        code: first,
      ));
    } else if (inpatient &&
        mce != null &&
        mce.isUnacceptablePrincipal(first) &&
        !isFirstListedOnly(first) &&
        !(mce.acceptableWithSecondary(first) && codes.length > 1)) {
      // MCE-UNACC-01 (MCE edit 9): an inpatient edit, so only for hospital inpatient visits.
      issues.add(ruleIssue('MCE-UNACC-01', 
        IssueSeverity.error,
        'Not accepted as principal diagnosis: $first',
        'Medicare\'s inpatient code editor (MCE edit 9) does not accept $first as the principal diagnosis. For a hospital '
            'stay, list the condition chiefly responsible for the admission first.',
        code: first,
      ));
    }
    for (var i = 1; i < codes.length; i++) {
      final c = codes[i];
      // CH1-SEPSIS-01: R65.2- follows the systemic infection.
      if (isSevereSepsisCode(c) && !codes.take(i).any(_isSystemicInfection)) {
        issues.add(ruleIssue('CH1-SEPSIS-01', 
          IssueSeverity.warning,
          'Severe sepsis without its infection first: $c',
          'Code the underlying systemic infection (for example A41.9) and list it before $c (guideline I.C.1.d.1.a).',
          code: c,
        ));
      }
      // CH21-Z-01 (guideline I.C.21.c.15).
      if (isFirstListedOnly(c)) {
        issues.add(ruleIssue(isPreopCode(c) ? 'OP-PREOP-01' : 'CH21-Z-01', 
          IssueSeverity.error,
          'Must be listed first: $c',
          '$c may only be the first-listed diagnosis. Move it to the first position, or remove it if it was not the reason '
              'for this visit. Two such codes are allowed together only when encounters on the same day are combined.',
          code: c,
        ));
      }
    }
    return issues;
  }

  static bool _isSystemicInfection(String code) {
    final c = code.toUpperCase();
    return c.startsWith('A') ||
        c.startsWith('B') ||
        c.startsWith('P36') ||
        c.startsWith('O85') ||
        c.startsWith('O86.04') ||
        c.startsWith('T80.2') ||
        c.startsWith('T81.44') ||
        c.startsWith('T88.0');
  }

  /// CH9-HTN-01/02/03 (guidelines I.C.9.a.1 to I.C.9.a.3) and CH14-CKD-01
  /// (guideline I.C.14.a.1), for codes entered by hand: hypertension with
  /// heart failure or CKD has a combination code, and ESRD replaces the stage.
  static List<ClaimIssue> combinationIssues(List<String> codes) {
    final c = [for (final x in codes) x.trim().toUpperCase()];
    final issues = <ClaimIssue>[];
    bool heartCode(String x) =>
        x.startsWith('I50') || x == 'I51.4' || x == 'I51.5' || x == 'I51.7' || x == 'I51.89' || x == 'I51.9';
    final heart = c.where(heartCode).toList();
    final ckd = c.where((x) => x.startsWith('N18')).toList();
    if (c.contains('I10') && (heart.isNotEmpty || ckd.isNotEmpty)) {
      final stage5 = ckd.any((x) => x == 'N18.5' || x == 'N18.6');
      final suggested = heart.isNotEmpty && ckd.isNotEmpty
          ? (stage5 ? 'I13.2' : 'I13.0')
          : heart.isNotEmpty
              ? 'I11.0'
              : (stage5 ? 'I12.0' : 'I12.9');
      issues.add(ruleIssue(heart.isNotEmpty && ckd.isNotEmpty ? 'CH9-HTN-03' : heart.isNotEmpty ? 'CH9-HTN-01' : 'CH9-HTN-02', 
        IssueSeverity.warning,
        'Hypertension needs its combination code: I10',
        'I10 is reported with ${[...heart, ...ckd].join(' and ')}. ICD-10-CM presumes hypertension causes heart failure and '
            'chronic kidney disease, so replace I10 with $suggested and keep ${[...heart, ...ckd].join(' and ')} '
            '(guideline I.C.9.a). Keep I10 only if the record says the conditions are unrelated.',
        code: 'I10',
      ));
    }
    if (c.any((x) => x.startsWith('I11')) && c.any((x) => x.startsWith('I12'))) {
      issues.add(ruleIssue('CH9-HTN-03', 
        IssueSeverity.warning,
        'Use I13 for heart and kidney disease',
        'Hypertensive heart disease (I11) and hypertensive CKD (I12) together are coded with one I13 code, plus the I50 '
            'and N18 codes (guideline I.C.9.a.3).',
      ));
    }
    if (ckd.contains('N18.6') && ckd.length > 1) {
      final stages = ckd.where((x) => x != 'N18.6').join(', ');
      issues.add(ruleIssue('CH14-CKD-01', 
        IssueSeverity.warning,
        'ESRD replaces the CKD stage: $stages',
        'When end stage renal disease is documented, report N18.6 only and remove $stages (guideline I.C.14.a.1).',
        code: ckd.firstWhere((x) => x != 'N18.6'),
      ));
    }
    return issues;
  }

  /// ICD-EXCL1-01 (guideline I.A.12.a). Diagnoses on the claim that an
  /// Excludes1 note says are not coded together. An error, as the rule
  /// catalog rates it; when either diagnosis carries a note saying the two
  /// conditions are unrelated (the official exception), a warning instead.
  static List<ClaimIssue> excludes1Issues(List<ClaimDiagnosis> dx) {
    final ex = ReferenceData.excludes1;
    if (ex == null || dx.length < 2) return const [];
    bool unrelated(String code) => dx.any((d) => d.code == code && (d.note ?? '').toLowerCase().contains('unrelated'));
    return [
      for (final c in ex.conflicts(dx.map((d) => d.code).toList()))
        if (unrelated(c.code) || unrelated(c.excluded))
          ruleIssue('ICD-EXCL1-01', 
            IssueSeverity.warning,
            'Excludes1 pair documented as unrelated: ${c.code} and ${c.excluded}',
            'An Excludes1 note at ${c.noteAt} says ${c.excludedRef} is not coded with ${c.code}. Both are kept because the record '
                'says the conditions are unrelated (guideline I.A.12.a exception). Make sure the note supports that.',
            code: c.excluded,
          )
        else
          ruleIssue('ICD-EXCL1-01', 
            IssueSeverity.error,
            'Excludes1 conflict: ${c.code} and ${c.excluded}',
            'An Excludes1 note at ${c.noteAt} says ${c.excludedRef} is never coded with ${c.code}: one includes the other or '
                'they cannot occur together. Keep the code that matches the documentation and remove the other. Exception '
                '(guideline I.A.12.a): if the two conditions are unrelated to each other, both may be reported; add a note '
                'saying they are unrelated.',
            code: c.excluded,
          ),
    ];
  }

  /// NCCI-ADDON-01 (NCCI Policy Manual Chapter I, Sections R and W). An
  /// add-on code needs one of its primary codes on the same claim. Type 1
  /// edits are errors; type 3 (listed plus contractor-defined primaries) are
  /// warnings; type 2 (contractor-defined only) cannot be checked.
  static List<ClaimIssue> addOnIssues(List<ServiceLine> lines) {
    final aoc = ReferenceData.addOns;
    if (aoc == null) return const [];
    final codes = lines.map((l) => l.code.trim().toUpperCase()).toSet();
    final seen = <String>{};
    final issues = <ClaimIssue>[];
    for (final l in lines) {
      final e = aoc.lookup(l.code);
      if (e == null || e.type == 2 || e.primaries.isEmpty || !seen.add(e.addOn)) continue;
      if (e.primaries.any((p) => p != e.addOn && codes.contains(p))) continue;
      final listed = (e.primaries.toList()..sort());
      final examples = listed.take(4).join(', ');
      issues.add(ruleIssue('NCCI-ADDON-01', 
        e.type == 1 ? IssueSeverity.error : IssueSeverity.warning,
        'Add-on code without its primary: ${l.code}',
        '${l.code} is an add-on code and is paid only with its primary procedure on the same claim, such as $examples'
            '${listed.length > 4 ? ' (${listed.length} codes qualify)' : ''}. Add the primary procedure or remove ${l.code}.'
            '${e.type == 3 ? ' Your Medicare contractor may accept other primary codes too.' : ''}',
        code: l.code,
      ));
    }
    return issues;
  }

  /// NCCI-EM-01 (NCCI Policy Manual Chapter I, Sections D and E). An E/M on
  /// the same day as a minor procedure (global period 000 or 010) is part of
  /// the procedure unless it is significant and separately identifiable,
  /// which modifier 25 on the E/M says.
  static List<ClaimIssue> minorProcedureEmIssues(List<ServiceLine> lines) {
    final fees = ReferenceData.fees;
    if (fees == null) return const [];
    final minor = [
      for (final l in lines)
        if (emSettingOf(l.code) == null && const {'000', '010'}.contains(fees.lookup(l.code)?.globalDays)) l.code,
    ];
    if (minor.isEmpty) return const [];
    return [
      for (final em in lines)
        if (emSettingOf(em.code) != null && !em.modifiers.any((m) => m.trim() == '25'))
          ruleIssue('NCCI-EM-01', 
            IssueSeverity.error,
            'E/M needs modifier 25: ${em.code}',
            '${em.code} is billed with ${minor.join(', ')}, a minor procedure (0 or 10 day global period) that already '
                'includes the evaluation to decide on it. If you also provided a significant, separately identifiable E/M '
                'service, add modifier 25 to ${em.code} and document it; otherwise remove ${em.code}.',
            code: em.code,
          ),
    ];
  }

  /// The knowledge-base checks (knowledge_checks.dart) on the billable
  /// diagnoses in claim order and the service lines. Each is skipped when the
  /// data it needs is not loaded.
  static List<ClaimIssue> knowledgeIssues({
    required ClaimDraft claim,
    required PatientAccount account,
    required Visit visit,
    IcdCatalog? icd,
  }) {
    final dos = DateTime.tryParse(visit.dateOfService);
    return ReferenceData.atDateOfService(dos, () => _knowledgeIssues(claim: claim, account: account, visit: visit, icd: icd, dos: dos));
  }

  static List<ClaimIssue> _knowledgeIssues({
    required ClaimDraft claim,
    required PatientAccount account,
    required Visit visit,
    required IcdCatalog? icd,
    required DateTime? dos,
  }) {
    final codes = claim.billable.map((d) => d.code).toList();
    final lines = claim.lines;
    final index = dos == null ? null : ReferenceData.indexFor(dos);
    return [
      ...KnowledgeChecks.duplicateIssues(codes),
      ...KnowledgeChecks.codeFirstIssues(codes, icd: icd),
      ...KnowledgeChecks.sequelaIssues(codes),
      ...KnowledgeChecks.symptomFirstIssues(codes),
      ...KnowledgeChecks.historyFirstIssues(codes),
      ...KnowledgeChecks.obstetricIssues(codes),
      ...KnowledgeChecks.poisoningIssues(codes),
      ...KnowledgeChecks.externalCauseStatusIssues(codes),
      ...KnowledgeChecks.statusIssues(codes),
      ...KnowledgeChecks.neoplasmHistoryIssues(codes, index, icd),
      ...KnowledgeChecks.bilateralIssues(codes, icd),
      ...KnowledgeChecks.unspecifiedSideIssues(codes),
      ...KnowledgeChecks.acuteChronicIssues(codes, index),
      ...KnowledgeChecks.combinationIndexIssues(codes, index, icd),
      ...KnowledgeChecks.injuryEncounterIssues(codes, account, visit),
      ...KnowledgeChecks.therapyEncounterIssues(codes, lines),
      ...KnowledgeChecks.diagnosticServiceIssues(codes, lines),
      ...KnowledgeChecks.useAdditionalIssues(codes),
      ...KnowledgeChecks.codeAlsoIssues(codes),
      ...KnowledgeChecks.majorProcedureEmIssues(lines, account: account, visit: visit),
      ...KnowledgeChecks.xxxProcedureEmIssues(lines),
      ...KnowledgeChecks.globalPeriodIssues(lines, account, visit),
      ...KnowledgeChecks.distinctServiceModifierIssues(lines),
      ...KnowledgeChecks.bilateralServiceIssues(lines),
      ...KnowledgeChecks.labRepeatIssues(lines),
    ];
  }

  /// Runs every check. [demoMode] is true only in the local demo: sample
  /// patients and the demo provider may then be billed (to the test
  /// clearinghouse); outside it they are errors.
  static List<ClaimIssue> check({
    required ClaimDraft claim,
    required PatientAccount account,
    required Visit visit,
    required ProviderProfile provider,
    required bool noteSigned,
    bool demoMode = false,
  }) {
    // Every check reads the ICD-10-CM edition of the visit's date of service
    // (validity, billable status, Excludes1, Tabular notes, 7th characters):
    // FY2026 through 2026-09-30, FY2027 from 2026-10-01.
    final issues = ReferenceData.atDateOfService(
      DateTime.tryParse(visit.dateOfService),
      () => _check(claim: claim, account: account, visit: visit, provider: provider, noteSigned: noteSigned, demoMode: demoMode),
    );
    return [for (final i in issues) i.fix == null ? i.withFix(fixFor(i, claim)) : i];
  }

  static List<ClaimIssue> _check({
    required ClaimDraft claim,
    required PatientAccount account,
    required Visit visit,
    required ProviderProfile provider,
    required bool noteSigned,
    required bool demoMode,
  }) {
    final issues = <ClaimIssue>[];
    final dx = claim.billable;
    final pos = placeOfService(visit.placeOfService);
    final dos = DateTime.tryParse(visit.dateOfService);
    final age = account.ageOn(dos);

    // Required data -----------------------------------------------------------
    if (!noteSigned) {
      issues.add(ruleIssue('CLAIM-SIGNED-01', IssueSeverity.error, 'Note not signed', 'Sign the note before the claim can be sent.'));
    }
    if (account.dateOfBirth == null) {
      issues.add(ruleIssue('CLAIM-PATIENT-01', IssueSeverity.error, 'Date of birth missing', 'Box 3 requires the patient date of birth. Scan the license or enter it.'));
    }
    if (account.sex == PatientSex.unknown) {
      issues.add(ruleIssue('CLAIM-PATIENT-01', IssueSeverity.error, 'Sex missing', 'Box 3 requires the patient sex. Payers use it for sex-specific code edits.'));
    }
    final ins = account.insurance;
    if (ins == null || ins.memberId.trim().isEmpty) {
      issues.add(ruleIssue('CLAIM-PAYER-01', IssueSeverity.error, 'No insurance on file', 'Scan the insurance card to add the payer and member ID (box 1a).'));
    } else if (!provider.acceptedPayers.any((p) => _samePayer(p, ins.payerName))) {
      issues.add(ruleIssue('CLAIM-NETWORK-01', 
        IssueSeverity.warning,
        'Payer may be out of network',
        '${ins.payerName} is not in your accepted payers. The claim may deny or pay out-of-network.',
      ));
    }
    if (!isValidNpi(provider.npi)) {
      issues.add(ruleIssue('CLAIM-NPI-01', IssueSeverity.error, 'Rendering NPI invalid', 'Box 24J needs a valid 10-digit NPI. Update the provider profile.'));
    }
    if (!isValidEin(provider.taxId)) {
      issues.add(ruleIssue('CLAIM-TIN-01', IssueSeverity.error, 'Tax ID missing or invalid', 'Box 25 needs the federal tax ID (EIN, NN-NNNNNNN).'));
    }
    if (!demoMode && provider.isDemoIdentity) {
      issues.add(ruleIssue('CLAIM-PROVIDER-01', IssueSeverity.error, 'Demo provider on the claim',
          'The NPI or tax ID is the demo provider\'s, not yours. Enter your own in the provider profile before billing.'));
    }
    final profileGaps = provider.missingForClaims.where((m) => m != 'Individual NPI' && m != 'Tax ID (EIN)').toList();
    if (profileGaps.isNotEmpty) {
      issues.add(ruleIssue('CLAIM-PROVIDER-02', IssueSeverity.error, 'Provider profile incomplete',
          'Boxes 24J, 32 and 33 need: ${profileGaps.join(', ')}. Complete the provider profile.'));
    }
    if (!demoMode && account.isSample) {
      issues.add(ruleIssue('CLAIM-SAMPLE-01', IssueSeverity.error, 'Sample patient, cannot be billed',
          '${account.fullName} is a demo patient. Claims are only sent for real patients.'));
    }
    final elig = visit.eligibility;
    if (ins != null && ins.memberId.trim().isNotEmpty) {
      if (elig == null) {
        issues.add(ruleIssue('CLAIM-ELIG-01', IssueSeverity.info, 'Coverage not verified for this date',
            'No eligibility check is on file for this visit. Check coverage to catch an inactive plan before the payer denies the claim.'));
      } else if (elig['success'] == true && elig['active'] == false) {
        issues.add(ruleIssue('CLAIM-ELIG-01', IssueSeverity.error, 'Coverage not active on the date of service',
            'The payer reported ${ins.payerName} coverage as inactive for ${visit.dateOfService}. Rescan the current card or bill the patient.'));
      } else if (elig['success'] != true) {
        issues.add(ruleIssue('CLAIM-ELIG-01', IssueSeverity.warning, 'Coverage could not be verified',
            'The last eligibility check failed${(elig['errors'] as List?)?.isNotEmpty == true ? ': ${(elig['errors'] as List).first}' : ''}. Check again before sending.'));
      }
    }
    if (isAmbulancePos(visit.placeOfService)) {
      final t = visit.transport;
      final missing = t == null ? const ['pick-up address', 'drop-off address', 'loaded miles', 'transport reason'] : t.missing;
      if (missing.isNotEmpty) {
        issues.add(ruleIssue('CLAIM-AMBULANCE-02', IssueSeverity.error, 'Transport details missing',
            'Ambulance claims carry the transport (837P CR1, loops 2310E and 2310F). Add the ${missing.join(', ')}.'));
      }
    }

    // Diagnoses ----------------------------------------------------------------
    if (dx.isEmpty) {
      issues.add(ruleIssue('CLAIM-DX-01', IssueSeverity.error, 'No diagnosis', 'Every claim needs at least one ICD-10-CM code in box 21.'));
    }
    if (dx.length > 12) {
      issues.add(ruleIssue('CLAIM-DX-01', IssueSeverity.warning, 'More than 12 diagnoses', 'Box 21 holds 12. Only the first 12 are sent; ${dx.length - 12} will be dropped.'));
    }
    if (dx.isNotEmpty && (dx.first.code.startsWith('R') || dx.first.code.startsWith('Z')) && claim.uncertain.isNotEmpty) {
      issues.add(ruleIssue('OP-UNCERTAIN-01', 
        IssueSeverity.info,
        'Primary diagnosis is a symptom',
        'You documented ${claim.uncertain.map((d) => d.code).join(', ')} with uncertain wording. Confirm it if it is established, or the visit is coded to symptoms.',
      ));
    }
    final icd = dos == null ? null : ReferenceData.icdFor(dos);
    for (final d in dx) {
      if (icd != null && !icd.isBillable(d.code)) {
        // ICD-7TH-01 and ICD-PLACEHOLDER-01: say which 7th characters apply.
        final seventh = seventhCharacterIssue(d.code, icd);
        if (seventh != null) {
          issues.add(seventh);
        } else if (!icd.isValid(d.code)) {
          issues.add(ruleIssue('ICD-VALID-01', 
            IssueSeverity.error,
            'Not a valid code: ${d.code}',
            '${d.code} is not in ICD-10-CM FY${icd.fiscalYear}, the edition for this date of service.',
            code: d.code,
          ));
        } else {
          final options = icd.billableChildren(d.code, limit: 3).map((e) => e.code).join(', ');
          final rule = ReferenceData.seventh?.ruleFor(d.code);
          issues.add(ruleIssue('ICD-BILLABLE-01', 
            IssueSeverity.error,
            'Code needs more characters: ${d.code}',
            '${d.code} is a category, not a billable code.${options.isEmpty ? '' : ' Choose one such as $options.'}'
                '${rule == null ? '' : ' Codes in ${rule.prefix} also need a 7th character: ${rule.describe()}.'}',
            code: d.code,
          ));
        }
      }
      final sex = icdSexRestriction(d.code);
      if (sex != null && account.sex != PatientSex.unknown && sex != account.sex) {
        issues.add(ruleIssue('MCE-SEX-01', 
          provider.enforceSexEdits ? IssueSeverity.error : IssueSeverity.warning,
          'Sex conflict: ${d.code}',
          '${d.description} applies to ${sex == PatientSex.female ? 'female' : 'male'} patients only. This patient is ${account.sex.name}.',
          code: d.code,
        ));
      }
      // MCE-AGE-01 / CH15-OB-01 / CH16-PERI-01: MCE v44 age lists.
      final range = icdAgeRange(d.code);
      if (range != null && age != null && !range.contains(age)) {
        issues.add(ruleIssue('MCE-AGE-01', IssueSeverity.error, 'Age conflict: ${d.code}', '${d.code} is for ${range.label}. Patient is $age.', code: d.code));
      } else if (range == null && age != null && age > 0 && isPerinatalCode(d.code)) {
        // CH16-PERI-01: guideline I.C.16.a.4 allows perinatal codes at any age.
        issues.add(ruleIssue('CH16-PERI-01', 
          IssueSeverity.warning,
          'Perinatal code after the newborn period: ${d.code}',
          '${d.code} is a perinatal condition code. It may be used at any age (patient is $age) only if the condition began '
              'in the perinatal period (guideline I.C.16.a.4). Confirm the record says so; otherwise use the code for the condition '
              'from its body-system chapter.',
          code: d.code,
        ));
      }
      // ICD-UNSPEC-01; ICD-LAT-02 gives the laterality-specific warning instead.
      if (isUnspecifiedIcd(d.code) && d == dx.first && !(ReferenceData.mce?.isUnspecifiedLaterality(d.code) ?? false)) {
        issues.add(ruleIssue('ICD-UNSPEC-01', 
          IssueSeverity.info,
          'Unspecified primary diagnosis',
          '${d.code} is valid, but some payers ask for more specificity (site, type, laterality) on the primary diagnosis.',
          code: d.code,
        ));
      }
    }
    issues.addAll(sequencingIssues(dx.map((d) => d.code).toList(), inpatient: pos.setting == EmSetting.inpatient, icdCatalog: icd));
    issues.addAll(excludes1Issues(dx));
    issues.addAll(combinationIssues(dx.map((d) => d.code).toList()));
    issues.addAll(knowledgeIssues(claim: claim, account: account, visit: visit, icd: icd));

    // Services ------------------------------------------------------------------
    if (claim.lines.isEmpty) {
      issues.add(ruleIssue('CLAIM-SERVICE-01', IssueSeverity.error, 'No services', 'Add at least one CPT or HCPCS code in box 24D.'));
    }
    final emLines = claim.lines.where((l) => emSettingOf(l.code) != null).toList();
    if (emLines.length > 1) {
      issues.add(ruleIssue('CLAIM-EM-01', IssueSeverity.warning, 'More than one E/M code', 'Only one E/M service per provider per day is normally paid.'));
    }
    issues.addAll(ptpIssues(claim.lines));
    issues.addAll(addOnIssues(claim.lines));
    issues.addAll(minorProcedureEmIssues(claim.lines));
    // NCCI-MUE-02: date-of-service MUEs (MAI 2 and 3) count every line of the code.
    final unitsByCode = <String, int>{};
    final linesByCode = <String, int>{};
    for (final l in claim.lines) {
      final k = l.code.trim().toUpperCase();
      unitsByCode[k] = (unitsByCode[k] ?? 0) + l.units;
      linesByCode[k] = (linesByCode[k] ?? 0) + 1;
    }
    final mueReported = <String>{};
    for (final l in claim.lines) {
      // Place of service must match the E/M family.
      final emSetting = emSettingOf(l.code);
      if (emSetting != null && emSetting != pos.setting && !(pos.setting == EmSetting.other)) {
        issues.add(ruleIssue('CLAIM-POS-01', 
          IssueSeverity.error,
          'Place of service conflict: ${l.code}',
          '${l.code} is a ${_settingName(emSetting)} code but the visit is at ${pos.label}.',
          code: l.code,
        ));
      }
      if (pos.setting == EmSetting.ambulance && emSetting != null) {
        issues.add(ruleIssue('CLAIM-AMBULANCE-01', IssueSeverity.error, 'E/M billed in an ambulance', 'Ambulance services bill HCPCS A0425 to A0434, not ${l.code}.', code: l.code));
      }
      if (l.code.startsWith('A04') && pos.setting != EmSetting.ambulance) {
        issues.add(ruleIssue('CLAIM-AMBULANCE-01', IssueSeverity.error, 'Ambulance code outside an ambulance', '${l.code} requires place of service 41 or 42.', code: l.code));
      }
      if (emSetting != null && isNewPatientEm(l.code) && account.visits.any((v) => v.number < visit.number)) {
        issues.add(ruleIssue('CLAIM-NEWPT-01', 
          IssueSeverity.warning,
          'New patient code on a return visit',
          '${l.code} is a new-patient code, but this is visit ${visit.number}. Established-patient codes apply after the first visit within 3 years.',
          code: l.code,
        ));
      }
      if (isTelehealthPos(visit.placeOfService) && emSetting != null && !l.modifiers.contains('95')) {
        issues.add(ruleIssue('CLAIM-TELEHEALTH-01', IssueSeverity.warning, 'Telehealth modifier', 'Many payers require modifier 95 on ${l.code} for telehealth visits.', code: l.code));
      }

      // Every line needs a supporting diagnosis.
      if (l.diagnosisCodes.isEmpty) {
        final systems = procedureSystems(l.code).map(bodySystemLabel).join(' or ');
        issues.add(ruleIssue('CLAIM-POINTER-01', 
          IssueSeverity.error,
          'No supporting diagnosis: ${l.code}',
          dx.isEmpty
              ? 'Add a diagnosis that supports ${l.code}.'
              : '${l.description} needs a $systems diagnosis. None of ${dx.map((d) => d.code).join(', ')} supports it, so the payer would deny it as not medically necessary.',
          code: l.code,
        ));
      }
      for (final d in l.diagnosisCodes) {
        if (!diagnosisSupportsProcedure(d, l.code)) {
          issues.add(ruleIssue('CLAIM-POINTER-01', IssueSeverity.error, 'Diagnosis does not support ${l.code}', '$d is not a ${procedureSystems(l.code).map(bodySystemLabel).join(' or ')} diagnosis.', code: l.code));
        }
      }

      final sex = procedureSexRestriction(l.code);
      if (sex != null && account.sex != PatientSex.unknown && sex != account.sex) {
        issues.add(ruleIssue('MCE-SEX-01', 
          provider.enforceSexEdits ? IssueSeverity.error : IssueSeverity.warning,
          'Sex conflict: ${l.code}',
          '${l.description} applies to ${sex == PatientSex.female ? 'female' : 'male'} patients only. This patient is ${account.sex.name}.',
          code: l.code,
        ));
      }
      final range = procedureAgeRange(l.code);
      if (range != null && age != null && !range.contains(age)) {
        issues.add(ruleIssue('CLAIM-PROCAGE-01', IssueSeverity.error, 'Age conflict: ${l.code}', '${l.code} is for ${range.label}. Patient is $age.', code: l.code));
      }
      final known = ReferenceData.isKnownProcedure(l.code);
      if (known == false) {
        issues.add(ruleIssue('CLAIM-PROCEDURE-01', IssueSeverity.warning, 'Unrecognized code: ${l.code}', '${l.code} is not on the 2026 physician fee schedule or the HCPCS file. Check it.', code: l.code));
      }
      final mue = ReferenceData.mue;
      final maxUnits = mue?.maxUnits(l.code);
      final mai = mue?.adjudicationIndicator(l.code);
      final key = l.code.trim().toUpperCase();
      if (maxUnits != null && (mai == 2 || mai == 3)) {
        // NCCI-MUE-02: units of the same code on the date of service are summed.
        final total = unitsByCode[key]!;
        final lineCount = linesByCode[key]!;
        if (total > maxUnits && mueReported.add(key)) {
          issues.add(ruleIssue('NCCI-MUE-02', 
            IssueSeverity.error,
            'Too many units: ${l.code}',
            'NCCI allows at most $maxUnits per day for ${l.code} (medically unlikely edit, counted per date of service); '
                '${lineCount > 1 ? 'the claim has $total across $lineCount lines' : 'this line has $total'}. Reduce the units or remove the extra lines.',
            code: l.code,
          ));
        }
      } else if (maxUnits != null && l.units > maxUnits) {
        issues.add(ruleIssue('NCCI-MUE-01', 
          IssueSeverity.error,
          'Too many units: ${l.code}',
          'NCCI allows at most $maxUnits per day for ${l.code} (medically unlikely edit); this line has ${l.units}.',
          code: l.code,
        ));
      }
      final pfs = ReferenceData.fees?.lookup(l.code);
      final isMedicare = (ins?.payerName ?? '').toLowerCase().contains('medicare');
      if (isMedicare && pfs != null && pfs.status == 'N') {
        issues.add(ruleIssue('CLAIM-COVERAGE-01', IssueSeverity.warning, 'Not covered by Medicare: ${l.code}', 'Medicare does not pay ${l.code}. Have the patient sign an ABN, or bill the patient.', code: l.code));
      }
      if (l.charge <= 0) {
        issues.add(ruleIssue('CLAIM-SERVICE-01', IssueSeverity.warning, 'No charge: ${l.code}', 'Enter the charge (box 24F) or add ${l.code} to your fee schedule.', code: l.code));
      }
      if (isAmbulanceMileageCode(l.code) && (l.quantity ?? visit.transport?.loadedMiles) == null) {
        issues.add(ruleIssue('CLAIM-AMBULANCE-01', IssueSeverity.error, 'Loaded miles missing: ${l.code}',
            '${l.code} is billed per loaded mile, to a tenth of a mile. Enter the miles in Transport; SOLIS never bills a default of 1.', code: l.code));
      }
      if (isAmbulancePos(visit.placeOfService) && isAmbulanceServiceCode(l.code) && !l.modifiers.any(isOriginDestinationModifier)) {
        issues.add(ruleIssue('CLAIM-AMBULANCE-03', IssueSeverity.error, 'Origin and destination modifier: ${l.code}',
            '${l.code} needs the two-letter origin and destination modifier, for example RH for residence to hospital. Set them in Transport.',
            code: l.code));
      }
    }

    // Medicare front-end edits (CMS CR 14429, October 2026) for MAC claims.
    issues.addAll(CmsEdiEdits.claimIssues(claim: claim, account: account));

    if (claim.uncertain.isNotEmpty) {
      issues.add(ruleIssue('CLAIM-UNCERTAIN-01', 
        IssueSeverity.info,
        '${claim.uncertain.length} diagnosis waiting for your confirmation',
        'Uncertain diagnoses are not billed. Confirm them only if they are established.',
      ));
    }

    issues.sort((a, b) => a.severity.index.compareTo(b.severity.index));
    return issues;
  }

  /// The deterministic fix for [issue], or null when the fix needs a
  /// decision only the physician can make.
  static IssueFix? fixFor(ClaimIssue issue, ClaimDraft claim) {
    final code = issue.code;
    switch (issue.ruleId) {
      case 'CLAIM-SIGNED-01':
        return const IssueFix(FixKind.signNote, 'Sign note');
      case 'CLAIM-PATIENT-01':
        return issue.title.startsWith('Date of birth')
            ? const IssueFix(FixKind.editPatient, 'Add date of birth', field: 'dob')
            : const IssueFix(FixKind.editPatient, 'Add sex', field: 'sex');
      case 'CLAIM-PAYER-01':
        return const IssueFix(FixKind.scanCard, 'Scan insurance card');
      case 'CLAIM-ELIG-01':
        return issue.severity == IssueSeverity.error ? const IssueFix(FixKind.scanCard, 'Rescan card') : null;
      case 'CLAIM-NPI-01':
      case 'CLAIM-TIN-01':
      case 'CLAIM-PROVIDER-01':
      case 'CLAIM-PROVIDER-02':
        return const IssueFix(FixKind.editProvider, 'Open provider profile');
      case 'CLAIM-POS-01':
        return const IssueFix(FixKind.choosePlaceOfService, 'Change place of service');
      case 'CLAIM-AMBULANCE-01':
      case 'CLAIM-AMBULANCE-02':
      case 'CLAIM-AMBULANCE-03':
        return const IssueFix(FixKind.editTransport, 'Add transport details');
      case 'CLAIM-NEWPT-01':
        final est = code == null ? null : establishedEquivalent(code);
        return est == null ? null : IssueFix(FixKind.replaceService, 'Use $est', code: code, replacement: est);
      case 'CLAIM-TELEHEALTH-01':
        return code == null ? null : IssueFix(FixKind.addModifier, 'Add modifier 95', code: code, replacement: '95');
      case 'CLAIM-SERVICE-01':
        return code == null ? null : IssueFix(FixKind.editLine, 'Enter charge', code: code);
      case 'NCCI-MUE-01':
      case 'NCCI-MUE-02':
        return code == null ? null : IssueFix(FixKind.editLine, 'Edit units', code: code);
      case CmsEdiEdits.serviceDescription:
        return code == null ? null : IssueFix(FixKind.editLine, 'Describe the service', code: code);
      case CmsEdiEdits.memberIdFormat:
        return const IssueFix(FixKind.scanCard, 'Rescan Medicare card');
      case 'CLAIM-UNCERTAIN-01':
      case 'OP-UNCERTAIN-01':
        final pending = claim.uncertain;
        return pending.length == 1 ? IssueFix(FixKind.confirmDiagnosis, 'Confirm ${pending.first.code}', code: pending.first.code) : null;
    }
    return null;
  }

  /// The established-patient code at the same MDM level as a new-patient
  /// office or home visit code (99204 to 99214). Null for other codes.
  static String? establishedEquivalent(String code) => const {
        '99202': '99212', '99203': '99213', '99204': '99214', '99205': '99215',
        '99341': '99347', '99342': '99348', '99344': '99349', '99345': '99350',
      }[code];

  /// "T744XXA" to "T74.4XXA".
  static String _dotted(String code) {
    final c = code.replaceAll('.', '');
    return c.length > 3 ? '${c.substring(0, 3)}.${c.substring(3)}' : c;
  }

  static bool _samePayer(String a, String b) {
    String n(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    final x = n(a), y = n(b);
    if (x.isEmpty || y.isEmpty) return false;
    if (x.contains(y) || y.contains(x)) return true;
    const aliases = [
      ['unitedhealthcare', 'uhc', 'unitedhealth'],
      ['bluecrossblueshield', 'bcbs', 'anthem', 'bluecross', 'blueshield'],
    ];
    return aliases.any((g) => g.any(x.contains) && g.any(y.contains));
  }

  static String _settingName(EmSetting s) => switch (s) {
        EmSetting.office => 'office or outpatient',
        EmSetting.emergency => 'emergency department',
        EmSetting.inpatient => 'hospital inpatient',
        EmSetting.nursingFacility => 'nursing facility',
        EmSetting.home => 'home or residence',
        EmSetting.ambulance => 'ambulance',
        EmSetting.other => 'other',
      };
}

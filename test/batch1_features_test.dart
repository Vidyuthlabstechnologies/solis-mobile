import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/models/provider_profile.dart';
import 'package:solis_mobile/services/billing/claim_status_codes.dart';
import 'package:solis_mobile/services/billing/claims_csv.dart';
import 'package:solis_mobile/services/billing/x12_837p.dart';
import 'package:solis_mobile/services/coding/claim_scrubber.dart';
import 'package:solis_mobile/services/coding/recent_codes.dart';
import 'package:solis_mobile/services/coding/rule_citations.g.dart';
import 'package:solis_mobile/services/patient_list.dart';
import 'package:solis_mobile/services/security/phi_clipboard.dart';
import 'package:solis_mobile/services/theme_preference.dart';

const _config = SubmitterConfig(
  submitterName: 'Bayview Family Medicine',
  submitterId: '123435',
  submitterContactName: 'Billing Office',
  isaSenderId: '574183004559',
  isaReceiverId: 'STEDITEST',
  usageIndicator: 'T',
  interchangeControlNumber: 39,
  groupControlNumber: 39,
  transactionControlNumber: 1,
);

const _aetna = InsuranceCoverage(payerName: 'Aetna', payerId: '60054', memberId: 'W281947365', relationship: 'self');
const _medicare = InsuranceCoverage(payerName: 'Medicare Part B', payerId: '01112', memberId: '1EG4TE5MK73', relationship: 'self');

ClaimDraft _claim(List<String> dx, {List<String> lines = const ['99213']}) => ClaimDraft(
      generatedAtUtc: DateTime.utc(2026, 10, 15),
      diagnoses: [for (final c in dx) ClaimDiagnosis(code: c, description: 'Dx $c', source: DxSource.physicianConfirmed)],
      lines: [for (final l in lines) ServiceLine(code: l, description: 'Service $l', charge: 120, diagnosisCodes: dx.take(1).toList())],
    );

PatientAccount _account({
  String number = 'SOL-1000017',
  String first = 'Jane',
  String last = 'Doe',
  InsuranceCoverage? insurance = _aetna,
  List<Visit> visits = const [],
  DateTime? dob,
}) =>
    PatientAccount(
      accountNumber: number,
      firstName: first,
      lastName: last,
      dateOfBirth: dob ?? DateTime(1958, 3, 4),
      sex: PatientSex.female,
      addressLine1: '12 Oak St',
      city: 'Oakland',
      state: 'CA',
      zip: '94607',
      createdAtUtc: DateTime.utc(2026, 10, 1),
      insurance: insurance,
      visits: visits,
    );

Visit _visit(String dos, {int n = 1, VisitStatus status = VisitStatus.signed, ClaimDraft? claim, Map<String, dynamic>? submission}) =>
    Visit(number: n, dateOfService: dos, placeOfService: '11', createdAtUtc: DateTime.parse('${dos}T12:00:00Z'), status: status, claim: claim, submission: submission);

List<String> _segments(String x12) => x12.split('~').where((s) => s.isNotEmpty).toList();

void main() {
  group('corrected and void claims (CLM05-3, REF*F8)', () {
    X12BuildResult build(ClaimFrequency f, {String? icn}) => Claim837PGenerator.build(
          claim: _claim(['I10']),
          account: _account(),
          visit: _visit('2026-10-15', n: 2),
          provider: ProviderProfile.demo(),
          config: _config,
          now: DateTime(2026, 10, 16, 9, 5),
          frequency: f,
          payerClaimControlNumber: icn,
        );

    test('an original claim is frequency 1 with no REF*F8', () {
      final r = build(ClaimFrequency.original);
      expect(r.errors, isEmpty);
      final segs = _segments(r.x12!);
      expect(segs.firstWhere((s) => s.startsWith('CLM*')).split('*')[5], '11:B:1');
      expect(segs.any((s) => s.startsWith('REF*F8*')), isFalse);
    });

    test('a corrected claim is frequency 7 and names the original right after CLM', () {
      final r = build(ClaimFrequency.replacement, icn: '2026288123456');
      expect(r.errors, isEmpty);
      final segs = _segments(r.x12!);
      final clm = segs.indexWhere((s) => s.startsWith('CLM*'));
      expect(segs[clm].split('*')[5], '11:B:7');
      expect(segs[clm + 1], 'REF*F8*2026288123456');
      // SE01 still counts every segment.
      final st = segs.indexWhere((s) => s.startsWith('ST*'));
      final se = segs.indexWhere((s) => s.startsWith('SE*'));
      expect(int.parse(segs[se].split('*')[1]), se - st + 1);
    });

    test('a void claim is frequency 8', () {
      final r = build(ClaimFrequency.voided, icn: 'ABC123');
      expect(_segments(r.x12!).firstWhere((s) => s.startsWith('CLM*')).split('*')[5], '11:B:8');
    });

    test('a corrected or void claim without the payer claim number is not built', () {
      for (final f in [ClaimFrequency.replacement, ClaimFrequency.voided]) {
        final r = build(f);
        expect(r.ok, isFalse);
        expect(r.errors.single, contains('REF*F8'));
      }
    });
  });

  group('date of service and filing limit', () {
    List<String> ids(Visit v, {InsuranceCoverage? ins = _aetna, DateTime? dob}) =>
        ClaimScrubber.dateOfServiceIssues(visit: v, account: _account(insurance: ins, dob: dob), today: DateTime(2026, 11, 6))
            .map((i) => '${i.ruleId}:${i.severity.name}')
            .toList();

    test('a visit today or in the past is fine', () {
      expect(ids(_visit('2026-11-06')), isEmpty);
      expect(ids(_visit('2026-10-15')), isEmpty);
    });

    test('a future date of service is an error', () {
      expect(ids(_visit('2026-11-07')), ['CLAIM-DOS-01:error']);
    });

    test('a date of service before birth is an error', () {
      expect(ids(_visit('2026-10-15'), dob: DateTime(2026, 10, 20)), ['CLAIM-DOS-01:error']);
    });

    test('Medicare: warns 30 days before one year, errors after', () {
      expect(ids(_visit('2025-12-01'), ins: _medicare), ['CLAIM-TIMELY-01:warning']);
      expect(ids(_visit('2025-11-01'), ins: _medicare), ['CLAIM-TIMELY-01:error']);
      expect(ids(_visit('2026-06-01'), ins: _medicare), isEmpty);
    });

    test('commercial: a warning after 90 days', () {
      expect(ids(_visit('2026-09-01')), isEmpty);
      expect(ids(_visit('2026-07-01')), ['CLAIM-TIMELY-01:warning']);
    });

    test('a claim already sent is not flagged for the filing limit', () {
      expect(ids(_visit('2025-01-01', status: VisitStatus.submitted), ins: _medicare), isEmpty);
    });

    test('both rules have a citation for the Why sheet', () {
      expect(ruleCitations['CLAIM-DOS-01'], isNotEmpty);
      expect(ruleCitations['CLAIM-TIMELY-01'], '42 CFR 424.44');
    });
  });

  group('plain-language claim status', () {
    test('category, status code and payer text are combined', () {
      final s = describeClaimStatus(categoryCode: 'A7', statusCode: '164', payerText: 'Entity\'s contract/member number');
      expect(s, contains('Rejected: information is invalid.'));
      expect(s, contains('member ID'));
      expect(s, contains('Payer says: "Entity\'s contract/member number".'));
    });

    test('paid and denied read plainly', () {
      expect(describeClaimStatus(categoryCode: 'F1'), 'Finalized: paid.');
      expect(describeClaimStatus(categoryCode: 'f2'), startsWith('Finalized: denied.'));
    });

    test('unknown codes fall back to the payer text', () {
      expect(describeClaimStatus(categoryCode: 'Z9', statusCode: '9999', payerText: 'Something'), 'Payer says: "Something".');
      expect(describeClaimStatus(), contains('does not recognize'));
    });

    test('request-for-information categories map to R0', () {
      expect(explainStatusCategory('R4')?.meaning, contains('more information'));
    });

    test('CARC with group code', () {
      expect(explainAdjustment('CO-16'), allOf(startsWith('Contractual'), contains('missing information')));
      expect(explainAdjustment('PR 2'), allOf(startsWith('Patient responsibility'), contains('Coinsurance')));
      expect(explainAdjustment('29'), contains('filing limit'));
      expect(explainAdjustment('CO-99999'), isNull);
      expect(explainAdjustment('nonsense text'), isNull);
    });
  });

  group('claims CSV', () {
    test('fields are quoted and formulas neutralized', () {
      expect(csvField('plain'), 'plain');
      expect(csvField('a,b'), '"a,b"');
      expect(csvField('say "hi"'), '"say ""hi"""');
      expect(csvField('=HYPERLINK("x")'), '"\'=HYPERLINK(""x"")"');
      expect(csvField('+1'), "'+1");
    });

    test('one row per visit with a claim, newest first', () {
      final csv = claimsCsv([
        _account(visits: [
          _visit('2026-10-01', n: 1, claim: _claim(['I10'])),
          _visit('2026-10-20', n: 2, claim: _claim(['E11.9', 'I10'], lines: ['99214', '36415']), submission: {'payerClaimNumber': 'P1', 'statusExplanation': 'Finalized: paid.'}),
          _visit('2026-10-25', n: 3), // no claim
        ]),
      ]);
      final rows = csv.trim().split('\r\n');
      expect(rows, hasLength(3));
      expect(rows.first, startsWith('Account,Patient,Date of birth'));
      expect(rows[1], contains('2026-10-20'));
      expect(rows[1], contains('E11.9; I10'));
      expect(rows[1], contains('99214 x1; 36415 x1'));
      expect(rows[1], contains('240.00'));
      expect(rows[1], contains('Finalized: paid.'));
      expect(rows[2], contains('2026-10-01'));
    });
  });

  group('patient list', () {
    final a = _account(number: 'A', first: 'Zoe', last: 'Adams', visits: [_visit('2026-10-01')]);
    final b = _account(number: 'B', first: 'Ann', last: 'Brown', insurance: null, visits: [_visit('2026-11-01', status: VisitStatus.inProgress)]);
    final c = _account(number: 'C', first: 'Bob', last: 'Adams');
    final all = [a, b, c];

    test('recent sorts by last visit, accounts without visits last', () {
      expect(patientList(all).map((x) => x.accountNumber), ['B', 'A', 'C']);
    });

    test('name sorts by last then first name', () {
      expect(patientList(all, sort: PatientSort.name).map((x) => x.accountNumber), ['C', 'A', 'B']);
    });

    test('filters', () {
      expect(patientList(all, filter: PatientFilter.needsSignature).map((x) => x.accountNumber), ['B']);
      expect(patientList(all, filter: PatientFilter.noInsurance).map((x) => x.accountNumber), ['B']);
    });

    test('search still works with filters', () {
      expect(patientList(all, query: 'adams').map((x) => x.accountNumber), ['A', 'C']);
      expect(patientList(all, query: 'w2819', filter: PatientFilter.noInsurance), isEmpty);
    });
  });

  group('recent codes', () {
    test('newest visit first, no repeats, invalid codes skipped', () {
      final accounts = [
        _account(visits: [
          _visit('2026-10-01', n: 1, claim: _claim(['I10', 'E78.5'], lines: ['99213'])),
          _visit('2026-10-20', n: 2, claim: _claim(['E11.9', 'I10'], lines: ['99214', '36415'])),
        ]),
      ];
      expect(recentDiagnoses(accounts).map((e) => e.$1), ['E11.9', 'I10', 'E78.5']);
      expect(recentDiagnoses(accounts, isValid: (c) => c != 'I10').map((e) => e.$1), ['E11.9', 'E78.5']);
      expect(recentDiagnoses(accounts, limit: 1), hasLength(1));
      expect(recentServiceCodes(accounts), ['99214', '36415', '99213']);
    });
  });

  group('theme preference', () {
    test('follows the system until a choice is saved', () async {
      final dir = await Directory.systemTemp.createTemp('solis_theme');
      addTearDown(() => dir.delete(recursive: true));
      final p = await ThemePreference.load(directory: dir);
      expect(p.mode, ThemeMode.system);
      expect(p.isDark(Brightness.dark), isTrue);
      expect(p.isDark(Brightness.light), isFalse);
      await p.set(ThemeMode.dark);
      final again = await ThemePreference.load(directory: dir);
      expect(again.mode, ThemeMode.dark);
      expect(again.isDark(Brightness.light), isTrue);
    });

    test('unknown saved text means system', () {
      expect(ThemePreference.parse('purple'), ThemeMode.system);
      expect(ThemePreference.parse('light'), ThemeMode.light);
    });
  });

  group('PHI clipboard', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    String? clip;
    setUp(() {
      clip = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clip = (call.arguments as Map)['text'] as String?;
        if (call.method == 'Clipboard.getData') return {'text': clip};
        return null;
      });
    });
    tearDown(() {
      PhiClipboard.clearAfterOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    test('clears what it copied', () async {
      PhiClipboard.clearAfterOverride = const Duration(milliseconds: 10);
      await PhiClipboard.copy('Jane Doe note');
      expect(clip, 'Jane Doe note');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(clip, '');
    });

    test('leaves something copied later alone', () async {
      await PhiClipboard.copy('note');
      clip = 'something else';
      await PhiClipboard.clearIfStill('note');
      expect(clip, 'something else');
    });
  });
}

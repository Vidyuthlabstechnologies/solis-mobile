// ICD-10-CM FY2027 takes effect by date of service: 2026-09-30 is coded and
// checked against FY2026, 2026-10-01 against FY2027. These tests use the real
// bundled assets (both editions, with their own Tabular notes) and run the
// claim checks with a visit date, never today's date.

import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/services/codesets/codesets.dart';
import 'package:solis_mobile/services/codesets/reference_data.dart';
import 'package:solis_mobile/services/coding/claim_scrubber.dart';
import 'package:solis_mobile/widgets/knowledge_widgets.dart';

import 'support/test_provider.dart';

final _sep30 = DateTime(2026, 9, 30);
final _oct1 = DateTime(2026, 10, 1);

String _iso(DateTime d) => d.toIso8601String().split('T').first;

List<ClaimIssue> _scrub(List<String> codes, DateTime dos) {
  final provider = testProvider();
  final visit = Visit(number: 1, dateOfService: _iso(dos), placeOfService: '11', createdAtUtc: DateTime.utc(2026, 10, 18));
  final account = PatientAccount(
    accountNumber: 'SOL-10000017',
    firstName: 'Pat',
    lastName: 'Lee',
    sex: PatientSex.female,
    dateOfBirth: DateTime(1960, 5, 1),
    createdAtUtc: DateTime.utc(2026),
    insurance: InsuranceCoverage(payerName: provider.acceptedPayers.first, memberId: 'W1'),
    visits: [visit],
  );
  return ClaimScrubber.check(
    claim: ClaimDraft(
      generatedAtUtc: DateTime.utc(2026, 10, 18),
      diagnoses: [for (final c in codes) ClaimDiagnosis(code: c, description: c, source: DxSource.physicianConfirmed)],
      lines: [ServiceLine(code: '99213', description: 'Office visit', charge: 140, diagnosisCodes: codes)],
    ),
    account: account,
    visit: visit,
    provider: provider,
    noteSigned: true,
  );
}

Iterable<ClaimIssue> _rule(List<ClaimIssue> issues, String id, [String? code]) =>
    issues.where((i) => i.ruleId == id && (code == null || i.code == code));

void main() {
  setUpAll(() async {
    CodeSetLoader.useSource(DirectoryCodeSetSource('assets/codes'));
    await ReferenceData.load();
  });
  tearDownAll(() {
    ReferenceData.clear();
    CodeSetLoader.useSource(const AssetCodeSetSource());
  });

  test('the edition switches on October 1 by date of service', () {
    expect(IcdEditions.resolve(_sep30), 2026);
    expect(IcdEditions.resolve(_oct1), 2027);
    expect(ReferenceData.icdFor(_sep30)!.fiscalYear, 2026);
    expect(ReferenceData.icdFor(_oct1)!.fiscalYear, 2027);
    expect(ReferenceData.atDateOfService(_sep30, () => ReferenceData.activeFiscalYear), 2026);
    expect(ReferenceData.atDateOfService(_oct1, () => ReferenceData.activeFiscalYear), 2027);
    expect(ReferenceData.activeFiscalYear, isNull, reason: 'outside a claim the latest edition is used');
  });

  test('both editions have their own Tabular notes, Excludes1 and 7th characters', () {
    for (final d in [_sep30, _oct1]) {
      expect(ReferenceData.excludes1For(d), isNotNull);
      expect(ReferenceData.notesFor(d), isNotNull);
      expect(ReferenceData.seventhFor(d), isNotNull);
    }
    expect(identical(ReferenceData.notesFor(_sep30), ReferenceData.notesFor(_oct1)), isFalse);
    expect(identical(ReferenceData.excludes1For(_sep30), ReferenceData.excludes1For(_oct1)), isFalse);
  });

  group('T52.8X1A, deleted in FY2027', () {
    test('validity and billable status follow the date of service', () {
      expect(ReferenceData.icdFor(_sep30)!.isBillable('T52.8X1A'), isTrue);
      expect(ReferenceData.icdFor(_oct1)!.isValid('T52.8X1A'), isFalse);
    });

    test('passes on 2026-09-30 and is an error on 2026-10-01', () {
      final before = _scrub(['T52.8X1A'], _sep30);
      expect(_rule(before, 'ICD-VALID-01'), isEmpty);
      expect(_rule(before, 'ICD-BILLABLE-01'), isEmpty);
      expect(_rule(before, 'ICD-7TH-01'), isEmpty);

      final after = _scrub(['T52.8X1A'], _oct1);
      final invalid = _rule(after, 'ICD-VALID-01', 'T52.8X1A').single;
      expect(invalid.severity, IssueSeverity.error);
      expect(invalid.detail, contains('FY2027'));
    });
  });

  group('I42.0, a billable code that became a header in FY2027', () {
    test('billable through September 30, a category from October 1', () {
      expect(ReferenceData.icdFor(_sep30)!.isBillable('I42.0'), isTrue);
      expect(ReferenceData.icdFor(_oct1)!.isBillable('I42.0'), isFalse);
      expect(ReferenceData.icdFor(_oct1)!.isBillable('I42.00'), isTrue);
    });

    test('the scrubber asks for more characters only from October 1, naming the FY2027 codes', () {
      expect(_rule(_scrub(['I42.0'], _sep30), 'ICD-BILLABLE-01'), isEmpty);
      final after = _rule(_scrub(['I42.0'], _oct1), 'ICD-BILLABLE-01', 'I42.0').single;
      expect(after.severity, IssueSeverity.error);
      expect(after.detail, contains('I42.0'));
      expect(after.detail, anyOf(contains('I42.00'), contains('I42.01')));
    });

    test('I42.00, new in FY2027, is not valid for a September 30 visit', () {
      expect(_rule(_scrub(['I42.00'], _sep30), 'ICD-VALID-01', 'I42.00').single.detail, contains('FY2026'));
      expect(_rule(_scrub(['I42.00'], _oct1), 'ICD-VALID-01'), isEmpty);
    });
  });

  group('Excludes1 and Tabular notes follow the date of service', () {
    // FY2026 has "Excludes1: ... (R26.81)" at R26.2; FY2027 dropped it.
    test('the FY2026 note is in the FY2026 notes only', () {
      bool excludesR2681(IcdNotes n) => n.of('R26.2', NoteKind.excludes1).any((x) => x.names('R26.81'));
      expect(excludesR2681(ReferenceData.notesFor(_sep30)!), isTrue);
      expect(excludesR2681(ReferenceData.notesFor(_oct1)!), isFalse);
    });

    test('R26.2 with R26.81 is an Excludes1 conflict on 9/30 and not on 10/1', () {
      final before = _rule(_scrub(['R26.2', 'R26.81'], _sep30), 'ICD-EXCL1-01');
      expect(before, isNotEmpty);
      expect(before.first.severity, IssueSeverity.error);
      expect(_rule(_scrub(['R26.2', 'R26.81'], _oct1), 'ICD-EXCL1-01'), isEmpty);
    });

    test('the coding notes shown for a code come from the visit edition', () {
      bool shows(DateTime d) =>
          codeNotesFor('R26.2', dateOfService: d).any((n) => n.kind == NoteKind.excludes1 && n.names('R26.81'));
      expect(shows(_sep30), isTrue);
      expect(shows(_oct1), isFalse);
    });

    test('the same claim checked on two dates gives different answers in one run', () {
      // No state leaks from one date of service to the next.
      expect(_rule(_scrub(['R26.2', 'R26.81'], _sep30), 'ICD-EXCL1-01'), isNotEmpty);
      expect(_rule(_scrub(['R26.2', 'R26.81'], _oct1), 'ICD-EXCL1-01'), isEmpty);
      expect(_rule(_scrub(['R26.2', 'R26.81'], _sep30), 'ICD-EXCL1-01'), isNotEmpty);
    });
  });
}

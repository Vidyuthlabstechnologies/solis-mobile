import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/data/sample_conversations.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/screens/patients_screen.dart';
import 'package:solis_mobile/services/account_repository.dart';
import 'package:solis_mobile/services/local_clinical_engine.dart';
import 'package:solis_mobile/services/patient_summary.dart';
import 'package:solis_mobile/services/value_report.dart';
import 'package:solis_mobile/theme/solis_theme.dart';

import 'support/billing_fixtures.dart';

void main() {
  group('what SOLIS did for you', () {
    test('counts notes signed and claims sent today and over 7 days', () async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final now = DateTime(2026, 11, 11, 17);
      Future<void> visit(DateTime signed, {DateTime? sent}) async {
        final v = await visitWith(repo, a, status: sent == null ? VisitStatus.signed : VisitStatus.submitted);
        await repo.updateVisit(
          a.accountNumber,
          v.copyWith(
            encounter: {'signedAtUtc': signed.toUtc().toIso8601String()},
            submission: sent == null ? null : {'submittedAtUtc': sent.toUtc().toIso8601String()},
          ),
        );
      }

      await visit(DateTime(2026, 11, 11, 9), sent: DateTime(2026, 11, 11, 10));
      await visit(DateTime(2026, 11, 11, 11));
      await visit(DateTime(2026, 11, 7, 9), sent: DateTime(2026, 11, 8, 9));
      await visit(DateTime(2026, 11, 1, 9), sent: DateTime(2026, 11, 1, 10)); // older than 7 days

      final r = ValueReport.compute(repo.accounts, now: now);
      expect(r.today.notesSigned, 2);
      expect(r.today.claimsSent, 1);
      expect(r.today.billed, 140);
      expect(r.week.notesSigned, 3);
      expect(r.week.claimsSent, 2);
      expect(r.week.billed, 280);
      expect(r.today.timeSavedLabel, '30 min');
      expect(const ValueTotals(notesSigned: 9).timeSavedLabel, '2 h 15 min');
      expect(formatDollars(2400), '\$2,400');
      expect(formatDollars(95.5), '\$95.50');
    });

    testWidgets('Today shows the card once there is something to show', (tester) async {
      final repo = await realRepo();
      AccountRepository.instance = repo;
      final a = await billablePatient(repo);
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(theme: SolisTheme.lightTheme(), home: const PatientsScreen(initialTab: 0)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('value_card')), findsNothing);

      final v = await visitWith(repo, a);
      await repo.updateVisit(a.accountNumber, v.copyWith(encounter: {'signedAtUtc': DateTime.now().toUtc().toIso8601String()}));
      await tester.pumpWidget(MaterialApp(theme: SolisTheme.lightTheme(), home: const PatientsScreen(initialTab: 0)));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('value_card')), findsOneWidget);
      expect(find.textContaining('Today: 1 note signed, 0 claims sent (\$0.00), about 15 min saved.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  group('patient after-visit summary', () {
    test('plain language from the note, no codes or abbreviations', () {
      final note = LocalClinicalEngine.synthesizeOnDevice(
        rawSpeech: sampleConversations['Diabetic Peripheral Neuropathy']!,
        patientName: 'Margaret Vance',
        mrn: '1',
        ageGender: '67F',
        attending: 'Dr. Lin',
      );
      final text = PatientSummary.write(
        note: note,
        patientFirstName: 'Margaret',
        dateOfService: '2026-11-11',
        clinician: 'Dr. Sarah Lin',
        practice: 'Bayview Family Medicine',
        phone: '415-555-0100',
      );
      expect(text, startsWith('Visit summary for Margaret, 2026-11-11'));
      expect(text, contains('What we found'));
      expect(text, contains('Findings consistent with diabetic peripheral neuropathy.'));
      expect(text, contains('Your medicines'));
      expect(text, contains('- Start gabapentin 300 mg at bedtime for nighttime burning nerve pain.'));
      expect(text, contains('What to do next'));
      expect(text, contains('Follow up in 6 weeks'));
      expect(text, contains('Call Bayview Family Medicine at 415-555-0100 if you get worse'));
      expect(text, isNot(contains('Coded as')));
      expect(text, isNot(contains('oral hypoglycemic')));
      expect(text, isNot(matches(RegExp(r'\b[A-TV-Z]\d{2}\.\w'))));
    });

    test('help advice given in the visit is used instead of the default', () {
      final note = LocalClinicalEngine.synthesizeOnDevice(
        rawSpeech: sampleConversations['Community-Acquired Pneumonia']!,
        patientName: 'Elena',
        mrn: '1',
        ageGender: '34F',
        attending: 'Dr',
      );
      final text = PatientSummary.write(note: note, patientFirstName: 'Elena', dateOfService: '2026-11-11', clinician: 'Dr. Lin');
      expect(text, contains('emergency room'));
      expect(text, contains('For an emergency, call 911.'));
    });
  });
}

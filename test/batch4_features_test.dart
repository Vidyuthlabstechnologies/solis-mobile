import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/screens/patient_chart_screen.dart';
import 'package:solis_mobile/screens/patients_screen.dart';
import 'package:solis_mobile/theme/solis_theme.dart';

import 'support/billing_fixtures.dart';

void main() {
  group('allergies', () {
    test('free text becomes a clean list; NKA alone means none', () {
      expect(parseAllergies('Penicillin (hives), latex; penicillin (hives)\nsulfa'), ['Penicillin (hives)', 'latex', 'sulfa']);
      expect(parseAllergies('NKDA'), isEmpty);
      expect(parseAllergies(' none '), isEmpty);
      expect(parseAllergies('No known allergies'), isEmpty);
      expect(parseAllergies('nka, shellfish'), ['nka', 'shellfish'], reason: 'only NKA alone means none');
      expect(parseAllergies(''), isEmpty);
    });

    test('not recorded, none, and a list survive a save', () {
      final a = PatientAccount(accountNumber: 'SOL-1', firstName: 'A', lastName: 'B', createdAtUtc: DateTime.utc(2026));
      expect(a.allergySummary, 'Not recorded');
      expect(PatientAccount.fromJson(a.toJson()).allergies, isNull);
      final none = a.copyWith(allergies: const []);
      expect(PatientAccount.fromJson(none.toJson()).allergySummary, 'No known allergies');
      final some = a.copyWith(allergies: const ['Penicillin', 'Latex']);
      expect(PatientAccount.fromJson(some.toJson()).allergies, ['Penicillin', 'Latex']);
      expect(some.allergySummary, 'Penicillin, Latex');
    });

    testWidgets('the chart records no known allergies in one tap', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final repo = await realRepo();
      final a = await billablePatient(repo);
      await tester.pumpWidget(MaterialApp(theme: SolisTheme.lightTheme(), home: PatientChartScreen(accountNumber: a.accountNumber)));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Not recorded'), findsOneWidget);
      await tester.tap(find.byKey(const Key('allergies_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('No known allergies'));
      await tester.pumpAndSettle();
      expect(repo.byNumber(a.accountNumber)!.allergies, isEmpty);
      expect(find.text('No known allergies'), findsOneWidget);
    });
  });

  test('a screen left open re-checks claim status every few hours', () {
    expect(PatientsScreen.statusRefreshEvery, const Duration(hours: 3));
  });
}

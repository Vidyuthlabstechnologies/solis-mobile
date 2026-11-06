import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/clinical_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/models/provider_profile.dart';
import 'package:solis_mobile/screens/charge_master_screen.dart';
import 'package:solis_mobile/screens/claim_tab.dart';
import 'package:solis_mobile/screens/encounter_screen.dart';
import 'package:solis_mobile/screens/patient_chart_screen.dart';
import 'package:solis_mobile/services/billing/x12_837p.dart';
import 'package:solis_mobile/services/coding/claim_builder.dart';
import 'package:solis_mobile/services/note_seal.dart';
import 'package:solis_mobile/theme/solis_theme.dart';

import 'support/billing_fixtures.dart';

const _config = SubmitterConfig(submitterName: 'Clinic', submitterId: '123', isaSenderId: 'CLINIC', isaReceiverId: 'STEDI');

List<String> _segments(String x12) => x12.split('~').where((s) => s.isNotEmpty).toList();

ClinicalEncounter _signedNote(DateTime at) {
  final e = ClinicalEncounter(
    id: 'e1',
    patientName: 'Jane Doe',
    mrn: 'SOL-1',
    ageGender: '56 F',
    attendingPhysician: 'Dr Test',
    date: '2026-10-15',
    vitals: const [],
    subjective: 'Cough for three days.',
    objective: 'Lungs clear.',
    assessment: 'Acute URI.',
    plan: 'Fluids and rest.',
    codes: const [],
    rawTranscript: 'Doctor: How long have you had the cough? Patient: Three days.',
  );
  return e.copyWith(isSigned: true, signedAtUtc: at, sha256Seal: NoteSeal.compute(noteText: 'note', signerNpi: '1234567893', signedAtUtc: at));
}

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: SolisTheme.lightTheme(), home: home));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('addendum after signing', () {
    final at = DateTime.utc(2026, 10, 15, 18, 30, 5);

    test('an addendum is sealed on its own and tied to the note seal', () {
      final note = _signedNote(at);
      final a = NoteAddendum.create(
        text: '  Patient called: fever resolved.  ',
        atUtc: at.add(const Duration(days: 2)),
        signerName: 'Dr Test',
        signerNpi: '1234567893',
        noteSeal: note.sha256Seal,
      );
      expect(a.text, 'Patient called: fever resolved.');
      expect(a.seal, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(a.verify(note.sha256Seal), isTrue);
      expect(a.verify('0' * 64), isFalse, reason: 'moved onto another note, the seal no longer matches');
      final tampered = NoteAddendum(text: '${a.text}!', atUtc: a.atUtc, signerName: a.signerName, signerNpi: a.signerNpi, seal: a.seal);
      expect(tampered.verify(note.sha256Seal), isFalse);

      // Survives a save, and leaves the signed note untouched.
      final withAddendum = note.copyWith(addenda: [a]);
      final back = ClinicalEncounter.fromJson(withAddendum.toJson());
      expect(back.addenda.single.verify(back.sha256Seal), isTrue);
      expect(back.sha256Seal, note.sha256Seal);
      expect(back.subjective, note.subjective);
      // Reopening the note as a draft drops the signature and its addenda.
      expect(withAddendum.copyWith(clearSignature: true).addenda, isEmpty);
      expect(ClinicalEncounter.fromJson(note.toJson()).toJson().containsKey('addenda'), isFalse);
    });

    testWidgets('once the claim is sent the note is locked and corrections go into an addendum', (tester) async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final v = await visitWith(repo, a, status: VisitStatus.submitted);
      await repo.updateVisit(a.accountNumber, v.copyWith(encounter: _signedNote(at).toJson()));

      await _pump(tester, EncounterScreen(accountNumber: a.accountNumber, visitNumber: v.number));
      if (find.byKey(const Key('add_addendum')).evaluate().isEmpty) {
        await tester.tap(find.text('Note').first);
        await tester.pump(const Duration(milliseconds: 600));
      }
      expect(find.textContaining('corrections are added as addenda'), findsOneWidget);

      // Edit is refused.
      await tester.tap(find.byTooltip('Signed note is locked').first);
      await tester.pump();
      expect(find.textContaining('Add an addendum instead'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));

      // Bring the card to mid-screen, clear of the bottom bar.
      await Scrollable.ensureVisible(tester.element(find.byKey(const Key('add_addendum'))), alignment: 0.5);
      await tester.pump();
      await tester.tap(find.byKey(const Key('add_addendum')));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byKey(const Key('addendum_text')), 'Spoke with the patient; fever resolved.');
      await tester.pump();
      await tester.tap(find.text('Sign addendum'));
      await tester.pump(const Duration(milliseconds: 600));

      final saved = ClinicalEncounter.fromJson(repo.byNumber(a.accountNumber)!.visit(v.number)!.encounter!);
      expect(saved.addenda.single.text, 'Spoke with the patient; fever resolved.');
      expect(saved.addenda.single.verify(saved.sha256Seal), isTrue);
      expect(saved.subjective, 'Cough for three days.');
      expect(find.text('Spoke with the patient; fever resolved.'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  });

  group('referring provider and prior authorization', () {
    Future<(X12BuildResult, Map<String, dynamic>)> build(Visit Function(Visit v) change) async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final v = change(await visitWith(repo, a));
      final r = Claim837PGenerator.build(claim: v.claim!, account: a, visit: v, provider: repo.provider, config: _config, now: DateTime(2026, 10, 16, 9));
      final json = ClaimBuilder.build(account: a, visit: v, provider: repo.provider, claim: v.claim!, issues: const []);
      return (r, json);
    }

    test('both go on the 837P in the right loops', () async {
      final (r, json) = await build((v) => v.copyWith(
            referringProvider: const ReferringProvider(firstName: 'Ann', lastName: 'Lee', npi: '1234567893'),
            priorAuthNumber: ' PA-77821 ',
          ));
      expect(r.errors, isEmpty);
      final segs = _segments(r.x12!);
      final clm = segs.indexWhere((s) => s.startsWith('CLM*'));
      final hi = segs.indexWhere((s) => s.startsWith('HI*'));
      final dn = segs.indexWhere((s) => s.startsWith('NM1*DN*'));
      expect(segs.indexOf('REF*G1*PA-77821'), greaterThan(clm));
      expect(segs.indexOf('REF*G1*PA-77821'), lessThan(hi));
      expect(segs[dn], 'NM1*DN*1*LEE*ANN****XX*1234567893');
      expect(dn, greaterThan(hi));
      expect(dn, lessThan(segs.indexWhere((s) => s.startsWith('LX*'))));
      final provider = json['provider'] as Map;
      expect((provider['box17_referringProvider'] as Map)['npi'], '1234567893');
      expect(provider['box23_priorAuthorization'], 'PA-77821');
    });

    test('none: no segments; a bad referring NPI is an error', () async {
      final (plain, _) = await build((v) => v);
      expect(_segments(plain.x12!).any((s) => s.startsWith('NM1*DN') || s.startsWith('REF*G1')), isFalse);
      final (bad, _) = await build((v) => v.copyWith(referringProvider: const ReferringProvider(firstName: 'A', lastName: '', npi: '1234567890')));
      expect(bad.errors.join(' '), allOf(contains('2310A NM103'), contains('2310A NM109')));
    });

    test('visit keeps, clears and saves them', () {
      final v = Visit(number: 1, dateOfService: '2026-10-15', placeOfService: '11', createdAtUtc: DateTime.utc(2026));
      final set = v.copyWith(referringProvider: const ReferringProvider(firstName: 'Ann', lastName: 'Lee', npi: '1234567893'), priorAuthNumber: 'X1');
      final back = Visit.fromJson(set.toJson());
      expect(back.referringProvider!.displayName, 'Ann Lee');
      expect(back.priorAuthNumber, 'X1');
      final cleared = back.copyWith(clearReferringProvider: true, priorAuthNumber: '');
      expect(cleared.referringProvider, isNull);
      expect(cleared.priorAuthNumber, isNull);
      expect(v.toJson().containsKey('priorAuthNumber'), isFalse);
    });

    testWidgets('the dialog checks the NPI before saving', (tester) async {
      (ReferringProvider?, String)? result;
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await showDialog<(ReferringProvider?, String)>(context: context, builder: (_) => const ReferralDialog()),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('referring_npi')), '1234567890');
      await tester.tap(find.byKey(const Key('referral_save')));
      await tester.pump();
      expect(find.text('Enter a valid 10-digit NPI'), findsOneWidget);
      expect(find.text('Last name is required'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('referring_npi')), '1234567893');
      await tester.enterText(find.byKey(const Key('referring_last')), 'Lee');
      await tester.enterText(find.byKey(const Key('prior_auth')), 'PA1');
      await tester.tap(find.byKey(const Key('referral_save')));
      await tester.pumpAndSettle();
      expect(result!.$1!.npi, '1234567893');
      expect(result!.$2, 'PA1');
    });
  });

  group('charge master', () {
    test('code and price parsing', () {
      expect(isServiceCodeFormat('99213'), isTrue);
      expect(isServiceCodeFormat('g2211'), isTrue);
      expect(isServiceCodeFormat('0001F'), isTrue);
      expect(isServiceCodeFormat('9921'), isFalse);
      expect(isServiceCodeFormat('J06.9'), isFalse);
      expect(parseCharge(r'$1,250.50'), 1250.5);
      expect(parseCharge('140'), 140);
      expect(parseCharge('-5'), isNull);
      expect(parseCharge('1.234'), isNull);
      expect(parseCharge(''), isNull);
    });

    testWidgets('edit, add and remove prices', (tester) async {
      Map<String, double>? result;
      await _pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await Navigator.push<Map<String, double>>(
              context,
              MaterialPageRoute(builder: (_) => const ChargeMasterScreen(fees: {'99213': 140, '93000': 45})),
            ),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(r'$140.00'), findsOneWidget);

      await tester.tap(find.byKey(const Key('price_99213')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('price_amount')), '155.5');
      await tester.tap(find.byKey(const Key('price_save')));
      await tester.pumpAndSettle();
      expect(find.text(r'$155.50'), findsOneWidget);

      await tester.tap(find.byKey(const Key('add_price')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('price_code')), '99213');
      await tester.enterText(find.byKey(const Key('price_amount')), '1');
      await tester.tap(find.byKey(const Key('price_save')));
      await tester.pump();
      expect(find.text('This code already has a price'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('price_code')), 'g2211');
      await tester.tap(find.byKey(const Key('price_save')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('price_93000')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(result, {'99213': 155.5, 'G2211': 1.0});
    });

    test('starting prices are the default list', () {
      expect(ProviderProfile.defaultFees['99213'], 140);
    });
  });

  group('language and interpreter', () {
    test('summary and save', () {
      final a = PatientAccount(accountNumber: 'SOL-1', firstName: 'A', lastName: 'B', createdAtUtc: DateTime.utc(2026));
      expect(a.languageSummary, 'Not recorded');
      final es = a.copyWith(preferredLanguage: 'Spanish', interpreterNeeded: true);
      final back = PatientAccount.fromJson(es.toJson());
      expect(back.languageSummary, 'Spanish, interpreter needed');
      expect(back.copyWith(preferredLanguage: '', interpreterNeeded: false).languageSummary, 'Not recorded');
      expect(a.toJson().containsKey('interpreterNeeded'), isFalse);
    });

    testWidgets('the chart records language in two taps', (tester) async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      await _pump(tester, PatientChartScreen(accountNumber: a.accountNumber));
      await tester.tap(find.byKey(const Key('language_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spanish'));
      await tester.pump();
      await tester.tap(find.byKey(const Key('language_save')));
      await tester.pumpAndSettle();
      final saved = repo.byNumber(a.accountNumber)!;
      expect(saved.preferredLanguage, 'Spanish');
      expect(saved.interpreterNeeded, isTrue);
      expect(find.text('Spanish, interpreter needed'), findsOneWidget);
    });
  });
}

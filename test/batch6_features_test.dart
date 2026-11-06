import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/models/provider_profile.dart';
import 'package:solis_mobile/screens/patient_chart_screen.dart';
import 'package:solis_mobile/screens/scan_card_screen.dart';
import 'package:solis_mobile/services/billing/x12_837p.dart';
import 'package:solis_mobile/services/coding/claim_builder.dart';
import 'package:solis_mobile/services/patient_merge.dart';
import 'package:solis_mobile/theme/solis_theme.dart';

import 'support/billing_fixtures.dart';

const _config = SubmitterConfig(submitterName: 'Clinic', submitterId: '123', isaSenderId: 'CLINIC', isaReceiverId: 'STEDI');

List<String> _segments(String x12) => x12.split('~').where((s) => s.isNotEmpty).toList();

const _snf = ServiceFacility(name: 'Bayview Care Center', line1: '12 Pine St', city: 'Oakland', state: 'CA', zip: '94607');

Future<void> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: SolisTheme.lightTheme(), home: home));
  await tester.pump(const Duration(milliseconds: 100));
}

PatientAccount _acct(String n, {List<Visit> visits = const [], String? phone, DateTime? dob, InsuranceCoverage? ins, PatientSex sex = PatientSex.unknown}) =>
    PatientAccount(accountNumber: n, firstName: 'Jane', lastName: 'Doe', createdAtUtc: DateTime.utc(2026), visits: visits, phone: phone, dateOfBirth: dob, insurance: ins, sex: sex);

Visit _v(int n, {VisitStatus status = VisitStatus.signed}) => Visit(number: n, dateOfService: '2026-10-0$n', placeOfService: '11', createdAtUtc: DateTime.utc(2026, 10, n), status: status);

void main() {
  group('service facility (2310C)', () {
    test('address text is read into parts', () {
      final f = ServiceFacility.parse('SNF', '450 Mission Bay Blvd, Suite 2, San Francisco, CA 94158, USA')!;
      expect(f.line1, '450 Mission Bay Blvd, Suite 2');
      expect(f.city, 'San Francisco');
      expect(f.state, 'CA');
      expect(f.zip, '94158');
      expect(ServiceFacility.parse('SNF', 'Somewhere'), isNull);
      expect(ServiceFacility.parse('SNF', null), isNull);
      expect(Visit.fromJson(_v(1).copyWith(serviceFacility: _snf).toJson()).serviceFacility!.oneLine, '12 Pine St, Oakland, CA 94607');
    });

    Future<(X12BuildResult, Map<String, dynamic>)> build(String pos, ServiceFacility? f) async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final v = (await visitWith(repo, a, pos: pos)).copyWith(serviceFacility: f);
      return (
        Claim837PGenerator.build(claim: v.claim!, account: a, visit: v, provider: repo.provider, config: _config, now: DateTime(2026, 10, 16, 9)),
        ClaimBuilder.build(account: a, visit: v, provider: repo.provider, claim: v.claim!, issues: const []),
      );
    }

    test('sent after 2310B and before the service lines; box 32 uses it', () async {
      final (r, json) = await build('31', _snf);
      expect(r.errors, isEmpty);
      final segs = _segments(r.x12!);
      final i = segs.indexOf('NM1*77*2*BAYVIEW CARE CENTER');
      expect(i, greaterThan(segs.indexWhere((s) => s.startsWith('HI*'))));
      expect(segs[i + 1], 'N3*12 PINE ST');
      expect(segs[i + 2], 'N4*OAKLAND*CA*94607');
      expect(i, lessThan(segs.indexWhere((s) => s.startsWith('LX*'))));
      expect(((json['provider'] as Map)['box32_serviceFacility'] as Map)['name'], 'Bayview Care Center');
    });

    test('not sent for home visits; an incomplete one is an error', () async {
      final (home, _) = await build('12', _snf);
      expect(_segments(home.x12!).any((s) => s.startsWith('NM1*77')), isFalse);
      final (bad, _) = await build('31', const ServiceFacility(name: 'X', line1: '', city: 'Oakland', state: 'CA', zip: '9'));
      expect(bad.errors.join(' '), contains('2310C'));
    });

    test('a saved place keeps an address it learns', () {
      const p = SavedPlace(id: 'p', name: 'SNF', placeOfService: '31', latitude: 1, longitude: 2);
      expect(p.copyWith(address: _snf.oneLine).address, _snf.oneLine);
      expect(p.copyWith(name: 'B').address, isNull);
    });
  });

  group('responsible party for minors', () {
    test('minors need one; it survives a save', () {
      final kid = _acct('SOL-1', dob: DateTime(2015, 3, 1));
      expect(kid.isMinorOn(DateTime(2026, 11, 6)), isTrue);
      expect(kid.needsGuarantor, isTrue);
      expect(_acct('SOL-2', dob: DateTime(1980)).needsGuarantor, isFalse);
      expect(_acct('SOL-3').needsGuarantor, isFalse, reason: 'unknown age is not assumed to be a minor');
      final withG = kid.copyWith(guarantor: const Guarantor(name: 'Ann Doe', relationship: 'guardian', phone: '555-0100'));
      final back = PatientAccount.fromJson(withG.toJson());
      expect(back.guarantor!.summary, 'Ann Doe (Legal guardian), 555-0100');
      expect(back.needsGuarantor, isFalse);
      expect(back.copyWith(clearGuarantor: true).guarantor, isNull);
    });

    testWidgets('the chart asks for one for a minor and records it', (tester) async {
      final repo = await realRepo();
      final a = await repo.createAccount(firstName: 'Tim', lastName: 'Doe', dateOfBirth: DateTime(2016, 5, 1), sex: PatientSex.male);
      await _pump(tester, PatientChartScreen(accountNumber: a.accountNumber));
      expect(find.text('Needed for a minor'), findsOneWidget);
      await tester.tap(find.byKey(const Key('guarantor_row')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('guarantor_save')));
      await tester.pump();
      expect(find.text('Enter their name'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('guarantor_name')), 'Ann Doe');
      await tester.tap(find.byKey(const Key('guarantor_save')));
      await tester.pumpAndSettle();
      expect(repo.byNumber(a.accountNumber)!.guarantor!.name, 'Ann Doe');
      expect(find.text('Ann Doe (Parent)'), findsOneWidget);
    });
  });

  group('merge two charts', () {
    test('kept details win, empty ones are filled, visits move with new numbers', () {
      final keep = _acct('SOL-1', visits: [_v(1), _v(2)], phone: '555-1');
      final dup = _acct('SOL-2',
          visits: [_v(2), _v(1)],
          phone: '555-2',
          dob: DateTime(1970, 1, 2),
          sex: PatientSex.female,
          ins: const InsuranceCoverage(payerName: 'Aetna', payerId: '60054', memberId: 'W1'));
      final plan = planMerge(keep, dup);
      expect(plan.blocked, isNull);
      expect(plan.merged.phone, '555-1');
      expect(plan.merged.dateOfBirth, DateTime(1970, 1, 2));
      expect(plan.merged.sex, PatientSex.female);
      expect(plan.merged.insurance!.memberId, 'W1');
      expect(plan.filled, containsAll(['date of birth', 'sex', 'insurance']));
      expect(plan.filled, isNot(contains('phone')));
      expect(plan.merged.visits.map((v) => v.number), [1, 2, 3, 4]);
      expect(plan.movedVisits, [(1, 3), (2, 4)]);
    });

    test('a chart with sent claims is never merged away', () {
      final plan = planMerge(_acct('SOL-1'), _acct('SOL-2', visits: [_v(1, status: VisitStatus.submitted)]));
      expect(plan.blocked, contains('already sent'));
      expect(planMerge(_acct('SOL-1'), _acct('SOL-1')).blocked, isNotNull);
    });

    test('the repository keeps one chart and soft-deletes the duplicate', () async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final b = await billablePatient(repo, first: 'Janet');
      await visitWith(repo, b);
      final plan = await repo.mergePatients(a.accountNumber, b.accountNumber);
      expect(plan.blocked, isNull);
      expect(repo.byNumber(a.accountNumber)!.visits, hasLength(1));
      expect(repo.byNumber(b.accountNumber), isNull, reason: 'soft-deleted charts are hidden');
      expect(repo.accounts.map((x) => x.accountNumber), isNot(contains(b.accountNumber)));
    });

    testWidgets('from the chart menu', (tester) async {
      final repo = await realRepo();
      final a = await billablePatient(repo);
      final b = await billablePatient(repo, first: 'Jane');
      await visitWith(repo, b);
      await _pump(tester, PatientChartScreen(accountNumber: a.accountNumber));
      await tester.tap(find.byKey(const Key('chart_menu')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Merge a duplicate chart'));
      await tester.pumpAndSettle();
      expect(find.textContaining('likely the same person'), findsOneWidget);
      await tester.tap(find.byKey(Key('merge_pick_${b.accountNumber}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('merge_confirm')));
      await tester.pumpAndSettle();
      expect(repo.byNumber(a.accountNumber)!.visits, hasLength(1));
      expect(repo.byNumber(b.accountNumber), isNull, reason: 'soft-deleted charts are hidden');
      expect(find.textContaining('1 visit moved'), findsOneWidget);
    });
  });

  group('pre-select the matching patient', () {
    final dob = DateTime(1970, 1, 2);
    PatientAccount m(String n, {String? id, DateTime? d}) => PatientAccount(
          accountNumber: n,
          firstName: 'Jane',
          lastName: 'Doe',
          createdAtUtc: DateTime.utc(2026),
          dateOfBirth: d,
          insurance: id == null ? null : InsuranceCoverage(payerName: 'Aetna', payerId: '1', memberId: id),
        );

    test('one clear match is chosen; anything unclear is left to the person', () {
      expect(strongMatch([m('A', id: 'W123456'), m('B', d: dob)], memberId: 'w-123456', dateOfBirth: dob)!.accountNumber, 'A');
      expect(strongMatch([m('A', d: dob), m('B')], dateOfBirth: dob)!.accountNumber, 'A');
      expect(strongMatch([m('A', d: dob), m('B', d: dob)], dateOfBirth: dob), isNull);
      expect(strongMatch([m('A')], dateOfBirth: null), isNull);
      expect(strongMatch([m('A', id: 'W123456'), m('B', id: 'W123456')], memberId: 'W123456', dateOfBirth: dob), isNull);
    });
  });
}

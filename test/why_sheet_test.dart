// The "Why" explanation of a claim check and the collapsible coding notes,
// rendered from the knowledge base.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/screens/claim_tab.dart';
import 'package:solis_mobile/services/codesets/codesets.dart';
import 'package:solis_mobile/services/codesets/reference_data.dart';
import 'package:solis_mobile/theme/solis_theme.dart';
import 'package:solis_mobile/widgets/knowledge_widgets.dart';
import 'support/test_provider.dart';

const _rules = 'OP-UNCERTAIN-01\tOutpatient: do not code uncertain diagnoses\twarning\tICD-10-CM Guidelines IV.H\t'
    'ICD-10-CM Guidelines IV.H\tDo not code diagnoses documented as probable, suspected or rule out; code the symptoms instead.\tIV.H\n'
    'CLAIM-DX-01\tAt least one and at most 12 diagnoses\terror\tCMS-1500 claim form, item 21\tCMS-1500 claim form, item 21\t'
    'Item 21 holds up to 12 ICD-10-CM codes.\t\n';
const _guidelines = 'IV.H\tH. Uncertain diagnosis\tDo not code diagnoses documented as "probable", "suspected".\\nRather, code the condition(s) to the highest degree of certainty.\n';

Widget _app(Widget child) => MaterialApp(theme: SolisTheme.lightTheme(), home: Scaffold(body: child));

void main() {
  tearDown(ReferenceData.clear);

  testWidgets('Why opens the rule, its citation and the guideline text', (t) async {
    ReferenceData.inject(knowledgeBase: KnowledgeBase.parse(rules: _rules, guidelines: _guidelines));
    const issue = ClaimIssue(IssueSeverity.info, 'Primary diagnosis is a symptom', 'You documented J18.9 with uncertain wording.',
        ruleId: 'OP-UNCERTAIN-01', citation: 'ICD-10-CM Guidelines IV.H');
    await t.pumpWidget(_app(const Center(child: WhyButton(issue: issue))));
    final size = t.getSize(find.byType(TextButton));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(size.width, greaterThanOrEqualTo(48));
    await t.tap(find.text('Why'));
    await t.pumpAndSettle();
    expect(find.text('Outpatient: do not code uncertain diagnoses'), findsOneWidget);
    expect(find.text('Rule OP-UNCERTAIN-01'), findsOneWidget);
    expect(find.textContaining('code the symptoms instead'), findsOneWidget);
    expect(find.text('ICD-10-CM Guidelines IV.H'), findsOneWidget);
    expect(find.text('Section IV.H  H. Uncertain diagnosis'), findsOneWidget);
    expect(find.textContaining('highest degree of certainty'), findsOneWidget);
    expect(find.textContaining('You documented J18.9'), findsOneWidget, reason: 'the claim-specific detail is kept');
  });

  testWidgets('Why still explains from the issue when the knowledge base is not loaded', (t) async {
    const issue = ClaimIssue(IssueSeverity.error, 'No diagnosis', 'Every claim needs at least one ICD-10-CM code in box 21.',
        ruleId: 'CLAIM-DX-01', citation: 'CMS-1500 claim form, item 21');
    await t.pumpWidget(_app(const Center(child: WhyButton(issue: issue))));
    await t.tap(find.text('Why'));
    await t.pumpAndSettle();
    expect(find.text('No diagnosis'), findsOneWidget);
    expect(find.text('CMS-1500 claim form, item 21'), findsOneWidget);
  });

  testWidgets('claim checks each get a Why button, and diagnoses show collapsible coding notes', (t) async {
    ReferenceData.inject(
      knowledgeBase: KnowledgeBase.parse(rules: _rules, guidelines: _guidelines),
      icdNotes: IcdNotes.parse('E11\tUA\tcode to identify control using:\t\nE11\tUA\tinsulin (Z79.4)\tZ79.4\n'
          'E11\tE1\ttype 1 diabetes mellitus (E10.-)\tE10.-\n'),
    );
    final visit = Visit(number: 1, dateOfService: '2026-10-15', placeOfService: '11', createdAtUtc: DateTime(2026));
    final claim = ClaimDraft(
      diagnoses: const [ClaimDiagnosis(code: 'E11.9', description: 'Type 2 diabetes mellitus without complications', source: DxSource.manual)],
      lines: const [ServiceLine(code: '99214', description: 'Office visit', charge: 120, diagnosisCodes: ['E11.9'])],
      generatedAtUtc: DateTime(2026),
    );
    final account = PatientAccount(
      accountNumber: 'SOL-1',
      firstName: 'Pat',
      lastName: 'Lee',
      sex: PatientSex.female,
      dateOfBirth: DateTime(1960),
      createdAtUtc: DateTime(2026),
      insurance: const InsuranceCoverage(payerName: 'Aetna', memberId: 'W1'),
      visits: [visit],
    );
    await t.pumpWidget(_app(ClaimTab(
      claim: claim,
      account: account,
      visit: visit,
      provider: testProvider(),
      noteSigned: false,
      claimReady: false,
      onClaimChanged: (_, {undoLabel}) {},
      onPlaceOfServiceChanged: (_) {},
    )));
    // The unsigned note is an error, so the checks come first; scroll down.
    await t.scrollUntilVisible(find.text('Coding notes (3)'), 300);
    expect(find.text('Coding notes (3)'), findsOneWidget);
    expect(find.text('insulin (Z79.4)'), findsNothing, reason: 'collapsed by default');
    await t.ensureVisible(find.text('Coding notes (3)'));
    await t.pump();
    await t.tap(find.text('Coding notes (3)'));
    await t.pump();
    await t.scrollUntilVisible(find.text('Use additional code'), 100);
    expect(find.text('Use additional code'), findsOneWidget);
    expect(find.textContaining('insulin (Z79.4)'), findsOneWidget);
    await t.scrollUntilVisible(find.text('Note not signed'), -300);
    expect(find.text('Why'), findsWidgets);
    final notSigned = find.ancestor(of: find.text('Note not signed'), matching: find.byType(Row)).first;
    expect(find.descendant(of: notSigned, matching: find.text('Why')), findsOneWidget);
  });
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/data/sample_conversations.dart';
import 'package:solis_mobile/models/clinical_models.dart';
import 'package:solis_mobile/models/note_style.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/models/provider_profile.dart';
import 'package:solis_mobile/screens/encounter_screen.dart';
import 'package:solis_mobile/services/account_repository.dart';
import 'package:solis_mobile/services/coding/clinical_coder.dart';
import 'package:solis_mobile/services/local_clinical_engine.dart';
import 'package:solis_mobile/services/note_formatter.dart';
import 'package:solis_mobile/theme/solis_theme.dart';

ClinicalEncounter _note(String talk, {CodingContext context = const CodingContext()}) =>
    LocalClinicalEngine.synthesizeOnDevice(rawSpeech: talk, patientName: 'P', mrn: '1', ageGender: '40F', attending: 'Dr', context: context);

const _psych = 'Doctor: How has your mood been since we last met?\n'
    'Patient: I have been feeling really down and hopeless for about three weeks.\n'
    'Doctor: How are you sleeping?\n'
    'Patient: I wake up at 4 every morning and cannot get back to sleep.\n'
    'Doctor: Any thoughts of suicide or of hurting yourself?\n'
    'Patient: No, never.\n'
    'Doctor: This sounds like major depressive disorder, single episode, moderate. We ruled out bipolar disorder last time. I will start sertraline 50 mg daily and follow up in 4 weeks.';

void main() {
  test('the style is remembered on the provider profile', () {
    const style = NoteStyle(template: NoteTemplate.psych, length: NoteLength.brief, abbreviations: AbbreviationMode.abbreviate);
    final p = ProviderProfile.demo().copyWith(noteStyle: style);
    final back = ProviderProfile.fromJson(p.toJson());
    expect(back.noteStyle, style);
    expect(back.noteStyle.summary, 'Psychiatry and therapy, brief, abbreviated');
    expect(ProviderProfile.demo().toJson().containsKey('noteStyle'), isFalse);
    expect(NoteStyle.fromJson({'template': 'nope'}), const NoteStyle());
  });

  test('length and abbreviations change the note', () {
    final e = _note(sampleConversations['Diabetic Peripheral Neuropathy']!);
    final standard = NoteFormatter.apply(e, const NoteStyle());
    expect(standard.subjective, e.subjective);
    final brief = NoteFormatter.apply(e, const NoteStyle(length: NoteLength.brief));
    expect(brief.subjective.length, lessThan(e.subjective.length));
    expect(brief.plan, e.plan, reason: 'plans are never trimmed');
    final detailed = NoteFormatter.apply(e, const NoteStyle(length: NoteLength.detailed));
    expect(detailed.subjective, contains("In the patient's words:"));

    final spelled = NoteFormatter.apply(e, const NoteStyle(abbreviations: AbbreviationMode.spellOut));
    expect(spelled.objective, contains('blood pressure 138/86'));
    final short = NoteFormatter.apply(e, const NoteStyle(abbreviations: AbbreviationMode.abbreviate));
    expect(short.plan, contains('BID'));
    expect(short.plan, contains('QHS'));
    expect(NoteFormatter.abbreviations('Follow up in 2 weeks.', abbreviate: true), 'F/u in 2 weeks.');
    expect(NoteFormatter.abbreviations('BP 120/80, f/u PRN.', abbreviate: false), 'blood pressure 120/80, follow up as needed.');
  });

  test('urgent care adds return precautions as said, or says they were not discussed', () {
    final e = _note(sampleConversations['Community-Acquired Pneumonia']!);
    final uc = NoteFormatter.apply(e, const NoteStyle(template: NoteTemplate.urgentCare));
    expect(uc.subjective, startsWith('Chief complaint: '));
    expect(uc.plan, contains('Return precautions: '));
    expect(uc.plan, contains('emergency room'));
    final none = NoteFormatter.apply(_note('Doctor: Your knee looks fine.\nPatient: Great, thanks.'), const NoteStyle(template: NoteTemplate.urgentCare));
    expect(none.plan, endsWith('Return precautions: not discussed.'));
  });

  test('psych quotes mood and sleep and reports safety as answered', () {
    final e = NoteFormatter.apply(_note(_psych), const NoteStyle(template: NoteTemplate.psych));
    expect(e.subjective, startsWith('Interval history: '));
    expect(e.objective, contains('Mood: "I have been feeling really down and hopeless for about three weeks."'));
    expect(e.objective, contains('Sleep: "'));
    expect(e.objective, contains('Appetite: not discussed'));
    expect(e.objective, contains('Suicidal ideation: asked; patient answered "No, never." (review)'));
    expect(e.objective, contains('Homicidal ideation: not discussed'));
  });

  test('a ruled-out diagnosis is never coded or written again', () {
    const talk = 'Doctor: Your headaches are a migraine without aura. I will start sumatriptan.';
    final first = _note(talk);
    expect(first.codes.map((c) => c.code), contains(startsWith('G43')));
    final code = first.codes.firstWhere((c) => c.code.startsWith('G43')).code;
    final again = _note(talk, context: CodingContext(ruledOut: {code}));
    expect(again.codes.map((c) => c.code), isNot(contains(code)));
    final psych = NoteFormatter.apply(again, const NoteStyle(template: NoteTemplate.psych), ruledOut: {code: 'Migraine'});
    expect(psych.assessment, contains('Ruled out (kept ruled out): $code Migraine'));
    final acct = PatientAccount.fromJson({
      ...PatientAccount(accountNumber: 'SOL-1', firstName: 'A', lastName: 'B', createdAtUtc: DateTime.utc(2026)).toJson(),
      'ruledOut': {code: 'Migraine'},
    });
    expect(acct.ruledOut, {code: 'Migraine'});
  });

  testWidgets('the note tab shows the style and saves a change', (tester) async {
    final repo = AccountRepository.memory();
    AccountRepository.instance = repo;
    await repo.seedDemoIfEmpty();
    final a = repo.accounts.firstWhere((a) => a.firstName == 'Margaret');
    final v = await repo.addVisit(a.accountNumber, dateOfService: DateTime(2026, 10, 15), placeOfService: '11');
    await repo.updateVisit(a.accountNumber, v.copyWith(transcript: sampleConversations['Diabetic Peripheral Neuropathy']));
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: SolisTheme.lightTheme(), home: EncounterScreen(accountNumber: a.accountNumber, visitNumber: v.number)));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Style: SOAP'), findsOneWidget);
    await tester.tap(find.byKey(const Key('note_style')));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('style_brief')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(repo.provider.noteStyle.length, NoteLength.brief);
    expect(find.byKey(const Key('rewrite_note')), findsOneWidget);
    await tester.tap(find.byKey(const Key('rewrite_note')));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Style: SOAP, brief'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  });
}

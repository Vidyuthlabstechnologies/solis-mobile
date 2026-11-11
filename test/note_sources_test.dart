import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/clinical_models.dart';
import 'package:solis_mobile/services/note_sources.dart';

void main() {
  const turns = [
    SpeakerTurn(speaker: 'Doctor', text: 'Good morning! How are you feeling today?'),
    SpeakerTurn(speaker: 'Patient', text: 'For the past couple of weeks my feet have this burning, pins and needles feeling at night.'),
    SpeakerTurn(speaker: 'Doctor', text: 'Nurse took your blood pressure, 138 over 86, pulse is 76.'),
    SpeakerTurn(speaker: 'Doctor', text: 'I want to start you on Gabapentin 300mg at bedtime, and follow up in 6 weeks.'),
  ];

  test('links each sentence to the turn it came from', () {
    final links = NoteSources.link(
      'Burning and pins and needles in both feet at night for two weeks. BP 138/86, HR 76. Start gabapentin 300 mg qhs.',
      turns,
    );
    expect(links, hasLength(3));
    expect(links[0].turnIndex, 1);
    expect(links[1].turnIndex, 2);
    expect(links[2].turnIndex, 3);
    expect(links.any((l) => l.unsupported), isFalse);
  });

  test('flags a sentence nobody said', () {
    final links = NoteSources.link('Gabapentin 300 mg at bedtime. Patient has a history of stroke with left sided weakness.', turns);
    expect(links[0].unsupported, isFalse);
    expect(links[1].unsupported, isTrue);
  });

  test('"Not discussed" and fragments need no source', () {
    final links = NoteSources.link('Not discussed.\nNone reported\nVitals:', turns);
    expect(links.every((l) => !l.needsSource), isTrue);
    expect(links.any((l) => l.unsupported), isFalse);
  });

  test('positions point back into the section text', () {
    const text = 'Feet burning at night.  Follow up in 6 weeks.';
    for (final l in NoteSources.link(text, turns)) {
      expect(text.substring(l.start, l.end), l.sentence);
    }
  });

  test('no transcript means nothing is flagged', () {
    expect(NoteSources.unsupportedCount(['History of stroke.'], const []), 0);
    expect(NoteSources.unsupportedCount(['History of stroke.', 'Feet burning at night.'], turns), 1);
  });
}

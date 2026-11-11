import '../models/clinical_models.dart';
import 'note_formatter.dart';

/// A plain-language after-visit summary for the patient, written only from
/// the signed note: what was found, what to do, medicines, and when to get
/// help. Codes, abbreviations and billing wording are left out.
class PatientSummary {
  PatientSummary._();

  static final _code = RegExp(r'\b[A-TV-Z]\d{2}\.\w{1,4}\b');
  static final _numbered = RegExp(r'^\s*\d+\.\s*');
  static final _dose = RegExp(r'\b\d+(\.\d+)?\s?(mg|mcg|g|units?|ml)\b', caseSensitive: false);
  static final _help = RegExp(r'emergency|\bER\b|911|come back|return|worse|call (us|the office)', caseSensitive: false);
  static final _billingOnly = RegExp(r'^(coded as|history of long term|no diagnosis stated|no plan documented)', caseSensitive: false);

  static List<String> _items(String section) => [
        for (final l in section.split('\n'))
          if (l.trim().isNotEmpty) NoteFormatter.abbreviations(l.replaceFirst(_numbered, '').replaceAll(_code, '').replaceAll(RegExp(r'\s{2,}'), ' ').trim(), abbreviate: false),
      ].where((l) => l.isNotEmpty && !_billingOnly.hasMatch(l)).toList();

  static String _sentence(String s) {
    final t = s.trim();
    if (t.isEmpty) return t;
    final first = '${t[0].toUpperCase()}${t.substring(1)}';
    return RegExp(r'[.!?]$').hasMatch(first) ? first : '$first.';
  }

  /// The summary text. [clinician] and [practice] sign it off.
  static String write({
    required ClinicalEncounter note,
    required String patientFirstName,
    required String dateOfService,
    required String clinician,
    String practice = '',
    String phone = '',
  }) {
    final found = _items(note.assessment);
    final plan = _items(note.plan);
    final medicines = plan.where((p) => _dose.hasMatch(p)).toList();
    final steps = plan.where((p) => !_dose.hasMatch(p) && !_help.hasMatch(p) && !p.toLowerCase().startsWith('return precautions')).toList();
    final help = [
      for (final p in plan)
        if (_help.hasMatch(p)) p.replaceFirst(RegExp(r'^return precautions:\s*', caseSensitive: false), ''),
    ].where((p) => !p.toLowerCase().contains('not discussed')).toList();

    String list(List<String> items) => items.map((i) => '- ${_sentence(i)}').join('\n');
    return [
      'Visit summary for $patientFirstName, $dateOfService',
      '',
      'What we found',
      found.isEmpty ? '- Talk with your clinician about today\'s findings.' : list(found),
      if (medicines.isNotEmpty) ...['', 'Your medicines', list(medicines)],
      if (steps.isNotEmpty) ...['', 'What to do next', list(steps)],
      '',
      'When to get help',
      help.isEmpty
          ? '- Call ${practice.isEmpty ? 'the office' : practice}${phone.isEmpty ? '' : ' at $phone'} if you get worse or have questions. For an emergency, call 911.'
          : '${list(help)}\n- For an emergency, call 911.',
      '',
      '$clinician${practice.isEmpty ? '' : ', $practice'}',
    ].join('\n');
  }
}

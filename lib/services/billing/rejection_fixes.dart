import '../../models/claim_models.dart';

/// Turns clearinghouse and payer rejection messages into the fix the
/// clinician can make in one tap: rescan the card, check the patient's
/// details, the provider profile, or the codes.
///
/// The messages are free text from the clearinghouse (277CA and 999 errors),
/// so this matches on the words they use. Messages it does not recognize get
/// no button; they are still shown as written.
class RejectionFixes {
  RejectionFixes._();

  /// Opens the Claim tab (not a [FixKind] of its own: the clinician picks
  /// the code there).
  static const reviewCodes = IssueFix(FixKind.editLine, 'Review the codes');

  static final List<(RegExp, IssueFix)> _rules = [
    (
      RegExp(r'subscriber|member|insured|policy|eligib|coverage|not found|not on file|identification number', caseSensitive: false),
      const IssueFix(FixKind.scanCard, 'Rescan the insurance card'),
    ),
    (
      RegExp(r'birth|\bdob\b|gender|\bsex\b|patient name|last name|first name', caseSensitive: false),
      const IssueFix(FixKind.editPatient, 'Check name and birth date', field: 'demographics'),
    ),
    (
      RegExp(r'\bnpi\b|taxonomy|tax id|\btin\b|\bein\b|billing provider|rendering provider|provider not', caseSensitive: false),
      const IssueFix(FixKind.editProvider, 'Check NPI and tax ID'),
    ),
    (
      RegExp(r'payer id|payor id|payer name|wrong payer|invalid payer', caseSensitive: false),
      const IssueFix(FixKind.editPatient, 'Check the payer', field: 'payer'),
    ),
    (
      RegExp(r'diagnosis|\bicd|procedure|\bcpt|hcpcs|modifier|place of service|\bpos\b|invalid code|code .*invalid|units', caseSensitive: false),
      reviewCodes,
    ),
  ];

  /// One fix per kind, in the order the messages name them.
  static List<IssueFix> forMessages(Iterable<String> messages) {
    final out = <IssueFix>[];
    for (final m in messages) {
      for (final (pattern, fix) in _rules) {
        if (pattern.hasMatch(m) && !out.any((f) => f.kind == fix.kind && f.field == fix.field)) out.add(fix);
      }
    }
    return out;
  }
}

import '../models/patient_account.dart';

/// What SOLIS did over a period: notes signed, claims sent and the amount
/// billed on them, and an estimate of documentation time saved.
class ValueTotals {
  final int notesSigned;
  final int claimsSent;
  final double billed;

  const ValueTotals({this.notesSigned = 0, this.claimsSent = 0, this.billed = 0});

  /// Estimated documentation minutes saved per signed note. Shown as an
  /// estimate wherever it appears.
  static const minutesPerNote = 15;

  int get minutesSaved => notesSigned * minutesPerNote;

  bool get isEmpty => notesSigned == 0 && claimsSent == 0;

  /// "2 h 15 min" or "45 min".
  String get timeSavedLabel {
    final m = minutesSaved;
    return m >= 60 ? '${m ~/ 60} h${m % 60 == 0 ? '' : ' ${m % 60} min'}' : '$m min';
  }
}

class ValueReport {
  final ValueTotals today;
  final ValueTotals week;

  const ValueReport(this.today, this.week);

  /// Today (local day of [now]) and the last 7 days including today.
  static ValueReport compute(List<PatientAccount> accounts, {DateTime? now}) {
    final n = (now ?? DateTime.now()).toLocal();
    final startToday = DateTime(n.year, n.month, n.day);
    final startWeek = startToday.subtract(const Duration(days: 6));
    var notesDay = 0, notesWeek = 0, sentDay = 0, sentWeek = 0;
    var billedDay = 0.0, billedWeek = 0.0;
    const sentStatuses = {VisitStatus.submitted, VisitStatus.paid, VisitStatus.denied};
    for (final a in accounts) {
      for (final v in a.visits) {
        final signed = DateTime.tryParse('${v.encounter?['signedAtUtc'] ?? ''}')?.toLocal();
        if (signed != null && !signed.isBefore(startWeek) && !signed.isAfter(n)) {
          notesWeek++;
          if (!signed.isBefore(startToday)) notesDay++;
        }
        final sent = DateTime.tryParse('${v.submission?['submittedAtUtc'] ?? ''}')?.toLocal();
        if (sent != null && sentStatuses.contains(v.status) && !sent.isBefore(startWeek) && !sent.isAfter(n)) {
          final total = v.claim?.totalCharge ?? 0;
          sentWeek++;
          billedWeek += total;
          if (!sent.isBefore(startToday)) {
            sentDay++;
            billedDay += total;
          }
        }
      }
    }
    return ValueReport(
      ValueTotals(notesSigned: notesDay, claimsSent: sentDay, billed: billedDay),
      ValueTotals(notesSigned: notesWeek, claimsSent: sentWeek, billed: billedWeek),
    );
  }
}

/// "$1,234" for whole dollars over a thousand, "$95.50" otherwise.
String formatDollars(double v) {
  final fixed = v.toStringAsFixed(v >= 1000 ? 0 : 2);
  final parts = fixed.split('.');
  final whole = parts.first.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  return '\$${parts.length > 1 ? '$whole.${parts[1]}' : whole}';
}

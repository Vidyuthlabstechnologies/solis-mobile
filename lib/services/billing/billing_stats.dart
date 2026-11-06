import '../../models/patient_account.dart';
import 'billing_queue.dart';

/// Accounts receivable aging: charges the payer still owes an answer on,
/// by days since the date of service. Sent, queued, rejected and denied
/// claims count; paid claims and claims not sent yet do not.
class ArAging {
  /// Totals for 0-30, 31-60, 61-90 and over 90 days.
  final List<double> buckets;
  final List<int> counts;
  const ArAging(this.buckets, this.counts);

  static const labels = ['0-30', '31-60', '61-90', '90+'];

  double get total => buckets.fold(0, (a, b) => a + b);
  int get count => counts.fold(0, (a, b) => a + b);
}

const _outstanding = {VisitStatus.queued, VisitStatus.submitted, VisitStatus.rejected, VisitStatus.denied};

int _bucketFor(int days) => days <= 30 ? 0 : days <= 60 ? 1 : days <= 90 ? 2 : 3;

ArAging arAging(Iterable<PatientAccount> accounts, {required DateTime today}) {
  final sums = [0.0, 0.0, 0.0, 0.0];
  final counts = [0, 0, 0, 0];
  final day = DateTime(today.year, today.month, today.day);
  for (final a in accounts) {
    for (final v in a.visits) {
      if (!_outstanding.contains(v.status) || v.claim == null) continue;
      final dos = DateTime.tryParse(v.dateOfService);
      if (dos == null) continue;
      final i = _bucketFor(day.difference(DateTime(dos.year, dos.month, dos.day)).inDays.clamp(0, 100000));
      sums[i] += v.claim!.totalCharge;
      counts[i]++;
    }
  }
  return ArAging(sums, counts);
}

/// Billed and paid amounts for one calendar month of service dates.
class MonthTotals {
  final double billed;
  final double paid;
  final int claims;
  const MonthTotals(this.billed, this.paid, this.claims);
}

/// What was billed (sent at least once) and what payers paid for visits
/// with a date of service in [month]'s calendar month.
MonthTotals monthTotals(Iterable<PatientAccount> accounts, {required DateTime month}) {
  final prefix = '${month.year.toString().padLeft(4, '0')}-${month.month.toString().padLeft(2, '0')}-';
  var billed = 0.0, paid = 0.0, n = 0;
  const sent = {VisitStatus.submitted, VisitStatus.paid, VisitStatus.denied, VisitStatus.rejected};
  for (final a in accounts) {
    for (final v in a.visits) {
      if (!v.dateOfService.startsWith(prefix) || v.claim == null || !sent.contains(v.status)) continue;
      billed += v.claim!.totalCharge;
      n++;
      if (v.status == VisitStatus.paid) paid += double.tryParse('${v.submission?['paidAmount'] ?? ''}') ?? 0;
    }
  }
  return MonthTotals(billed, paid, n);
}

/// What is left for the day: notes to sign, claims to fix, claims ready to
/// send, all dates. Shown at the top of Today.
class DaySummary {
  final int unsigned;
  final int needsFixes;
  final int readyToSend;
  const DaySummary(this.unsigned, this.needsFixes, this.readyToSend);

  bool get clear => unsigned == 0 && needsFixes == 0 && readyToSend == 0;
}

DaySummary daySummary(List<BillingItem> items) => DaySummary(
      items.where((i) => i.bucket == BillingBucket.needsSignature).length,
      items.where((i) => i.bucket == BillingBucket.needsFixes).length,
      items.where((i) => i.bucket == BillingBucket.readyToSend).length,
    );

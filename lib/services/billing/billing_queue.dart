import '../../models/claim_models.dart';
import '../../models/patient_account.dart';
import '../../models/provider_profile.dart';
import '../coding/claim_scrubber.dart';

/// Where a visit stands in the end-of-day billing work, in the order the
/// Billing tab lists them.
enum BillingBucket { needsSignature, needsFixes, readyToSend, queued, awaitingPayer, rejected, denied, paidThisWeek }

String billingBucketLabel(BillingBucket b) => switch (b) {
      BillingBucket.needsSignature => 'Needs signature',
      BillingBucket.needsFixes => 'Needs fixes',
      BillingBucket.readyToSend => 'Ready to send',
      BillingBucket.queued => 'Waiting for a connection',
      BillingBucket.awaitingPayer => 'Sent, awaiting payer',
      BillingBucket.rejected => 'Rejected',
      BillingBucket.denied => 'Denied',
      BillingBucket.paidThisWeek => 'Paid this week',
    };

class BillingItem {
  final PatientAccount account;
  final Visit visit;
  final BillingBucket bucket;

  /// Claim check errors (Needs fixes) or warnings to review (Ready to send).
  final int errors;
  final int warnings;

  const BillingItem(this.account, this.visit, this.bucket, {this.errors = 0, this.warnings = 0});

  String get claimId => '${account.accountNumber}-V${visit.number}';
  double get total => visit.claim?.totalCharge ?? 0;
}

/// Sorts every visit of [accounts] into billing buckets. Visits without a
/// note yet are not billing work and are left out. Pure, so the queue can
/// be tested without a screen.
List<BillingItem> classifyVisits(
  List<PatientAccount> accounts,
  ProviderProfile provider, {
  bool demoMode = false,
  DateTime? now,
}) {
  final today = (now ?? DateTime.now()).toUtc();
  final items = <BillingItem>[];
  for (final a in accounts) {
    for (final v in a.visits) {
      switch (v.status) {
        case VisitStatus.inProgress:
          if (v.encounter != null) items.add(BillingItem(a, v, BillingBucket.needsSignature));
        case VisitStatus.signed:
        case VisitStatus.claimReady:
          final claim = v.claim;
          if (claim == null) {
            items.add(BillingItem(a, v, BillingBucket.needsFixes, errors: 1));
            continue;
          }
          final issues = ClaimScrubber.check(claim: claim, account: a, visit: v, provider: provider, noteSigned: true, demoMode: demoMode);
          final errors = issues.where((i) => i.severity == IssueSeverity.error).length;
          final warnings = issues.where((i) => i.severity == IssueSeverity.warning).length;
          items.add(BillingItem(a, v, errors > 0 ? BillingBucket.needsFixes : BillingBucket.readyToSend, errors: errors, warnings: warnings));
        case VisitStatus.queued:
          items.add(BillingItem(a, v, BillingBucket.queued));
        case VisitStatus.submitted:
          items.add(BillingItem(a, v, BillingBucket.awaitingPayer));
        case VisitStatus.rejected:
          items.add(BillingItem(a, v, BillingBucket.rejected));
        case VisitStatus.denied:
          items.add(BillingItem(a, v, BillingBucket.denied));
        case VisitStatus.paid:
          final paidAt = DateTime.tryParse(v.submission?['paidAtUtc']?.toString() ?? v.submission?['statusCheckedAtUtc']?.toString() ?? '');
          if (paidAt != null && today.difference(paidAt) <= const Duration(days: 7)) {
            items.add(BillingItem(a, v, BillingBucket.paidThisWeek));
          }
      }
    }
  }
  items.sort((x, y) {
    final b = x.bucket.index.compareTo(y.bucket.index);
    if (b != 0) return b;
    // Rejections and denials are a work queue: oldest first, nearest its
    // filing or appeal limit. Everything else: newest first.
    if (x.bucket == BillingBucket.rejected || x.bucket == BillingBucket.denied) {
      return x.visit.dateOfService.compareTo(y.visit.dateOfService);
    }
    return y.visit.dateOfService.compareTo(x.visit.dateOfService);
  });
  return items;
}

/// Ready claims that can go out in one batch: no errors and no warnings.
/// A claim with warnings needs its own review first.
List<BillingItem> batchSendable(List<BillingItem> items) =>
    items.where((i) => i.bucket == BillingBucket.readyToSend && i.warnings == 0).toList();

/// Visits on [day] (today by default), unfinished work first.
List<(PatientAccount, Visit)> visitsOn(List<PatientAccount> accounts, {DateTime? day}) {
  final d = (day ?? DateTime.now()).toIso8601String().split('T').first;
  final out = <(PatientAccount, Visit)>[
    for (final a in accounts)
      for (final v in a.visits)
        if (v.dateOfService == d) (a, v),
  ];
  out.sort((x, y) {
    final s = x.$2.status.index.compareTo(y.$2.status.index);
    return s != 0 ? s : y.$2.createdAtUtc.compareTo(x.$2.createdAtUtc);
  });
  return out;
}

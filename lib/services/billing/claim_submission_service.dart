import 'package:intl/intl.dart';

import '../../models/claim_models.dart';
import '../../models/patient_account.dart';
import '../account_repository.dart';
import '../coding/claim_scrubber.dart';
import '../integrations.dart';
import 'claim_idempotency.dart';
import 'claim_status_codes.dart';
import 'clearinghouse.dart';
import 'integration_settings.dart';
import 'x12_837p.dart';

enum SendStatus {
  /// The clearinghouse took the claim.
  accepted,

  /// The clearinghouse or payer rejected it; see [SendResult.problems].
  rejected,

  /// No connection: the claim waits in the outbox and is retried with the
  /// same idempotency key, so it can never be billed twice.
  queued,

  /// Not sent and not queued (for example a bad key); see the problems.
  failed,

  /// Something on this phone stops the claim (errors, unsigned note,
  /// incomplete profile, no clearinghouse). Nothing was sent.
  blocked,
}

class SendResult {
  final SendStatus status;
  final List<String> problems;
  final bool testMode;

  const SendResult(this.status, {this.problems = const [], this.testMode = true});

  bool get sent => status == SendStatus.accepted;
}

/// What a claim status check found.
class StatusRefresh {
  final bool updated;
  final String message;
  final VisitStatus? status;

  const StatusRefresh(this.updated, this.message, {this.status});
}

/// Sends claims, keeps the offline outbox and refreshes claim status. Used
/// by the visit screen, the Billing queue's batch send and pull to refresh,
/// so every path uses the same checks and the same idempotency key.
class ClaimSubmissionService {
  final AccountRepository _repo;
  final ClearinghouseClient? Function() _client;
  final IntegrationSettings Function() _settings;
  final DateTime Function() _now;

  ClaimSubmissionService({
    AccountRepository? repo,
    ClearinghouseClient? Function()? client,
    IntegrationSettings Function()? settings,
    DateTime Function()? now,
  })  : _repo = repo ?? AccountRepository.instance,
        _client = client ?? Integrations.clearinghouse,
        _settings = settings ?? (() => Integrations.settings),
        _now = now ?? DateTime.now;

  bool get isConnected => _client() != null;

  /// True when claims would go to the test clearinghouse.
  bool get isTest => _settings().submitterConfig?.isTest ?? true;

  /// Reasons on this phone that stop the claim. Empty when it can be sent.
  List<String> blockers(PatientAccount account, Visit visit) {
    final provider = _repo.provider;
    final claim = visit.claim;
    return [
      if (claim == null) 'No claim has been built for this visit.',
      if (visit.status == VisitStatus.inProgress) 'Sign the note first.',
      if (claim != null && !visit.codesConfirmedFor(claim)) codesNotConfirmed,
      if (!provider.isComplete) 'Complete your provider profile: ${provider.missingForClaims.join(', ')}.',
      if (!_repo.demoMode && provider.isDemoIdentity) 'The provider profile has the demo NPI or tax ID.',
      if (claim != null)
        for (final i in ClaimScrubber.check(
          claim: claim,
          account: account,
          visit: visit,
          provider: provider,
          noteSigned: visit.status != VisitStatus.inProgress,
          demoMode: _repo.demoMode,
        ))
          if (i.severity == IssueSeverity.error) i.title,
    ];
  }

  /// The blocker shown until the clinician confirms the current codes.
  static const codesNotConfirmed = 'Confirm the E/M level and codes before sending.';

  /// Sends one signed visit's claim. Unreachable clearinghouse: the claim is
  /// queued with its file and key and sent later by [retryQueued].
  Future<SendResult> send(String accountNumber, int visitNumber) async {
    final account = _repo.byNumber(accountNumber);
    final visit = account?.visit(visitNumber);
    if (account == null || visit == null) return const SendResult(SendStatus.blocked, problems: ['The visit no longer exists.']);
    if (visit.status == VisitStatus.submitted || visit.status == VisitStatus.paid || visit.status == VisitStatus.denied) {
      return const SendResult(SendStatus.blocked, problems: ['This claim was already sent.']);
    }
    if (visit.status == VisitStatus.queued) return retry(accountNumber, visitNumber);
    final pending = _pendingReplacement(visit);
    if (visit.status == VisitStatus.rejected && pending != null) return sendReplacement(accountNumber, visitNumber, pending);
    final blocked = blockers(account, visit);
    if (blocked.isNotEmpty) return SendResult(SendStatus.blocked, problems: blocked);
    final client = _client();
    if (client == null) return const SendResult(SendStatus.blocked, problems: ['No clearinghouse is connected.']);
    final config = await _settings().submitterConfigForNextClaim();
    if (config == null) return const SendResult(SendStatus.blocked, problems: ['Add your submitter details in Integrations before sending claims.']);
    final built = Claim837PGenerator.build(claim: visit.claim!, account: account, visit: visit, provider: _repo.provider, config: config);
    if (!built.ok) return SendResult(SendStatus.blocked, problems: built.errors);
    // Same claim, same key: a retry after a lost response is not a second claim.
    final key = claimIdempotencyKey(built.x12!, built.patientControlNumber);
    return _submit(accountNumber, visitNumber, x12: built.x12!, key: key, pcn: built.patientControlNumber, test: config.isTest, attempts: 1);
  }

  /// Whether [visit]'s sent claim can be corrected (frequency 7) or voided
  /// (frequency 8): the payer adjudicated or received it and gave it a
  /// claim number to refer to.
  static bool canReplace(Visit visit) {
    if (visit.claim == null) return false;
    const sent = {VisitStatus.submitted, VisitStatus.paid, VisitStatus.denied};
    if (sent.contains(visit.status)) return (_originalClaimNumber(visit) ?? '').isNotEmpty;
    // A corrected or void claim that was rejected can be fixed and sent again.
    return visit.status == VisitStatus.rejected && _pendingReplacement(visit) != null;
  }

  /// The payer claim number a corrected or void claim refers to.
  static String? _originalClaimNumber(Visit visit) {
    final s = visit.submission;
    final v = (s?['payerClaimNumber'] ?? s?['replacesPayerClaimNumber'])?.toString().trim();
    return v == null || v.isEmpty ? null : v;
  }

  /// The frequency of a corrected or void claim that was rejected, so a
  /// resend stays a correction and never becomes a second original claim.
  static ClaimFrequency? _pendingReplacement(Visit visit) {
    final s = visit.submission;
    if (s?['replacesPayerClaimNumber'] == null) return null;
    final code = s?['frequency']?.toString();
    for (final f in ClaimFrequency.values) {
      if (f.code == code && f != ClaimFrequency.original) return f;
    }
    return null;
  }

  /// Sends a corrected ([ClaimFrequency.replacement]) or void
  /// ([ClaimFrequency.voided]) claim for a claim the payer already has,
  /// naming the payer's claim number in REF*F8. The current claim on the
  /// visit is what is sent; the original claim number is kept.
  Future<SendResult> sendReplacement(String accountNumber, int visitNumber, ClaimFrequency frequency) async {
    final account = _repo.byNumber(accountNumber);
    final visit = account?.visit(visitNumber);
    if (account == null || visit == null) return const SendResult(SendStatus.blocked, problems: ['The visit no longer exists.']);
    if (frequency == ClaimFrequency.original) return send(accountNumber, visitNumber);
    if (!canReplace(visit)) {
      return const SendResult(SendStatus.blocked, problems: ['Only a sent claim with a payer claim number can be corrected or voided. Check the claim status first.']);
    }
    final blocked = blockers(account, visit);
    if (blocked.isNotEmpty) return SendResult(SendStatus.blocked, problems: blocked);
    final client = _client();
    if (client == null) return const SendResult(SendStatus.blocked, problems: ['No clearinghouse is connected.']);
    final config = await _settings().submitterConfigForNextClaim();
    if (config == null) return const SendResult(SendStatus.blocked, problems: ['Add your submitter details in Integrations before sending claims.']);
    final icn = _originalClaimNumber(visit)!;
    final built = Claim837PGenerator.build(
      claim: visit.claim!,
      account: account,
      visit: visit,
      provider: _repo.provider,
      config: config,
      frequency: frequency,
      payerClaimControlNumber: icn,
    );
    if (!built.ok) return SendResult(SendStatus.blocked, problems: built.errors);
    final key = claimIdempotencyKey(built.x12!, built.patientControlNumber);
    return _submit(accountNumber, visitNumber,
        x12: built.x12!,
        key: key,
        pcn: built.patientControlNumber,
        test: config.isTest,
        attempts: 1,
        extra: {'frequency': frequency.code, 'replacesPayerClaimNumber': icn, 'previousStatus': visit.status.name});
  }

  /// Sends a queued claim again with its stored file and key.
  Future<SendResult> retry(String accountNumber, int visitNumber) async {
    final visit = _repo.byNumber(accountNumber)?.visit(visitNumber);
    final s = visit?.submission;
    if (visit == null || visit.status != VisitStatus.queued || s == null || s['x12'] == null) {
      return const SendResult(SendStatus.blocked, problems: ['Nothing is queued for this visit.']);
    }
    if (_client() == null) return const SendResult(SendStatus.queued, problems: ['No clearinghouse is connected.']);
    return _submit(
      accountNumber,
      visitNumber,
      x12: s['x12'] as String,
      key: s['idempotencyKey'] as String,
      pcn: s['patientControlNumber'] as String,
      test: s['testMode'] != false,
      attempts: ((s['attempts'] as num?)?.toInt() ?? 1) + 1,
      extra: {
        for (final k in const ['frequency', 'replacesPayerClaimNumber', 'previousStatus'])
          if (s[k] != null) k: s[k],
      },
    );
  }

  /// Sends every queued claim. Returns how many left the outbox.
  Future<int> retryQueued() async {
    if (_client() == null) return 0;
    var sent = 0;
    for (final a in _repo.accounts) {
      for (final v in a.visits) {
        if (v.status != VisitStatus.queued) continue;
        final r = await retry(a.accountNumber, v.number);
        if (r.status != SendStatus.queued) sent++;
      }
    }
    return sent;
  }

  Future<SendResult> _submit(String accountNumber, int visitNumber,
      {required String x12,
      required String key,
      required String pcn,
      required bool test,
      required int attempts,
      Map<String, dynamic> extra = const {}}) async {
    final client = _client()!;
    ClaimSubmissionResult res;
    try {
      res = await client.submitClaim(x12, idempotencyKey: key);
    } catch (e) {
      res = ClaimSubmissionResult(
        outcome: SubmissionOutcome.failed,
        httpStatus: 0,
        rawResponse: '',
        errors: [ClearinghouseError(description: 'Could not reach the clearinghouse (${e.runtimeType})')],
      );
    }
    final latest = _repo.byNumber(accountNumber)?.visit(visitNumber);
    if (latest == null) return const SendResult(SendStatus.failed, problems: ['The visit was removed while sending.']);
    final nowIso = _now().toUtc().toIso8601String();
    final errors = res.errors.map((e) => e.description).toList();

    if (res.outcome == SubmissionOutcome.failed && isRetryable(res)) {
      await _repo.updateVisit(
        accountNumber,
        latest.copyWith(status: VisitStatus.queued, submission: {
          'queued': true,
          'queuedAtUtc': latest.submission?['queuedAtUtc'] ?? nowIso,
          'lastAttemptUtc': nowIso,
          'attempts': attempts,
          'x12': x12,
          'idempotencyKey': key,
          'patientControlNumber': pcn,
          'testMode': test,
          'errors': errors,
          ...extra,
          'history': appendHistory(latest.submission, nowIso, '${_sendLabel(extra)} queued: no connection (attempt $attempts)'),
        }),
      );
      return SendResult(SendStatus.queued, problems: errors, testMode: test);
    }
    if (res.outcome == SubmissionOutcome.failed) {
      return SendResult(SendStatus.failed, problems: errors.isEmpty ? ['HTTP ${res.httpStatus}'] : errors, testMode: test);
    }
    final accepted = res.outcome == SubmissionOutcome.accepted;
    final audited = latest.withAudit(
      _repo.provider.displayName,
      accepted ? '${_sendLabel(extra)} sent' : '${_sendLabel(extra)} rejected',
      detail: [
        if (latest.claim != null) latest.claim!.codeSummary,
        if ((res.testMode ?? test)) 'test',
        if (!accepted && errors.isNotEmpty) errors.first,
      ].join('; '),
      atUtc: _now().toUtc(),
    );
    await _repo.updateVisit(
      accountNumber,
      audited.copyWith(
        status: accepted ? VisitStatus.submitted : VisitStatus.rejected,
        submission: {
          'submittedAtUtc': nowIso,
          'outcome': res.outcome.name,
          'status': res.status,
          'controlNumber': res.controlNumber,
          'correlationId': res.correlationId,
          'patientControlNumber': pcn,
          'idempotencyKey': key,
          'testMode': res.testMode ?? test,
          'attempts': attempts,
          'errors': errors,
          ...extra,
          'history': appendHistory(
            latest.submission,
            nowIso,
            accepted
                ? '${_sendLabel(extra)} accepted by the clearinghouse${(res.testMode ?? test) ? ' (test)' : ''}'
                : '${_sendLabel(extra)} rejected by the clearinghouse${errors.isEmpty ? '' : ': ${errors.first}'}',
          ),
        },
      ),
    );
    return SendResult(accepted ? SendStatus.accepted : SendStatus.rejected, problems: errors, testMode: res.testMode ?? test);
  }

  /// Most events kept in a claim's history.
  static const historyLimit = 30;

  /// The claim's history so far plus [event], newest last. Each entry is
  /// {atUtc, event}. Kept in the submission so it survives every update.
  static List<Map<String, dynamic>> appendHistory(Map<String, dynamic>? submission, String atUtc, String event) {
    final old = [
      for (final e in (submission?['history'] as List? ?? const []))
        if (e is Map) e.cast<String, dynamic>(),
    ];
    final all = [...old, {'atUtc': atUtc, 'event': event}];
    return all.length > historyLimit ? all.sublist(all.length - historyLimit) : all;
  }

  static String _sendLabel(Map<String, dynamic> extra) => switch (extra['frequency']) {
        '7' => 'Corrected claim',
        '8' => 'Void request',
        _ => 'Claim',
      };

  /// Unreachable, timed out, rate limited or a server error: worth sending
  /// again later. A missing key or a refused login is not.
  static bool isRetryable(ClaimSubmissionResult r) {
    if (r.outcome != SubmissionOutcome.failed) return false;
    if (r.httpStatus == 0) return !r.errors.any((e) => e.description.contains('No Stedi API key'));
    return r.httpStatus == 408 || r.httpStatus == 429 || r.httpStatus >= 500;
  }

  /// Asks the payer for one claim's status (276/277), matched by the claim's
  /// patient control number, and records paid, denied or rejected.
  Future<StatusRefresh> refreshStatus(String accountNumber, int visitNumber) async {
    final client = _client();
    final account = _repo.byNumber(accountNumber);
    final visit = account?.visit(visitNumber);
    final payerId = account?.insurance?.payerId;
    if (client == null || account == null || visit == null) return const StatusRefresh(false, 'No clearinghouse is connected.');
    if (payerId == null || payerId.isEmpty) return const StatusRefresh(false, 'The payer ID is missing.');
    final res = await client.claimStatus(ClaimStatusRequest(account: account, provider: _repo.provider, payerId: payerId, dateOfServiceFrom: visit.dateOfService));
    final checkedAt = _now().toUtc().toIso8601String();
    Future<void> touch() async {
      final latest = _repo.byNumber(accountNumber)?.visit(visitNumber);
      if (latest != null) await _repo.updateVisit(accountNumber, latest.copyWith(submission: {...?latest.submission, 'statusCheckedAtUtc': checkedAt}));
    }

    if (!res.success || res.claims.isEmpty) {
      await touch();
      return StatusRefresh(false, res.errors.isNotEmpty ? res.errors.first.description : 'The payer has no status for this claim yet.');
    }
    final c = matchClaim(res.claims, pcn: visit.submission?['patientControlNumber']?.toString(), dateOfService: visit.dateOfService);
    if (c == null) {
      await touch();
      return const StatusRefresh(false, 'The payer returned claims for this date, but none with this claim number.');
    }
    final latest = _repo.byNumber(accountNumber)!.visit(visitNumber)!;
    final explanation = describeClaimStatus(
      categoryCode: c.statusCategoryCode,
      statusCode: c.statusCode,
      payerText: c.statusDescription ?? c.statusCategory,
    );
    final status = c.paid
        ? VisitStatus.paid
        : c.denied
            ? VisitStatus.denied
            : c.rejected
                ? VisitStatus.rejected
                : latest.status;
    await _repo.updateVisit(
      accountNumber,
      latest.copyWith(status: status, submission: {
        ...?latest.submission,
        'lastStatus': c.statusDescription ?? c.statusCategory,
        'statusCategoryCode': c.statusCategoryCode,
        'statusCode': c.statusCode,
        'statusExplanation': explanation,
        'paidAmount': c.paidAmount,
        'payerClaimNumber': c.payerClaimNumber,
        'statusCheckedAtUtc': checkedAt,
        if (latest.submission?['statusExplanation'] != explanation)
          'history': appendHistory(latest.submission, checkedAt, 'Payer status: $explanation'),
        if (status == VisitStatus.paid) 'paidAtUtc': latest.submission?['paidAtUtc'] ?? checkedAt,
      }),
    );
    return StatusRefresh(true, 'Claim status: $explanation', status: status);
  }

  /// The 277 entry for this claim: the one whose patient account number is
  /// the claim's control number (CLM01). When the payer echoes no control
  /// numbers, a single claim for the date of service is accepted. Two
  /// visits on one date can never be confused.
  static ClaimStatusEntry? matchClaim(List<ClaimStatusEntry> claims, {String? pcn, required String dateOfService}) {
    String n(String? s) => (s ?? '').toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    if (pcn != null && pcn.isNotEmpty) {
      for (final c in claims) {
        if (n(c.patientAccountNumber) == n(pcn)) return c;
      }
    }
    if (claims.any((c) => (c.patientAccountNumber ?? '').isNotEmpty)) return null;
    final dos = dateOfService.replaceAll('-', '');
    final sameDay = claims.where((c) => c.serviceDate == null || c.serviceDate!.replaceAll('-', '') == dos).toList();
    return sameDay.length == 1 ? sameDay.single : null;
  }

  /// Checks every submitted claim whose last check is older than [minAge].
  /// Returns how many changed state.
  Future<int> refreshAll({Duration minAge = const Duration(hours: 1)}) async {
    if (_client() == null) return 0;
    var changed = 0;
    final now = _now().toUtc();
    for (final a in _repo.accounts) {
      for (final v in a.visits) {
        if (v.status != VisitStatus.submitted) continue;
        final last = DateTime.tryParse(v.submission?['statusCheckedAtUtc']?.toString() ?? '');
        if (last != null && now.difference(last) < minAge) continue;
        try {
          final r = await refreshStatus(a.accountNumber, v.number);
          if (r.updated && r.status != VisitStatus.submitted) changed++;
        } catch (_) {
          // Offline: try again on the next refresh.
        }
      }
    }
    return changed;
  }
}

/// The newest [limit] events of a claim's history, newest first, as
/// "Nov 6, 2:05 PM  Claim accepted by the clearinghouse" in local time.
List<String> claimHistoryLines(Map<String, dynamic>? submission, {int limit = 5}) {
  final events = [
    for (final e in (submission?['history'] as List? ?? const []))
      if (e is Map && e['event'] != null) e,
  ];
  final f = DateFormat('MMM d, h:mm a');
  return [
    for (final e in events.reversed.take(limit))
      '${DateTime.tryParse('${e['atUtc']}') == null ? '' : '${f.format(DateTime.parse('${e['atUtc']}').toLocal())}  '}${e['event']}',
  ];
}

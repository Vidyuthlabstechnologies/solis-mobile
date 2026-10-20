import 'package:solis_mobile/services/billing/clearinghouse.dart';

/// A clearinghouse with scripted answers. Records every claim and key sent.
class FakeClearinghouse implements ClearinghouseClient {
  final List<(String x12, String? key)> submitted = [];
  final List<ClaimStatusRequest> statusRequests = [];
  final List<EligibilityRequest> eligibilityRequests = [];

  /// Next submission answers, in order; the last one repeats.
  List<ClaimSubmissionResult> submitAnswers = [accepted()];
  ClaimStatusResult statusAnswer = const ClaimStatusResult(success: true, httpStatus: 200, rawResponse: '');
  EligibilityResult eligibilityAnswer = const EligibilityResult(success: true, httpStatus: 200, rawResponse: '', activeCoverage: true, copay: '25');
  bool throwOnSubmit = false;

  static ClaimSubmissionResult accepted() => const ClaimSubmissionResult(
        outcome: SubmissionOutcome.accepted,
        httpStatus: 200,
        rawResponse: '{}',
        status: 'SUCCESS',
        correlationId: 'corr-1',
        testMode: true,
      );

  static ClaimSubmissionResult offline() => const ClaimSubmissionResult(
        outcome: SubmissionOutcome.failed,
        httpStatus: 0,
        rawResponse: '',
        errors: [ClearinghouseError(description: 'Could not reach Stedi: SocketException')],
      );

  @override
  Future<ClaimSubmissionResult> submitClaim(String x12, {String? idempotencyKey}) async {
    if (throwOnSubmit) throw StateError('network down');
    submitted.add((x12, idempotencyKey));
    final i = submitted.length - 1;
    return submitAnswers[i < submitAnswers.length ? i : submitAnswers.length - 1];
  }

  @override
  Future<ClaimStatusResult> claimStatus(ClaimStatusRequest request) async {
    statusRequests.add(request);
    return statusAnswer;
  }

  @override
  Future<EligibilityResult> checkEligibility(EligibilityRequest request) async {
    eligibilityRequests.add(request);
    return eligibilityAnswer;
  }
}

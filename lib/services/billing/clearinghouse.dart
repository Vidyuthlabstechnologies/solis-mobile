import '../../models/patient_account.dart';
import '../../models/provider_profile.dart';

/// One error or rejection reason returned by a clearinghouse or payer.
class ClearinghouseError {
  final String? code;
  final String description;
  final String? followupAction;
  final String? location;

  const ClearinghouseError({this.code, required this.description, this.followupAction, this.location});

  @override
  String toString() => [
        if (code != null && code!.isNotEmpty) '[$code]',
        description,
        if (followupAction != null && followupAction!.isNotEmpty) '($followupAction)',
      ].join(' ');
}

enum SubmissionOutcome {
  /// The clearinghouse validated the claim and sent it on. Payer acceptance
  /// arrives later as a 277CA.
  accepted,

  /// The clearinghouse or payer rejected the claim; see the errors.
  rejected,

  /// Transport or authentication failure; nothing was submitted.
  failed,
}

class ClaimSubmissionResult {
  final SubmissionOutcome outcome;
  final int httpStatus;
  final String? status; // clearinghouse status string, e.g. SUCCESS
  final String? controlNumber;
  final String? correlationId; // clearinghouse claim reference, for 277CA matching
  final String? patientControlNumber;
  final String? payerName;
  final String? payerId;
  final bool? testMode;
  final List<ClearinghouseError> errors;
  final String rawResponse;

  const ClaimSubmissionResult({
    required this.outcome,
    required this.httpStatus,
    required this.rawResponse,
    this.status,
    this.controlNumber,
    this.correlationId,
    this.patientControlNumber,
    this.payerName,
    this.payerId,
    this.testMode,
    this.errors = const [],
  });

  bool get accepted => outcome == SubmissionOutcome.accepted;
}

/// Inputs for a 270 eligibility inquiry.
class EligibilityRequest {
  final PatientAccount account;
  final ProviderProfile provider;
  final String payerId;

  /// X12 service type codes; 30 is health benefit plan coverage.
  final List<String> serviceTypeCodes;

  /// yyyy-MM-dd; defaults to today at the payer.
  final String? dateOfService;

  const EligibilityRequest({
    required this.account,
    required this.provider,
    required this.payerId,
    this.serviceTypeCodes = const ['30'],
    this.dateOfService,
  });
}

/// Summary of a 271 eligibility response.
class EligibilityResult {
  final bool success;
  final int httpStatus;

  /// True for active coverage, false for inactive, null when the response did not say.
  final bool? activeCoverage;
  final String? planName;
  final String? groupNumber;

  /// Amounts as returned by the payer, in dollars, e.g. "25" or "1500.00".
  final String? copay;
  final String? coinsurancePercent;
  final String? deductibleRemaining;
  final String? outOfPocketRemaining;
  final bool? testMode;
  final List<ClearinghouseError> errors;
  final String rawResponse;

  const EligibilityResult({
    required this.success,
    required this.httpStatus,
    required this.rawResponse,
    this.activeCoverage,
    this.planName,
    this.groupNumber,
    this.copay,
    this.coinsurancePercent,
    this.deductibleRemaining,
    this.outOfPocketRemaining,
    this.testMode,
    this.errors = const [],
  });
}

/// Inputs for a 276 claim status inquiry.
class ClaimStatusRequest {
  final PatientAccount account;
  final ProviderProfile provider;
  final String payerId;
  final String dateOfServiceFrom; // yyyy-MM-dd
  final String? dateOfServiceTo; // yyyy-MM-dd

  const ClaimStatusRequest({
    required this.account,
    required this.provider,
    required this.payerId,
    required this.dateOfServiceFrom,
    this.dateOfServiceTo,
  });
}

/// One claim found by a 277 response.
class ClaimStatusEntry {
  final String? statusCategoryCode; // e.g. A1, A3, F1, F2
  final String? statusCategory;
  final String? statusCode;
  final String? statusDescription;
  final String? serviceDate;
  final String? submittedAmount;
  final String? paidAmount;
  final String? effectiveDate;
  final String? payerClaimNumber;
  final String? patientAccountNumber;

  const ClaimStatusEntry({
    this.statusCategoryCode,
    this.statusCategory,
    this.statusCode,
    this.statusDescription,
    this.serviceDate,
    this.submittedAmount,
    this.paidAmount,
    this.effectiveDate,
    this.payerClaimNumber,
    this.patientAccountNumber,
  });

  /// F categories are finalized (paid, denied, or forwarded).
  bool get finalized => (statusCategoryCode ?? '').startsWith('F');
  bool get paid => statusCategoryCode == 'F1';
  bool get denied => statusCategoryCode == 'F2';

  /// A3, A6, A7 and A8 mean the claim was returned or rejected before adjudication.
  bool get rejected => const {'A3', 'A6', 'A7', 'A8'}.contains(statusCategoryCode);
  bool get pending => (statusCategoryCode ?? '').startsWith('P');
}

class ClaimStatusResult {
  final bool success;
  final int httpStatus;
  final List<ClaimStatusEntry> claims;
  final List<ClearinghouseError> errors;
  final String rawResponse;

  const ClaimStatusResult({
    required this.success,
    required this.httpStatus,
    required this.rawResponse,
    this.claims = const [],
    this.errors = const [],
  });
}

/// A clearinghouse that takes 837P claims and answers 270 and 276 inquiries.
abstract class ClearinghouseClient {
  /// Sends one 837P interchange (as produced by Claim837PGenerator).
  /// [idempotencyKey] lets a retry avoid a duplicate submission.
  Future<ClaimSubmissionResult> submitClaim(String x12, {String? idempotencyKey});

  /// 270/271 real-time eligibility.
  Future<EligibilityResult> checkEligibility(EligibilityRequest request);

  /// 276/277 real-time claim status.
  Future<ClaimStatusResult> claimStatus(ClaimStatusRequest request);
}

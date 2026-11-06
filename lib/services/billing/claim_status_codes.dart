// Plain-language meaning of the codes a payer sends back about a claim:
//
// - 277 Claim Status Category Codes (X12 external code list 507), the
//   first element of STC01, which say where the claim is.
// - A few common 277 Claim Status Codes (code list 508), the second element,
//   which say what is wrong, with what to do.
// - Common Claim Adjustment Reason Codes (CARC, code list 139) with their
//   group code (CO, PR, OA, PI), as they appear on an 835 remittance or a
//   denial letter, with the likely fix.
//
// Wording is SOLIS's own summary for a clinician, not the official code
// text; the payer's own description is always shown next to it.

/// What a status or reason code means and what to do about it.
class CodeExplanation {
  final String code;
  final String meaning;
  final String? action;
  const CodeExplanation(this.code, this.meaning, [this.action]);

  @override
  String toString() => action == null ? meaning : '$meaning $action';
}

/// 277 Claim Status Category Codes (code list 507).
const Map<String, CodeExplanation> claimStatusCategories = {
  'A0': CodeExplanation('A0', 'The clearinghouse received the claim and passed it on to the payer.'),
  'A1': CodeExplanation('A1', 'The payer received the claim.'),
  'A2': CodeExplanation('A2', 'The payer accepted the claim for processing.'),
  'A3': CodeExplanation('A3', 'The payer returned the claim as unprocessable.', 'Fix the problem the payer names and send it again as a new claim.'),
  'A4': CodeExplanation('A4', 'The payer cannot find this claim.', 'Check the payer ID, member ID and date of service; send it again if it never arrived.'),
  'A5': CodeExplanation('A5', 'The payer split the claim into more than one claim.'),
  'A6': CodeExplanation('A6', 'Rejected: information is missing.', 'Add what the payer names and send it again.'),
  'A7': CodeExplanation('A7', 'Rejected: information is invalid.', 'Correct what the payer names and send it again.'),
  'A8': CodeExplanation('A8', 'Rejected: two fields on the claim contradict each other.', 'Correct the fields the payer names and send it again.'),
  'P0': CodeExplanation('P0', 'Pending: the payer is processing the claim.'),
  'P1': CodeExplanation('P1', 'Pending: in process.'),
  'P2': CodeExplanation('P2', 'Pending: under payer review.'),
  'P3': CodeExplanation('P3', 'Pending: the payer asked the practice for information.', 'Send the records or answers the payer asked for.'),
  'P4': CodeExplanation('P4', 'Pending: the payer asked the patient for information.', 'Ask the patient to answer the payer (often coordination of benefits).'),
  'P5': CodeExplanation('P5', 'Pending: on an administrative or system hold at the payer.'),
  'F0': CodeExplanation('F0', 'Finalized: the payer finished processing the claim.'),
  'F1': CodeExplanation('F1', 'Finalized: paid.'),
  'F2': CodeExplanation('F2', 'Finalized: denied.', 'Read the reason, then send a corrected claim or an appeal.'),
  'F3': CodeExplanation('F3', 'Finalized: the payer revised its earlier decision.'),
  'F3F': CodeExplanation('F3F', 'Finalized: forwarded to another payer.'),
  'F3N': CodeExplanation('F3N', 'Finalized: not forwarded to another payer.', 'Send the claim to the secondary payer yourself.'),
  'F4': CodeExplanation('F4', 'Finalized: processed with no payment coming (for example applied to the deductible).', 'Bill the patient for their share.'),
  'R0': CodeExplanation('R0', 'The payer is asking for more information.', 'Send what the payer asks for.'),
  'E0': CodeExplanation('E0', 'The status request itself had an error.', 'Check the patient and provider details and ask again.'),
  'E1': CodeExplanation('E1', 'The payer\'s system is unavailable.', 'Try again later.'),
  'E2': CodeExplanation('E2', 'The payer is not responding.', 'Try again later.'),
  'E3': CodeExplanation('E3', 'The status request needs a correction.', 'Check the patient and provider details and ask again.'),
  'E4': CodeExplanation('E4', 'The request does not meet the payer\'s trading partner requirements.'),
  'D0': CodeExplanation('D0', 'The payer found no claim matching this search.', 'Check the date of service and member ID.'),
};

/// Common 277 Claim Status Codes (code list 508) with what to do. Codes not
/// listed fall back to the payer's own description.
const Map<String, CodeExplanation> claimStatusCodes = {
  '19': CodeExplanation('19', 'The payer acknowledged receipt of the claim.'),
  '20': CodeExplanation('20', 'Accepted for processing.'),
  '21': CodeExplanation('21', 'Information is missing or invalid.', 'The payer names the field; correct it and send again.'),
  '33': CodeExplanation('33', 'The payer cannot find the subscriber or member ID.', 'Rescan the insurance card and check the member ID and name.'),
  '116': CodeExplanation('116', 'The claim was sent to the wrong payer.', 'Check the payer on the card and the payer ID.'),
  '158': CodeExplanation('158', 'The date of birth is the problem.', 'Check the patient\'s birth date against the card.'),
  '164': CodeExplanation('164', 'The member ID is the problem.', 'Rescan the card; for Medicare use the MBI.'),
  '187': CodeExplanation('187', 'The date of service is the problem.', 'Check the visit date.'),
  '306': CodeExplanation('306', 'A service needs a written description (unlisted or NOC code).', 'Describe the service on the line and send again.'),
  '562': CodeExplanation('562', 'The NPI is the problem.', 'Check the NPI in the provider profile and the payer enrollment.'),
};

/// Common Claim Adjustment Reason Codes (code list 139).
const Map<String, CodeExplanation> adjustmentReasonCodes = {
  '1': CodeExplanation('1', 'Applied to the patient\'s deductible.', 'Bill the patient.'),
  '2': CodeExplanation('2', 'Coinsurance: the patient\'s share.', 'Bill the patient.'),
  '3': CodeExplanation('3', 'Copay: the patient\'s share.', 'Collect the copay from the patient.'),
  '4': CodeExplanation('4', 'The modifier does not fit the procedure, or a required modifier is missing.', 'Fix the modifier and send a corrected claim.'),
  '11': CodeExplanation('11', 'The diagnosis does not support the procedure.', 'Check the diagnosis pointers and codes, then correct and resend.'),
  '16': CodeExplanation('16', 'The claim is missing information or has an error.', 'The remark code says which; correct it and resend.'),
  '18': CodeExplanation('18', 'Duplicate claim or service.', 'Do not resend. Check status of the original claim.'),
  '22': CodeExplanation('22', 'Another payer may be primary (coordination of benefits).', 'Ask the patient about other coverage and bill the primary payer first.'),
  '27': CodeExplanation('27', 'Coverage had ended before the date of service.', 'Check eligibility; bill the patient or the new plan.'),
  '29': CodeExplanation('29', 'The filing limit has passed.', 'Appeal only with proof the claim was sent on time.'),
  '31': CodeExplanation('31', 'The payer says this patient is not their member.', 'Rescan the card and check the member ID and name.'),
  '45': CodeExplanation('45', 'The charge is above the contracted rate.', 'No action: this is the contractual write-off.'),
  '50': CodeExplanation('50', 'The payer says the service was not medically necessary.', 'Appeal with the note if the record supports it.'),
  '96': CodeExplanation('96', 'Non-covered charge.', 'Check the patient\'s benefits; bill the patient if an ABN was signed.'),
  '97': CodeExplanation('97', 'This service is included in another service already paid.', 'Add a modifier only if it was truly separate (for example 25 or 59), otherwise write it off.'),
  '109': CodeExplanation('109', 'Not covered by this payer.', 'Send the claim to the correct payer.'),
  '167': CodeExplanation('167', 'The diagnosis is not covered.', 'Check the diagnosis codes and the payer\'s coverage policy.'),
  '170': CodeExplanation('170', 'Payment is denied for this type of provider.', 'Check the payer enrollment and taxonomy.'),
  '197': CodeExplanation('197', 'Prior authorization or precertification was missing.', 'Get the authorization number and send a corrected claim.'),
  '204': CodeExplanation('204', 'Not covered under the patient\'s current benefit plan.', 'Bill the patient if they agreed in advance.'),
};

/// Claim adjustment group codes on an 835.
const Map<String, String> adjustmentGroups = {
  'CO': 'Contractual: the practice cannot bill the patient for this.',
  'PR': 'Patient responsibility: bill the patient.',
  'OA': 'Other adjustment.',
  'PI': 'Payer-initiated reduction.',
  'CR': 'Correction or reversal of an earlier claim.',
};

/// The meaning of a 277 status category code (A1, F2, ...). Null when unknown.
CodeExplanation? explainStatusCategory(String? code) {
  final c = (code ?? '').trim().toUpperCase();
  if (c.isEmpty) return null;
  return claimStatusCategories[c] ?? (c.startsWith('R') ? claimStatusCategories['R0'] : null);
}

/// "CO-16", "PR 2", "16" to an explanation, with the group meaning first
/// when a group is given. Null when the reason code is not listed.
String? explainAdjustment(String raw) {
  final m = RegExp(r'^\s*([A-Za-z]{2})?\s*[-: ]?\s*([A-Za-z]?\d+)\s*$').firstMatch(raw);
  if (m == null) return null;
  final group = m.group(1)?.toUpperCase();
  final reason = adjustmentReasonCodes[m.group(2)!.toUpperCase()];
  if (reason == null) return null;
  final g = group == null ? null : adjustmentGroups[group];
  return [?g, reason.toString()].join(' ');
}

/// One line for a person: the category meaning, the status code's meaning
/// when SOLIS knows it, and the payer's own words when they add anything.
String describeClaimStatus({String? categoryCode, String? statusCode, String? payerText}) {
  final parts = <String>[];
  final cat = explainStatusCategory(categoryCode);
  if (cat != null) parts.add(cat.toString());
  final csc = claimStatusCodes[(statusCode ?? '').trim()];
  if (csc != null) parts.add(csc.toString());
  final payer = (payerText ?? '').trim();
  if (payer.isNotEmpty) parts.add('Payer says: "$payer".');
  return parts.isEmpty ? 'The payer sent a status SOLIS does not recognize.' : parts.join(' ');
}

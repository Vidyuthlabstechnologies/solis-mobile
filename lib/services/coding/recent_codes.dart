import '../../models/claim_models.dart';
import '../../models/patient_account.dart';

/// The clinician's most recently billed diagnoses, newest first, without
/// repeats: what code search offers before anything is typed. Read from the
/// visits on this phone, so nothing extra is stored. Sample patients are
/// left out outside demo mode.
List<(String code, String description)> recentDiagnoses(
  Iterable<PatientAccount> accounts, {
  int limit = 8,
  bool includeSamples = false,
  bool Function(String code)? isValid,
}) {
  final visits = <({String date, DateTime created, ClaimDraft claim})>[
    for (final a in accounts)
      if (includeSamples || !a.isSample)
        for (final v in a.visits)
          if (v.claim != null) (date: v.dateOfService, created: v.createdAtUtc, claim: v.claim!),
  ]..sort((x, y) {
      final byDate = y.date.compareTo(x.date);
      return byDate != 0 ? byDate : y.created.compareTo(x.created);
    });
  final seen = <String>{};
  final out = <(String, String)>[];
  for (final v in visits) {
    for (final d in v.claim.billable) {
      final key = d.code.toUpperCase();
      if (!seen.add(key)) continue;
      if (isValid != null && !isValid(d.code)) continue;
      out.add((d.code, d.description));
      if (out.length >= limit) return out;
    }
  }
  return out;
}

/// The clinician's most recently billed services (CPT/HCPCS), newest first.
List<String> recentServiceCodes(Iterable<PatientAccount> accounts, {int limit = 8, bool includeSamples = false}) {
  final visits = [
    for (final a in accounts)
      if (includeSamples || !a.isSample)
        for (final v in a.visits)
          if (v.claim != null) v,
  ]..sort((x, y) => y.dateOfService.compareTo(x.dateOfService));
  final out = <String>[];
  for (final v in visits) {
    for (final l in v.claim!.lines) {
      if (!out.contains(l.code)) out.add(l.code);
      if (out.length >= limit) return out;
    }
  }
  return out;
}

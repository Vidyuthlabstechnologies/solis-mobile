import '../models/patient_account.dart';

/// What merging two charts would do, or why it cannot.
class MergePlan {
  /// The kept chart after the merge.
  final PatientAccount merged;

  /// Details copied from the duplicate because the kept chart had none.
  final List<String> filled;

  /// Visits moved from the duplicate, as (old number, new number).
  final List<(int, int)> movedVisits;

  /// Why the merge is refused; null when it can go ahead.
  final String? blocked;

  const MergePlan({required this.merged, this.filled = const [], this.movedVisits = const [], this.blocked});
}

/// Statuses whose claim has reached a clearinghouse or payer. Their patient
/// control number (account and visit number) must not change, so a chart
/// holding one is never merged away.
const sentStatuses = {VisitStatus.queued, VisitStatus.submitted, VisitStatus.rejected, VisitStatus.paid, VisitStatus.denied};

/// Merges [duplicate] into [keep]: the kept chart's own details win, empty
/// ones are filled from the duplicate, and the duplicate's visits move
/// across with new numbers after the kept chart's last visit.
MergePlan planMerge(PatientAccount keep, PatientAccount duplicate) {
  if (keep.accountNumber == duplicate.accountNumber) {
    return MergePlan(merged: keep, blocked: 'Pick a different chart to merge.');
  }
  final sent = duplicate.visits.where((v) => sentStatuses.contains(v.status)).toList();
  if (sent.isNotEmpty) {
    return MergePlan(
      merged: keep,
      blocked: 'The chart ${duplicate.accountNumber} has ${sent.length} ${sent.length == 1 ? 'claim' : 'claims'} already sent under its account number. '
          'Keep that chart and merge this one into it instead.',
    );
  }
  final filled = <String>[];
  T? fill<T>(T? mine, T? theirs, String label) {
    if ((mine == null || (mine is String && mine.trim().isEmpty)) && theirs != null && !(theirs is String && theirs.trim().isEmpty)) {
      filled.add(label);
      return theirs;
    }
    return null;
  }

  var next = keep.visits.fold<int>(0, (m, v) => v.number > m ? v.number : m);
  final moved = <(int, int)>[];
  final visits = [
    ...keep.visits,
    for (final v in [...duplicate.visits]..sort((a, b) => a.number.compareTo(b.number)))
      () {
        next++;
        moved.add((v.number, next));
        return Visit.fromJson({...v.toJson(), 'number': next});
      }(),
  ];
  final sex = keep.sex == PatientSex.unknown && duplicate.sex != PatientSex.unknown ? duplicate.sex : null;
  if (sex != null) filled.add('sex');
  final hasAddress = (keep.addressLine1 ?? '').trim().isNotEmpty;
  final takeAddress = !hasAddress && (duplicate.addressLine1 ?? '').trim().isNotEmpty;
  if (takeAddress) filled.add('address');

  final merged = keep.copyWith(
    middleName: fill(keep.middleName, duplicate.middleName, 'middle name'),
    dateOfBirth: fill(keep.dateOfBirth, duplicate.dateOfBirth, 'date of birth'),
    sex: sex,
    addressLine1: takeAddress ? duplicate.addressLine1 : null,
    city: takeAddress ? duplicate.city : null,
    state: takeAddress ? duplicate.state : null,
    zip: takeAddress ? duplicate.zip : null,
    phone: fill(keep.phone, duplicate.phone, 'phone'),
    insurance: fill(keep.insurance, duplicate.insurance, 'insurance'),
    allergies: fill(keep.allergies, duplicate.allergies, 'allergies'),
    preferredLanguage: fill(keep.preferredLanguage, duplicate.preferredLanguage, 'language'),
    interpreterNeeded: keep.interpreterNeeded || duplicate.interpreterNeeded,
    guarantor: fill(keep.guarantor, duplicate.guarantor, 'responsible party'),
    visits: visits,
  );
  return MergePlan(merged: merged, filled: filled, movedVisits: moved);
}

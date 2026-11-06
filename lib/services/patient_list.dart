import '../models/patient_account.dart';

/// How the Patients list is ordered.
enum PatientSort { recent, name }

/// Which patients the Patients list shows.
enum PatientFilter { all, needsSignature, noInsurance }

String patientFilterLabel(PatientFilter f) => switch (f) {
      PatientFilter.all => 'All',
      PatientFilter.needsSignature => 'Unsigned notes',
      PatientFilter.noInsurance => 'No insurance',
    };

/// The newest date of service (yyyy-MM-dd) of an account, or '' with no visits.
String lastVisitDate(PatientAccount a) {
  var latest = '';
  for (final v in a.visits) {
    if (v.dateOfService.compareTo(latest) > 0) latest = v.dateOfService;
  }
  return latest;
}

bool _matches(PatientAccount a, String q) {
  if (q.isEmpty) return true;
  String n(String? s) => (s ?? '').toLowerCase();
  return n(a.fullName).contains(q) ||
      n(a.accountNumber).contains(q) ||
      n(a.insurance?.memberId).contains(q) ||
      n(a.insurance?.payerName).contains(q);
}

bool _passes(PatientAccount a, PatientFilter f) => switch (f) {
      PatientFilter.all => true,
      PatientFilter.needsSignature => a.visits.any((v) => v.status == VisitStatus.inProgress),
      PatientFilter.noInsurance => a.insurance == null || a.insurance!.memberId.trim().isEmpty,
    };

/// Search, filter and sort for the Patients list. [accounts] arrive newest
/// account first; "recent" orders by last date of service, and accounts
/// without visits keep their arrival order after those with visits.
List<PatientAccount> patientList(
  List<PatientAccount> accounts, {
  String query = '',
  PatientFilter filter = PatientFilter.all,
  PatientSort sort = PatientSort.recent,
}) {
  final q = query.trim().toLowerCase();
  final indexed = [
    for (var i = 0; i < accounts.length; i++)
      if (_matches(accounts[i], q) && _passes(accounts[i], filter)) (i, accounts[i]),
  ];
  int cmp((int, PatientAccount) x, (int, PatientAccount) y) {
    final c = switch (sort) {
      PatientSort.recent => lastVisitDate(y.$2).compareTo(lastVisitDate(x.$2)),
      PatientSort.name => '${x.$2.lastName} ${x.$2.firstName}'.toLowerCase().compareTo('${y.$2.lastName} ${y.$2.firstName}'.toLowerCase()),
    };
    return c != 0 ? c : x.$1.compareTo(y.$1); // stable
  }

  indexed.sort(cmp);
  return [for (final (_, a) in indexed) a];
}

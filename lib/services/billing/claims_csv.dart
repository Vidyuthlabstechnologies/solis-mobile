import '../../models/patient_account.dart';

/// Every visit with a claim as CSV (RFC 4180), for an outside biller or a
/// spreadsheet. One row per visit, newest date of service first. The file
/// holds patient data: it is copied with PhiClipboard, never written to
/// shared storage.
String claimsCsv(Iterable<PatientAccount> accounts) {
  const header = [
    'Account', 'Patient', 'Date of birth', 'Payer', 'Payer ID', 'Member ID', 'Visit', 'Date of service',
    'Place of service', 'Status', 'Diagnoses', 'Services', 'Total charge', 'Payer claim number', 'Paid amount', 'Latest status',
  ];
  final rows = <({String dos, List<String> cells})>[];
  for (final a in accounts) {
    for (final v in a.visits) {
      final c = v.claim;
      if (c == null) continue;
      final s = v.submission ?? const {};
      final dob = a.dateOfBirth;
      rows.add((
        dos: v.dateOfService,
        cells: [
          a.accountNumber,
          a.fullName,
          dob == null ? '' : '${dob.year.toString().padLeft(4, '0')}-${dob.month.toString().padLeft(2, '0')}-${dob.day.toString().padLeft(2, '0')}',
          a.insurance?.payerName ?? '',
          a.insurance?.payerId ?? '',
          a.insurance?.memberId ?? '',
          '${v.number}',
          v.dateOfService,
          v.placeOfService,
          visitStatusLabel(v.status),
          c.billable.map((d) => d.code).join('; '),
          c.lines.map((l) => [l.code, if (l.modifiers.isNotEmpty) l.modifiers.join(':'), 'x${l.unitsLabel}'].join(' ')).join('; '),
          c.totalCharge.toStringAsFixed(2),
          '${s['payerClaimNumber'] ?? ''}',
          '${s['paidAmount'] ?? ''}',
          '${s['statusExplanation'] ?? s['lastStatus'] ?? ''}',
        ],
      ));
    }
  }
  rows.sort((x, y) => y.dos.compareTo(x.dos));
  final lines = [header, for (final r in rows) r.cells].map((r) => r.map(csvField).join(','));
  return '${lines.join('\r\n')}\r\n';
}

/// One CSV field, quoted when it holds a comma, quote or line break. A
/// leading =, +, - or @ is prefixed with ' so a spreadsheet does not run it
/// as a formula.
String csvField(String v) {
  var s = v;
  if (s.isNotEmpty && '=+-@\t\r'.contains(s[0])) s = "'$s";
  if (s.contains(RegExp(r'[",\r\n]'))) return '"${s.replaceAll('"', '""')}"';
  return s;
}

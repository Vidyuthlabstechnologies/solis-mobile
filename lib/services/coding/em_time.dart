// Office and outpatient E/M by total time on the date of service (CPT 2021
// E/M guidelines, kept by CMS for 99202-99215), and prolonged services past
// the top level: CPT 99417 for commercial payers and HCPCS G2212 for
// Medicare (CMS CY2021 PFS final rule; CMS counts from the end of the
// 99205/99215 time range, so G2212 starts later than 99417).

import 'place_of_service.dart';

/// Minimum total minutes for each office/outpatient level.
const Map<String, int> officeEmMinutes = {
  '99202': 15, '99203': 30, '99204': 45, '99205': 60, //
  '99212': 10, '99213': 20, '99214': 30, '99215': 40,
};

bool _isNew(String code) => const {'99202', '99203', '99204', '99205'}.contains(code);

bool isOfficeEm(String code) => officeEmMinutes.containsKey(code);

/// The office/outpatient level that [minutes] of total time supports, in
/// the same family as [code] (new or established). Null when [code] is not
/// an office E/M code or the time is below the lowest level.
String? officeEmForTime(String code, int minutes) {
  if (!isOfficeEm(code)) return null;
  String? best;
  for (final c in emFamily(code)) {
    final m = officeEmMinutes[c];
    if (m != null && minutes >= m) best = c;
  }
  return best;
}

/// A prolonged-service add-on line: code and units.
class ProlongedService {
  final String code;
  final int units;
  const ProlongedService(this.code, this.units);

  @override
  bool operator ==(Object other) => other is ProlongedService && other.code == code && other.units == units;

  @override
  int get hashCode => Object.hash(code, units);

  @override
  String toString() => '$code x$units';
}

/// Prolonged services for [minutes] of total time when the visit is billed
/// at the top level ([code] is 99205 or 99215). CPT 99417: one unit per
/// full 15 minutes beyond the top level's minimum (from 75 or 55 minutes).
/// Medicare G2212: from 89 (99205) or 69 (99215) minutes, then one more
/// unit per further full 15 minutes. Null when none applies.
ProlongedService? prolongedFor(String code, int minutes, {required bool medicare}) {
  if (code != '99205' && code != '99215') return null;
  final isNew = _isNew(code);
  if (medicare) {
    final start = isNew ? 89 : 69;
    if (minutes < start) return null;
    return ProlongedService('G2212', 1 + (minutes - start) ~/ 15);
  }
  final base = officeEmMinutes[code]!;
  final units = (minutes - base) ~/ 15;
  return units < 1 ? null : ProlongedService('99417', units);
}

/// Prolonged-service codes SOLIS manages from total time.
const prolongedCodes = {'99417', 'G2212'};

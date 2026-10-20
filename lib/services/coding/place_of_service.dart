/// CMS Place of Service code set (professional claims, CMS-1500 box 24B).
/// Source: https://www.cms.gov/medicare/coding/place-of-service-codes/place_of_service_code_set.html
class PlaceOfService {
  final String code;
  final String name;
  final EmSetting setting;

  const PlaceOfService(this.code, this.name, this.setting);

  String get label => '$name ($code)';
}

/// Which family of evaluation and management codes is valid in a setting.
enum EmSetting {
  office, // 99202-99215 (office, outpatient, urgent care, clinics, telehealth)
  emergency, // 99281-99285
  inpatient, // 99221-99239
  nursingFacility, // 99304-99316
  home, // 99341-99350
  ambulance, // HCPCS A0425-A0434, no physician E/M
  other,
}

const List<PlaceOfService> placesOfService = [
  PlaceOfService('11', 'Office', EmSetting.office),
  PlaceOfService('02', 'Telehealth, other than patient home', EmSetting.office),
  PlaceOfService('10', 'Telehealth, patient home', EmSetting.office),
  PlaceOfService('12', 'Home', EmSetting.home),
  PlaceOfService('13', 'Assisted living facility', EmSetting.home),
  PlaceOfService('14', 'Group home', EmSetting.home),
  PlaceOfService('17', 'Walk-in retail clinic', EmSetting.office),
  PlaceOfService('19', 'Off-campus outpatient hospital', EmSetting.office),
  PlaceOfService('20', 'Urgent care facility', EmSetting.office),
  PlaceOfService('21', 'Inpatient hospital', EmSetting.inpatient),
  PlaceOfService('22', 'On-campus outpatient hospital', EmSetting.office),
  PlaceOfService('23', 'Emergency room, hospital', EmSetting.emergency),
  PlaceOfService('31', 'Skilled nursing facility', EmSetting.nursingFacility),
  PlaceOfService('32', 'Nursing facility', EmSetting.nursingFacility),
  PlaceOfService('33', 'Custodial care facility', EmSetting.home),
  PlaceOfService('41', 'Ambulance, land', EmSetting.ambulance),
  PlaceOfService('42', 'Ambulance, air or water', EmSetting.ambulance),
  PlaceOfService('49', 'Independent clinic', EmSetting.office),
  PlaceOfService('50', 'Federally qualified health center', EmSetting.office),
  PlaceOfService('71', 'Public health clinic', EmSetting.office),
  PlaceOfService('72', 'Rural health clinic', EmSetting.office),
];

PlaceOfService placeOfService(String code) =>
    placesOfService.firstWhere((p) => p.code == code, orElse: () => PlaceOfService(code, 'POS $code', EmSetting.other));

bool isTelehealthPos(String code) => code == '02' || code == '10';

/// Medical decision making level (2021+ E/M guidelines).
enum MdmLevel { straightforward, low, moderate, high }

/// Picks the E/M code for a setting, patient status and MDM level.
/// Returns null for settings without a physician E/M (ambulance).
String? emCodeFor(EmSetting setting, {required bool newPatient, required MdmLevel mdm}) {
  final i = mdm.index; // 0..3
  switch (setting) {
    case EmSetting.office:
    case EmSetting.other:
      return newPatient ? ['99202', '99203', '99204', '99205'][i] : ['99212', '99213', '99214', '99215'][i];
    case EmSetting.emergency:
      return ['99282', '99283', '99284', '99285'][i];
    case EmSetting.inpatient:
      return newPatient ? ['99221', '99221', '99222', '99223'][i] : ['99231', '99231', '99232', '99233'][i];
    case EmSetting.nursingFacility:
      return newPatient ? ['99304', '99304', '99305', '99306'][i] : ['99307', '99308', '99309', '99310'][i];
    case EmSetting.home:
      return newPatient ? ['99341', '99342', '99344', '99345'][i] : ['99347', '99348', '99349', '99350'][i];
    case EmSetting.ambulance:
      return null;
  }
}

/// The setting an E/M code belongs to, or null if [code] is not an E/M code.
EmSetting? emSettingOf(String code) {
  final n = int.tryParse(code);
  if (n == null) return null;
  if (n >= 99202 && n <= 99215) return EmSetting.office;
  if (n >= 99221 && n <= 99239) return EmSetting.inpatient;
  if (n >= 99281 && n <= 99285) return EmSetting.emergency;
  if (n >= 99304 && n <= 99316) return EmSetting.nursingFacility;
  if (n >= 99341 && n <= 99350) return EmSetting.home;
  return null;
}

/// The levels of [code]'s E/M family, lowest first (99202 to 99205 for a
/// new office patient). Empty when [code] is not an E/M code of a known
/// family. Used for the one-tap level change on the claim.
List<String> emFamily(String code) {
  const families = [
    ['99202', '99203', '99204', '99205'],
    ['99212', '99213', '99214', '99215'],
    ['99281', '99282', '99283', '99284', '99285'],
    ['99221', '99222', '99223'],
    ['99231', '99232', '99233'],
    ['99304', '99305', '99306'],
    ['99307', '99308', '99309', '99310'],
    ['99341', '99342', '99344', '99345'],
    ['99347', '99348', '99349', '99350'],
  ];
  for (final f in families) {
    if (f.contains(code)) return f;
  }
  return const [];
}

/// New-patient E/M codes (used to cross-check against visit history).
bool isNewPatientEm(String code) {
  final n = int.tryParse(code) ?? 0;
  return (n >= 99202 && n <= 99205) || (n >= 99341 && n <= 99345) || (n >= 99304 && n <= 99306) || (n >= 99221 && n <= 99223);
}

String emDescription(String code) => switch (code) {
      '99202' => 'Office visit, new patient, straightforward MDM',
      '99203' => 'Office visit, new patient, low MDM',
      '99204' => 'Office visit, new patient, moderate MDM',
      '99205' => 'Office visit, new patient, high MDM',
      '99212' => 'Office visit, established patient, straightforward MDM',
      '99213' => 'Office visit, established patient, low MDM',
      '99214' => 'Office visit, established patient, moderate MDM',
      '99215' => 'Office visit, established patient, high MDM',
      '99282' => 'Emergency department visit, straightforward MDM',
      '99283' => 'Emergency department visit, low MDM',
      '99284' => 'Emergency department visit, moderate MDM',
      '99285' => 'Emergency department visit, high MDM',
      '99221' => 'Initial hospital care, straightforward or low MDM',
      '99222' => 'Initial hospital care, moderate MDM',
      '99223' => 'Initial hospital care, high MDM',
      '99231' => 'Subsequent hospital care, straightforward or low MDM',
      '99232' => 'Subsequent hospital care, moderate MDM',
      '99233' => 'Subsequent hospital care, high MDM',
      '99304' => 'Initial nursing facility care, straightforward or low MDM',
      '99305' => 'Initial nursing facility care, moderate MDM',
      '99306' => 'Initial nursing facility care, high MDM',
      '99307' => 'Subsequent nursing facility care, straightforward MDM',
      '99308' => 'Subsequent nursing facility care, low MDM',
      '99309' => 'Subsequent nursing facility care, moderate MDM',
      '99310' => 'Subsequent nursing facility care, high MDM',
      '99341' => 'Home visit, new patient, straightforward MDM',
      '99342' => 'Home visit, new patient, low MDM',
      '99344' => 'Home visit, new patient, moderate MDM',
      '99345' => 'Home visit, new patient, high MDM',
      '99347' => 'Home visit, established patient, straightforward MDM',
      '99348' => 'Home visit, established patient, low MDM',
      '99349' => 'Home visit, established patient, moderate MDM',
      '99350' => 'Home visit, established patient, high MDM',
      _ => 'Evaluation and management',
    };

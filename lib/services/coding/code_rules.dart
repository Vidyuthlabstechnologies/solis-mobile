import '../../models/patient_account.dart';
import '../codesets/reference_data.dart';

/// Organ systems used to check that a procedure is supported by a diagnosis
/// in a related system. A headache diagnosis does not support an upper GI
/// endoscopy; payers deny that as a medical-necessity mismatch.
enum BodySystem {
  general,
  cardiovascular,
  respiratory,
  digestive,
  nervous,
  musculoskeletal,
  genitourinary,
  femaleReproductive,
  maleReproductive,
  maternity,
  endocrine,
  skin,
  eye,
  ear,
  mental,
  blood,
}

String bodySystemLabel(BodySystem s) => switch (s) {
      BodySystem.general => 'general',
      BodySystem.cardiovascular => 'cardiovascular',
      BodySystem.respiratory => 'respiratory',
      BodySystem.digestive => 'digestive',
      BodySystem.nervous => 'nervous system',
      BodySystem.musculoskeletal => 'musculoskeletal',
      BodySystem.genitourinary => 'urinary',
      BodySystem.femaleReproductive => 'female reproductive',
      BodySystem.maleReproductive => 'male reproductive',
      BodySystem.maternity => 'pregnancy',
      BodySystem.endocrine => 'endocrine',
      BodySystem.skin => 'skin',
      BodySystem.eye => 'eye',
      BodySystem.ear => 'ear',
      BodySystem.mental => 'mental health',
      BodySystem.blood => 'blood',
    };

String _icdNorm(String code) => code.toUpperCase().replaceAll('.', '');

/// True when [code] falls in the ICD-10-CM range [from]..[to], inclusive of
/// every code under [to] (N40..N53 includes N53.9).
bool _inIcd(String code, String from, String to) {
  final c = _icdNorm(code);
  final f = _icdNorm(from);
  final t = _icdNorm(to);
  return c.compareTo(f) >= 0 && (c.startsWith(t) || c.compareTo(t) <= 0);
}

/// Wildcard diagnoses (infections, neoplasms, congenital) can support a
/// procedure in any system because they can involve any organ.
bool isWildcardDiagnosis(String icd) {
  final l = icd.toUpperCase()[0];
  return l == 'A' || l == 'B' || l == 'C' || l == 'Q' || _inIcd(icd, 'D00', 'D49');
}

Set<BodySystem> icdSystems(String icd) {
  final c = icd.toUpperCase();
  final l = c[0];
  switch (l) {
    case 'A':
    case 'B':
    case 'C':
    case 'Q':
    case 'Z':
      return {BodySystem.general};
    case 'D':
      return _inIcd(c, 'D50', 'D89') ? {BodySystem.blood} : {BodySystem.general};
    case 'E':
      // Diabetes combination codes carry their manifestation's system
      // (E11.42 polyneuropathy is also a nervous system diagnosis).
      final dm = RegExp(r'^E(08|09|10|11|13)\.(\d)').firstMatch(c);
      if (dm != null) {
        return {
          BodySystem.endocrine,
          ...switch (dm.group(2)) {
            '2' => {BodySystem.genitourinary},
            '3' => {BodySystem.eye},
            '4' => {BodySystem.nervous, BodySystem.skin},
            '5' => {BodySystem.cardiovascular},
            '6' => {BodySystem.musculoskeletal, BodySystem.skin, BodySystem.digestive},
            _ => <BodySystem>{},
          },
        };
      }
      return {BodySystem.endocrine};
    case 'F':
      return {BodySystem.mental};
    case 'G':
      return {BodySystem.nervous};
    case 'H':
      return _inIcd(c, 'H00', 'H59') ? {BodySystem.eye} : {BodySystem.ear};
    case 'I':
      return {BodySystem.cardiovascular};
    case 'J':
      return {BodySystem.respiratory};
    case 'K':
      return {BodySystem.digestive};
    case 'L':
      return {BodySystem.skin};
    case 'M':
      return {BodySystem.musculoskeletal};
    case 'N':
      if (_inIcd(c, 'N40', 'N53')) return {BodySystem.maleReproductive};
      if (_inIcd(c, 'N60', 'N98')) return {BodySystem.femaleReproductive};
      return {BodySystem.genitourinary};
    case 'O':
      return {BodySystem.maternity};
    case 'P':
      return {BodySystem.general};
    case 'R':
      if (_inIcd(c, 'R00', 'R03')) return {BodySystem.cardiovascular};
      if (_inIcd(c, 'R04', 'R06')) return {BodySystem.respiratory};
      if (_inIcd(c, 'R07', 'R07')) return {BodySystem.cardiovascular, BodySystem.respiratory, BodySystem.musculoskeletal};
      if (_inIcd(c, 'R09', 'R09')) return {BodySystem.respiratory, BodySystem.cardiovascular};
      if (_inIcd(c, 'R10', 'R19')) return {BodySystem.digestive};
      if (_inIcd(c, 'R20', 'R23')) return {BodySystem.skin, BodySystem.nervous};
      if (_inIcd(c, 'R25', 'R29')) return {BodySystem.nervous, BodySystem.musculoskeletal};
      if (_inIcd(c, 'R30', 'R39')) return {BodySystem.genitourinary};
      if (_inIcd(c, 'R40', 'R46')) return {BodySystem.nervous, BodySystem.mental};
      if (_inIcd(c, 'R47', 'R49')) return {BodySystem.nervous};
      if (_inIcd(c, 'R51', 'R51')) return {BodySystem.nervous};
      if (_inIcd(c, 'R68.84', 'R68.84')) return {BodySystem.musculoskeletal, BodySystem.cardiovascular};
      return {BodySystem.general};
    case 'S':
    case 'T':
      return {BodySystem.musculoskeletal, BodySystem.skin, BodySystem.nervous};
    default:
      return {BodySystem.general};
  }
}

/// Systems a CPT/HCPCS procedure belongs to. General means any diagnosis can
/// support it (E/M, most labs, ambulance transport).
Set<BodySystem> procedureSystems(String code) {
  final n = int.tryParse(code);
  if (n == null) return {BodySystem.general}; // HCPCS (A0427 etc.)
  bool r(int a, int b) => n >= a && n <= b;
  if (r(99000, 99499)) return {BodySystem.general};
  if (r(80000, 89398)) return {BodySystem.general};
  if (r(36000, 36598)) return {BodySystem.general}; // venipuncture, lines
  if (r(10004, 19499)) return {BodySystem.skin};
  if (r(20005, 29999)) return {BodySystem.musculoskeletal};
  if (r(30000, 32999)) return {BodySystem.respiratory};
  if (r(33010, 37799)) return {BodySystem.cardiovascular};
  if (r(38100, 38999)) return {BodySystem.blood};
  if (r(39000, 39599)) return {BodySystem.respiratory, BodySystem.digestive};
  if (r(40490, 49999)) return {BodySystem.digestive};
  if (r(50010, 53899)) return {BodySystem.genitourinary};
  if (r(54000, 55899)) return {BodySystem.maleReproductive};
  if (r(56405, 58999)) return {BodySystem.femaleReproductive};
  if (r(59000, 59899)) return {BodySystem.maternity};
  if (r(60000, 60699)) return {BodySystem.endocrine};
  if (r(61000, 64999)) return {BodySystem.nervous};
  if (r(65091, 68899)) return {BodySystem.eye};
  if (r(69000, 69979)) return {BodySystem.ear};
  if (r(70010, 70559)) return {BodySystem.nervous, BodySystem.ear, BodySystem.eye, BodySystem.musculoskeletal};
  if (r(71045, 71555)) return {BodySystem.respiratory, BodySystem.cardiovascular, BodySystem.musculoskeletal};
  if (r(72020, 72295)) return {BodySystem.musculoskeletal, BodySystem.nervous};
  if (r(73000, 73725)) return {BodySystem.musculoskeletal};
  if (r(74018, 74485)) return {BodySystem.digestive, BodySystem.genitourinary};
  if (r(76801, 76828)) return {BodySystem.maternity};
  if (r(76830, 76857)) return {BodySystem.femaleReproductive, BodySystem.genitourinary};
  if (r(92002, 92499)) return {BodySystem.eye};
  if (r(92502, 92700)) return {BodySystem.ear};
  if (r(92920, 93799)) return {BodySystem.cardiovascular};
  if (r(94002, 94799)) return {BodySystem.respiratory};
  if (r(95700, 96020)) return {BodySystem.nervous};
  if (r(97010, 97799)) return {BodySystem.musculoskeletal, BodySystem.nervous};
  return {BodySystem.general};
}

/// True when [icd] can support procedure [cpt] on medical-necessity grounds.
bool diagnosisSupportsProcedure(String icd, String cpt) {
  final proc = procedureSystems(cpt);
  if (proc.contains(BodySystem.general)) return true;
  if (isWildcardDiagnosis(icd)) return true;
  return icdSystems(icd).intersection(proc).isNotEmpty;
}

// ---------------------------------------------------------------------------
// Sex edits (diagnoses and procedures that apply to one sex only).
// ---------------------------------------------------------------------------

/// Female-only ICD-10-CM ranges, modeled on the CMS Medicare Code Editor lists.
const _femaleOnlyIcd = [
  ['O00', 'O9A'], ['Z32', 'Z36'], ['Z39', 'Z39'], ['N70', 'N98'], ['C51', 'C58'],
  ['D06', 'D06'], ['D25', 'D28'], ['Z12.4', 'Z12.4'], ['R87', 'R87'], ['Z01.41', 'Z01.42'],
];

const _maleOnlyIcd = [
  ['N40', 'N53'], ['C60', 'C63'], ['D29', 'D29'], ['Z12.5', 'Z12.5'], ['R86', 'R86'],
];

const _femaleOnlyProc = ['G0101', 'Q0091'];
const _maleOnlyProc = ['G0102', 'G0103'];

/// Returns the only sex [icd] applies to, or null when it is unrestricted.
PatientSex? icdSexRestriction(String icd) {
  final c = icd.toUpperCase();
  if (c.startsWith('O')) return PatientSex.female;
  for (final r in _femaleOnlyIcd) {
    if (_inIcd(c, r[0], r[1])) return PatientSex.female;
  }
  for (final r in _maleOnlyIcd) {
    if (_inIcd(c, r[0], r[1])) return PatientSex.male;
  }
  return null;
}

PatientSex? procedureSexRestriction(String code) {
  final c = code.toUpperCase();
  if (_femaleOnlyProc.contains(c)) return PatientSex.female;
  if (_maleOnlyProc.contains(c)) return PatientSex.male;
  final systems = procedureSystems(c);
  if (systems.length == 1) {
    if (systems.contains(BodySystem.maleReproductive)) return PatientSex.male;
    if (systems.contains(BodySystem.femaleReproductive) || systems.contains(BodySystem.maternity)) return PatientSex.female;
  }
  return null;
}

// ---------------------------------------------------------------------------
// Age edits.
// ---------------------------------------------------------------------------

class AgeRange {
  final int min;
  final int max;
  final String label;
  const AgeRange(this.min, this.max, this.label);
  bool contains(int age) => age >= min && age <= max;
}

/// Age limits for diagnoses (MCE-AGE-01, CH15-OB-01, CH16-PERI-01).
///
/// Driven by the MCE v44 age lists when they are loaded: newborn (age 0),
/// pediatric (0 to 17), maternity (9 to 64) and adult (15 to 124). Without
/// the lists, a small fallback covers the common cases. Perinatal P codes are
/// not age-limited: guideline I.C.16.a.4 allows them at any age when the
/// condition began in the perinatal period (see [isPerinatalCode]).
AgeRange? icdAgeRange(String icd) {
  final mce = ReferenceData.mce;
  if (mce != null) {
    final a = mce.ageFor(icd);
    return a == null ? null : AgeRange(a.min, a.max, a.label);
  }
  final c = icd.toUpperCase();
  if (c.startsWith('O')) return const AgeRange(9, 64, 'maternity (age 9 to 64)');
  if (c.startsWith('Z00.11')) return const AgeRange(0, 0, 'newborn (age 0)');
  if (c.startsWith('Z00.12')) return const AgeRange(0, 17, 'pediatric (age 0 to 17)');
  if (c == 'Z00.00' || c == 'Z00.01') return const AgeRange(15, 124, 'adult (age 15 to 124)');
  return null;
}

/// Chapter 16 perinatal codes (P00-P96). Used after the newborn period they
/// need documentation that the condition began in the perinatal period.
bool isPerinatalCode(String icd) => icd.toUpperCase().startsWith('P');

// ---------------------------------------------------------------------------
// Sequencing: codes that must, or must never, be first-listed.
// ---------------------------------------------------------------------------

/// External cause codes V00-Y99 (ICD-EXTCAUSE-01). Never first-listed.
bool isExternalCauseCode(String icd) {
  final l = icd.trim().toUpperCase();
  return l.startsWith('V') || l.startsWith('W') || l.startsWith('X') || l.startsWith('Y');
}

/// Severe sepsis R65.2- (CH1-SEPSIS-01). Never first-listed.
bool isSevereSepsisCode(String icd) => _icdNorm(icd).startsWith('R652');

/// Codes reported only as secondary diagnoses (ICD-SECONDARY-ONLY-01),
/// from guidelines I.B.14, I.C.18.e.1, I.C.18.i and I.C.21.c.17: BMI,
/// coma scale, NIHSS, blood alcohol level, underimmunization status and
/// social determinants of health. Value: plain-English name of the group.
const secondaryOnlyIcdPrefixes = {
  'Z68': 'Body mass index (BMI)',
  'R40.21': 'Coma scale',
  'R40.22': 'Coma scale',
  'R40.23': 'Coma scale',
  'R40.24': 'Coma scale',
  'R29.7': 'NIH stroke scale (NIHSS)',
  'Y90': 'Blood alcohol level',
  'Z28.3': 'Underimmunization status',
  'Z55': 'Social determinants of health',
  'Z56': 'Social determinants of health',
  'Z57': 'Social determinants of health',
  'Z58': 'Social determinants of health',
  'Z59': 'Social determinants of health',
  'Z60': 'Social determinants of health',
  'Z62': 'Social determinants of health',
  'Z63': 'Social determinants of health',
  'Z64': 'Social determinants of health',
  'Z65': 'Social determinants of health',
};

/// The secondary-only group [icd] belongs to, or null.
String? secondaryOnlyGroup(String icd) {
  final c = _icdNorm(icd);
  for (final e in secondaryOnlyIcdPrefixes.entries) {
    if (c.startsWith(_icdNorm(e.key))) return e.value;
  }
  return null;
}

/// Z codes that may only be the first-listed diagnosis (CH21-Z-01),
/// guideline I.C.21.c.15. Value: codes under the prefix that are exceptions.
const firstListedOnlyZPrefixes = {
  'Z00': ['Z00.6'],
  'Z01': <String>[],
  'Z02': <String>[],
  'Z04': <String>[],
  'Z33.2': <String>[],
  'Z31.81': <String>[],
  'Z31.83': <String>[],
  'Z31.84': <String>[],
  'Z34': <String>[],
  'Z39': <String>[],
  'Z38': <String>[],
  'Z40': <String>[],
  'Z42': <String>[],
  'Z51.0': <String>[],
  'Z51.1': <String>[],
  'Z52': ['Z52.9'],
  'Z76.1': <String>[],
  'Z76.2': <String>[],
  'Z99.12': <String>[],
};

/// True when [icd] may only be reported as the first-listed diagnosis.
bool isFirstListedOnly(String icd) {
  final c = _icdNorm(icd);
  for (final e in firstListedOnlyZPrefixes.entries) {
    if (!c.startsWith(_icdNorm(e.key))) continue;
    return !e.value.any((x) => c.startsWith(_icdNorm(x)));
  }
  return false;
}

/// True when [icd] is never the first-listed diagnosis: external causes,
/// secondary-only codes, severe sepsis and (when the MCE lists are loaded)
/// manifestation codes.
bool isNeverFirstListed(String icd) =>
    isExternalCauseCode(icd) || secondaryOnlyGroup(icd) != null || isSevereSepsisCode(icd) || (ReferenceData.mce?.isManifestation(icd) ?? false);

/// [icd] with the placeholder X filling positions 4 to 6 and [seventh] as
/// the 7th character (guidelines I.A.4 and I.A.5): T74.4 + A = T74.4XXA.
String withSeventhCharacter(String icd, String seventh) {
  var c = _icdNorm(icd);
  if (c.length > 6) c = c.substring(0, 6);
  final padded = c.padRight(6, 'X') + seventh.toUpperCase();
  return '${padded.substring(0, 3)}.${padded.substring(3)}';
}

AgeRange? procedureAgeRange(String code) {
  const preventive = {
    '99381': AgeRange(0, 0, 'under 1 year'), '99391': AgeRange(0, 0, 'under 1 year'),
    '99382': AgeRange(1, 4, 'age 1 to 4'), '99392': AgeRange(1, 4, 'age 1 to 4'),
    '99383': AgeRange(5, 11, 'age 5 to 11'), '99393': AgeRange(5, 11, 'age 5 to 11'),
    '99384': AgeRange(12, 17, 'age 12 to 17'), '99394': AgeRange(12, 17, 'age 12 to 17'),
    '99385': AgeRange(18, 39, 'age 18 to 39'), '99395': AgeRange(18, 39, 'age 18 to 39'),
    '99386': AgeRange(40, 64, 'age 40 to 64'), '99396': AgeRange(40, 64, 'age 40 to 64'),
    '99387': AgeRange(65, 124, 'age 65 and over'), '99397': AgeRange(65, 124, 'age 65 and over'),
    '99460': AgeRange(0, 0, 'newborn'), '99461': AgeRange(0, 0, 'newborn'), '99462': AgeRange(0, 0, 'newborn'),
    '90460': AgeRange(0, 18, 'under 19'), '90461': AgeRange(0, 18, 'under 19'),
  };
  return preventive[code];
}

/// Codes that end in an unspecified site or type (.9, .90, .909) are valid but
/// often trigger payer specificity edits.
bool isUnspecifiedIcd(String icd) => RegExp(r'\.(9|90|99|909)$').hasMatch(icd) || icd == 'R51.9';

/// Removes the dot for X12 HI segments (I21.19 -> I2119).
String icdForX12(String icd) => icd.replaceAll('.', '').toUpperCase();

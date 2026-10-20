import '../models/patient_account.dart';

enum CardType { insurance, driverLicense, ssnCard }

String cardTypeLabel(CardType t) => switch (t) {
      CardType.insurance => 'Insurance card',
      CardType.driverLicense => "Driver's license",
      CardType.ssnCard => 'Social Security card',
    };

/// Everything we could read from one or more identity and insurance cards.
/// Fields stay null when not found, so the review screen can show what is
/// missing instead of guessing.
class ScannedIdentity {
  final String? firstName;
  final String? middleName;
  final String? lastName;
  final DateTime? dateOfBirth;
  final PatientSex? sex;
  final String? addressLine1;
  final String? city;
  final String? state;
  final String? zip;
  final String? licenseNumber;
  final String? licenseState;
  final String? ssnLast4;
  final String? payerName;
  final String? payerId;
  final String? planName;
  final String? planType;
  final String? memberId;
  final String? groupNumber;
  final String? subscriberName;
  final String? rxBin;
  final String? rxPcn;
  final String? rxGroup;
  final String? effectiveDate;
  final Map<String, String> copays;
  final Set<String> sources; // which cards contributed, for the review screen

  const ScannedIdentity({
    this.firstName,
    this.middleName,
    this.lastName,
    this.dateOfBirth,
    this.sex,
    this.addressLine1,
    this.city,
    this.state,
    this.zip,
    this.licenseNumber,
    this.licenseState,
    this.ssnLast4,
    this.payerName,
    this.payerId,
    this.planName,
    this.planType,
    this.memberId,
    this.groupNumber,
    this.subscriberName,
    this.rxBin,
    this.rxPcn,
    this.rxGroup,
    this.effectiveDate,
    this.copays = const {},
    this.sources = const {},
  });

  bool get isEmpty =>
      firstName == null && lastName == null && dateOfBirth == null && memberId == null && payerName == null && ssnLast4 == null && licenseNumber == null;

  /// Combines two scans. Values already present win, except that a driver's
  /// license barcode (machine-encoded) overrides OCR guesses for name, DOB,
  /// sex and address.
  ScannedIdentity merge(ScannedIdentity other, {bool otherIsAuthoritative = false}) {
    T? pick<T>(T? mine, T? theirs) => otherIsAuthoritative ? (theirs ?? mine) : (mine ?? theirs);
    return ScannedIdentity(
      firstName: pick(firstName, other.firstName),
      middleName: pick(middleName, other.middleName),
      lastName: pick(lastName, other.lastName),
      dateOfBirth: pick(dateOfBirth, other.dateOfBirth),
      sex: pick(sex, other.sex),
      addressLine1: pick(addressLine1, other.addressLine1),
      city: pick(city, other.city),
      state: pick(state, other.state),
      zip: pick(zip, other.zip),
      licenseNumber: licenseNumber ?? other.licenseNumber,
      licenseState: licenseState ?? other.licenseState,
      ssnLast4: ssnLast4 ?? other.ssnLast4,
      payerName: payerName ?? other.payerName,
      payerId: payerId ?? other.payerId,
      planName: planName ?? other.planName,
      planType: planType ?? other.planType,
      memberId: memberId ?? other.memberId,
      groupNumber: groupNumber ?? other.groupNumber,
      subscriberName: subscriberName ?? other.subscriberName,
      rxBin: rxBin ?? other.rxBin,
      rxPcn: rxPcn ?? other.rxPcn,
      rxGroup: rxGroup ?? other.rxGroup,
      effectiveDate: effectiveDate ?? other.effectiveDate,
      copays: {...other.copays, ...copays},
      sources: {...sources, ...other.sources},
    );
  }
}

class CardParser {
  // ---------------------------------------------------------------------------
  // Insurance card (OCR text)
  // ---------------------------------------------------------------------------

  static const _payers = <String, String>{
    'unitedhealthcare': 'UnitedHealthcare',
    'united healthcare': 'UnitedHealthcare',
    'uhc': 'UnitedHealthcare',
    'aetna': 'Aetna',
    'cigna': 'Cigna',
    'humana': 'Humana',
    'blue cross blue shield': 'Blue Cross Blue Shield',
    'bluecross blueshield': 'Blue Cross Blue Shield',
    'blue cross': 'Blue Cross Blue Shield',
    'blue shield': 'Blue Shield',
    'bcbs': 'Blue Cross Blue Shield',
    'anthem': 'Anthem Blue Cross',
    'kaiser': 'Kaiser Permanente',
    'medicare': 'Medicare',
    'medicaid': 'Medicaid',
    'medi-cal': 'Medi-Cal',
    'molina': 'Molina Healthcare',
    'ambetter': 'Ambetter',
    'wellcare': 'WellCare',
    'oscar': 'Oscar Health',
    'tricare': 'TRICARE',
    'highmark': 'Highmark',
    'health net': 'Health Net',
    'carefirst': 'CareFirst',
    'florida blue': 'Florida Blue',
    'emblemhealth': 'EmblemHealth',
    'oxford': 'Oxford Health Plans',
    'geisinger': 'Geisinger Health Plan',
    'priority health': 'Priority Health',
    'harvard pilgrim': 'Harvard Pilgrim',
  };

  /// Medicare Beneficiary Identifier: 11 characters, no S L O I B Z.
  static final _mbi = RegExp(r'\b[1-9][AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y0-9][0-9]-?[AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y0-9][0-9]-?[AC-HJKMNP-RT-Y]{2}[0-9]{2}\b');

  static String? _after(List<String> lines, RegExp label, {RegExp? value}) {
    final v = value ?? RegExp(r'[A-Z0-9][A-Z0-9\-]{3,24}', caseSensitive: false);
    for (var i = 0; i < lines.length; i++) {
      final m = label.firstMatch(lines[i]);
      if (m == null) continue;
      final rest = lines[i].substring(m.end).replaceFirst(RegExp(r'^[\s:#.\-]+'), '');
      final inLine = v.firstMatch(rest);
      if (inLine != null) return inLine.group(0)!.trim();
      if (i + 1 < lines.length) {
        final next = v.firstMatch(lines[i + 1]);
        if (next != null && next.start == 0) return next.group(0)!.trim();
      }
    }
    return null;
  }

  static ScannedIdentity parseInsuranceCard(String text) {
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final lower = text.toLowerCase();

    String? payer;
    for (final e in _payers.entries) {
      if (lower.contains(e.key)) {
        payer = e.value;
        break;
      }
    }

    String? memberId = _after(lines, RegExp(r"\b(member\s*id|member\s*#|subscriber\s*id|id\s*(no|number|#)|identification\s*(no|number)|member\s*number|id)\b\s*[:#]?", caseSensitive: false));
    final mbi = _mbi.firstMatch(text.toUpperCase());
    if (mbi != null && (payer == null || payer == 'Medicare')) {
      payer ??= 'Medicare';
      memberId = mbi.group(0)!.replaceAll('-', '');
    }
    if (memberId != null && RegExp(r'^(no|number|member|name)$', caseSensitive: false).hasMatch(memberId)) memberId = null;

    final group = _after(lines, RegExp(r'\b(group\s*(no|number|#)?|grp\s*#?)\b\s*[:#]?', caseSensitive: false));
    final rxBin = _after(lines, RegExp(r'\b(rx\s*)?bin\b\s*[:#]?', caseSensitive: false), value: RegExp(r'\d{6}'));
    final rxPcn = _after(lines, RegExp(r'\b(rx\s*)?pcn\b\s*[:#]?', caseSensitive: false), value: RegExp(r'[A-Z0-9]{2,15}', caseSensitive: false));
    final rxGrp = _after(lines, RegExp(r'\brx\s*(grp|group)\b\s*[:#]?', caseSensitive: false));
    final payerId = _after(lines, RegExp(r'\b(payer\s*id|payor\s*id|edi\s*#?)\b\s*[:#]?', caseSensitive: false), value: RegExp(r'[A-Z0-9]{5}', caseSensitive: false));
    final effective = _after(lines, RegExp(r'\b(effective(\s*date)?|eff\.?\s*date|coverage\s*date)\b\s*[:#]?', caseSensitive: false),
        value: RegExp(r'\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4}'));
    final dob = _parseDate(_after(lines, RegExp(r'\b(dob|date of birth|birth\s*date)\b\s*[:#]?', caseSensitive: false), value: RegExp(r'\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4}')));

    String? planType;
    for (final t in ['PPO', 'HMO', 'EPO', 'POS', 'HDHP', 'Medicare Advantage', 'Part B', 'Choice Plus', 'Open Access Plus']) {
      if (RegExp('\\b${RegExp.escape(t)}\\b', caseSensitive: false).hasMatch(text)) {
        planType = t;
        break;
      }
    }

    final copays = <String, String>{};
    for (final m in RegExp(r'\b(PCP|Primary(?: Care)?|Specialist|SPC|ER|Emergency|Urgent(?: Care)?|UC|Office Visit|OV)\b[^\$\n]{0,12}\$\s?(\d{1,4})', caseSensitive: false)
        .allMatches(text)) {
      final key = m.group(1)!.toUpperCase();
      final label = key.startsWith('PRIMARY') || key == 'PCP' || key == 'OV' || key.startsWith('OFFICE')
          ? 'PCP'
          : key.startsWith('SP')
              ? 'Specialist'
              : key.startsWith('E')
                  ? 'ER'
                  : 'Urgent care';
      copays[label] = '\$${m.group(2)}';
    }

    // Member name: a labelled line, or the first line that looks like a name.
    String? name = _after(lines, RegExp(r'\b(member\s*name|member|name|subscriber|insured)\b\s*[:#]?', caseSensitive: false),
        value: RegExp(r"[A-Za-z][A-Za-z'\-]+(\s+[A-Za-z]\.?)?(\s+[A-Za-z][A-Za-z'\-]+){1,2}"));
    if (name != null && _payers.keys.any((p) => name!.toLowerCase().contains(p))) name = null;
    name ??= lines
        .map((l) => l.trim())
        .where((l) => RegExp(r"^[A-Z][A-Za-z'\-]+(\s+[A-Z]\.?)?\s+[A-Z][A-Za-z'\-]+$").hasMatch(l))
        .where((l) => !_payers.keys.any((p) => l.toLowerCase().contains(p)))
        .where((l) => !RegExp(r'\b(plan|group|member|card|health|insurance|copay|network|pharmacy|blue|choice|open|access)\b', caseSensitive: false).hasMatch(l))
        .firstOrNull;
    final (first, middle, last) = _splitName(name);

    return ScannedIdentity(
      firstName: first,
      middleName: middle,
      lastName: last,
      dateOfBirth: dob,
      payerName: payer,
      payerId: payerId,
      planType: planType,
      memberId: memberId,
      groupNumber: group,
      subscriberName: name,
      rxBin: rxBin,
      rxPcn: rxPcn,
      rxGroup: rxGrp,
      effectiveDate: effective,
      copays: copays,
      sources: {'Insurance card'},
    );
  }

  // ---------------------------------------------------------------------------
  // Driver's license
  // ---------------------------------------------------------------------------

  /// Parses the AAMVA PDF417 barcode on the back of US and Canadian licenses
  /// and ID cards. Machine-encoded, so it is exact where OCR can misread.
  static ScannedIdentity? parseAamva(String raw) {
    if (!raw.contains('ANSI') && !raw.contains('AAMVA') && !RegExp(r'\nD(AQ|CS|BB)').hasMatch(raw)) return null;
    final fields = <String, String>{};
    for (final line in raw.split(RegExp(r'[\n\r\x1e]'))) {
      var l = line.trim();
      // The header line ends with the subfile type glued to the first
      // element: "...ANSI 636014...DLDAQD1234562".
      final glued = RegExp(r'(?:DL|ID)(D[A-Z]{2}.*)$').firstMatch(l);
      if (glued != null && (l.contains('ANSI') || l.contains('AAMVA') || l.startsWith('DL') || l.startsWith('ID'))) l = glued.group(1)!;
      final m = RegExp(r'^(D[A-Z]{2})(.*)$').firstMatch(l);
      if (m != null && !fields.containsKey(m.group(1))) fields[m.group(1)!] = m.group(2)!.trim();
    }
    if (fields.isEmpty) return null;

    var first = fields['DAC'];
    var last = fields['DCS'];
    var middle = fields['DAD'];
    if ((first == null || last == null) && fields['DAA'] != null) {
      final parts = fields['DAA']!.split(RegExp(r'[,$]')).map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
      if (parts.length >= 2) {
        last ??= parts[0];
        first ??= parts[1];
        if (parts.length > 2) middle ??= parts[2];
      }
    }
    if (middle != null && (middle.toUpperCase() == 'NONE' || middle.isEmpty)) middle = null;

    DateTime? dob;
    final b = fields['DBB'];
    if (b != null && b.length == 8) {
      // US: MMDDCCYY. Canada: CCYYMMDD.
      final us = DateTime.tryParse('${b.substring(4, 8)}-${b.substring(0, 2)}-${b.substring(2, 4)}');
      final ca = DateTime.tryParse('${b.substring(0, 4)}-${b.substring(4, 6)}-${b.substring(6, 8)}');
      dob = (us != null && us.year > 1900 && us.year <= DateTime.now().year) ? us : ca;
    }

    return ScannedIdentity(
      firstName: _title(first),
      middleName: _title(middle),
      lastName: _title(last),
      dateOfBirth: dob,
      sex: fields['DBC'] == null ? null : sexFromString(fields['DBC']),
      addressLine1: _title(fields['DAG']),
      city: _title(fields['DAI']),
      state: fields['DAJ']?.toUpperCase(),
      zip: fields['DAK']?.replaceAll(RegExp(r'[^0-9]'), '').padRight(5).substring(0, 5).trim(),
      licenseNumber: fields['DAQ'],
      licenseState: fields['DAJ']?.toUpperCase(),
      sources: {"Driver's license barcode"},
    );
  }

  /// Fallback for the license front when the barcode cannot be read. AAMVA
  /// card design numbers fields: 1 last name, 2 first name, 3 DOB, 15 sex.
  static ScannedIdentity parseLicenseFront(String text) {
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    String? numbered(String n) {
      for (final l in lines) {
        final m = RegExp('^$n\\s+([A-Z][A-Z\'\\- ]+)\$').firstMatch(l.toUpperCase());
        if (m != null) return m.group(1)!.trim();
      }
      return null;
    }

    final last = numbered('1') ?? _after(lines, RegExp(r'\b(LN|last name)\b', caseSensitive: false), value: RegExp(r"[A-Za-z'\-]+"));
    final first = numbered('2') ?? _after(lines, RegExp(r'\b(FN|first name)\b', caseSensitive: false), value: RegExp(r"[A-Za-z'\-]+(\s+[A-Za-z]+)?"));
    final dob = _parseDate(_after(lines, RegExp(r'\b(DOB|3\s*DOB|date of birth)\b', caseSensitive: false), value: RegExp(r'\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4}')));
    final sexRaw = _after(lines, RegExp(r'\b(sex|15\s*sex)\b', caseSensitive: false), value: RegExp(r'\b[MF]\b'));
    final dl = _after(lines, RegExp(r'\b(DL|LIC|license\s*(no|number|#)?|4d\s*DLN?)\b', caseSensitive: false), value: RegExp(r'[A-Z0-9]{5,15}'));
    String? state;
    final st = RegExp(r'\b(ALABAMA|ALASKA|ARIZONA|ARKANSAS|CALIFORNIA|COLORADO|CONNECTICUT|DELAWARE|FLORIDA|GEORGIA|HAWAII|IDAHO|ILLINOIS|INDIANA|IOWA|KANSAS|KENTUCKY|LOUISIANA|MAINE|MARYLAND|MASSACHUSETTS|MICHIGAN|MINNESOTA|MISSISSIPPI|MISSOURI|MONTANA|NEBRASKA|NEVADA|NEW HAMPSHIRE|NEW JERSEY|NEW MEXICO|NEW YORK|NORTH CAROLINA|NORTH DAKOTA|OHIO|OKLAHOMA|OREGON|PENNSYLVANIA|RHODE ISLAND|SOUTH CAROLINA|SOUTH DAKOTA|TENNESSEE|TEXAS|UTAH|VERMONT|VIRGINIA|WASHINGTON|WEST VIRGINIA|WISCONSIN|WYOMING)\b')
        .firstMatch(text.toUpperCase());
    if (st != null) state = _stateAbbrev[st.group(1)!];

    // Field 2 holds the given names: first, then middle name or initial.
    final given = first?.trim().split(RegExp(r'\s+')) ?? const <String>[];
    return ScannedIdentity(
      firstName: given.isEmpty ? null : _title(given.first),
      middleName: given.length > 1 ? _title(given.skip(1).join(' ')) : null,
      lastName: _title(last),
      dateOfBirth: dob,
      sex: sexRaw == null ? null : sexFromString(sexRaw),
      licenseNumber: dl,
      licenseState: state,
      state: state,
      sources: {"Driver's license"},
    );
  }

  // ---------------------------------------------------------------------------
  // Social Security card
  // ---------------------------------------------------------------------------

  /// Reads the name and keeps only the last four digits of the SSN. The full
  /// number is never stored: claims do not need it (Medicare replaced SSN-based
  /// IDs with the MBI) and holding it raises identity-theft risk.
  static ScannedIdentity parseSsnCard(String text) {
    final ssn = RegExp(r'\b(\d{3})[\s\-]?(\d{2})[\s\-]?(\d{4})\b').firstMatch(text);
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final name = lines
        .where((l) => RegExp(r"^[A-Z][A-Za-z'\-]+(\s+[A-Z]\.?)?(\s+[A-Z][A-Za-z'\-]+){1,2}$").hasMatch(l))
        .where((l) => !RegExp(r'social|security|united|states|america|account|number|established|signature', caseSensitive: false).hasMatch(l))
        .firstOrNull;
    final (first, middle, last) = _splitName(name);
    return ScannedIdentity(
      firstName: first,
      middleName: middle,
      lastName: last,
      ssnLast4: ssn?.group(3),
      sources: {'Social Security card'},
    );
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static (String?, String?, String?) _splitName(String? name) {
    if (name == null) return (null, null, null);
    var n = name.trim();
    // "LAST, FIRST M" form.
    if (n.contains(',')) {
      final parts = n.split(',');
      final rest = parts[1].trim().split(RegExp(r'\s+'));
      return (_title(rest.first), rest.length > 1 ? _title(rest.sublist(1).join(' ')) : null, _title(parts[0].trim()));
    }
    final parts = n.split(RegExp(r'\s+'));
    if (parts.length == 1) return (null, null, _title(parts.first));
    if (parts.length == 2) return (_title(parts[0]), null, _title(parts[1]));
    return (_title(parts.first), _title(parts.sublist(1, parts.length - 1).join(' ')), _title(parts.last));
  }

  static String? _title(String? s) {
    if (s == null || s.trim().isEmpty) return null;
    return s.trim().split(RegExp(r'\s+')).map((w) {
      if (w.length <= 1) return w.toUpperCase();
      final lower = w.toLowerCase();
      // Keep Mc/O' casing reasonable.
      final cased = lower[0].toUpperCase() + lower.substring(1);
      return cased.replaceAllMapped(RegExp(r"(Mc|O')([a-z])"), (m) => '${m.group(1)}${m.group(2)!.toUpperCase()}');
    }).join(' ');
  }

  static DateTime? _parseDate(String? s) {
    if (s == null) return null;
    final m = RegExp(r'(\d{1,2})[/\-](\d{1,2})[/\-](\d{2,4})').firstMatch(s);
    if (m == null) return null;
    var year = int.parse(m.group(3)!);
    if (year < 100) year += year > (DateTime.now().year % 100) ? 1900 : 2000;
    final month = int.parse(m.group(1)!);
    final day = int.parse(m.group(2)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  }

  static const _stateAbbrev = {
    'ALABAMA': 'AL', 'ALASKA': 'AK', 'ARIZONA': 'AZ', 'ARKANSAS': 'AR', 'CALIFORNIA': 'CA', 'COLORADO': 'CO', 'CONNECTICUT': 'CT',
    'DELAWARE': 'DE', 'FLORIDA': 'FL', 'GEORGIA': 'GA', 'HAWAII': 'HI', 'IDAHO': 'ID', 'ILLINOIS': 'IL', 'INDIANA': 'IN', 'IOWA': 'IA',
    'KANSAS': 'KS', 'KENTUCKY': 'KY', 'LOUISIANA': 'LA', 'MAINE': 'ME', 'MARYLAND': 'MD', 'MASSACHUSETTS': 'MA', 'MICHIGAN': 'MI',
    'MINNESOTA': 'MN', 'MISSISSIPPI': 'MS', 'MISSOURI': 'MO', 'MONTANA': 'MT', 'NEBRASKA': 'NE', 'NEVADA': 'NV', 'NEW HAMPSHIRE': 'NH',
    'NEW JERSEY': 'NJ', 'NEW MEXICO': 'NM', 'NEW YORK': 'NY', 'NORTH CAROLINA': 'NC', 'NORTH DAKOTA': 'ND', 'OHIO': 'OH', 'OKLAHOMA': 'OK',
    'OREGON': 'OR', 'PENNSYLVANIA': 'PA', 'RHODE ISLAND': 'RI', 'SOUTH CAROLINA': 'SC', 'SOUTH DAKOTA': 'SD', 'TENNESSEE': 'TN',
    'TEXAS': 'TX', 'UTAH': 'UT', 'VERMONT': 'VT', 'VIRGINIA': 'VA', 'WASHINGTON': 'WA', 'WEST VIRGINIA': 'WV', 'WISCONSIN': 'WI', 'WYOMING': 'WY',
  };
}

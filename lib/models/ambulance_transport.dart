import 'dart:math' as math;

/// A pick-up or drop-off location for an ambulance claim (837P loops 2310E
/// and 2310F: NM1, N3, N4).
class TransportAddress {
  final String? name; // facility name, drop-off only (NM103)
  final String line1;
  final String city;
  final String state; // 2-letter
  final String zip;

  const TransportAddress({this.name, this.line1 = '', this.city = '', this.state = '', this.zip = ''});

  bool get isEmpty => line1.trim().isEmpty && city.trim().isEmpty && state.trim().isEmpty && zip.trim().isEmpty;

  /// Street, city, a 2-letter state and a 5 or 9 digit ZIP: what N3 and N4 need.
  bool get isComplete {
    final digits = zip.replaceAll(RegExp(r'[^0-9]'), '');
    return line1.trim().isNotEmpty &&
        city.trim().isNotEmpty &&
        RegExp(r'^[A-Za-z]{2}$').hasMatch(state.trim()) &&
        (digits.length == 5 || digits.length == 9);
  }

  String get oneLine => [
        if (name != null && name!.trim().isNotEmpty) name!.trim(),
        line1.trim(),
        [city.trim(), [state.trim().toUpperCase(), zip.trim()].where((s) => s.isNotEmpty).join(' ')].where((s) => s.isNotEmpty).join(', '),
      ].where((s) => s.isNotEmpty).join(', ');

  TransportAddress copyWith({String? name, String? line1, String? city, String? state, String? zip}) => TransportAddress(
        name: name ?? this.name,
        line1: line1 ?? this.line1,
        city: city ?? this.city,
        state: state ?? this.state,
        zip: zip ?? this.zip,
      );

  Map<String, dynamic> toJson() => {'name': name, 'line1': line1, 'city': city, 'state': state, 'zip': zip};

  factory TransportAddress.fromJson(Map<String, dynamic> j) => TransportAddress(
        name: j['name'],
        line1: j['line1'] ?? '',
        city: j['city'] ?? '',
        state: j['state'] ?? '',
        zip: j['zip'] ?? '',
      );

  /// Builds an address from a device location fix (native geocoder fields).
  /// Returns null when the fix has no usable street address. Nothing is
  /// guessed: missing parts stay empty for the crew to fill in.
  static TransportAddress? fromGps(Map<String, dynamic>? gps) {
    if (gps == null || gps['available'] != true) return null;
    final full = gps['address']?.toString().trim() ?? '';
    final street = (gps['street']?.toString().trim().isNotEmpty ?? false) ? gps['street'].toString().trim() : (full.isEmpty ? '' : full.split(',').first.trim());
    final city = gps['locality']?.toString().trim() ?? '';
    final state = usStateCode(gps['adminArea']?.toString()) ?? '';
    final zip = gps['postalCode']?.toString().trim() ?? '';
    if (street.isEmpty && city.isEmpty) return null;
    return TransportAddress(line1: street, city: city, state: state, zip: zip);
  }
}

/// CMS ambulance origin and destination codes. The pair forms the
/// two-letter modifier on the ambulance and mileage lines (for example RH,
/// residence to hospital). Medicare Claims Processing Manual, Chapter 15,
/// section 30.A.
const Map<String, String> ambulanceLocationCodes = {
  'D': 'Diagnostic or therapeutic site',
  'E': 'Residential, domiciliary or custodial facility',
  'G': 'Hospital-based ESRD facility',
  'H': 'Hospital',
  'I': 'Site of transfer (airport or helicopter pad)',
  'J': 'Freestanding ESRD facility',
  'N': 'Skilled nursing facility',
  'P': 'Physician office',
  'R': 'Residence',
  'S': 'Scene of accident or acute event',
  'X': 'Intermediate stop at physician office (destination only)',
};

/// CR104 ambulance transport reason codes (005010X222A1).
const Map<String, String> ambulanceTransportReasons = {
  'A': 'Nearest facility for care of symptoms, complaints or both',
  'B': 'For the benefit of a preferred physician',
  'C': 'For the nearness of family members',
  'D': 'For the care of a specialist or specialized equipment',
  'E': 'To a rehabilitation facility',
};

/// CRC03 to CRC07 ambulance certification condition codes (CRC01 = 07).
const Map<String, String> ambulanceConditionCodes = {
  '01': 'Admitted to a hospital',
  '04': 'Moved by stretcher',
  '05': 'Unconscious or in shock',
  '06': 'Transported in an emergency situation',
  '07': 'Had to be physically restrained',
  '08': 'Had visible hemorrhaging',
  '09': 'Ambulance service was medically necessary',
  '12': 'Confined to bed or chair',
};

/// Transport details for a ground or air ambulance visit (POS 41 or 42).
/// Everything here comes from the crew or the phone's own location fixes;
/// nothing is defaulted.
class AmbulanceTransport {
  final TransportAddress pickup;
  final TransportAddress dropoff;

  /// Loaded miles, to a tenth of a mile.
  final double? loadedMiles;

  /// Where [loadedMiles] came from: 'gps' (sum of location fixes while
  /// recording) or 'entered'.
  final String? milesSource;

  /// Miles measured from location fixes while recording; kept even after
  /// the crew types a different value, for the audit trail.
  final double? gpsMiles;

  final String? reasonCode; // CR104, A to E
  final int? patientWeightLbs; // CR102, only when known
  final String? originCode; // ambulanceLocationCodes key
  final String? destinationCode;
  final List<String> conditionCodes; // CRC03..CRC07

  const AmbulanceTransport({
    this.pickup = const TransportAddress(),
    this.dropoff = const TransportAddress(),
    this.loadedMiles,
    this.milesSource,
    this.gpsMiles,
    this.reasonCode,
    this.patientWeightLbs,
    this.originCode,
    this.destinationCode,
    this.conditionCodes = const [],
  });

  /// Origin and destination modifier, for example RH. Null until both set.
  String? get modifier => (originCode == null || destinationCode == null) ? null : '$originCode$destinationCode';

  /// What the 837P still needs, in the order the crew would fill it in.
  List<String> get missing => [
        if (!pickup.isComplete) 'pick-up address',
        if (!dropoff.isComplete) 'drop-off address',
        if (loadedMiles == null || loadedMiles! <= 0) 'loaded miles',
        if (reasonCode == null) 'transport reason',
      ];

  bool get isComplete => missing.isEmpty;

  AmbulanceTransport copyWith({
    TransportAddress? pickup,
    TransportAddress? dropoff,
    double? loadedMiles,
    bool clearMiles = false,
    String? milesSource,
    double? gpsMiles,
    String? reasonCode,
    int? patientWeightLbs,
    bool clearWeight = false,
    String? originCode,
    String? destinationCode,
    List<String>? conditionCodes,
  }) =>
      AmbulanceTransport(
        pickup: pickup ?? this.pickup,
        dropoff: dropoff ?? this.dropoff,
        loadedMiles: clearMiles ? null : (loadedMiles ?? this.loadedMiles),
        milesSource: clearMiles ? null : (milesSource ?? this.milesSource),
        gpsMiles: gpsMiles ?? this.gpsMiles,
        reasonCode: reasonCode ?? this.reasonCode,
        patientWeightLbs: clearWeight ? null : (patientWeightLbs ?? this.patientWeightLbs),
        originCode: originCode ?? this.originCode,
        destinationCode: destinationCode ?? this.destinationCode,
        conditionCodes: conditionCodes ?? this.conditionCodes,
      );

  Map<String, dynamic> toJson() => {
        'pickup': pickup.toJson(),
        'dropoff': dropoff.toJson(),
        'loadedMiles': loadedMiles,
        'milesSource': milesSource,
        'gpsMiles': gpsMiles,
        'reasonCode': reasonCode,
        'patientWeightLbs': patientWeightLbs,
        'originCode': originCode,
        'destinationCode': destinationCode,
        'conditionCodes': conditionCodes,
      };

  factory AmbulanceTransport.fromJson(Map<String, dynamic> j) => AmbulanceTransport(
        pickup: j['pickup'] is Map ? TransportAddress.fromJson((j['pickup'] as Map).cast<String, dynamic>()) : const TransportAddress(),
        dropoff: j['dropoff'] is Map ? TransportAddress.fromJson((j['dropoff'] as Map).cast<String, dynamic>()) : const TransportAddress(),
        loadedMiles: (j['loadedMiles'] as num?)?.toDouble(),
        milesSource: j['milesSource'],
        gpsMiles: (j['gpsMiles'] as num?)?.toDouble(),
        reasonCode: j['reasonCode'],
        patientWeightLbs: (j['patientWeightLbs'] as num?)?.toInt(),
        originCode: j['originCode'],
        destinationCode: j['destinationCode'],
        conditionCodes: List<String>.from(j['conditionCodes'] ?? const []),
      );
}

/// Rounds miles up to the next tenth (CMS: fractional mileage to 0.1 mile).
double roundUpTenth(double miles) => (miles * 10 - 1e-9).ceil() / 10;

/// Great-circle distance in statute miles between two fixes.
double haversineMiles(double lat1, double lng1, double lat2, double lng2) {
  const r = 3958.7613; // mean Earth radius in statute miles
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1);
  final dLng = rad(lng2 - lng1);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.sin(dLng / 2) * math.sin(dLng / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// Sums a track of location fixes into miles. Fixes worse than
/// [maxAccuracyMeters] are skipped so GPS jitter does not add distance.
double trackMiles(List<Map<String, dynamic>> fixes, {double maxAccuracyMeters = 50}) {
  var total = 0.0;
  Map<String, dynamic>? prev;
  for (final f in fixes) {
    if (f['available'] != true) continue;
    final acc = (f['accuracy'] as num?)?.toDouble();
    if (acc != null && acc > maxAccuracyMeters) continue;
    final lat = (f['latitude'] as num?)?.toDouble();
    final lng = (f['longitude'] as num?)?.toDouble();
    if (lat == null || lng == null) continue;
    if (prev != null) {
      total += haversineMiles((prev['latitude'] as num).toDouble(), (prev['longitude'] as num).toDouble(), lat, lng);
    }
    prev = f;
  }
  return total;
}

const Map<String, String> _usStates = {
  'alabama': 'AL', 'alaska': 'AK', 'arizona': 'AZ', 'arkansas': 'AR', 'california': 'CA', 'colorado': 'CO',
  'connecticut': 'CT', 'delaware': 'DE', 'district of columbia': 'DC', 'florida': 'FL', 'georgia': 'GA', 'hawaii': 'HI',
  'idaho': 'ID', 'illinois': 'IL', 'indiana': 'IN', 'iowa': 'IA', 'kansas': 'KS', 'kentucky': 'KY', 'louisiana': 'LA',
  'maine': 'ME', 'maryland': 'MD', 'massachusetts': 'MA', 'michigan': 'MI', 'minnesota': 'MN', 'mississippi': 'MS',
  'missouri': 'MO', 'montana': 'MT', 'nebraska': 'NE', 'nevada': 'NV', 'new hampshire': 'NH', 'new jersey': 'NJ',
  'new mexico': 'NM', 'new york': 'NY', 'north carolina': 'NC', 'north dakota': 'ND', 'ohio': 'OH', 'oklahoma': 'OK',
  'oregon': 'OR', 'pennsylvania': 'PA', 'rhode island': 'RI', 'south carolina': 'SC', 'south dakota': 'SD',
  'tennessee': 'TN', 'texas': 'TX', 'utah': 'UT', 'vermont': 'VT', 'virginia': 'VA', 'washington': 'WA',
  'west virginia': 'WV', 'wisconsin': 'WI', 'wyoming': 'WY', 'puerto rico': 'PR',
};

/// "California" or "CA" to "CA"; null when not a US state.
String? usStateCode(String? name) {
  final n = (name ?? '').trim();
  if (RegExp(r'^[A-Za-z]{2}$').hasMatch(n) && _usStates.containsValue(n.toUpperCase())) return n.toUpperCase();
  return _usStates[n.toLowerCase()];
}

/// The rendering and billing provider. Feeds CMS-1500 boxes 24J, 25, 31-33.
class ProviderProfile {
  final String fullName; // e.g. Sarah Lin
  final String credentials; // MD, DO, NP, PA
  final String npi; // individual (Type 1) NPI, box 24J
  final String? groupNpi; // organization (Type 2) NPI, box 33a when billing as a group
  final String taxId; // EIN NN-NNNNNNN, box 25
  final String taxonomyCode; // e.g. 207Q00000X family medicine, PRV segment
  final String specialty;
  final String practiceName;
  final String addressLine1;
  final String city;
  final String state;
  final String zip;
  final String phone;
  final String defaultPlaceOfService; // POS code used for new visits
  final List<String> acceptedPayers; // payers the provider is credentialed with
  final Map<String, double> feeSchedule; // CPT/HCPCS -> charge
  final bool enforceSexEdits; // treat sex-specific code conflicts as errors
  final bool blockScreenshots; // FLAG_SECURE: no screenshots, recording or previews
  final List<SavedPlace> savedPlaces; // places that set POS and facility from a location fix
  final bool preferOnDevice; // write notes on this phone by default

  /// Diagnoses the clinician starred, code to description, in the order
  /// they were added. Code search lists them first.
  final Map<String, String> favoriteDiagnoses;

  /// Services (CPT/HCPCS) the clinician starred.
  final List<String> favoriteServices;

  const ProviderProfile({
    required this.fullName,
    required this.credentials,
    required this.npi,
    required this.taxId,
    required this.taxonomyCode,
    required this.specialty,
    required this.practiceName,
    required this.addressLine1,
    required this.city,
    required this.state,
    required this.zip,
    required this.phone,
    this.groupNpi,
    this.defaultPlaceOfService = '11',
    this.acceptedPayers = const [],
    this.feeSchedule = const {},
    this.enforceSexEdits = true,
    this.blockScreenshots = false,
    this.savedPlaces = const [],
    this.preferOnDevice = false,
    this.favoriteDiagnoses = const {},
    this.favoriteServices = const [],
  });

  /// Stars or unstars a diagnosis.
  ProviderProfile toggleFavoriteDiagnosis(String code, String description) {
    final key = code.trim().toUpperCase();
    final next = {...favoriteDiagnoses};
    if (next.remove(key) == null) next[key] = description;
    return copyWith(favoriteDiagnoses: next);
  }

  /// Stars or unstars a service code.
  ProviderProfile toggleFavoriteService(String code) {
    final key = code.trim().toUpperCase();
    return copyWith(favoriteServices: favoriteServices.contains(key) ? favoriteServices.where((c) => c != key).toList() : [...favoriteServices, key]);
  }

  String get displayName => credentials.isEmpty ? 'Dr. $fullName' : '$fullName, $credentials';

  String get initials {
    final parts = fullName.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
  }

  static const Map<String, double> defaultFees = {
    '99202': 110, '99203': 170, '99204': 260, '99205': 340,
    '99212': 90, '99213': 140, '99214': 210, '99215': 290,
    '99282': 110, '99283': 190, '99284': 330, '99285': 480,
    '99304': 160, '99305': 230, '99306': 300, '99307': 70, '99308': 110, '99309': 160, '99310': 230,
    '99341': 120, '99342': 170, '99344': 280, '99345': 350, '99347': 110, '99348': 160, '99349': 230, '99350': 320,
    '99221': 200, '99222': 270, '99223': 380, '99231': 90, '99232': 140, '99233': 210,
    '93000': 45, '93010': 20, '20610': 140, '94640': 35, '87880': 30, '81002': 15, '36415': 12,
    'A0427': 650, 'A0429': 480, 'A0425': 12,
  };

  /// Starting profile shown until the provider fills in their own details.
  static ProviderProfile demo() => const ProviderProfile(
        fullName: 'Sarah Lin',
        credentials: 'MD',
        npi: '1982736450',
        taxId: '84-1234567',
        taxonomyCode: '207Q00000X',
        specialty: 'Family Medicine',
        practiceName: 'Bayview Family Medicine',
        addressLine1: '450 Mission Bay Blvd',
        city: 'San Francisco',
        state: 'CA',
        zip: '94158',
        phone: '(415) 555-0142',
        acceptedPayers: ['Aetna', 'Blue Cross Blue Shield', 'Cigna', 'Medicare', 'UnitedHealthcare'],
        feeSchedule: defaultFees,
      );

  /// NPI and tax ID of the demo provider. A claim carrying either outside
  /// demo mode would bill under a fictional identity.
  static const demoNpi = '1982736450';
  static const demoTaxId = '84-1234567';

  /// A real clinician's starting profile: nothing filled in, so nothing on a
  /// claim is fictional. The fee schedule is the editable placeholder list.
  static ProviderProfile empty() => const ProviderProfile(
        fullName: '',
        credentials: '',
        npi: '',
        taxId: '',
        taxonomyCode: '',
        specialty: '',
        practiceName: '',
        addressLine1: '',
        city: '',
        state: '',
        zip: '',
        phone: '',
        feeSchedule: defaultFees,
      );

  /// True when this profile carries the demo provider's NPI or tax ID.
  bool get isDemoIdentity => npi.trim() == demoNpi || taxId.trim() == demoTaxId;

  /// What a claim still needs from the profile, in form order. Empty when the
  /// profile can bill.
  List<String> get missingForClaims {
    final zipDigits = zip.replaceAll(RegExp(r'[^0-9]'), '');
    return [
      if (fullName.trim().isEmpty) 'Full name',
      if (!isValidNpi(npi.trim())) 'Individual NPI',
      if (taxonomyCode.trim().length != 10) 'Specialty',
      if (practiceName.trim().isEmpty) 'Practice name',
      if (!isValidEin(taxId)) 'Tax ID (EIN)',
      if (addressLine1.trim().isEmpty) 'Street address',
      if (city.trim().isEmpty) 'City',
      if (!RegExp(r'^[A-Za-z]{2}$').hasMatch(state.trim())) 'State',
      if (zipDigits.length != 5 && zipDigits.length != 9) 'ZIP',
    ];
  }

  /// A real billing identity: every claim field present and valid.
  bool get isComplete => missingForClaims.isEmpty;

  ProviderProfile copyWith({
    String? fullName,
    String? credentials,
    String? npi,
    String? groupNpi,
    String? taxId,
    String? taxonomyCode,
    String? specialty,
    String? practiceName,
    String? addressLine1,
    String? city,
    String? state,
    String? zip,
    String? phone,
    String? defaultPlaceOfService,
    List<String>? acceptedPayers,
    Map<String, double>? feeSchedule,
    bool? enforceSexEdits,
    bool? blockScreenshots,
    List<SavedPlace>? savedPlaces,
    bool? preferOnDevice,
    Map<String, String>? favoriteDiagnoses,
    List<String>? favoriteServices,
  }) =>
      ProviderProfile(
        fullName: fullName ?? this.fullName,
        credentials: credentials ?? this.credentials,
        npi: npi ?? this.npi,
        groupNpi: groupNpi ?? this.groupNpi,
        taxId: taxId ?? this.taxId,
        taxonomyCode: taxonomyCode ?? this.taxonomyCode,
        specialty: specialty ?? this.specialty,
        practiceName: practiceName ?? this.practiceName,
        addressLine1: addressLine1 ?? this.addressLine1,
        city: city ?? this.city,
        state: state ?? this.state,
        zip: zip ?? this.zip,
        phone: phone ?? this.phone,
        defaultPlaceOfService: defaultPlaceOfService ?? this.defaultPlaceOfService,
        acceptedPayers: acceptedPayers ?? this.acceptedPayers,
        feeSchedule: feeSchedule ?? this.feeSchedule,
        enforceSexEdits: enforceSexEdits ?? this.enforceSexEdits,
        blockScreenshots: blockScreenshots ?? this.blockScreenshots,
        savedPlaces: savedPlaces ?? this.savedPlaces,
        preferOnDevice: preferOnDevice ?? this.preferOnDevice,
        favoriteDiagnoses: favoriteDiagnoses ?? this.favoriteDiagnoses,
        favoriteServices: favoriteServices ?? this.favoriteServices,
      );

  Map<String, dynamic> toJson() => {
        'fullName': fullName,
        'credentials': credentials,
        'npi': npi,
        'groupNpi': groupNpi,
        'taxId': taxId,
        'taxonomyCode': taxonomyCode,
        'specialty': specialty,
        'practiceName': practiceName,
        'addressLine1': addressLine1,
        'city': city,
        'state': state,
        'zip': zip,
        'phone': phone,
        'defaultPlaceOfService': defaultPlaceOfService,
        'acceptedPayers': acceptedPayers,
        'feeSchedule': feeSchedule,
        'enforceSexEdits': enforceSexEdits,
        'blockScreenshots': blockScreenshots,
        'savedPlaces': savedPlaces.map((p) => p.toJson()).toList(),
        'preferOnDevice': preferOnDevice,
        if (favoriteDiagnoses.isNotEmpty) 'favoriteDiagnoses': favoriteDiagnoses,
        if (favoriteServices.isNotEmpty) 'favoriteServices': favoriteServices,
      };

  factory ProviderProfile.fromJson(Map<String, dynamic> j) => ProviderProfile(
        fullName: j['fullName'] ?? '',
        credentials: j['credentials'] ?? '',
        npi: j['npi'] ?? '',
        groupNpi: j['groupNpi'],
        taxId: j['taxId'] ?? '',
        taxonomyCode: j['taxonomyCode'] ?? '',
        specialty: j['specialty'] ?? '',
        practiceName: j['practiceName'] ?? '',
        addressLine1: j['addressLine1'] ?? '',
        city: j['city'] ?? '',
        state: j['state'] ?? '',
        zip: j['zip'] ?? '',
        phone: j['phone'] ?? '',
        defaultPlaceOfService: j['defaultPlaceOfService'] ?? '11',
        acceptedPayers: List<String>.from(j['acceptedPayers'] ?? const []),
        feeSchedule: {
          for (final e in ((j['feeSchedule'] as Map?) ?? const {}).entries) e.key.toString(): (e.value as num).toDouble(),
        },
        enforceSexEdits: j['enforceSexEdits'] ?? true,
        blockScreenshots: j['blockScreenshots'] ?? false,
        savedPlaces: [for (final p in (j['savedPlaces'] as List? ?? const [])) SavedPlace.fromJson((p as Map).cast<String, dynamic>())],
        preferOnDevice: j['preferOnDevice'] == true,
        favoriteDiagnoses: {for (final e in ((j['favoriteDiagnoses'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
        favoriteServices: [for (final c in (j['favoriteServices'] as List? ?? const [])) '$c'],
      );
}

/// A place the clinician works (clinic, nursing home, hospital). When the
/// phone's location fix falls inside [radiusMeters], a new visit there takes
/// its place of service.
class SavedPlace {
  final String id;
  final String name;
  final String placeOfService;
  final double latitude;
  final double longitude;
  final double radiusMeters;
  final String? address;

  const SavedPlace({
    required this.id,
    required this.name,
    required this.placeOfService,
    required this.latitude,
    required this.longitude,
    this.radiusMeters = 150,
    this.address,
  });

  SavedPlace copyWith({String? name, String? placeOfService, double? radiusMeters, String? address}) => SavedPlace(
        id: id,
        name: name ?? this.name,
        placeOfService: placeOfService ?? this.placeOfService,
        latitude: latitude,
        longitude: longitude,
        radiusMeters: radiusMeters ?? this.radiusMeters,
        address: address ?? this.address,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'placeOfService': placeOfService,
        'latitude': latitude,
        'longitude': longitude,
        'radiusMeters': radiusMeters,
        'address': address,
      };

  factory SavedPlace.fromJson(Map<String, dynamic> j) => SavedPlace(
        id: j['id']?.toString() ?? '',
        name: j['name'] ?? '',
        placeOfService: j['placeOfService'] ?? '11',
        latitude: (j['latitude'] as num?)?.toDouble() ?? 0,
        longitude: (j['longitude'] as num?)?.toDouble() ?? 0,
        radiusMeters: (j['radiusMeters'] as num?)?.toDouble() ?? 150,
        address: j['address'],
      );
}

/// Common specialties and their NUCC taxonomy codes.
const Map<String, String> specialtyTaxonomy = {
  'Family Medicine': '207Q00000X',
  'Internal Medicine': '207R00000X',
  'Cardiovascular Disease': '207RC0000X',
  'Emergency Medicine': '207P00000X',
  'Pediatrics': '208000000X',
  'Obstetrics and Gynecology': '207V00000X',
  'Neurology': '2084N0400X',
  'Orthopaedic Surgery': '207X00000X',
  'Endocrinology': '207RE0101X',
  'Urology': '208800000X',
  'Nurse Practitioner, Family': '363LF0000X',
  'Physician Assistant, Medical': '363AM0700X',
};

/// Validates an NPI with the CMS Luhn check (prefix 80840).
bool isValidNpi(String npi) {
  if (!RegExp(r'^\d{10}$').hasMatch(npi)) return false;
  final full = '80840$npi';
  var sum = 0;
  var alt = false;
  for (var i = full.length - 1; i >= 0; i--) {
    var d = int.parse(full[i]);
    if (alt) {
      d *= 2;
      if (d > 9) d -= 9;
    }
    sum += d;
    alt = !alt;
  }
  return sum % 10 == 0;
}

/// EIN format NN-NNNNNNN.
bool isValidEin(String tin) => RegExp(r'^\d{2}-?\d{7}$').hasMatch(tin.trim());

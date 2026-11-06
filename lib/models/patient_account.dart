import 'ambulance_transport.dart';
import 'claim_models.dart';

/// Biological sex as used on claims (CMS-1500 box 3, 837P DMG03).
enum PatientSex { male, female, unknown }

/// Placeholder first name of a patient registered before they can be
/// identified (EMS, ED). The claim checks keep such an account from being
/// billed until a name, date of birth, sex and coverage are entered.
const unidentifiedFirstName = 'Unidentified';

/// A unique placeholder name for an unidentified patient registered at
/// [now]: first name "Unidentified", last name "Patient 1106-1442"
/// (month, day, hour, minute), so two arrivals are told apart.
({String first, String last}) unidentifiedName(DateTime now) {
  String two(int n) => n.toString().padLeft(2, '0');
  return (first: unidentifiedFirstName, last: 'Patient ${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}');
}

PatientSex sexFromString(String? s) {
  switch ((s ?? '').trim().toUpperCase()) {
    case 'M':
    case 'MALE':
    case '1':
      return PatientSex.male;
    case 'F':
    case 'FEMALE':
    case '2':
      return PatientSex.female;
    default:
      return PatientSex.unknown;
  }
}

String sexCode(PatientSex s) => switch (s) { PatientSex.male => 'M', PatientSex.female => 'F', PatientSex.unknown => 'U' };

/// Insurance coverage read from the member's card.
class InsuranceCoverage {
  final String payerName;
  final String? payerId; // EDI payer ID, when printed on the card
  final String? planName;
  final String? planType; // PPO, HMO, EPO, POS, Medicare, Medicaid
  final String memberId;
  final String? groupNumber;
  final String? subscriberName;
  final String relationship; // self, spouse, child, other (box 6)
  final String? rxBin;
  final String? rxPcn;
  final String? rxGroup;
  final String? effectiveDate;
  final Map<String, String> copays; // e.g. {'PCP': '\$25', 'Specialist': '\$50'}

  const InsuranceCoverage({
    required this.payerName,
    required this.memberId,
    this.payerId,
    this.planName,
    this.planType,
    this.groupNumber,
    this.subscriberName,
    this.relationship = 'self',
    this.rxBin,
    this.rxPcn,
    this.rxGroup,
    this.effectiveDate,
    this.copays = const {},
  });

  Map<String, dynamic> toJson() => {
        'payerName': payerName,
        'payerId': payerId,
        'planName': planName,
        'planType': planType,
        'memberId': memberId,
        'groupNumber': groupNumber,
        'subscriberName': subscriberName,
        'relationship': relationship,
        'rxBin': rxBin,
        'rxPcn': rxPcn,
        'rxGroup': rxGroup,
        'effectiveDate': effectiveDate,
        'copays': copays,
      };

  factory InsuranceCoverage.fromJson(Map<String, dynamic> j) => InsuranceCoverage(
        payerName: j['payerName'] ?? '',
        memberId: j['memberId'] ?? '',
        payerId: j['payerId'],
        planName: j['planName'],
        planType: j['planType'],
        groupNumber: j['groupNumber'],
        subscriberName: j['subscriberName'],
        relationship: j['relationship'] ?? 'self',
        rxBin: j['rxBin'],
        rxPcn: j['rxPcn'],
        rxGroup: j['rxGroup'],
        effectiveDate: j['effectiveDate'],
        copays: Map<String, String>.from(j['copays'] ?? const {}),
      );
}

/// Order matters: everything after [claimReady] means the claim left the
/// physician's hands ([queued] waits in the outbox for a connection).
enum VisitStatus { inProgress, signed, claimReady, queued, submitted, rejected, paid, denied }

String visitStatusLabel(VisitStatus s) => switch (s) {
      VisitStatus.inProgress => 'In progress',
      VisitStatus.signed => 'Signed',
      VisitStatus.claimReady => 'Claim ready',
      VisitStatus.queued => 'Queued',
      VisitStatus.submitted => 'Submitted',
      VisitStatus.rejected => 'Rejected',
      VisitStatus.paid => 'Paid',
      VisitStatus.denied => 'Denied',
    };

/// How the patient agreed to be recorded.
class ConsentRecord {
  final String method; // verbal, signature, declined
  final DateTime atUtc;
  final String? signedBy; // name typed by the patient or representative
  final String? relationship; // self, parent, guardian, representative
  final List<List<double>>? signature; // strokes as x,y pairs, 0..1 normalized, with -1 as pen-up
  final Map<String, dynamic>? location;
  final String language;

  const ConsentRecord({
    required this.method,
    required this.atUtc,
    this.signedBy,
    this.relationship,
    this.signature,
    this.location,
    this.language = 'en',
  });

  Map<String, dynamic> toJson() => {
        'method': method,
        'atUtc': atUtc.toIso8601String(),
        'signedBy': signedBy,
        'relationship': relationship,
        'signature': signature,
        'location': location,
        'language': language,
      };

  /// The patient was asked and said no. Kept so the audit trail shows it.
  bool get declined => method == 'declined';

  factory ConsentRecord.fromJson(Map<String, dynamic> j) => ConsentRecord(
        method: j['method'] ?? 'verbal',
        atUtc: DateTime.tryParse(j['atUtc'] ?? '') ?? DateTime.now().toUtc(),
        signedBy: j['signedBy'],
        relationship: j['relationship'],
        signature: (j['signature'] as List?)?.map((s) => (s as List).map((v) => (v as num).toDouble()).toList()).toList(),
        location: (j['location'] as Map?)?.cast<String, dynamic>(),
        language: j['language'] ?? 'en',
      );
}

/// One date of service under an account: Visit 1, Visit 2, ...
class Visit {
  final int number;
  final String dateOfService; // yyyy-MM-dd
  final String placeOfService; // CMS POS code, e.g. '11'
  final DateTime createdAtUtc;
  final VisitStatus status;
  final Map<String, dynamic>? encounter; // ClinicalEncounter JSON
  final String transcript; // raw captured text
  final ClaimDraft? claim;
  final bool consentConfirmed;
  final DateTime? consentAtUtc;
  final ConsentRecord? consent;
  final Map<String, dynamic>? eligibility; // last eligibility check summary
  final Map<String, dynamic>? submission; // last clearinghouse submission and status
  final AmbulanceTransport? transport; // POS 41/42: pick-up, drop-off, miles

  /// How the place of service was chosen: 'place', 'last visit', 'default'
  /// or 'manual'. A manual choice is never changed automatically.
  final String? posSource;

  const Visit({
    required this.number,
    required this.dateOfService,
    required this.placeOfService,
    required this.createdAtUtc,
    this.status = VisitStatus.inProgress,
    this.encounter,
    this.transcript = '',
    this.claim,
    this.consentConfirmed = false,
    this.consentAtUtc,
    this.consent,
    this.eligibility,
    this.submission,
    this.transport,
    this.posSource,
  });

  Visit copyWith({
    String? dateOfService,
    String? placeOfService,
    VisitStatus? status,
    Map<String, dynamic>? encounter,
    String? transcript,
    ClaimDraft? claim,
    bool clearClaim = false,
    bool? consentConfirmed,
    DateTime? consentAtUtc,
    ConsentRecord? consent,
    Map<String, dynamic>? eligibility,
    Map<String, dynamic>? submission,
    AmbulanceTransport? transport,
    String? posSource,
  }) =>
      Visit(
        number: number,
        dateOfService: dateOfService ?? this.dateOfService,
        placeOfService: placeOfService ?? this.placeOfService,
        createdAtUtc: createdAtUtc,
        status: status ?? this.status,
        encounter: encounter ?? this.encounter,
        transcript: transcript ?? this.transcript,
        claim: clearClaim ? null : (claim ?? this.claim),
        consentConfirmed: consentConfirmed ?? this.consentConfirmed,
        consentAtUtc: consentAtUtc ?? this.consentAtUtc,
        consent: consent ?? this.consent,
        eligibility: eligibility ?? this.eligibility,
        submission: submission ?? this.submission,
        transport: transport ?? this.transport,
        posSource: posSource ?? this.posSource,
      );

  Map<String, dynamic> toJson() => {
        'number': number,
        'dateOfService': dateOfService,
        'placeOfService': placeOfService,
        'createdAtUtc': createdAtUtc.toIso8601String(),
        'status': status.name,
        'encounter': encounter,
        'transcript': transcript,
        'claim': claim?.toJson(),
        'consentConfirmed': consentConfirmed,
        'consentAtUtc': consentAtUtc?.toIso8601String(),
        'consent': consent?.toJson(),
        'eligibility': eligibility,
        'submission': submission,
        'transport': transport?.toJson(),
        'posSource': posSource,
      };

  factory Visit.fromJson(Map<String, dynamic> j) => Visit(
        number: j['number'] as int,
        dateOfService: j['dateOfService'] as String,
        placeOfService: j['placeOfService'] ?? '11',
        createdAtUtc: DateTime.tryParse(j['createdAtUtc'] ?? '') ?? DateTime.now().toUtc(),
        status: VisitStatus.values.firstWhere((s) => s.name == j['status'], orElse: () => VisitStatus.inProgress),
        encounter: (j['encounter'] as Map?)?.cast<String, dynamic>(),
        transcript: j['transcript'] ?? '',
        claim: j['claim'] == null ? null : ClaimDraft.fromJson((j['claim'] as Map).cast<String, dynamic>()),
        consentConfirmed: j['consentConfirmed'] == true,
        consentAtUtc: DateTime.tryParse(j['consentAtUtc'] ?? ''),
        consent: j['consent'] == null ? null : ConsentRecord.fromJson((j['consent'] as Map).cast<String, dynamic>()),
        eligibility: (j['eligibility'] as Map?)?.cast<String, dynamic>(),
        submission: (j['submission'] as Map?)?.cast<String, dynamic>(),
        transport: j['transport'] is Map ? AmbulanceTransport.fromJson((j['transport'] as Map).cast<String, dynamic>()) : null,
        posSource: j['posSource'],
      );
}

/// A patient's account: demographics, coverage and every visit.
class PatientAccount {
  final String accountNumber; // e.g. SOL-1000017 (box 26, patient account no.)
  final String firstName;
  final String lastName;
  final String? middleName;
  final DateTime? dateOfBirth;
  final PatientSex sex;
  final String? addressLine1;
  final String? city;
  final String? state;
  final String? zip;
  final String? phone;
  final String? driverLicenseNumber;
  final String? driverLicenseState;
  final String? ssnLast4; // never the full SSN
  final InsuranceCoverage? insurance;
  final List<Visit> visits;
  final DateTime createdAtUtc;
  final String? sampleConversationKey; // demo accounts only

  /// Belongs to demo mode (seeded sample patients and patients added while
  /// trying the demo). Never shown or billed for a signed-in clinician.
  final bool isSample;

  /// Set when the patient was deleted; the account is kept, hidden, for
  /// [AccountRepository.softDeleteWindow] so it can be restored.
  final DateTime? deletedAtUtc;

  const PatientAccount({
    required this.accountNumber,
    required this.firstName,
    required this.lastName,
    required this.createdAtUtc,
    this.middleName,
    this.dateOfBirth,
    this.sex = PatientSex.unknown,
    this.addressLine1,
    this.city,
    this.state,
    this.zip,
    this.phone,
    this.driverLicenseNumber,
    this.driverLicenseState,
    this.ssnLast4,
    this.insurance,
    this.visits = const [],
    this.sampleConversationKey,
    this.isSample = false,
    this.deletedAtUtc,
  });

  bool get isDeleted => deletedAtUtc != null;

  /// Registered with a placeholder name (see [unidentifiedName]).
  bool get isUnidentified => firstName == unidentifiedFirstName && lastName.startsWith('Patient ');

  String get fullName => [firstName, if (middleName != null && middleName!.isNotEmpty) middleName, lastName].join(' ');

  /// Age in whole years on [on] (defaults to today), or null without a DOB.
  int? ageOn([DateTime? on]) {
    final dob = dateOfBirth;
    if (dob == null) return null;
    final d = on ?? DateTime.now();
    var age = d.year - dob.year;
    if (d.month < dob.month || (d.month == dob.month && d.day < dob.day)) age--;
    return age;
  }

  String get ageSex {
    final age = ageOn();
    return '${age ?? '?'}${sexCode(sex)}';
  }

  Visit? visit(int number) {
    for (final v in visits) {
      if (v.number == number) return v;
    }
    return null;
  }

  PatientAccount copyWith({
    String? firstName,
    String? lastName,
    String? middleName,
    DateTime? dateOfBirth,
    PatientSex? sex,
    String? addressLine1,
    String? city,
    String? state,
    String? zip,
    String? phone,
    String? driverLicenseNumber,
    String? driverLicenseState,
    String? ssnLast4,
    InsuranceCoverage? insurance,
    List<Visit>? visits,
    DateTime? deletedAtUtc,
    bool restore = false,
  }) =>
      PatientAccount(
        accountNumber: accountNumber,
        createdAtUtc: createdAtUtc,
        sampleConversationKey: sampleConversationKey,
        isSample: isSample,
        deletedAtUtc: restore ? null : (deletedAtUtc ?? this.deletedAtUtc),
        firstName: firstName ?? this.firstName,
        lastName: lastName ?? this.lastName,
        middleName: middleName ?? this.middleName,
        dateOfBirth: dateOfBirth ?? this.dateOfBirth,
        sex: sex ?? this.sex,
        addressLine1: addressLine1 ?? this.addressLine1,
        city: city ?? this.city,
        state: state ?? this.state,
        zip: zip ?? this.zip,
        phone: phone ?? this.phone,
        driverLicenseNumber: driverLicenseNumber ?? this.driverLicenseNumber,
        driverLicenseState: driverLicenseState ?? this.driverLicenseState,
        ssnLast4: ssnLast4 ?? this.ssnLast4,
        insurance: insurance ?? this.insurance,
        visits: visits ?? this.visits,
      );

  Map<String, dynamic> toJson() => {
        'accountNumber': accountNumber,
        'firstName': firstName,
        'lastName': lastName,
        'middleName': middleName,
        'dateOfBirth': dateOfBirth?.toIso8601String().split('T').first,
        'sex': sexCode(sex),
        'addressLine1': addressLine1,
        'city': city,
        'state': state,
        'zip': zip,
        'phone': phone,
        'driverLicenseNumber': driverLicenseNumber,
        'driverLicenseState': driverLicenseState,
        'ssnLast4': ssnLast4,
        'insurance': insurance?.toJson(),
        'visits': visits.map((v) => v.toJson()).toList(),
        'createdAtUtc': createdAtUtc.toIso8601String(),
        'sampleConversationKey': sampleConversationKey,
        'isSample': isSample,
        'deletedAtUtc': deletedAtUtc?.toIso8601String(),
      };

  factory PatientAccount.fromJson(Map<String, dynamic> j) => PatientAccount(
        accountNumber: j['accountNumber'],
        firstName: j['firstName'] ?? '',
        lastName: j['lastName'] ?? '',
        middleName: j['middleName'],
        dateOfBirth: DateTime.tryParse(j['dateOfBirth'] ?? ''),
        sex: sexFromString(j['sex']),
        addressLine1: j['addressLine1'],
        city: j['city'],
        state: j['state'],
        zip: j['zip'],
        phone: j['phone'],
        driverLicenseNumber: j['driverLicenseNumber'],
        driverLicenseState: j['driverLicenseState'],
        ssnLast4: j['ssnLast4'],
        insurance: j['insurance'] == null ? null : InsuranceCoverage.fromJson((j['insurance'] as Map).cast<String, dynamic>()),
        visits: [for (final v in (j['visits'] as List? ?? const [])) Visit.fromJson((v as Map).cast<String, dynamic>())],
        createdAtUtc: DateTime.tryParse(j['createdAtUtc'] ?? '') ?? DateTime.now().toUtc(),
        sampleConversationKey: j['sampleConversationKey'],
        // Older stores marked seeded patients only by their sample conversation.
        isSample: j['isSample'] ?? (j['sampleConversationKey'] != null),
        deletedAtUtc: DateTime.tryParse(j['deletedAtUtc'] ?? ''),
      );
}

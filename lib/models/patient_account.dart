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

/// A recording in progress, saved every few seconds while it runs. Still set
/// when the visit is opened again means the recording was cut off (the app
/// was closed, killed or crashed); the transcript saved with it is kept.
class RecordingCheckpoint {
  final DateTime startedAtUtc;
  final DateTime savedAtUtc;
  final int seconds; // recorded time, pauses excluded

  const RecordingCheckpoint({required this.startedAtUtc, required this.savedAtUtc, required this.seconds});

  Map<String, dynamic> toJson() => {
        'startedAtUtc': startedAtUtc.toIso8601String(),
        'savedAtUtc': savedAtUtc.toIso8601String(),
        'seconds': seconds,
      };

  static RecordingCheckpoint? fromJson(Object? j) {
    if (j is! Map) return null;
    final started = DateTime.tryParse('${j['startedAtUtc'] ?? ''}');
    final saved = DateTime.tryParse('${j['savedAtUtc'] ?? ''}');
    if (started == null || saved == null) return null;
    return RecordingCheckpoint(startedAtUtc: started, savedAtUtc: saved, seconds: (j['seconds'] as num?)?.toInt() ?? 0);
  }
}

/// The clinician's confirmation of the E/M level and codes on a claim.
/// Valid only for the codes it names: [fingerprint] is
/// [ClaimDraft.codeFingerprint] at the time of the confirmation.
class CodeConfirmation {
  final DateTime atUtc;
  final String by;
  final String fingerprint;
  final String codes;

  const CodeConfirmation({required this.atUtc, required this.by, required this.fingerprint, required this.codes});

  Map<String, dynamic> toJson() => {'atUtc': atUtc.toIso8601String(), 'by': by, 'fingerprint': fingerprint, 'codes': codes};

  static CodeConfirmation? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['atUtc'] ?? ''}');
    if (at == null || j['fingerprint'] == null) return null;
    return CodeConfirmation(atUtc: at, by: '${j['by'] ?? ''}', fingerprint: '${j['fingerprint']}', codes: '${j['codes'] ?? ''}');
  }
}

/// One line of a visit's audit trail: who did what, and when.
class AuditEvent {
  final DateTime atUtc;
  final String by;
  final String action;
  final String detail;

  const AuditEvent({required this.atUtc, required this.by, required this.action, this.detail = ''});

  Map<String, dynamic> toJson() => {'atUtc': atUtc.toIso8601String(), 'by': by, 'action': action, if (detail.isNotEmpty) 'detail': detail};

  static AuditEvent? fromJson(Object? j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['atUtc'] ?? ''}');
    if (at == null) return null;
    return AuditEvent(atUtc: at, by: '${j['by'] ?? ''}', action: '${j['action'] ?? ''}', detail: '${j['detail'] ?? ''}');
  }

  /// One line for an exported audit trail (UTC, tab separated).
  String toLine() => [atUtc.toIso8601String(), by, action, detail].join('\t');
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

  /// Referring or ordering provider, when the service needs one (box 17).
  final ReferringProvider? referringProvider;

  /// The payer's prior authorization number (box 23, 2300 REF*G1).
  final String? priorAuthNumber;

  /// Service facility when the visit was not at the billing address.
  final ServiceFacility? serviceFacility;

  /// Set while a recording runs; see [RecordingCheckpoint].
  final RecordingCheckpoint? liveRecording;

  /// The clinician's confirmation of the claim's E/M level and codes.
  final CodeConfirmation? codeConfirmation;

  /// Who signed, confirmed, changed or sent what on this visit.
  final List<AuditEvent> audit;

  /// Whether the clinician confirmed exactly these codes.
  bool codesConfirmedFor(ClaimDraft claim) => codeConfirmation?.fingerprint == claim.codeFingerprint;

  /// This visit with [action] added to the audit trail.
  Visit withAudit(String by, String action, {String detail = '', DateTime? atUtc}) =>
      copyWith(audit: [...audit, AuditEvent(atUtc: atUtc ?? DateTime.now().toUtc(), by: by, action: action, detail: detail)]);

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
    this.referringProvider,
    this.priorAuthNumber,
    this.serviceFacility,
    this.liveRecording,
    this.codeConfirmation,
    this.audit = const [],
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
    ReferringProvider? referringProvider,
    bool clearReferringProvider = false,
    String? priorAuthNumber,
    ServiceFacility? serviceFacility,
    bool clearServiceFacility = false,
    RecordingCheckpoint? liveRecording,
    bool clearLiveRecording = false,
    CodeConfirmation? codeConfirmation,
    List<AuditEvent>? audit,
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
        referringProvider: clearReferringProvider ? null : (referringProvider ?? this.referringProvider),
        // An empty string clears the number.
        priorAuthNumber: priorAuthNumber == null ? this.priorAuthNumber : (priorAuthNumber.trim().isEmpty ? null : priorAuthNumber.trim()),
        serviceFacility: clearServiceFacility ? null : (serviceFacility ?? this.serviceFacility),
        liveRecording: clearLiveRecording ? null : (liveRecording ?? this.liveRecording),
        codeConfirmation: codeConfirmation ?? this.codeConfirmation,
        audit: audit ?? this.audit,
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
        if (referringProvider != null) 'referringProvider': referringProvider!.toJson(),
        if (priorAuthNumber != null) 'priorAuthNumber': priorAuthNumber,
        if (serviceFacility != null) 'serviceFacility': serviceFacility!.toJson(),
        if (liveRecording != null) 'liveRecording': liveRecording!.toJson(),
        if (codeConfirmation != null) 'codeConfirmation': codeConfirmation!.toJson(),
        if (audit.isNotEmpty) 'audit': [for (final e in audit) e.toJson()],
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
        referringProvider: j['referringProvider'] is Map ? ReferringProvider.fromJson((j['referringProvider'] as Map).cast<String, dynamic>()) : null,
        priorAuthNumber: j['priorAuthNumber'] as String?,
        serviceFacility: j['serviceFacility'] is Map ? ServiceFacility.fromJson((j['serviceFacility'] as Map).cast<String, dynamic>()) : null,
        liveRecording: RecordingCheckpoint.fromJson(j['liveRecording']),
        codeConfirmation: CodeConfirmation.fromJson(j['codeConfirmation']),
        audit: [for (final e in (j['audit'] as List? ?? const [])) ?AuditEvent.fromJson(e)],
      );
}

/// The provider who referred or ordered the service (CMS-1500 box 17,
/// 837P loop 2310A, qualifier DN).
class ReferringProvider {
  final String firstName;
  final String lastName;
  final String npi;

  const ReferringProvider({required this.firstName, required this.lastName, required this.npi});

  String get displayName => [firstName, lastName].where((s) => s.trim().isNotEmpty).join(' ');

  Map<String, dynamic> toJson() => {'firstName': firstName, 'lastName': lastName, 'npi': npi};

  factory ReferringProvider.fromJson(Map<String, dynamic> j) =>
      ReferringProvider(firstName: '${j['firstName'] ?? ''}', lastName: '${j['lastName'] ?? ''}', npi: '${j['npi'] ?? ''}');
}

/// Where the service was given, when that is not the billing address
/// (CMS-1500 box 32, 837P loop 2310C).
class ServiceFacility {
  final String name;
  final String line1;
  final String city;
  final String state;
  final String zip;

  const ServiceFacility({required this.name, required this.line1, required this.city, required this.state, required this.zip});

  bool get isComplete =>
      name.trim().isNotEmpty &&
      line1.trim().isNotEmpty &&
      city.trim().isNotEmpty &&
      RegExp(r'^[A-Za-z]{2}$').hasMatch(state.trim()) &&
      RegExp(r'^\d{5}(-?\d{4})?$').hasMatch(zip.trim());

  /// "450 Mission Bay Blvd, San Francisco, CA 94158".
  String get oneLine => '${line1.trim()}, ${city.trim()}, ${state.trim().toUpperCase()} ${zip.trim()}';

  Map<String, dynamic> toJson() => {'name': name, 'line1': line1, 'city': city, 'state': state, 'zip': zip};

  factory ServiceFacility.fromJson(Map<String, dynamic> j) => ServiceFacility(
        name: '${j['name'] ?? ''}',
        line1: '${j['line1'] ?? ''}',
        city: '${j['city'] ?? ''}',
        state: '${j['state'] ?? ''}',
        zip: '${j['zip'] ?? ''}',
      );

  /// Reads "street, city, ST 12345" (a trailing country is ignored). Null
  /// when the text does not have that shape.
  static ServiceFacility? parse(String name, String? address) {
    if (address == null) return null;
    final parts = address.split(',').map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
    if (parts.isNotEmpty && RegExp(r'^(usa|us|united states( of america)?)$', caseSensitive: false).hasMatch(parts.last)) parts.removeLast();
    if (parts.length < 3) return null;
    final m = RegExp(r'^([A-Za-z]{2})\s+(\d{5}(?:-?\d{4})?)$').firstMatch(parts.last);
    if (m == null) return null;
    final f = ServiceFacility(
      name: name,
      line1: parts.sublist(0, parts.length - 2).join(', '),
      city: parts[parts.length - 2],
      state: m.group(1)!.toUpperCase(),
      zip: m.group(2)!,
    );
    return f.isComplete ? f : null;
  }
}

/// Who is responsible for the bill when it is not the patient, usually a
/// parent or guardian of a minor.
class Guarantor {
  final String name;
  final String relationship; // parent, guardian, spouse, other
  final String? phone;

  const Guarantor({required this.name, this.relationship = 'parent', this.phone});

  static const relationships = {'parent': 'Parent', 'guardian': 'Legal guardian', 'spouse': 'Spouse', 'other': 'Other'};

  String get summary => '$name (${relationships[relationship] ?? relationship})${phone == null || phone!.isEmpty ? '' : ', $phone'}';

  Map<String, dynamic> toJson() => {'name': name, 'relationship': relationship, if (phone != null) 'phone': phone};

  factory Guarantor.fromJson(Map<String, dynamic> j) =>
      Guarantor(name: '${j['name'] ?? ''}', relationship: '${j['relationship'] ?? 'parent'}', phone: j['phone'] as String?);
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
    this.allergies,
    this.preferredLanguage,
    this.interpreterNeeded = false,
    this.guarantor,
  });

  /// The language the patient prefers for care, such as "Spanish". Null
  /// when not recorded.
  final String? preferredLanguage;

  /// The patient needs an interpreter for the visit.
  final bool interpreterNeeded;

  /// "Spanish, interpreter needed", "English" or "Not recorded".
  String get languageSummary => preferredLanguage == null
      ? (interpreterNeeded ? 'Interpreter needed' : 'Not recorded')
      : '$preferredLanguage${interpreterNeeded ? ', interpreter needed' : ''}';

  /// Allergies as the clinician recorded them. Null means not asked yet;
  /// an empty list means the patient has no known allergies.
  final List<String>? allergies;

  bool get allergiesRecorded => allergies != null;

  /// "No known allergies", "Not recorded" or the list.
  String get allergySummary => allergies == null
      ? 'Not recorded'
      : allergies!.isEmpty
          ? 'No known allergies'
          : allergies!.join(', ');

  bool get isDeleted => deletedAtUtc != null;

  /// Registered with a placeholder name (see [unidentifiedName]).
  bool get isUnidentified => firstName == unidentifiedFirstName && lastName.startsWith('Patient ');

  String get fullName => [firstName, if (middleName != null && middleName!.isNotEmpty) middleName, lastName].join(' ');

  /// Age in whole years on [on] (defaults to today), or null without a DOB.
  /// The responsible party when it is not the patient.
  final Guarantor? guarantor;

  /// Under 18 on [on]. Unknown birth dates are not minors.
  bool isMinorOn([DateTime? on]) {
    final age = ageOn(on);
    return age != null && age < 18;
  }

  /// A minor with no responsible party recorded.
  bool get needsGuarantor => isMinorOn() && guarantor == null;

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
    List<String>? allergies,
    String? preferredLanguage,
    bool? interpreterNeeded,
    Guarantor? guarantor,
    bool clearGuarantor = false,
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
        allergies: allergies ?? this.allergies,
        // An empty string clears the language.
        preferredLanguage: preferredLanguage == null ? this.preferredLanguage : (preferredLanguage.trim().isEmpty ? null : preferredLanguage.trim()),
        interpreterNeeded: interpreterNeeded ?? this.interpreterNeeded,
        guarantor: clearGuarantor ? null : (guarantor ?? this.guarantor),
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
        'allergies': allergies,
        if (preferredLanguage != null) 'preferredLanguage': preferredLanguage,
        if (interpreterNeeded) 'interpreterNeeded': true,
        if (guarantor != null) 'guarantor': guarantor!.toJson(),
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
        allergies: j['allergies'] is List ? [for (final a in j['allergies'] as List) '$a'] : null,
        preferredLanguage: j['preferredLanguage'] as String?,
        interpreterNeeded: j['interpreterNeeded'] == true,
        guarantor: j['guarantor'] is Map ? Guarantor.fromJson((j['guarantor'] as Map).cast<String, dynamic>()) : null,
      );
}

/// Cleans an allergy list typed as free text: one entry per comma or line,
/// trimmed, without repeats (case-insensitive). "NKA", "NKDA" or "none"
/// alone means no known allergies (an empty list).
List<String> parseAllergies(String text) {
  final parts = text.split(RegExp(r'[,;\n]')).map((p) => p.trim()).where((p) => p.isNotEmpty).toList();
  if (parts.length == 1 && RegExp(r'^(nka|nkda|none|no known (drug )?allergies)$', caseSensitive: false).hasMatch(parts.single)) {
    return const [];
  }
  final seen = <String>{};
  return [
    for (final p in parts)
      if (seen.add(p.toLowerCase())) p,
  ];
}

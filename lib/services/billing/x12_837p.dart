// ASC X12N 837 Health Care Claim: Professional, version 005010X222A1.
//
// Segment and loop layout follows the 005010X222A1 TR3 as summarized in the
// CMS 837P companion guide
// (https://www.cms.gov/Medicare/Billing/ElectronicBillingEDITrans/Downloads/5010A1837BCG.pdf)
// and the UnitedHealthcare 837P companion guide
// (https://www.uhcprovider.com/content/dam/provider/docs/public/resources/edi/EDI-837P-CG-005010X222A1.pdf).
// Clearinghouse specifics (reserved delimiters, patient control number length)
// follow https://www.stedi.com/docs/healthcare/submit-professional-claims.
//
// Ambulance claims (place of service 41 or 42) carry, per the TR3 and the
// payer companion guides (for example the Virginia Medicaid 837P companion
// guide and the CMS ambulance transport reason code list):
//   2300 CR1  ambulance transport information: CR101 LB and CR102 weight when
//             known, CR104 transport reason A to E, CR105 DH, CR106 miles.
//   2300 CRC  ambulance certification (CRC01 07, CRC02 Y, CRC03..07 condition
//             codes), sent only when condition codes were recorded.
//   2310E     NM1*PW pick-up location with N3 and N4.
//   2310F     NM1*45 drop-off location with N3 and N4.
//   SV104     loaded miles to a tenth of a mile on A0425.

import '../../models/ambulance_transport.dart';
import '../../models/claim_models.dart';
import '../../models/patient_account.dart';
import '../../models/provider_profile.dart';
import '../coding/code_rules.dart';
import 'cms_edi_edits.dart';

/// Envelope and trading partner settings for an outbound 837P.
class SubmitterConfig {
  /// Loop 1000A NM103: the organization sending the file.
  final String submitterName;

  /// Loop 1000A NM109 (qualifier 46): ID assigned by the clearinghouse.
  final String submitterId;

  /// Loop 1000A PER02 and PER04. Phone falls back to the provider phone.
  final String submitterContactName;
  final String submitterPhone;

  /// Loop 1000B NM103 and NM109. For Stedi this is the payer name and payer ID.
  /// When [receiverId] is empty the payer ID from the patient's coverage is used.
  final String receiverName;
  final String receiverId;

  /// ISA05/ISA06 and ISA07/ISA08. Qualifier is usually ZZ (mutually defined).
  final String isaSenderQualifier;
  final String isaSenderId;
  final String isaReceiverQualifier;
  final String isaReceiverId;

  /// GS02 and GS03. Default to the ISA IDs when empty.
  final String applicationSenderCode;
  final String applicationReceiverCode;

  /// ISA15: T for test, P for production.
  final String usageIndicator;

  /// ISA13/IEA02 (1..999999999), GS06/GE02 (1..999999999), ST02/SE02 (1..9999).
  final int interchangeControlNumber;
  final int groupControlNumber;
  final int transactionControlNumber;

  const SubmitterConfig({
    required this.submitterName,
    required this.submitterId,
    required this.isaSenderId,
    required this.isaReceiverId,
    this.submitterContactName = 'BILLING',
    this.submitterPhone = '',
    this.receiverName = '',
    this.receiverId = '',
    this.isaSenderQualifier = 'ZZ',
    this.isaReceiverQualifier = 'ZZ',
    this.applicationSenderCode = '',
    this.applicationReceiverCode = '',
    this.usageIndicator = 'T',
    this.interchangeControlNumber = 1,
    this.groupControlNumber = 1,
    this.transactionControlNumber = 1,
  });

  bool get isTest => usageIndicator == 'T';

  /// True when every value the envelope needs is present.
  bool get isComplete =>
      submitterName.trim().isNotEmpty &&
      submitterId.trim().isNotEmpty &&
      isaSenderId.trim().isNotEmpty &&
      isaReceiverId.trim().isNotEmpty &&
      (usageIndicator == 'T' || usageIndicator == 'P');

  SubmitterConfig copyWith({
    String? submitterName,
    String? submitterId,
    String? submitterContactName,
    String? submitterPhone,
    String? receiverName,
    String? receiverId,
    String? isaSenderQualifier,
    String? isaSenderId,
    String? isaReceiverQualifier,
    String? isaReceiverId,
    String? applicationSenderCode,
    String? applicationReceiverCode,
    String? usageIndicator,
    int? interchangeControlNumber,
    int? groupControlNumber,
    int? transactionControlNumber,
  }) =>
      SubmitterConfig(
        submitterName: submitterName ?? this.submitterName,
        submitterId: submitterId ?? this.submitterId,
        submitterContactName: submitterContactName ?? this.submitterContactName,
        submitterPhone: submitterPhone ?? this.submitterPhone,
        receiverName: receiverName ?? this.receiverName,
        receiverId: receiverId ?? this.receiverId,
        isaSenderQualifier: isaSenderQualifier ?? this.isaSenderQualifier,
        isaSenderId: isaSenderId ?? this.isaSenderId,
        isaReceiverQualifier: isaReceiverQualifier ?? this.isaReceiverQualifier,
        isaReceiverId: isaReceiverId ?? this.isaReceiverId,
        applicationSenderCode: applicationSenderCode ?? this.applicationSenderCode,
        applicationReceiverCode: applicationReceiverCode ?? this.applicationReceiverCode,
        usageIndicator: usageIndicator ?? this.usageIndicator,
        interchangeControlNumber: interchangeControlNumber ?? this.interchangeControlNumber,
        groupControlNumber: groupControlNumber ?? this.groupControlNumber,
        transactionControlNumber: transactionControlNumber ?? this.transactionControlNumber,
      );

  /// Same config with all three control numbers set from one counter value.
  SubmitterConfig withControlNumber(int n) => copyWith(
        interchangeControlNumber: n,
        groupControlNumber: n,
        transactionControlNumber: ((n - 1) % 9999) + 1,
      );

  Map<String, dynamic> toJson() => {
        'submitterName': submitterName,
        'submitterId': submitterId,
        'submitterContactName': submitterContactName,
        'submitterPhone': submitterPhone,
        'receiverName': receiverName,
        'receiverId': receiverId,
        'isaSenderQualifier': isaSenderQualifier,
        'isaSenderId': isaSenderId,
        'isaReceiverQualifier': isaReceiverQualifier,
        'isaReceiverId': isaReceiverId,
        'applicationSenderCode': applicationSenderCode,
        'applicationReceiverCode': applicationReceiverCode,
        'usageIndicator': usageIndicator,
        'interchangeControlNumber': interchangeControlNumber,
        'groupControlNumber': groupControlNumber,
        'transactionControlNumber': transactionControlNumber,
      };

  factory SubmitterConfig.fromJson(Map<String, dynamic> j) => SubmitterConfig(
        submitterName: j['submitterName'] ?? '',
        submitterId: j['submitterId'] ?? '',
        submitterContactName: j['submitterContactName'] ?? 'BILLING',
        submitterPhone: j['submitterPhone'] ?? '',
        receiverName: j['receiverName'] ?? '',
        receiverId: j['receiverId'] ?? '',
        isaSenderQualifier: j['isaSenderQualifier'] ?? 'ZZ',
        isaSenderId: j['isaSenderId'] ?? '',
        isaReceiverQualifier: j['isaReceiverQualifier'] ?? 'ZZ',
        isaReceiverId: j['isaReceiverId'] ?? '',
        applicationSenderCode: j['applicationSenderCode'] ?? '',
        applicationReceiverCode: j['applicationReceiverCode'] ?? '',
        usageIndicator: j['usageIndicator'] ?? 'T',
        interchangeControlNumber: (j['interchangeControlNumber'] as num?)?.toInt() ?? 1,
        groupControlNumber: (j['groupControlNumber'] as num?)?.toInt() ?? 1,
        transactionControlNumber: (j['transactionControlNumber'] as num?)?.toInt() ?? 1,
      );
}

/// Outcome of building an 837P. [x12] is null whenever [errors] is not empty.
class X12BuildResult {
  final String? x12;
  final List<String> errors;
  final List<String> warnings;

  /// Segments from ST through SE inclusive (the SE01 value).
  final int transactionSegmentCount;

  /// CLM01 used for this claim.
  final String patientControlNumber;

  const X12BuildResult({
    required this.x12,
    required this.errors,
    required this.warnings,
    required this.transactionSegmentCount,
    required this.patientControlNumber,
  });

  bool get ok => errors.isEmpty && x12 != null;

  /// The interchange with one segment per line, for display or review.
  String? get pretty => x12 == null ? null : X12Formatter.pretty(x12!);
}

class X12Formatter {
  static const elementSeparator = '*';
  static const componentSeparator = ':';
  static const repetitionSeparator = '^';
  static const segmentTerminator = '~';

  /// One segment per line. Accepts compact or already pretty input.
  static String pretty(String x12) => x12
      .split(segmentTerminator)
      .map((s) => s.replaceAll('\r', '').replaceAll('\n', ''))
      .where((s) => s.isNotEmpty)
      .map((s) => '$s$segmentTerminator')
      .join('\n');

  /// Splits an interchange into segments without terminators.
  static List<String> segments(String x12) => x12
      .split(segmentTerminator)
      .map((s) => s.replaceAll('\r', '').replaceAll('\n', ''))
      .where((s) => s.isNotEmpty)
      .toList();
}

/// Claim filing indicator for SBR09 from the coverage on file.
/// MB Medicare Part B, MC Medicaid, 16 Medicare Advantage HMO, CH TRICARE, CI commercial.
String claimFilingIndicatorFor(InsuranceCoverage? ins) {
  if (ins == null) return 'CI';
  final s = '${ins.planType ?? ''} ${ins.payerName} ${ins.planName ?? ''}'.toLowerCase();
  if (s.contains('medicare advantage')) return '16';
  if (s.contains('medicare')) return 'MB';
  if (s.contains('medicaid') || s.contains('medi-cal')) return 'MC';
  if (s.contains('tricare') || s.contains('champus')) return 'CH';
  return 'CI';
}

/// Individual relationship code (SBR02 / PAT01) from the coverage relationship.
String relationshipCode(String relationship) {
  switch (relationship.trim().toLowerCase()) {
    case 'self':
    case '':
      return '18';
    case 'spouse':
      return '01';
    case 'child':
      return '19';
    default:
      return 'G8';
  }
}

/// Ground (41) and air or water (42) ambulance places of service.
bool isAmbulancePos(String pos) => pos.trim() == '41' || pos.trim() == '42';

/// HCPCS ambulance codes A0425 to A0436 (services and mileage).
bool isAmbulanceServiceCode(String code) {
  final m = RegExp(r'^A04(\d\d)$').firstMatch(code.trim().toUpperCase());
  if (m == null) return false;
  final n = int.parse(m.group(1)!);
  return n >= 25 && n <= 36;
}

/// Mileage codes billed per loaded mile: ground A0425, fixed and rotary wing
/// air A0435 and A0436.
bool isAmbulanceMileageCode(String code) => const {'A0425', 'A0435', 'A0436'}.contains(code.trim().toUpperCase());

/// A two-letter ambulance origin and destination modifier such as RH.
bool isOriginDestinationModifier(String m) {
  final s = m.trim().toUpperCase();
  return s.length == 2 && ambulanceLocationCodes.containsKey(s[0]) && ambulanceLocationCodes.containsKey(s[1]) && s[0] != 'X';
}

/// Builds 005010X222A1 837P interchanges.
class Claim837PGenerator {
  static const implementationGuide = '005010X222A1';
  static const maxDiagnoses = 12;
  static const maxPointersPerLine = 4;
  static const maxModifiers = 4;

  /// Builds one ISA/GS/ST interchange carrying one claim.
  ///
  /// [now] sets the ISA/GS/BHT date and time (defaults to the current local time).
  /// [filingIndicator] overrides SBR09.
  /// [pretty] puts each segment on its own line.
  static X12BuildResult build({
    required ClaimDraft claim,
    required PatientAccount account,
    required Visit visit,
    required ProviderProfile provider,
    required SubmitterConfig config,
    DateTime? now,
    String? filingIndicator,
    bool pretty = false,
  }) {
    final errors = <String>[];
    final warnings = <String>[];
    final ins = account.insurance;
    final pcn = _clean('${account.accountNumber}-V${visit.number}');

    // ---- Envelope checks.
    if (_clean(config.submitterName).isEmpty) errors.add('Submitter name is required (1000A NM103).');
    if (_clean(config.submitterId).isEmpty) errors.add('Submitter ID is required (1000A NM109).');
    if (_clean(config.isaSenderId).isEmpty) errors.add('ISA sender ID is required (ISA06).');
    if (_clean(config.isaReceiverId).isEmpty) errors.add('ISA receiver ID is required (ISA08).');
    if (config.isaSenderId.trim().length > 15) errors.add('ISA sender ID is longer than 15 characters.');
    if (config.isaReceiverId.trim().length > 15) errors.add('ISA receiver ID is longer than 15 characters.');
    if (config.isaSenderQualifier.trim().length != 2) errors.add('ISA sender qualifier must be 2 characters (ISA05).');
    if (config.isaReceiverQualifier.trim().length != 2) errors.add('ISA receiver qualifier must be 2 characters (ISA07).');
    if (config.usageIndicator != 'T' && config.usageIndicator != 'P') errors.add('Usage indicator must be T or P (ISA15).');
    if (config.interchangeControlNumber < 1 || config.interchangeControlNumber > 999999999) {
      errors.add('Interchange control number must be 1 to 999999999 (ISA13).');
    }
    if (config.groupControlNumber < 1 || config.groupControlNumber > 999999999) {
      errors.add('Group control number must be 1 to 999999999 (GS06).');
    }
    if (config.transactionControlNumber < 1 || config.transactionControlNumber > 9999) {
      errors.add('Transaction set control number must be 1 to 9999 (ST02).');
    }

    // ---- Billing provider (2010AA) and rendering provider (2310B).
    final groupNpi = provider.groupNpi?.trim() ?? '';
    final individualNpi = provider.npi.trim();
    final billAsGroup = groupNpi.isNotEmpty && groupNpi != individualNpi;
    final billingNpi = billAsGroup ? groupNpi : individualNpi;
    if (billingNpi.isEmpty) {
      errors.add('Billing provider NPI is required (2010AA NM109).');
    } else if (!isValidNpi(billingNpi)) {
      errors.add('Billing provider NPI $billingNpi fails the NPI check digit.');
    }
    if (billAsGroup && !isValidNpi(individualNpi)) {
      errors.add('Rendering provider NPI is missing or invalid (2310B NM109).');
    }
    final ein = provider.taxId.replaceAll(RegExp(r'[^0-9]'), '');
    if (!isValidEin(provider.taxId) || ein.length != 9) errors.add('Billing provider EIN is required as 9 digits (2010AA REF*EI).');
    if (provider.taxonomyCode.trim().length != 10) errors.add('Billing provider taxonomy code must be 10 characters (2000A PRV03).');
    if (_clean(provider.addressLine1).isEmpty) errors.add('Billing provider street address is required (2010AA N3).');
    if (_clean(provider.city).isEmpty) errors.add('Billing provider city is required (2010AA N4).');
    if (!RegExp(r'^[A-Za-z]{2}$').hasMatch(provider.state.trim())) errors.add('Billing provider state must be a 2-letter code (2010AA N4).');
    final providerZip = _zip(provider.zip);
    if (providerZip == null) {
      errors.add('Billing provider ZIP code is required (2010AA N4).');
    } else if (providerZip.length != 9) {
      warnings.add('The 837P guide asks for the 9-digit ZIP+4 for the billing provider; some payers reject a 5-digit ZIP.');
    }
    if (billAsGroup ? _clean(provider.practiceName).isEmpty : _clean(provider.fullName).isEmpty) {
      errors.add('Billing provider name is required (2010AA NM103).');
    }

    // ---- Coverage, subscriber, patient.
    if (ins == null) {
      errors.add('Patient has no insurance coverage on file.');
    } else {
      if (_clean(ins.memberId).isEmpty) errors.add('Member ID is required (2010BA NM109).');
      if (_clean(ins.payerName).isEmpty) errors.add('Payer name is required (2010BB NM103).');
      if (_clean(ins.payerId ?? '').isEmpty) errors.add('Payer ID is required (2010BB NM109).');
    }
    final relCode = relationshipCode(ins?.relationship ?? 'self');
    final patientIsSubscriber = relCode == '18';
    if (_clean(account.lastName).isEmpty) errors.add('Patient last name is required.');
    if (_clean(account.firstName).isEmpty) errors.add('Patient first name is required.');
    if (account.dateOfBirth == null) errors.add('Patient date of birth is required (DMG02).');
    if (_clean(account.addressLine1 ?? '').isEmpty) errors.add('Patient street address is required (N3).');
    if (_clean(account.city ?? '').isEmpty) errors.add('Patient city is required (N4).');
    if (!RegExp(r'^[A-Za-z]{2}$').hasMatch((account.state ?? '').trim())) errors.add('Patient state must be a 2-letter code (N4).');
    final patientZip = _zip(account.zip ?? '');
    if (patientZip == null) errors.add('Patient ZIP code is required (N4).');
    if (account.sex == PatientSex.unknown) warnings.add('Patient sex is unknown; DMG03 is sent as U.');

    ({String last, String first})? subscriberName;
    if (!patientIsSubscriber) {
      subscriberName = _splitName(ins?.subscriberName ?? '');
      if (subscriberName == null) errors.add('Subscriber name is required when the patient is not the subscriber (2010BA NM103).');
    }

    // ---- Diagnoses, primary first.
    final billable = claim.billable;
    final primary = claim.primaryCode;
    if (primary != null) {
      final i = billable.indexWhere((d) => d.code == primary);
      if (i > 0) billable.insert(0, billable.removeAt(i));
    }
    final seen = <String>{};
    final dx = <ClaimDiagnosis>[
      for (final d in billable)
        if (icdForX12(d.code).isNotEmpty && seen.add(icdForX12(d.code))) d,
    ];
    if (dx.isEmpty) errors.add('At least one billable diagnosis is required (HI ABK).');
    if (dx.length > maxDiagnoses) {
      warnings.add('Only the first $maxDiagnoses of ${dx.length} diagnoses are sent; the 837P allows 12.');
      dx.removeRange(maxDiagnoses, dx.length);
    }
    final dxIndex = <String, int>{for (var i = 0; i < dx.length; i++) icdForX12(dx[i].code): i + 1};

    // ---- Ambulance transport (CR1, CRC, 2310E, 2310F).
    final ambulance = isAmbulancePos(visit.placeOfService);
    final transport = visit.transport;
    if (ambulance) {
      if (transport == null) {
        errors.add('Ambulance claims need the transport details: pick-up and drop-off addresses, loaded miles and transport reason (CR1, 2310E, 2310F).');
      } else {
        if (!transport.pickup.isComplete) errors.add('Ambulance pick-up address needs street, city, 2-letter state and ZIP (2310E N3, N4).');
        if (!transport.dropoff.isComplete) errors.add('Ambulance drop-off address needs street, city, 2-letter state and ZIP (2310F N3, N4).');
        if (transport.loadedMiles == null || transport.loadedMiles! <= 0) errors.add('Loaded miles are required for an ambulance claim (CR106).');
        if (transport.reasonCode == null || !ambulanceTransportReasons.containsKey(transport.reasonCode)) {
          errors.add('Ambulance transport reason code A to E is required (CR104).');
        }
      }
    }

    // ---- Service lines.
    if (claim.lines.isEmpty) errors.add('At least one service line is required (2400).');
    final lineCharges = <String>[];
    final lineUnits = <String>[];
    final linePointers = <List<int>>[];
    var totalCents = 0;
    for (var i = 0; i < claim.lines.length; i++) {
      final l = claim.lines[i];
      final n = i + 1;
      if (!RegExp(r'^[A-Za-z0-9]{5}$').hasMatch(l.code.trim())) errors.add('Line $n: procedure code "${l.code}" must be a 5-character CPT or HCPCS code.');
      var quantity = l.billedUnits;
      if (isAmbulanceMileageCode(l.code)) {
        // Mileage is billed in loaded miles, never a default of 1.
        final miles = l.quantity ?? transport?.loadedMiles;
        if (miles == null || miles <= 0) {
          errors.add('Line $n: ${l.code} needs the loaded miles as units (SV104). Enter them in Transport.');
        } else {
          quantity = roundUpTenth(miles);
        }
      }
      if (ambulance && isAmbulanceServiceCode(l.code) && !l.modifiers.any(isOriginDestinationModifier)) {
        errors.add('Line $n: ${l.code} needs the origin and destination modifier (for example RH).');
      }
      if (quantity <= 0) errors.add('Line $n: units must be greater than zero.');
      lineUnits.add(_quantity(quantity));
      final cents = (l.charge * 100 * (quantity <= 0 ? 1 : quantity)).round();
      if (cents <= 0) errors.add('Line $n: charge must be greater than zero.');
      totalCents += cents;
      lineCharges.add(_money(cents));
      if (l.modifiers.length > maxModifiers) warnings.add('Line $n: only the first $maxModifiers modifiers are sent.');
      final ptrs = <int>[];
      for (final c in l.diagnosisCodes) {
        final p = dxIndex[icdForX12(c)];
        if (p != null && !ptrs.contains(p)) ptrs.add(p);
      }
      if (ptrs.isEmpty && dx.isNotEmpty) {
        warnings.add('Line $n: no linked diagnosis is on the claim; pointed to the primary diagnosis.');
        ptrs.add(1);
      }
      if (ptrs.length > maxPointersPerLine) {
        warnings.add('Line $n: only the first $maxPointersPerLine diagnosis pointers are sent.');
        ptrs.removeRange(maxPointersPerLine, ptrs.length);
      }
      linePointers.add(ptrs);
    }

    // ---- Claim level.
    if (pcn.length > 20) errors.add('Patient control number $pcn is longer than 20 characters (CLM01).');
    if (pcn.length > 17) warnings.add('Patient control number is longer than 17 characters; some clearinghouses truncate it.');
    final dos = _d8(visit.dateOfService);
    if (dos == null) errors.add('Date of service ${visit.dateOfService} is not a valid yyyy-MM-dd date.');
    final pos = visit.placeOfService.trim();
    if (!RegExp(r'^\d{2}$').hasMatch(pos)) errors.add('Place of service must be a 2-digit CMS code (CLM05-1).');
    final dob = account.dateOfBirth;

    // ---- Medicare front-end edits (CMS CR 14429, R13967OTN, October 2026).
    final medicare = (filingIndicator ?? claimFilingIndicatorFor(ins)) == 'MB';
    if (medicare) {
      // X222.079.1000B.NM109.060: a MAC rejects the file at the translator
      // when 1000B NM109 differs from GS03. It applies when this file goes
      // straight to the MAC, which is when a receiver ID is set; through a
      // clearinghouse (no receiver ID: 1000B carries the payer ID, as Stedi
      // asks) the clearinghouse builds the envelope the MAC sees.
      final receiver = _clean(config.receiverId);
      final gs03 = _clean(config.applicationReceiverCode).isEmpty ? _clean(config.isaReceiverId) : _clean(config.applicationReceiverCode);
      if (receiver.isNotEmpty && receiver != gs03) {
        errors.add('${CmsEdiEdits.receiverMatchesGs03}: the receiver ID $receiver (1000B NM109) must equal the application '
            'receiver code $gs03 (GS03) for Medicare, or the MAC rejects the file (${CmsEdiEdits.citation}).');
      }
    }
    for (var i = 0; i < claim.lines.length; i++) {
      final l = claim.lines[i];
      if (CmsEdiEdits.requiresServiceDescription(l.code) && CmsEdiEdits.serviceDescriptionFor(l) == null) {
        // X222.351.2400.SV101-7.020 (Medicare); every payer asks for the
        // narrative of an unlisted or NOC code.
        (medicare ? errors : warnings).add('Line ${i + 1}: ${l.code} is an unlisted or not-otherwise-classified code and needs '
            'a service description (SV101-7)${medicare ? ' (${CmsEdiEdits.serviceDescription}, ${CmsEdiEdits.citation})' : ''}.');
      }
    }

    if (errors.isNotEmpty) {
      return X12BuildResult(x12: null, errors: errors, warnings: warnings, transactionSegmentCount: 0, patientControlNumber: pcn);
    }

    // ---- Assemble.
    final t = now ?? DateTime.now();
    final ccyymmdd = _dateDigits(t);
    final hhmm = '${_two(t.hour)}${_two(t.minute)}';
    final st02 = config.transactionControlNumber.toString().padLeft(4, '0');
    final gsSender = _clean(config.applicationSenderCode).isEmpty ? _clean(config.isaSenderId) : _clean(config.applicationSenderCode);
    final gsReceiver = _clean(config.applicationReceiverCode).isEmpty ? _clean(config.isaReceiverId) : _clean(config.applicationReceiverCode);
    final submitterPhone = _digits(config.submitterPhone).isNotEmpty ? _digits(config.submitterPhone) : _digits(provider.phone);
    final payerId = _clean(ins!.payerId!);
    final receiverId = _clean(config.receiverId).isEmpty ? payerId : _clean(config.receiverId);
    final receiverName = _clean(config.receiverName).isEmpty ? _clean(ins.payerName) : _clean(config.receiverName);
    final sbr09 = filingIndicator ?? claimFilingIndicatorFor(ins);
    final group = _clean(ins.groupNumber ?? '');
    final planName = _clean(ins.planName ?? '');
    final renderingName = _splitName(provider.fullName) ?? (last: _clean(provider.fullName), first: '');

    final body = <String>[];
    void add(List<String> els) => body.add(_segment(els));

    add(['ST', '837', st02, implementationGuide]);
    add(['BHT', '0019', '00', _cap(pcn, 50), ccyymmdd, hhmm, 'CH']);
    // 1000A submitter.
    add(['NM1', '41', '2', _cap(_clean(config.submitterName), 60), '', '', '', '', '46', _cap(_clean(config.submitterId), 80)]);
    add([
      'PER', 'IC', _cap(_clean(config.submitterContactName).isEmpty ? 'BILLING' : _clean(config.submitterContactName), 60),
      if (submitterPhone.isNotEmpty) ...['TE', submitterPhone],
    ]);
    // 1000B receiver.
    add(['NM1', '40', '2', _cap(receiverName, 60), '', '', '', '', '46', _cap(receiverId, 80)]);
    // 2000A billing provider.
    add(['HL', '1', '', '20', '1']);
    add(['PRV', 'BI', 'PXC', provider.taxonomyCode.trim().toUpperCase()]);
    // 2010AA.
    if (billAsGroup) {
      add(['NM1', '85', '2', _cap(_clean(provider.practiceName), 60), '', '', '', '', 'XX', billingNpi]);
    } else {
      add(['NM1', '85', '1', _cap(renderingName.last, 60), _cap(renderingName.first, 35), '', '', '', 'XX', billingNpi]);
    }
    add(['N3', _cap(_clean(provider.addressLine1), 55)]);
    add(['N4', _cap(_clean(provider.city), 30), provider.state.trim().toUpperCase(), providerZip!]);
    add(['REF', 'EI', ein]);
    // 2000B subscriber.
    add(['HL', '2', '1', '22', patientIsSubscriber ? '0' : '1']);
    add([
      'SBR', 'P', patientIsSubscriber ? '18' : '', _cap(group, 50),
      group.isEmpty ? _cap(planName, 60) : '', '', '', '', '', sbr09,
    ]);
    // 2010BA subscriber name.
    if (patientIsSubscriber) {
      add([
        'NM1', 'IL', '1', _cap(_clean(account.lastName), 60), _cap(_clean(account.firstName), 35),
        _cap(_clean(account.middleName ?? ''), 25), '', '', 'MI', _cap(_clean(ins.memberId), 80),
      ]);
      add(['N3', _cap(_clean(account.addressLine1!), 55)]);
      add(['N4', _cap(_clean(account.city!), 30), account.state!.trim().toUpperCase(), patientZip!]);
      add(['DMG', 'D8', _dateDigits(dob!), sexCode(account.sex)]);
    } else {
      add(['NM1', 'IL', '1', _cap(subscriberName!.last, 60), _cap(subscriberName.first, 35), '', '', '', 'MI', _cap(_clean(ins.memberId), 80)]);
    }
    // 2010BB payer.
    add(['NM1', 'PR', '2', _cap(_clean(ins.payerName), 60), '', '', '', '', 'PI', _cap(payerId, 80)]);
    // 2000C patient, only when the patient is not the subscriber.
    if (!patientIsSubscriber) {
      add(['HL', '3', '2', '23', '0']);
      add(['PAT', relCode]);
      add(['NM1', 'QC', '1', _cap(_clean(account.lastName), 60), _cap(_clean(account.firstName), 35), _cap(_clean(account.middleName ?? ''), 25)]);
      add(['N3', _cap(_clean(account.addressLine1!), 55)]);
      add(['N4', _cap(_clean(account.city!), 30), account.state!.trim().toUpperCase(), patientZip!]);
      add(['DMG', 'D8', _dateDigits(dob!), sexCode(account.sex)]);
    }
    // 2300 claim.
    add(['CLM', pcn, _money(totalCents), '', '', '$pos:B:1', 'Y', 'A', 'Y', 'Y']);
    if (ambulance) {
      final t = transport!;
      final weight = t.patientWeightLbs;
      add([
        'CR1', weight != null && weight > 0 ? 'LB' : '', weight != null && weight > 0 ? '$weight' : '', '',
        t.reasonCode!, 'DH', _quantity(roundUpTenth(t.loadedMiles!)),
      ]);
      final conditions = t.conditionCodes.where(ambulanceConditionCodes.containsKey).take(5).toList();
      if (conditions.isNotEmpty) add(['CRC', '07', 'Y', ...conditions]);
    }
    add([
      'HI',
      for (var i = 0; i < dx.length; i++) '${i == 0 ? 'ABK' : 'ABF'}:${icdForX12(dx[i].code)}',
    ]);
    // 2310B rendering provider when the claim bills under a group NPI.
    if (billAsGroup) {
      add(['NM1', '82', '1', _cap(renderingName.last, 60), _cap(renderingName.first, 35), '', '', '', 'XX', individualNpi]);
      add(['PRV', 'PE', 'PXC', provider.taxonomyCode.trim().toUpperCase()]);
    }
    // 2310E ambulance pick-up and 2310F drop-off locations.
    if (ambulance) {
      final t = transport!;
      add(['NM1', 'PW', '2']);
      add(['N3', _cap(_clean(t.pickup.line1), 55)]);
      add(['N4', _cap(_clean(t.pickup.city), 30), t.pickup.state.trim().toUpperCase(), _zip(t.pickup.zip)!]);
      add(['NM1', '45', '2', _cap(_clean(t.dropoff.name ?? ''), 60)]);
      add(['N3', _cap(_clean(t.dropoff.line1), 55)]);
      add(['N4', _cap(_clean(t.dropoff.city), 30), t.dropoff.state.trim().toUpperCase(), _zip(t.dropoff.zip)!]);
    }
    // 2400 service lines.
    for (var i = 0; i < claim.lines.length; i++) {
      final l = claim.lines[i];
      final mods = l.modifiers.map(_clean).where((m) => m.isNotEmpty).take(maxModifiers);
      add(['LX', '${i + 1}']);
      // SV105 is sent only when it differs from CLM05-1, which never happens here.
      // SV101-7: the narrative for unlisted and not-otherwise-classified codes.
      final narrative = CmsEdiEdits.serviceDescriptionFor(l);
      final sv101 = ['HC', l.code.trim().toUpperCase(), ...mods];
      if (narrative != null) {
        while (sv101.length < 6) {
          sv101.add('');
        }
        sv101.add(narrative);
      }
      add([
        'SV1', sv101.join(':'), lineCharges[i], 'UN', lineUnits[i],
        '', '', linePointers[i].join(':'),
      ]);
      add(['DTP', '472', 'D8', dos!]);
    }
    final segCount = body.length + 1;
    add(['SE', '$segCount', st02]);

    final isa = [
      'ISA', '00', ' ' * 10, '00', ' ' * 10,
      config.isaSenderQualifier.trim().toUpperCase(), _clean(config.isaSenderId).padRight(15),
      config.isaReceiverQualifier.trim().toUpperCase(), _clean(config.isaReceiverId).padRight(15),
      ccyymmdd.substring(2), hhmm, X12Formatter.repetitionSeparator, '00501',
      config.interchangeControlNumber.toString().padLeft(9, '0'), '0', config.usageIndicator, X12Formatter.componentSeparator,
    ].join(X12Formatter.elementSeparator) + X12Formatter.segmentTerminator;
    final gs = _segment(['GS', 'HC', _cap(gsSender, 15), _cap(gsReceiver, 15), ccyymmdd, hhmm, '${config.groupControlNumber}', 'X', implementationGuide]);
    final ge = _segment(['GE', '1', '${config.groupControlNumber}']);
    final iea = _segment(['IEA', '1', config.interchangeControlNumber.toString().padLeft(9, '0')]);

    final all = [isa, gs, ...body, ge, iea];
    return X12BuildResult(
      x12: all.join(pretty ? '\n' : ''),
      errors: const [],
      warnings: warnings,
      transactionSegmentCount: segCount,
      patientControlNumber: pcn,
    );
  }

  // ---- Helpers.

  /// Joins elements, dropping trailing empty elements, and terminates.
  static String _segment(List<String> els) {
    var end = els.length;
    while (end > 1 && els[end - 1].isEmpty) {
      end--;
    }
    return els.sublist(0, end).join(X12Formatter.elementSeparator) + X12Formatter.segmentTerminator;
  }

  /// Uppercases and strips delimiters and characters outside the X12 basic set.
  static String _clean(String s) => s
      .toUpperCase()
      .replaceAll(RegExp(r'[~*:^>]'), ' ')
      .replaceAll(RegExp(r"[^A-Z0-9 !&'()+,\-./;?=%@\[\]_{}\\|<#$]"), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  static String _cap(String s, int max) => s.length <= max ? s : s.substring(0, max).trim();

  static String _digits(String s) => s.replaceAll(RegExp(r'[^0-9]'), '');

  static String? _zip(String s) {
    final d = _digits(s);
    return (d.length == 5 || d.length == 9) ? d : null;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  /// Units and miles: whole numbers as "2", tenths as "7.3".
  static String _quantity(double q) {
    final tenths = (q * 10).round();
    return tenths % 10 == 0 ? '${tenths ~/ 10}' : '${tenths ~/ 10}.${tenths % 10}';
  }

  static String _dateDigits(DateTime d) => '${d.year.toString().padLeft(4, '0')}${_two(d.month)}${_two(d.day)}';

  static String? _d8(String yyyyMmDd) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(yyyyMmDd.trim());
    if (m == null) return null;
    final d = DateTime.tryParse(yyyyMmDd.trim());
    if (d == null || d.month != int.parse(m.group(2)!) || d.day != int.parse(m.group(3)!)) return null;
    return '${m.group(1)}${m.group(2)}${m.group(3)}';
  }

  static String _money(int cents) {
    final whole = cents ~/ 100;
    final frac = cents % 100;
    return frac == 0 ? '$whole' : '$whole.${_two(frac)}'.replaceFirst(RegExp(r'0$'), '');
  }

  /// "Last, First" or "First Middle Last".
  static ({String last, String first})? _splitName(String raw) {
    final s = _clean(raw);
    if (s.isEmpty) return null;
    if (s.contains(',')) {
      final parts = s.split(',');
      final last = parts.first.trim();
      final first = parts.skip(1).join(' ').trim().split(' ').first;
      return last.isEmpty ? null : (last: last, first: first);
    }
    final parts = s.split(' ');
    if (parts.length == 1) return (last: parts.first, first: '');
    return (last: parts.last, first: parts.first);
  }
}

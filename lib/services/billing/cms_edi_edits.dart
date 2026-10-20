// Medicare front-end (CCEM) edits from CMS Change Request 14429, transmittal
// R13967OTN (September 18, 2026; replaces R13934OTN): "HIPAA EDI Front End
// Updates for October 2026", effective October 1, 2026, implementation
// October 5, 2026. https://www.cms.gov/files/document/r13967otn.pdf
//
// The edits spreadsheets in that transmittal are what Medicare
// Administrative Contractors (Part A/B MACs and CEDI for DME) run on every
// 837 and 276 they receive. SOLIS applies the ones its 837P and 276 could
// violate to Medicare Part B claims (claim filing indicator MB) before they
// are sent. docs/CMS_EDI_OCT2026.md lists every new or changed 837P edit and
// what SOLIS does about it.
//
// Rule ids are 'CMS-EDI-<CMS edit reference>'.

import '../../models/claim_models.dart';
import '../../models/patient_account.dart';
import '../../models/provider_profile.dart' show isValidNpi;
import '../codesets/reference_data.dart';
import 'clearinghouse.dart';
import 'x12_837p.dart' show claimFilingIndicatorFor;

class CmsEdiEdits {
  CmsEdiEdits._();

  /// Citation on every issue these edits raise.
  static const citation = 'CMS CR 14429 (R13977OTN)';

  /// 2400 SV101-7 must be present when SV101-2 is on the CMS table of
  /// procedure codes that require a description (revised 10/5/2026).
  static const serviceDescription = 'CMS-EDI-X222.351.2400.SV101-7.020';

  /// SV101-7 is 1 to 80 characters (X222.351.2400.SV101-7.030).
  static const serviceDescriptionMax = 80;

  /// 1000B NM109 must equal GS03 (revised 10/5/2026: now rejected at the
  /// translator with a 999 instead of later in the CEM).
  static const receiverMatchesGs03 = 'CMS-EDI-X222.079.1000B.NM109.060';

  /// 2010BA NM109 must be a Medicare Beneficiary Identifier in MBI format.
  static const memberIdFormat = 'CMS-EDI-X222.121.2010BA.NM109.020';

  // 276 claim status request (005010X212) edits.
  static const statusProviderNpi = 'CMS-EDI-X212.49/126.2100C.NM109.020';
  static const statusProviderName = 'CMS-EDI-X212.49/126.2100C.NM103.010';
  static const statusSubscriberLastName = 'CMS-EDI-X212.56/135.2100D.NM103.010';
  static const statusSubscriberFirstName = 'CMS-EDI-X212.56/135.2100D.NM104.010';
  static const statusMemberIdMissing = 'CMS-EDI-X212.56/135.2100D.NM109.010';
  static const statusMemberId = 'CMS-EDI-X212.56/135.2100D.NM109.020';
  static const statusBirthDate = 'CMS-EDI-X212.54/NA.2000D.DMG02.010';
  static const statusBirthDateFuture = 'CMS-EDI-X212.54/NA.2000D.DMG02.030';
  static const statusGender = 'CMS-EDI-X212.54/NA.2000D.DMG03.010';
  static const statusServiceDate = 'CMS-EDI-X212.67/155.2200D.DTP03.020';
  static const statusServiceDateOrder = 'CMS-EDI-X212.67/155.2200D.DTP03.040';

  /// True for coverage billed to a Medicare Administrative Contractor
  /// (Original Medicare Part B, SBR09 MB). Medicare Advantage plans are
  /// commercial payers for EDI purposes and do not run the CCEM.
  static bool isMedicarePartB(InsuranceCoverage? ins) => ins != null && claimFilingIndicatorFor(ins) == 'MB';

  static final _nocWords = RegExp(
    r'not oth\w*\s+(c|s)|\bunclassified\b|\bunlisted\b|\bnoc\b|\bnos\b|\bmiscellaneous\b|\bmisc\b',
    caseSensitive: false,
  );

  /// True when a claim line with [code] must carry a narrative description
  /// (2400 SV101-7; CMS-1500 item 19 on paper): unlisted CPT procedures
  /// (codes ending in 99, plus 99429) and HCPCS Level II codes whose official
  /// descriptor says not otherwise classified, unlisted, unclassified or
  /// miscellaneous. CMS keeps the authoritative table inside the CCEM and
  /// does not publish it; this is the published-descriptor approximation.
  static bool requiresServiceDescription(String code) {
    final c = code.trim().toUpperCase();
    if (RegExp(r'^\d{3}99$').hasMatch(c) || c == '99429') return true;
    final h = ReferenceData.hcpcs?.lookup(c);
    if (h == null) return false;
    return _nocWords.hasMatch(h.shortDescription) || _nocWords.hasMatch(h.longDescription);
  }

  /// True when [description] only restates the generic code descriptor
  /// ("Unclassified drugs") instead of naming what was done or given.
  static bool isGenericDescription(String code, String description) {
    final d = description.trim().toLowerCase();
    if (d.isEmpty) return true;
    final h = ReferenceData.hcpcs?.lookup(code.trim().toUpperCase());
    if (h != null && (d == h.shortDescription.trim().toLowerCase() || d == h.longDescription.trim().toLowerCase())) return true;
    return RegExp(r'^(unlisted|unclassified|not otherwise|misc)', caseSensitive: false).hasMatch(d);
  }

  /// The SV101-7 text for a line: its description in X12 basic characters,
  /// at most 80. Null when the line does not need one or has none.
  static String? serviceDescriptionFor(ServiceLine line) {
    if (!requiresServiceDescription(line.code)) return null;
    final s = line.description
        .toUpperCase()
        .replaceAll(RegExp(r'[~*:^>]'), ' ')
        .replaceAll(RegExp(r"[^A-Z0-9 !&'()+,\-./;?=%@\[\]_{}\\|<#$]"), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (s.isEmpty) return null;
    return s.length <= serviceDescriptionMax ? s : s.substring(0, serviceDescriptionMax).trim();
  }

  static final _mbi = RegExp(r'^[1-9][AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y0-9][0-9][AC-HJKMNP-RT-Y][AC-HJKMNP-RT-Y0-9][0-9][AC-HJKMNP-RT-Y]{2}[0-9]{2}$');

  /// Medicare Beneficiary Identifier format (11 characters, no S L O I B Z;
  /// dashes as printed on the card are ignored).
  static bool isValidMbi(String id) => _mbi.hasMatch(id.trim().toUpperCase().replaceAll('-', ''));

  /// Problems in a 276 claim status request that the Medicare 276 edits
  /// (X212) reject, found before it is sent. NPI, names and service dates
  /// are checked for every payer (the 276 guide requires them); the member
  /// ID format, birth date and gender only for Medicare Part B, where the
  /// CMS edits require them. [today] is for tests.
  static List<ClearinghouseError> claimStatusProblems(ClaimStatusRequest r, {DateTime? today}) {
    final out = <ClearinghouseError>[];
    void add(String id, String message) => out.add(ClearinghouseError(code: id, description: '$message ($citation)'));
    final p = r.provider;
    final a = r.account;
    final medicare = isMedicarePartB(a.insurance);
    final groupNpi = p.groupNpi?.trim() ?? '';
    final npi = groupNpi.isNotEmpty ? groupNpi : p.npi.trim();
    if (!isValidNpi(npi)) add(statusProviderNpi, 'The provider NPI "$npi" is not a valid NPI (276 loop 2100C NM109).');
    if (p.practiceName.trim().isEmpty && p.fullName.trim().isEmpty) {
      add(statusProviderName, 'The provider name is missing (276 loop 2100C NM103).');
    }
    if (a.lastName.trim().isEmpty) add(statusSubscriberLastName, 'The patient last name is missing (276 loop 2100D NM103).');
    if (a.firstName.trim().isEmpty) add(statusSubscriberFirstName, 'Medicare requires the patient first name (276 loop 2100D NM104).');
    final memberId = a.insurance?.memberId.trim() ?? '';
    if (memberId.isEmpty) {
      add(statusMemberIdMissing, 'The member ID is missing (276 loop 2100D NM109).');
    } else if (medicare && !isValidMbi(memberId)) {
      add(statusMemberId, 'The Medicare ID "$memberId" is not an 11-character MBI (276 loop 2100D NM109).');
    }
    if (medicare) {
      final dob = a.dateOfBirth;
      final now = today ?? DateTime.now();
      if (dob == null) {
        add(statusBirthDate, 'Medicare requires the patient date of birth (276 loop 2000D DMG02).');
      } else if (dob.isAfter(DateTime(now.year, now.month, now.day))) {
        add(statusBirthDateFuture, 'The patient date of birth is in the future (276 loop 2000D DMG02).');
      }
      if (a.sex == PatientSex.unknown) add(statusGender, 'Medicare requires the patient sex (276 loop 2000D DMG03).');
    }
    final from = _date(r.dateOfServiceFrom);
    final to = r.dateOfServiceTo == null ? from : _date(r.dateOfServiceTo!);
    if (from == null || to == null) {
      add(statusServiceDate, 'The date of service is not a valid date (276 loop 2200D DTP03).');
    } else if (to.isBefore(from)) {
      add(statusServiceDateOrder, 'The service period ends before it begins (276 loop 2200D DTP03).');
    }
    return out;
  }

  /// yyyy-MM-dd or yyyyMMdd that is a real calendar date, else null.
  static DateTime? _date(String s) {
    final m = RegExp(r'^(\d{4})-?(\d{2})-?(\d{2})$').firstMatch(s.trim());
    if (m == null) return null;
    final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!), d = int.parse(m.group(3)!);
    final dt = DateTime(y, mo, d);
    return dt.year == y && dt.month == mo && dt.day == d ? dt : null;
  }

  /// Pre-submission checks for a Medicare Part B claim. Empty for other
  /// payers.
  static List<ClaimIssue> claimIssues({required ClaimDraft claim, required PatientAccount account}) {
    final ins = account.insurance;
    if (!isMedicarePartB(ins)) return const [];
    final issues = <ClaimIssue>[];
    final memberId = ins!.memberId.trim();
    if (memberId.isNotEmpty && !isValidMbi(memberId)) {
      issues.add(ClaimIssue(
        IssueSeverity.error,
        'Medicare ID is not an MBI: $memberId',
        'Medicare rejects a claim whose member ID (2010BA NM109) is not an 11-character Medicare Beneficiary Identifier, '
            'for example 1EG4TE5MK73. Rescan the red, white and blue Medicare card or ask the patient for the MBI.',
        ruleId: memberIdFormat,
        citation: citation,
      ));
    }
    for (final l in claim.lines) {
      if (!requiresServiceDescription(l.code)) continue;
      final empty = l.description.trim().isEmpty;
      final generic = !empty && isGenericDescription(l.code, l.description);
      if (!empty && !generic) continue;
      issues.add(ClaimIssue(
        empty ? IssueSeverity.error : IssueSeverity.warning,
        empty ? 'Describe the service: ${l.code}' : 'Name what was done: ${l.code}',
        '${l.code} is an unlisted or not-otherwise-classified code. Medicare rejects the line unless it carries a description '
            'of the service (837P SV101-7, up to $serviceDescriptionMax characters), for example the drug name, dose and route, '
            'or the procedure performed.${empty ? '' : ' "${l.description.trim()}" only repeats the code\'s own wording.'}',
        code: l.code,
        ruleId: serviceDescription,
        citation: citation,
      ));
    }
    return issues;
  }
}

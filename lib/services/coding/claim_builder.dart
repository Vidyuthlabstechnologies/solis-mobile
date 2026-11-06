import '../../models/claim_models.dart';
import '../../models/patient_account.dart';
import '../../models/provider_profile.dart';
import 'code_rules.dart';
import 'place_of_service.dart';

/// Builds a billing-software-ready claim from a visit. The output carries
/// both the CMS-1500 (02/12) box layout and the matching ASC X12 837P loops,
/// so it can feed a clearinghouse API or a practice management import.
class ClaimBuilder {
  static const _pointerLetters = 'ABCDEFGHIJKL';

  static String claimId(PatientAccount a, Visit v) => '${a.accountNumber}-V${v.number}';

  static Map<String, dynamic> build({
    required PatientAccount account,
    required Visit visit,
    required ProviderProfile provider,
    required ClaimDraft claim,
    List<ClaimIssue> issues = const [],
  }) {
    final ins = account.insurance;
    final dx = claim.billable.take(12).toList();
    String pointer(String code) {
      final i = dx.indexWhere((d) => d.code == code);
      return i < 0 ? '' : _pointerLetters[i];
    }

    final dob = account.dateOfBirth?.toIso8601String().split('T').first;
    final pos = placeOfService(visit.placeOfService);
    final lines = [
      for (final l in claim.lines)
        {
          'box24A_dateOfService': visit.dateOfService,
          'box24B_placeOfService': visit.placeOfService,
          'box24D_procedure': l.code,
          'box24D_modifiers': l.modifiers,
          'box24E_diagnosisPointer': l.diagnosisCodes.map(pointer).where((p) => p.isNotEmpty).join(),
          'box24F_charge': l.lineCharge,
          'box24G_units': l.billedUnits,
          'box24J_renderingNpi': provider.npi,
          'description': l.description,
        },
    ];

    return {
      'claimId': claimId(account, visit),
      'formType': 'CMS-1500 (02/12)',
      'transaction': '837P',
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
      'readyToSubmit': !issues.any((i) => i.severity == IssueSeverity.error),
      'payer': {
        'name': ins?.payerName,
        'payerId': ins?.payerId,
        'planName': ins?.planName,
        'planType': ins?.planType,
      },
      'insured': {
        'box1a_memberId': ins?.memberId,
        'box4_name': ins?.subscriberName ?? account.fullName,
        'box11_groupNumber': ins?.groupNumber,
        'box11c_planName': ins?.planName,
      },
      'patient': {
        'box2_name': '${account.lastName}, ${account.firstName}${account.middleName != null ? ' ${account.middleName}' : ''}',
        'box3_dateOfBirth': dob,
        'box3_sex': sexCode(account.sex),
        'box5_address': {
          'line1': account.addressLine1,
          'city': account.city,
          'state': account.state,
          'zip': account.zip,
          'phone': account.phone,
        },
        'box6_relationshipToInsured': ins?.relationship ?? 'self',
        'box26_patientAccountNumber': account.accountNumber,
      },
      'diagnoses': {
        'box21_icdIndicator': '0', // ICD-10-CM
        'codes': [
          for (var i = 0; i < dx.length; i++) {'pointer': _pointerLetters[i], 'code': dx[i].code, 'description': dx[i].description},
        ],
      },
      'serviceLines': lines,
      'provider': {
        'box17_referringProvider': visit.referringProvider == null
            ? null
            : {'qualifier': 'DN', 'name': visit.referringProvider!.displayName, 'npi': visit.referringProvider!.npi},
        'box23_priorAuthorization': visit.priorAuthNumber,
        'box24J_renderingNpi': provider.npi,
        'box25_federalTaxId': provider.taxId,
        'box25_taxIdType': 'EIN',
        'box27_acceptAssignment': true,
        'box28_totalCharge': claim.totalCharge,
        'box31_signature': '${provider.displayName}, signature on file',
        'box32_serviceFacility': {
          'name': visit.serviceFacility?.name ?? provider.practiceName,
          'address': visit.serviceFacility?.oneLine ?? '${provider.addressLine1}, ${provider.city}, ${provider.state} ${provider.zip}',
          'placeOfService': pos.label,
        },
        'box33_billingProvider': {
          'name': provider.practiceName,
          'address': '${provider.addressLine1}, ${provider.city}, ${provider.state} ${provider.zip}',
          'phone': provider.phone,
          'npi': provider.groupNpi ?? provider.npi,
          'taxonomy': provider.taxonomyCode,
        },
      },
      'x12_837P': {
        'loop2010AA_billingProvider': {
          'NM1': ['85', '2', provider.practiceName, '', '', '', '', 'XX', provider.groupNpi ?? provider.npi],
          'PRV': ['BI', 'PXC', provider.taxonomyCode],
          'REF': ['EI', provider.taxId.replaceAll('-', '')],
        },
        'loop2010BA_subscriber': {
          'NM1': ['IL', '1', account.lastName, account.firstName, account.middleName ?? '', '', '', 'MI', ins?.memberId ?? ''],
          'DMG': ['D8', dob?.replaceAll('-', '') ?? '', sexCode(account.sex)],
        },
        'loop2010BB_payer': {
          'NM1': ['PR', '2', ins?.payerName ?? '', '', '', '', '', 'PI', ins?.payerId ?? ''],
        },
        'loop2300_claim': {
          'CLM': [claimId(account, visit), claim.totalCharge.toStringAsFixed(2), '', '', '${visit.placeOfService}:B:1', 'Y', 'A', 'Y', 'Y'],
          'HI': [
            for (var i = 0; i < dx.length; i++) '${i == 0 ? 'ABK' : 'ABF'}:${icdForX12(dx[i].code)}',
          ],
        },
        'loop2400_serviceLines': [
          for (var i = 0; i < claim.lines.length; i++)
            {
              'LX': i + 1,
              'SV1': [
                ['HC', claim.lines[i].code, ...claim.lines[i].modifiers].join(':'),
                claim.lines[i].lineCharge.toStringAsFixed(2),
                'UN',
                claim.lines[i].unitsLabel,
                visit.placeOfService,
                '',
                claim.lines[i].diagnosisCodes
                    .map((c) => dx.indexWhere((d) => d.code == c) + 1)
                    .where((n) => n > 0)
                    .join(':'),
              ],
              'DTP': ['472', 'D8', visit.dateOfService.replaceAll('-', '')],
            },
        ],
      },
      if (visit.transport != null) 'ambulanceTransport': visit.transport!.toJson(),
      'scrubber': issues.map((i) => i.toJson()).toList(),
    };
  }
}

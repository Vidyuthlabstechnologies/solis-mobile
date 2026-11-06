import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/claim_models.dart';
import 'package:solis_mobile/models/clinical_models.dart';
import 'package:solis_mobile/models/provider_profile.dart';
import 'package:solis_mobile/services/attestation.dart';
import 'package:solis_mobile/services/coding/clinical_coder.dart';
import 'package:solis_mobile/services/coding/place_of_service.dart';
import 'package:solis_mobile/services/security/redaction.dart';

ClaimDiagnosis _dx(String code) => ClaimDiagnosis(code: code, description: code, source: DxSource.physicianConfirmed);

void main() {
  group('favorite codes', () {
    test('star and unstar, kept across a save', () {
      var p = ProviderProfile.demo();
      p = p.toggleFavoriteDiagnosis('j06.9', 'Acute URI').toggleFavoriteDiagnosis('I10', 'Hypertension').toggleFavoriteService('99214');
      final back = ProviderProfile.fromJson(p.toJson());
      expect(back.favoriteDiagnoses, {'J06.9': 'Acute URI', 'I10': 'Hypertension'});
      expect(back.favoriteServices, ['99214']);
      final off = back.toggleFavoriteDiagnosis('J06.9', 'x').toggleFavoriteService('99214');
      expect(off.favoriteDiagnoses.keys, ['I10']);
      expect(off.favoriteServices, isEmpty);
      expect(ProviderProfile.demo().toJson().containsKey('favoriteServices'), isFalse);
    });
  });

  group('versioned attestation', () {
    test('text and version are stored with the signature and cleared with it', () {
      expect(attestationVersion, isNotEmpty);
      expect(attestationText('Dr. A'), endsWith('Signing as Dr. A.'));
      final e = ClinicalEncounter(
        id: '1', patientName: 'P', mrn: 'M', ageGender: '1F', attendingPhysician: 'A', date: '2026-11-06',
        vitals: const [], subjective: 's', objective: 'o', assessment: 'a', plan: 'p', codes: const [],
      ).copyWith(isSigned: true, attestationVersion: attestationVersion, attestationText: attestationText('Dr. A'));
      final back = ClinicalEncounter.fromJson(e.toJson());
      expect(back.attestationVersion, attestationVersion);
      expect(back.attestationText, attestationText('Dr. A'));
      expect(back.copyWith(clearSignature: true).attestationText, isEmpty);
    });
  });

  group('why this E/M level, by element', () {
    test('each element is named', () {
      final mod = ClinicalCoder.mdmBreakdown('I will start you on lisinopril 10 mg daily.', [_dx('I10')]);
      expect(mod.level, MdmLevel.moderate);
      expect(mod.explain(), 'Problems: 1 billable problem addressed. Data: no tests or outside records named. Risk: prescription drug management.');
      final low = ClinicalCoder.mdmBreakdown('Get an x-ray of the knee.', [_dx('M25.561')]);
      expect(low.level, MdmLevel.low);
      expect(low.data, 'imaging or a referral ordered');
      final none = ClinicalCoder.mdmBreakdown('Hello.', const []);
      expect(none.level, MdmLevel.straightforward);
      expect(none.problems, 'no billable problem documented');
      final high = ClinicalCoder.mdmBreakdown('We need to admit the patient now.', [_dx('I10')]);
      expect(high.level, MdmLevel.high);
      expect(high.risk, contains('hospital-level care'));
    });
  });

  group('identifiers are removed before upload', () {
    test('SSN, MBI and card numbers; clinical numbers stay', () {
      expect(redactIdentifiers('My social is 123-45-6789, thanks.'), 'My social is [SSN], thanks.');
      expect(redactIdentifiers('SSN 123456789'), 'SSN [SSN]');
      expect(redactIdentifiers('social security number is 123 45 6789'), 'social security number is [SSN]');
      expect(redactIdentifiers('Medicare number 1EG4-TE5-MK73'), 'Medicare number [MBI]');
      expect(redactIdentifiers('card 4111 1111 1111 1111 please'), 'card [CARD] please');
      const clinical = 'BP 120/80, zip 94158-1234, call 415-555-0142, 500 mg twice daily, order 123456789.';
      expect(redactIdentifiers(clinical), clinical);
      expect(redactIdentifiers('card 4111 1111 1111 1112'), 'card 4111 1111 1111 1112', reason: 'fails Luhn');
    });
  });
}

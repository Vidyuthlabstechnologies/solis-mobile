import 'place_of_service.dart';

/// CPT and HCPCS services offered in the "add service" search. CPT
/// descriptions are short paraphrases, not AMA descriptors.
class CatalogService {
  final String code;
  final String description;
  const CatalogService(this.code, this.description);
}

final List<CatalogService> serviceCatalog = [
  for (final c in const [
    '99202', '99203', '99204', '99205', '99212', '99213', '99214', '99215',
    '99282', '99283', '99284', '99285',
    '99221', '99222', '99223', '99231', '99232', '99233',
    '99304', '99305', '99306', '99307', '99308', '99309', '99310',
    '99341', '99342', '99344', '99345', '99347', '99348', '99349', '99350',
  ])
    CatalogService(c, emDescription(c)),
  const CatalogService('99385', 'Preventive visit, new patient, age 18 to 39'),
  const CatalogService('99386', 'Preventive visit, new patient, age 40 to 64'),
  const CatalogService('99387', 'Preventive visit, new patient, age 65 and over'),
  const CatalogService('99395', 'Preventive visit, established patient, age 18 to 39'),
  const CatalogService('99396', 'Preventive visit, established patient, age 40 to 64'),
  const CatalogService('99397', 'Preventive visit, established patient, age 65 and over'),
  const CatalogService('93000', 'Electrocardiogram, 12 leads, with interpretation and report'),
  const CatalogService('93010', 'Electrocardiogram, interpretation and report only'),
  const CatalogService('20610', 'Arthrocentesis, aspiration or injection, major joint'),
  const CatalogService('94640', 'Inhalation treatment (nebulizer)'),
  const CatalogService('87880', 'Rapid strep test (group A Streptococcus antigen)'),
  const CatalogService('81002', 'Urinalysis, non-automated, without microscopy'),
  const CatalogService('36415', 'Venipuncture, routine'),
  const CatalogService('96372', 'Therapeutic injection, subcutaneous or intramuscular'),
  const CatalogService('90471', 'Immunization administration, first vaccine'),
  const CatalogService('G0101', 'Cervical or vaginal cancer screening; pelvic and clinical breast exam'),
  const CatalogService('Q0091', 'Screening Papanicolaou smear, obtaining and preparing'),
  const CatalogService('G0103', 'Prostate cancer screening, PSA test'),
  const CatalogService('43235', 'Upper GI endoscopy, diagnostic'),
  const CatalogService('A0427', 'Ambulance, advanced life support, emergency (ALS1)'),
  const CatalogService('A0429', 'Ambulance, basic life support, emergency (BLS)'),
  const CatalogService('A0425', 'Ambulance ground mileage, per statute mile'),
  const CatalogService('G2211', 'Visit complexity add-on: longitudinal care of a serious or complex condition (Medicare)'),
  const CatalogService('99417', 'Prolonged office visit, each additional 15 minutes'),
  const CatalogService('G2212', 'Prolonged office visit, each additional 15 minutes (Medicare)'),
];

/// The catalog description of [code], or null when it is not in the catalog.
String? serviceDescription(String code) {
  for (final s in serviceCatalog) {
    if (s.code == code) return s.description;
  }
  return null;
}

import 'dart:convert';
import '../models/clinical_models.dart';

class FhirExportService {
  /// Generates a compliant HL7 FHIR R4 Transaction Bundle from a ClinicalEncounter
  static Map<String, dynamic> generateFhirR4Bundle(ClinicalEncounter encounter) {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    final patientId = encounter.mrn.replaceAll(RegExp(r'[^a-zA-Z0-9-]'), '');
    final encounterId = encounter.id.replaceAll(RegExp(r'[^a-zA-Z0-9-]'), '');

    final entries = <Map<String, dynamic>>[];

    // 1. Patient Resource
    entries.add({
      'fullUrl': 'urn:uuid:patient-$patientId',
      'resource': {
        'resourceType': 'Patient',
        'id': patientId,
        'identifier': [
          {
            'system': 'urn:oid:solis.hospital.mrn',
            'value': encounter.mrn,
          }
        ],
        'name': [
          {
            'use': 'official',
            'text': encounter.patientName,
          }
        ],
        'gender': encounter.ageGender.toUpperCase().contains('F')
            ? 'female'
            : encounter.ageGender.toUpperCase().contains('M')
                ? 'male'
                : 'unknown',
      },
      'request': {
        'method': 'POST',
        'url': 'Patient',
      },
    });

    // 2. Encounter Resource
    entries.add({
      'fullUrl': 'urn:uuid:encounter-$encounterId',
      'resource': {
        'resourceType': 'Encounter',
        'id': encounterId,
        'status': 'finished',
        'class': {
          'system': 'http://terminology.hl7.org/CodeSystem/v3-ActCode',
          'code': 'AMB',
          'display': 'ambulatory',
        },
        'subject': {
          'reference': 'urn:uuid:patient-$patientId',
          'display': encounter.patientName,
        },
        'participant': [
          {
            'individual': {
              'display': encounter.attendingPhysician,
            }
          }
        ],
        'period': {
          'start': encounter.date,
          'end': timestamp,
        },
      },
      'request': {
        'method': 'POST',
        'url': 'Encounter',
      },
    });

    // 3. Observations (Vital Signs)
    for (int i = 0; i < encounter.vitals.length; i++) {
      final v = encounter.vitals[i];
      entries.add({
        'fullUrl': 'urn:uuid:obs-$encounterId-$i',
        'resource': {
          'resourceType': 'Observation',
          'status': 'final',
          'category': [
            {
              'coding': [
                {
                  'system': 'http://terminology.hl7.org/CodeSystem/observation-category',
                  'code': 'vital-signs',
                  'display': 'Vital Signs',
                }
              ]
            }
          ],
          'code': {
            'text': v.label,
          },
          'subject': {
            'reference': 'urn:uuid:patient-$patientId',
          },
          'encounter': {
            'reference': 'urn:uuid:encounter-$encounterId',
          },
          'valueString': v.value,
          'interpretation': v.isAbnormal
              ? [
                  {
                    'coding': [
                      {
                        'system': 'http://terminology.hl7.org/CodeSystem/v3-ObservationInterpretation',
                        'code': 'A',
                        'display': 'Abnormal',
                      }
                    ]
                  }
                ]
              : null,
        },
        'request': {
          'method': 'POST',
          'url': 'Observation',
        },
      });
    }

    // 4. Conditions (ICD-10 Diagnoses)
    for (int i = 0; i < encounter.codes.length; i++) {
      final c = encounter.codes[i];
      if (c.type == 'ICD10') {
        entries.add({
          'fullUrl': 'urn:uuid:condition-$encounterId-$i',
          'resource': {
            'resourceType': 'Condition',
            'clinicalStatus': {
              'coding': [
                {
                  'system': 'http://terminology.hl7.org/CodeSystem/condition-clinical',
                  'code': 'active',
                }
              ]
            },
            'verificationStatus': {
              'coding': [
                {
                  'system': 'http://terminology.hl7.org/CodeSystem/condition-ver-status',
                  'code': 'confirmed',
                }
              ]
            },
            'category': [
              {
                'coding': [
                  {
                    'system': 'http://terminology.hl7.org/CodeSystem/condition-category',
                    'code': 'encounter-diagnosis',
                  }
                ]
              }
            ],
            'code': {
              'coding': [
                {
                  'system': 'http://hl7.org/fhir/sid/icd-10-cm',
                  'code': c.code,
                  'display': c.description,
                }
              ],
              'text': c.description,
            },
            'subject': {
              'reference': 'urn:uuid:patient-$patientId',
            },
            'encounter': {
              'reference': 'urn:uuid:encounter-$encounterId',
            },
            'note': c.rationale != null
                ? [
                    {'text': c.rationale}
                  ]
                : null,
          },
          'request': {
            'method': 'POST',
            'url': 'Condition',
          },
        });
      }
    }

    // 5. MedicationRequests (Prescriptions from Action Items)
    for (final a in encounter.nextSteps) {
      if (a.category == ActionCategory.prescription) {
        entries.add({
          'fullUrl': 'urn:uuid:med-${a.id}',
          'resource': {
            'resourceType': 'MedicationRequest',
            'status': a.isCompleted ? 'completed' : 'active',
            'intent': 'order',
            'medicationCodeableConcept': {
              'text': a.title,
            },
            'subject': {
              'reference': 'urn:uuid:patient-$patientId',
            },
            'dosageInstruction': [
              {
                'text': a.detailPayload ?? a.description,
              }
            ],
          },
          'request': {
            'method': 'POST',
            'url': 'MedicationRequest',
          },
        });
      }
    }

    // 6. ServiceRequests (CPOE Labs & Imaging)
    for (final a in encounter.nextSteps) {
      if (a.category == ActionCategory.order) {
        entries.add({
          'fullUrl': 'urn:uuid:service-${a.id}',
          'resource': {
            'resourceType': 'ServiceRequest',
            'status': a.isCompleted ? 'completed' : 'active',
            'intent': 'order',
            'priority': a.urgency.toLowerCase() == 'stat' ? 'stat' : 'routine',
            'code': {
              'text': a.title,
            },
            'subject': {
              'reference': 'urn:uuid:patient-$patientId',
            },
            'encounter': {
              'reference': 'urn:uuid:encounter-$encounterId',
            },
            'note': [
              {'text': a.description}
            ],
          },
          'request': {
            'method': 'POST',
            'url': 'ServiceRequest',
          },
        });
      }
    }

    // 7. DocumentReference (Signed Clinical Note)
    final notePlainText = '''
SUBJECTIVE:
${encounter.subjective}

OBJECTIVE:
${encounter.objective}

ASSESSMENT:
${encounter.assessment}

PLAN:
${encounter.plan}
''';

    entries.add({
      'fullUrl': 'urn:uuid:docref-$encounterId',
      'resource': {
        'resourceType': 'DocumentReference',
        'status': 'current',
        'docStatus': encounter.isSigned ? 'final' : 'preliminary',
        'type': {
          'coding': [
            {
              'system': 'http://loinc.org',
              'code': '11488-4',
              'display': 'Consultation note',
            }
          ]
        },
        'subject': {
          'reference': 'urn:uuid:patient-$patientId',
        },
        'author': [
          {
            'display': encounter.attendingPhysician,
          }
        ],
        'authenticator': {
          'display': encounter.attendingPhysician,
        },
        'securityLabel': [
          {
            'coding': [
              {
                'system': 'http://terminology.hl7.org/CodeSystem/v3-Confidentiality',
                'code': 'N',
                'display': 'normal',
              }
            ]
          }
        ],
        'content': [
          {
            'attachment': {
              'contentType': 'text/plain',
              'data': base64Encode(utf8.encode(notePlainText)),
              'title': 'Signed SOAP Progress Note',
              'creation': timestamp,
            }
          }
        ],
        'context': {
          'encounter': [
            {
              'reference': 'urn:uuid:encounter-$encounterId',
            }
          ]
        },
      },
      'request': {
        'method': 'POST',
        'url': 'DocumentReference',
      },
    });

    return {
      'resourceType': 'Bundle',
      'id': 'solis-bundle-$encounterId',
      'meta': {
        'lastUpdated': timestamp,
        'profile': [
          'http://hl7.org/fhir/us/core/StructureDefinition/us-core-documentreference'
        ],
      },
      'type': 'transaction',
      'entry': entries,
    };
  }
}

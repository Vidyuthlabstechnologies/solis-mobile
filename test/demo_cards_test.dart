import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/models/patient_account.dart';
import 'package:solis_mobile/services/card_parser.dart';
import 'package:solis_mobile/services/card_scanner.dart';

/// The bundled SAMPLE cards (assets/demo_cards) and the text ML Kit reads
/// from them, line by line, top to bottom. Keeps the "Try a sample card"
/// demo working end to end in the parser.
void main() {
  test('every demo card asset exists', () {
    for (final list in CardScanner.demoAssets.values) {
      for (final a in list) {
        expect(File(a).existsSync(), isTrue, reason: a);
      }
    }
  });

  test('sample license barcode (AAMVA) parses to the demo patient', () {
    const body = 'DLDCAC\nDCBNONE\nDCDNONE\nDBA03142030\nDCSRIVERA\nDACJORDAN\nDADA\nDBD03102025\n'
        'DBB03141982\nDBC1\nDAYBRO\nDAU070 IN\nDAG1234 SAMPLE ST\nDAISACRAMENTO\nDAJCA\nDAK958140000\n'
        'DAQD1234567\nDCFDEMO0000000001\nDCGUSA\nDDEN\nDDFN\nDDGN\n\r';
    final raw = '@\n\x1e\rANSI 636014090001DL0031${body.length.toString().padLeft(4, '0')}$body';
    final id = CardParser.parseAamva(raw)!;
    expect(id.firstName, 'Jordan');
    expect(id.lastName, 'Rivera');
    expect(id.dateOfBirth, DateTime(1982, 3, 14));
    expect(id.sex, PatientSex.male);
    expect(id.addressLine1, isNotNull);
    expect(id.city, isNotNull);
    expect(id.state, 'CA');
    expect(id.zip, '95814');
    expect(id.licenseNumber, 'D1234567');
  });

  test('sample insurance card text', () {
    const front = 'DEMO HEALTH PLAN\nPPO\nMember Name: JORDAN A RIVERA\nMember ID: DHP123456789\nGroup No: 0012345\n'
        'DOB: 03/14/1982\nEffective Date: 01/01/2026\nPCP \$25 Specialist \$50 ER \$250\n'
        'Rx BIN: 999999\nRx PCN: DEMO\nRx Grp: DEMORX1\nPayer ID: 99999';
    final id = CardParser.parseInsuranceCard(front);
    expect(id.memberId, 'DHP123456789');
    expect(id.groupNumber, '0012345');
    expect(id.rxBin, '999999');
    expect(id.rxPcn, 'DEMO');
    expect(id.payerId, '99999');
    expect(id.dateOfBirth, DateTime(1982, 3, 14));
    expect(id.firstName, 'Jordan');
    expect(id.lastName, 'Rivera');
    expect(id.copays, isNotEmpty);
  });

  test('sample license front text', () {
    const front = 'SAMPLE DRIVER LICENSE\nDEMO\n4d DLN D1234567\n1 RIVERA\n2 JORDAN A\n8 1234 SAMPLE ST\n'
        'SACRAMENTO, CA 95814\n3 DOB 03/14/1982\n15 SEX M\n4b EXP 03/14/2030\n4a ISS 03/10/2025\nSPECIMEN - NOT A GOVERNMENT ID';
    final id = CardParser.parseLicenseFront(front);
    expect(id.lastName, 'Rivera');
    expect(id.firstName, 'Jordan');
    expect(id.dateOfBirth, DateTime(1982, 3, 14));
    expect(id.sex, PatientSex.male);
    expect(id.licenseNumber, 'D1234567');
  });

  test('sample SSN card keeps only the last 4', () {
    const text = 'SAMPLE SOCIAL SECURITY CARD\n078-05-1120\nTHIS NUMBER HAS BEEN ESTABLISHED FOR\nJORDAN A RIVERA\nSIGNATURE\nSPECIMEN NUMBER - DEMO ONLY';
    final id = CardParser.parseSsnCard(text);
    expect(id.ssnLast4, '1120');
    expect(id.firstName, 'Jordan');
    expect(id.lastName, 'Rivera');
  });
}

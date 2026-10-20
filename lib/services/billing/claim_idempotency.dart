import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Idempotency key for sending one claim to the clearinghouse.
///
/// The key must be the same when the same claim is sent twice (a double tap,
/// or a retry after a timeout whose request did reach Stedi), and different
/// when the claim itself changed. So it is built from the patient control
/// number and a hash of the claim content without the envelope: ISA, GS, ST,
/// BHT, SE, GE and IEA carry control numbers, dates and times that change on
/// every build of the file, while the claim does not.
String claimIdempotencyKey(String x12, String patientControlNumber) {
  final body = x12
      .replaceAll('\r', '')
      .replaceAll('\n', '')
      .split('~')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty && !_envelope.contains(s.split('*').first))
      .join('~');
  final digest = sha256.convert(utf8.encode(body)).toString().substring(0, 32);
  final pcn = patientControlNumber.replaceAll(RegExp(r'[^A-Za-z0-9-]'), '');
  return 'solis-$pcn-$digest';
}

const _envelope = {'ISA', 'GS', 'ST', 'BHT', 'SE', 'GE', 'IEA'};

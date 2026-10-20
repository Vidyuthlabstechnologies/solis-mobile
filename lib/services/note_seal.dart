import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Tamper evidence for a signed note: hex SHA-256 over the exact note text
/// the physician signed, the signer's NPI and the signing time. Anyone with
/// the stored note can recompute it; a changed character gives a different
/// seal. It is not a digital signature (no private key is involved).
class NoteSeal {
  NoteSeal._();

  static const version = 'solis-note-seal-v1';

  /// The bytes that are hashed: a version line, the NPI, the UTC signing time
  /// to the second, then the note with line endings normalized.
  static String canonical({required String noteText, required String signerNpi, required DateTime signedAtUtc}) {
    final t = signedAtUtc.toUtc();
    final when = DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second).toIso8601String();
    final note = noteText.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n').map((l) => l.trimRight()).join('\n').trim();
    return '$version\n${signerNpi.trim()}\n$when\n$note';
  }

  static String compute({required String noteText, required String signerNpi, required DateTime signedAtUtc}) =>
      sha256.convert(utf8.encode(canonical(noteText: noteText, signerNpi: signerNpi, signedAtUtc: signedAtUtc))).toString();

  static bool verify({required String seal, required String noteText, required String signerNpi, required DateTime signedAtUtc}) =>
      seal.isNotEmpty && seal == compute(noteText: noteText, signerNpi: signerNpi, signedAtUtc: signedAtUtc);
}

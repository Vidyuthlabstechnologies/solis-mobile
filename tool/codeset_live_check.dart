// Live check of the published code sets, exactly as the app does it: fetches
// manifest.json from the public bucket, verifies the Ed25519 signature with
// the key compiled into the app, downloads every file, verifies size and
// sha256, installs into a temp folder and prints what would be used. Also
// reports whether the host's TLS chain ends in one of the pinned roots
// (informational: the updater uses platform trust, see codeset_updates.dart).
//
//   dart run tool/codeset_live_check.dart [baseUrl]
//
// Exit code 0 when the published set verifies and installs.
import 'dart:convert';
import 'dart:io';

import 'package:solis_mobile/services/codesets/codeset_update_client.dart';
import 'package:solis_mobile/services/net/pinned_roots.dart';

// Same values as lib/services/codesets/codeset_updates.dart (that file
// imports Flutter, so it cannot be loaded by `dart run`).
const _baseUrl = 'https://pub-c522aa6f22b14c29b715aff2d857c424.r2.dev';

Future<void> main(List<String> args) async {
  final base = Uri.parse(args.isNotEmpty ? args.first : _baseUrl);
  final keyText = File('tool/codeset_updater/public_key.txt').readAsStringSync();
  final appKeys = File('lib/services/codesets/codeset_updates.dart').readAsStringSync();
  final keys = parseTrustedKeys(keyText);
  for (final id in keys.keys) {
    if (!appKeys.contains(id)) {
      stderr.writeln('key $id from public_key.txt is not compiled into the app');
      exitCode = 1;
    }
  }

  final dir = await Directory.systemTemp.createTemp('codeset_live_check');
  try {
    final client = CodesetUpdateClient(
      root: dir,
      baseUrl: base,
      trustedKeys: keys,
      httpGet: ioHttpGet(),
    );
    final r = await client.checkForUpdate();
    stdout.writeln(r);
    if (r.status != CodesetUpdateStatus.updated) exitCode = 1;
    final m = client.installed;
    if (m != null) {
      stdout.writeln('serial ${m.serial}, key ${m.keyId} (signature verified), '
          '${m.files.length} files, ICD editions ${client.icdEditions()}');
      for (final dos in [DateTime(2026, 9, 30), DateTime(2026, 10, 1), DateTime(2027, 10, 1)]) {
        stdout.writeln('  ICD-10-CM for DOS ${dos.toIso8601String().substring(0, 10)}: '
            '${client.fileForSet('icd10cm', dateOfService: dos)?.uri.pathSegments.last ?? 'bundled'}');
      }
      for (final f in m.files) {
        final bundled = File('assets/codes/${f.name}');
        final same = bundled.existsSync() && await sha256Hex(bundled.readAsBytesSync()) == f.sha256;
        stdout.writeln('  ${f.name.padRight(32)} ${f.size.toString().padLeft(8)}  '
            '${same ? 'same as bundled' : 'differs from bundled'}');
      }
    }
  } finally {
    await dir.delete(recursive: true);
  }

  // TLS: does the chain verify against only the pinned roots?
  final ctx = SecurityContext(withTrustedRoots: false)..setTrustedCertificatesBytes(utf8.encode(pinnedRootsPem));
  try {
    final s = await SecureSocket.connect(base.host, 443, context: ctx, timeout: const Duration(seconds: 20));
    stdout.writeln('TLS ${base.host}: chain verifies against the pinned roots '
        '(leaf issuer ${s.peerCertificate?.issuer})');
    await s.close();
  } on Exception catch (e) {
    stdout.writeln('TLS ${base.host}: does NOT verify against the pinned roots ($e)');
  }
}

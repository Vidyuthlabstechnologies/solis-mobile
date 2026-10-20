import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/services/codesets/codeset_update_client.dart';
import 'package:solis_mobile/services/codesets/codeset_updates.dart';

// Fixtures are written by tool/codeset_updater/make_dart_fixtures.py with the
// Python signer, so these tests also prove that Python and Dart agree on
// canonical JSON.
final fixtures = Directory('test/codeset_update/fixtures');
const productionKeyFile = 'tool/codeset_updater/public_key.txt';

Map<String, dynamic> readJson(String name) =>
    jsonDecode(File('${fixtures.path}/$name').readAsStringSync()) as Map<String, dynamic>;

/// Test key: Ed25519 seed bytes 1..32 (same as make_fixtures.py). Not the production key.
final testSeed = List<int>.generate(32, (i) => i + 1);

Future<Map<String, dynamic>> signInDart(Map<String, dynamic> manifest) async {
  final kp = await Ed25519().newKeyPairFromSeed(testSeed);
  final pub = await kp.extractPublicKey();
  final keyId = parseTrustedKeys(File('${fixtures.path}/test_public_key.txt').readAsStringSync()).keys.single;
  expect(pub.bytes, parseTrustedKeys(File('${fixtures.path}/test_public_key.txt').readAsStringSync())[keyId]);
  final body = Map<String, dynamic>.of(manifest)..remove('signature');
  final sig = await Ed25519().sign(utf8.encode(canonicalJson(body)), keyPair: kp);
  return {
    ...body,
    'signature': {'alg': 'Ed25519', 'key_id': keyId, 'value': base64.encode(sig.bytes)},
  };
}

Uint8List gz(String text) => Uint8List.fromList(gzip.encode(utf8.encode(text)));

Future<String> sha(List<int> b) => sha256Hex(b);

/// In-memory "R2 bucket".
class FakeBucket {
  final objects = <String, Uint8List>{};
  final requests = <String>[];

  Future<Uint8List> get(Uri url) async {
    final key = url.path.replaceFirst(RegExp(r'^/'), '');
    requests.add(key);
    final v = objects[key];
    if (v == null) throw HttpException('HTTP 404', uri: url);
    return v;
  }

  void putManifest(Map<String, dynamic> m) {
    objects['manifest.json'] = Uint8List.fromList(utf8.encode(const JsonEncoder.withIndent(' ').convert(m)));
  }

  void putFixtureFiles() {
    final m = readJson('manifest_v1.json');
    for (final f in (m['files'] as List).cast<Map<String, dynamic>>()) {
      objects[f['path'] as String] = File('${fixtures.path}/files/${f['name']}').readAsBytesSync();
    }
  }
}

void main() {
  final trusted = parseTrustedKeys(File('${fixtures.path}/test_public_key.txt').readAsStringSync());
  late Directory tmp;
  late FakeBucket bucket;
  var now = DateTime.utc(2026, 10, 17, 8);

  CodesetUpdateClient client({int bundledSerial = 0}) => CodesetUpdateClient(
        root: Directory('${tmp.path}/codesets'),
        baseUrl: Uri.parse('https://pub.example.r2.dev'),
        trustedKeys: trusted,
        httpGet: bucket.get,
        bundledSerial: bundledSerial,
        clock: () => now,
      );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('codeset_client_test');
    bucket = FakeBucket();
    now = DateTime.utc(2026, 10, 17, 8);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('canonical JSON and signature', () {
    test('Dart canonical bytes equal the Python canonical bytes', () {
      final m = readJson('manifest_v1.json')..remove('signature');
      expect(canonicalJson(m), File('${fixtures.path}/manifest_v1.canonical.txt').readAsStringSync());
    });

    test('accepts the Python-signed manifest', () async {
      final m = await verifyManifest(File('${fixtures.path}/manifest_v1.json').readAsBytesSync(), trusted);
      expect(m.serial, 2026101701);
      expect(m.files.map((f) => f.name), ['icd10cm_2026.tsv.gz', 'icd10cm_2027.tsv.gz', 'hcpcs.tsv.gz']);
      expect(m.sources['icd10cm-2027'], '2026-10-01');
    });

    test('rejects a tampered manifest', () async {
      final m = readJson('manifest_v1.json');
      m['serial'] = 2026101799;
      expect(() => verifyManifest(utf8.encode(jsonEncode(m)), trusted), throwsA(isA<CodesetVerificationException>()));
    });

    test('rejects a manifest signed by an unknown key', () async {
      final prod = parseTrustedKeys(File(productionKeyFile).readAsStringSync());
      expect(() => verifyManifest(File('${fixtures.path}/manifest_v1.json').readAsBytesSync(), prod),
          throwsA(isA<CodesetVerificationException>()));
    });

    test('the key compiled into the app is the published production key', () {
      expect(parseTrustedKeys(codesetPublicKeys), parseTrustedKeys(File(productionKeyFile).readAsStringSync()));
      expect(parseTrustedKeys(codesetPublicKeys).keys, ['solis-codesets-ad12fdbd']);
    });

    test('rejects a manifest whose signature does not match', () async {
      final m = readJson('manifest_v1.json');
      final sig = base64.decode((m['signature'] as Map)['value'] as String);
      sig[0] ^= 0x01;
      (m['signature'] as Map)['value'] = base64.encode(sig);
      expect(() => verifyManifest(utf8.encode(jsonEncode(m)), trusted), throwsA(isA<CodesetVerificationException>()));
    });

    test('rejects floats and non-ASCII strings in canonical form', () {
      expect(() => canonicalJson({'a': 1.5}), throwsA(isA<CodesetVerificationException>()));
      expect(() => canonicalJson({'a': 'café'}), throwsA(isA<CodesetVerificationException>()));
      expect(canonicalJson({'b': [1, true, null], 'a': 'x"y\\z/'}), r'{"a":"x\"y\\z/","b":[1,true,null]}');
    });

    test('rejects file names that are not plain asset names', () async {
      final m = readJson('manifest_v1.json');
      (m['files'] as List).first['name'] = '../evil.tsv.gz';
      final signed = await signInDart(m);
      expect(() => verifyManifest(utf8.encode(jsonEncode(signed)), trusted), throwsA(isA<CodesetVerificationException>()));
    });
  });

  group('client', () {
    test('first install, edition by date of service, bundled fallback', () async {
      bucket.objects['manifest.json'] = File('${fixtures.path}/manifest_v1.json').readAsBytesSync();
      bucket.putFixtureFiles();
      final c = client();
      final r = await c.checkForUpdate();
      expect(r.status, CodesetUpdateStatus.updated, reason: r.message);
      expect(r.changedFiles.length, 3);
      expect(c.icdEditions(), [2026, 2027]);
      expect(c.fileForSet('icd10cm', dateOfService: DateTime(2026, 9, 30))!.path, endsWith('icd10cm_2026.tsv.gz'));
      expect(c.fileForSet('icd10cm', dateOfService: DateTime(2026, 10, 1))!.path, endsWith('icd10cm_2027.tsv.gz'));
      expect(c.fileForSet('icd10cm', dateOfService: DateTime(2027, 10, 1)), isNull, reason: 'FY2028 not published: use bundled');
      expect(c.fileForSet('icd10cm')!.path, endsWith('icd10cm_2027.tsv.gz'), reason: 'today is FY2027');
      expect(c.fileForSet('hcpcs')!.existsSync(), isTrue);
      expect(c.fileForSet('pfs_rvu'), isNull, reason: 'not in this manifest: use bundled');

      // A fresh client (next app launch) loads and re-verifies the same set.
      final c2 = client();
      await c2.load();
      expect(c2.installed!.serial, 2026101701);
    });

    test('at most one check per day', () async {
      bucket.objects['manifest.json'] = File('${fixtures.path}/manifest_v1.json').readAsBytesSync();
      bucket.putFixtureFiles();
      final c = client();
      expect((await c.checkForUpdate()).status, CodesetUpdateStatus.updated);
      now = now.add(const Duration(hours: 3));
      expect((await c.checkForUpdate()).status, CodesetUpdateStatus.throttled);
      now = now.add(const Duration(hours: 22));
      expect((await c.checkForUpdate()).status, CodesetUpdateStatus.upToDate);
    });

    test('update downloads only changed files, keeps the previous set, rollback blocks the bad serial', () async {
      bucket.objects['manifest.json'] = File('${fixtures.path}/manifest_v1.json').readAsBytesSync();
      bucket.putFixtureFiles();
      final c = client();
      expect((await c.checkForUpdate()).status, CodesetUpdateStatus.updated);

      final newHcpcs = gz('A0021\tOutside state ambulance serv\tAmbulance service, outside state per mile\n'
          'A0999\tUnlisted ambulance service\tUnlisted ambulance service\n');
      final hsha = await sha(newHcpcs);
      Future<Map<String, dynamic>> version(int serial) async {
        final m = readJson('manifest_v1.json')
          ..['serial'] = serial
          ..['previous_serial'] = 2026101701;
        final files = (m['files'] as List).cast<Map<String, dynamic>>();
        final h = files.firstWhere((f) => f['name'] == 'hcpcs.tsv.gz');
        h['sha256'] = hsha;
        h['size'] = newHcpcs.length;
        h['path'] = 'files/$hsha/hcpcs.tsv.gz';
        return signInDart(m);
      }

      bucket.objects['files/$hsha/hcpcs.tsv.gz'] = newHcpcs;
      bucket.putManifest(await version(2027011501));
      bucket.requests.clear();
      now = now.add(const Duration(days: 2));
      final r = await c.checkForUpdate();
      expect(r.status, CodesetUpdateStatus.updated, reason: r.message);
      expect(r.changedFiles, ['hcpcs.tsv.gz']);
      expect(bucket.requests, ['manifest.json', 'files/$hsha/hcpcs.tsv.gz']);
      expect(c.fileForSet('hcpcs')!.readAsBytesSync(), newHcpcs);
      expect(Directory('${tmp.path}/codesets/sets/2026101701').existsSync(), isTrue, reason: 'previous kept');

      expect(await c.rollback(), isTrue);
      expect(c.installed!.serial, 2026101701);
      expect(Directory('${tmp.path}/codesets/sets/2027011501').existsSync(), isFalse);
      now = now.add(const Duration(days: 2));
      expect((await c.checkForUpdate()).status, CodesetUpdateStatus.upToDate, reason: 'rolled-back serial is blocked');

      bucket.putManifest(await version(2027011601));
      now = now.add(const Duration(days: 2));
      expect((await c.checkForUpdate()).status, CodesetUpdateStatus.updated, reason: 'a newer fix is accepted');
    });

    test('a file with the wrong hash fails the update and leaves the current set active', () async {
      bucket.objects['manifest.json'] = File('${fixtures.path}/manifest_v1.json').readAsBytesSync();
      bucket.putFixtureFiles();
      final m = readJson('manifest_v1.json');
      final path = ((m['files'] as List).last as Map)['path'] as String;
      bucket.objects[path] = gz('tampered\n');
      final c = client();
      final r = await c.checkForUpdate();
      expect(r.status, CodesetUpdateStatus.failed);
      expect(r.message, contains('hcpcs.tsv.gz'));
      expect(c.installed, isNull, reason: 'app keeps using bundled assets');
      final sets = Directory('${tmp.path}/codesets/sets');
      expect(sets.existsSync() ? sets.listSync() : <FileSystemEntity>[], isEmpty, reason: 'no partial set left behind');
    });

    test('older or bundled-equivalent serials are ignored', () async {
      bucket.objects['manifest.json'] = File('${fixtures.path}/manifest_v1.json').readAsBytesSync();
      bucket.putFixtureFiles();
      final c = client(bundledSerial: 2026101701);
      expect((await c.checkForUpdate()).status, CodesetUpdateStatus.upToDate);
      expect(c.installed, isNull);
    });

    test('unknown manifest format is not installed', () async {
      final m = readJson('manifest_v1.json')..['format'] = 'solis-codesets/2';
      bucket.putManifest(await signInDart(m));
      final r = await client().checkForUpdate();
      expect(r.status, CodesetUpdateStatus.incompatible);
    });

    test('damaged current set falls back to the previous one on load', () async {
      bucket.objects['manifest.json'] = File('${fixtures.path}/manifest_v1.json').readAsBytesSync();
      bucket.putFixtureFiles();
      final c = client();
      await c.checkForUpdate();
      final m = readJson('manifest_v1.json')..['serial'] = 2027011501;
      bucket.putManifest(await signInDart(m));
      now = now.add(const Duration(days: 2));
      expect((await c.checkForUpdate()).status, CodesetUpdateStatus.updated);
      File('${tmp.path}/codesets/sets/2027011501/hcpcs.tsv.gz').deleteSync();
      final c2 = client();
      await c2.load();
      expect(c2.installed!.serial, 2026101701);
    });
  });
}

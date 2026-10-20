// App integration of the code-set updater: layered source (downloaded first,
// bundled fallback), ICD edition selection, apply-on-next-start, rollback on
// a parse failure, and offline / verification-failure fallback.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:solis_mobile/services/codesets/codeset_update_client.dart';
import 'package:solis_mobile/services/codesets/codeset_updates.dart';
import 'package:solis_mobile/services/codesets/codesets.dart';
import 'package:solis_mobile/services/codesets/reference_data.dart';

final fixtures = Directory('test/codeset_update/fixtures');
final testSeed = List<int>.generate(32, (i) => i + 1);
final trusted = parseTrustedKeys(File('${fixtures.path}/test_public_key.txt').readAsStringSync());

Uint8List gz(String text) => Uint8List.fromList(gzip.encode(utf8.encode(text)));

/// One file in a test release.
class Entry {
  Entry(this.name, this.set, this.bytes, {this.edition, this.from, this.to, this.select = 'latest'});
  final String name;
  final String set;
  final Uint8List bytes;
  final String? edition;
  final String? from;
  final String? to;
  final String select;
}

Entry icd(int fy, String tsv) => Entry('icd10cm_$fy.tsv.gz', 'icd10cm', gz(tsv),
    edition: 'FY$fy', from: '${fy - 1}-10-01', to: '$fy-09-30', select: 'date_of_service');

/// In-memory bucket that publishes signed releases (test key).
class Bucket {
  final objects = <String, Uint8List>{};
  bool offline = false;

  Future<Uint8List> get(Uri url) async {
    if (offline) throw const SocketException('Network is unreachable');
    final v = objects[url.path.replaceFirst(RegExp(r'^/'), '')];
    if (v == null) throw HttpException('HTTP 404', uri: url);
    return v;
  }

  Future<Map<String, dynamic>> publish(int serial, List<Entry> entries, {bool corruptSignature = false}) async {
    final files = <Map<String, dynamic>>[];
    for (final e in entries) {
      final sha = await sha256Hex(e.bytes);
      final path = 'files/$sha/${e.name}';
      objects[path] = e.bytes;
      files.add({
        'name': e.name,
        'set': e.set,
        'sha256': sha,
        'size': e.bytes.length,
        'path': path,
        'select': e.select,
        'edition': ?e.edition,
        'effective_from': ?e.from,
        'effective_to': ?e.to,
      });
    }
    final body = <String, dynamic>{
      'format': 'solis-codesets/1',
      'serial': serial,
      'generated_at': '2026-10-17T12:00:00Z',
      'previous_serial': null,
      'publisher': 'test',
      'sources': {'hcpcs': 'test'},
      'releases': [
        {'id': 'hcpcs', 'version': 'test', 'label': 'HCPCS Level II test release'},
      ],
      'files': files,
    };
    final kp = await Ed25519().newKeyPairFromSeed(testSeed);
    final sig = await Ed25519().sign(utf8.encode(canonicalJson(body)), keyPair: kp);
    final sigBytes = Uint8List.fromList(sig.bytes);
    if (corruptSignature) sigBytes[5] ^= 0x40;
    final signed = {
      ...body,
      'signature': {'alg': 'Ed25519', 'key_id': trusted.keys.single, 'value': base64.encode(sigBytes)},
    };
    objects['manifest.json'] = Uint8List.fromList(utf8.encode(jsonEncode(signed)));
    return signed;
  }
}

void main() {
  late Directory tmp;
  late Bucket bucket;
  var now = DateTime.utc(2026, 10, 17, 8);

  CodesetUpdates updates({Future<void> Function()? loadAll}) => CodesetUpdates(
        root: Directory('${tmp.path}/codesets'),
        httpGet: bucket.get,
        trustedKeys: trusted,
        bundledSerial: 2026101701,
        baseUrl: Uri.parse('https://pub.example.r2.dev'),
        clock: () => now,
        fallback: DirectoryCodeSetSource('assets/codes'),
        loadReferenceData: loadAll,
      );

  Future<String> read(CodeSetSource s, String name) async => CodeSetLoader.decode((await s.readBytes(name))!);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('codeset_updates_test');
    bucket = Bucket();
    now = DateTime.utc(2026, 10, 17, 8);
  });

  tearDown(() {
    IcdEditions.useDownloaded(const []);
    CodeSetLoader.useSource(const AssetCodeSetSource());
    CodeSetLoader.onParseError = null;
    ReferenceData.clear();
    tmp.deleteSync(recursive: true);
  });

  test('a new set is applied at the next start, then read before the bundled assets', () async {
    await bucket.publish(2026111001, [
      icd(2027, 'A00\t0\tCholera\nZ99.99\t1\tDownloaded FY2027 test code\n'),
      icd(2028, 'A00\t0\tCholera\nZ99.98\t1\tDownloaded FY2028 test code\n'),
      Entry('mce_v45.tsv.gz', 'mce', gz('kind\tcode\n')),
    ]);

    final first = updates();
    await first.activate();
    expect(IcdEditions.available, [2026, 2027]);
    final r = await first.check();
    expect(r.status, CodesetUpdateStatus.updated, reason: r.message);

    // Still the bundled sets in this run; the new one waits for the next start.
    expect(first.active.installed, isNull);
    expect(IcdEditions.available, [2026, 2027]);
    final s = await first.status();
    expect(s.usingBundled, isTrue);
    expect(s.activeSerial, 2026101701);
    expect(s.pendingSerial, 2026111001);
    expect(s.lastCheck, now);
    expect((await read(CodeSetLoader.source, 'icd10cm_2027.tsv.gz')), isNot(contains('Z99.99')));

    // Next start.
    final next = updates();
    await next.activate();
    final status = await next.status();
    expect(status.usingBundled, isFalse);
    expect(status.activeSerial, 2026111001);
    expect(status.pendingSerial, isNull);
    expect(status.labels, ['HCPCS Level II test release']);

    // Editions: bundled union downloaded; a future edition only for its own FY.
    expect(IcdEditions.available, [2026, 2027, 2028]);
    expect(IcdEditions.resolve(DateTime(2027, 9, 30)), 2027);
    expect(IcdEditions.resolve(DateTime(2027, 10, 1)), 2028);
    expect(IcdEditions.resolve(DateTime(2026, 9, 30)), 2026);

    final src = CodeSetLoader.source;
    expect(await read(src, 'icd10cm_2027.tsv.gz'), contains('Z99.99'));
    expect(await read(src, 'icd10cm_2028.tsv.gz'), contains('Z99.98'));
    // FY2026 is not in the downloaded set: the bundled edition is used.
    expect(await read(src, 'icd10cm_2026.tsv.gz'), startsWith('A00\t0\t'));
    expect(next.source.servedFromDownload, isNot(contains('icd10cm_2026.tsv.gz')));
    // Looked up by set, so a renamed file (mce_v45) replaces mce_v44.
    expect(await read(src, CodeSetFiles.mce), 'kind\tcode\n');
    // Sets missing from the download come from the bundled assets.
    expect((await src.readBytes(CodeSetFiles.pfsRvu))!.length, File('assets/codes/pfs_rvu.tsv.gz').lengthSync());

    final fy2028 = await IcdCatalog.forFiscalYear(2028);
    expect(fy2028.lookup('Z99.98')?.description, 'Downloaded FY2028 test code');
    final fy2027 = await IcdCatalog.forDate(DateTime(2027, 9, 30));
    expect(fy2027.lookup('Z99.99'), isNotNull);
  });

  test('bad signature: nothing installed, bundled sets stay in use', () async {
    await bucket.publish(2026111001, [icd(2027, 'Z99.99\t1\tShould never be used\n')], corruptSignature: true);
    final u = updates();
    await u.activate();
    final r = await u.check();
    expect(r.status, CodesetUpdateStatus.failed);
    expect(r.message, contains('signature'));
    expect(await u.checker.storedSerial(), isNull);
    await updates().activate();
    expect(await read(CodeSetLoader.source, 'icd10cm_2027.tsv.gz'), isNot(contains('Z99.99')));
  });

  test('bad file hash: nothing installed, no partial set left', () async {
    await bucket.publish(2026111001, [icd(2027, 'Z99.99\t1\tTampered later\n')]);
    final path = bucket.objects.keys.firstWhere((k) => k.startsWith('files/'));
    bucket.objects[path] = gz('Z99.99\t1\tSwapped on the server\n');
    final u = updates();
    await u.activate();
    final r = await u.check();
    expect(r.status, CodesetUpdateStatus.failed);
    expect(r.message, contains('icd10cm_2027.tsv.gz'));
    final sets = Directory('${tmp.path}/codesets/sets');
    expect(sets.existsSync() ? sets.listSync() : const <FileSystemEntity>[], isEmpty);
    expect((await u.status()).usingBundled, isTrue);
  });

  test('offline: the check fails quietly and the installed set stays in use', () async {
    await bucket.publish(2026111001, [icd(2027, 'A00\t0\tCholera\nZ99.99\t1\tDownloaded\n')]);
    await updates().check();
    bucket.offline = true;
    now = now.add(const Duration(days: 2));
    final u = updates();
    await u.activate();
    final r = await u.check();
    expect(r.status, CodesetUpdateStatus.failed);
    expect(u.active.installed!.serial, 2026111001);
    expect(await read(CodeSetLoader.source, 'icd10cm_2027.tsv.gz'), contains('Z99.99'));

    // Offline on a phone that never downloaded anything: bundled assets.
    final fresh = CodesetUpdates(
      root: Directory('${tmp.path}/other'),
      httpGet: bucket.get,
      trustedKeys: trusted,
      clock: () => now,
      fallback: DirectoryCodeSetSource('assets/codes'),
    );
    await fresh.activate();
    expect((await fresh.check()).status, CodesetUpdateStatus.failed);
    expect((await fresh.status()).usingBundled, isTrue);
    expect((await CodeSetLoader.source.readBytes(CodeSetFiles.hcpcs))!.length,
        File('assets/codes/hcpcs.tsv.gz').lengthSync());
  });

  test('a downloaded file the parsers reject is rolled back and the bundled set reloaded', () async {
    // Signed and hashed correctly, but not gzip: only parsing can catch it.
    await bucket.publish(2026111001, [Entry(CodeSetFiles.hcpcs, 'hcpcs', Uint8List.fromList(utf8.encode('not gzip')))]);
    expect((await updates().check()).status, CodesetUpdateStatus.updated);

    final u = updates();
    await u.activate();
    expect(u.active.installed!.serial, 2026111001);
    await u.loadReferenceData();

    expect(u.active.installed, isNull, reason: 'rolled back to the bundled assets');
    expect(ReferenceData.hcpcs, isNotNull);
    expect(ReferenceData.hcpcs!.length, greaterThan(1000), reason: 'bundled HCPCS loaded');
    expect(ReferenceData.icdFor(DateTime(2026, 10, 17)), isNotNull);
    expect(Directory('${tmp.path}/codesets/sets/2026111001').existsSync(), isFalse);

    // The bad serial is never installed again; a fixed, newer one is.
    now = now.add(const Duration(days: 2));
    expect((await u.check()).status, CodesetUpdateStatus.upToDate);
    await bucket.publish(2026111101, [Entry(CodeSetFiles.hcpcs, 'hcpcs', gz('A0021\tAmbulance\tAmbulance service\n'))]);
    expect((await u.check(force: true)).status, CodesetUpdateStatus.updated);
  });

  test('"Use built-in code sets" drops downloads and reloads the bundled sets', () async {
    await bucket.publish(2026111001, [icd(2027, 'A00\t0\tCholera\nZ99.99\t1\tDownloaded\n')]);
    await updates().check();
    var loads = 0;
    final u = updates(loadAll: () async => loads++);
    await u.activate();
    expect(u.active.installed, isNotNull);
    await u.useBuiltIn();
    expect(loads, 1);
    final s = await u.status();
    expect(s.usingBundled, isTrue);
    expect(s.pendingSerial, isNull);
    expect(await read(CodeSetLoader.source, 'icd10cm_2027.tsv.gz'), isNot(contains('Z99.99')));
    expect(Directory('${tmp.path}/codesets/sets').existsSync(), isFalse);
    now = now.add(const Duration(days: 2));
    expect((await u.check()).status, CodesetUpdateStatus.upToDate, reason: 'the dropped serial is not reinstalled');
  });
}

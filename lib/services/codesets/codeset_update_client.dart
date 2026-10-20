// SOLIS code-set update client.
//
// Pure Dart (dart:io + package:cryptography), no Flutter imports, so it also
// runs under `dart run` (tool/codeset_live_check.dart). The app wiring is in
// codeset_updates.dart; see docs/CODESET_UPDATES.md for the full contract.
//
// Dependency: cryptography: ^2.7.0 (Ed25519 verify and SHA-256). On Flutter,
// adding cryptography_flutter is optional (faster native SHA-256); not needed.
//
// What it does:
//  - At most once per [minInterval] (one day by default) fetches
//    <baseUrl>/manifest.json, verifies its Ed25519 signature against the
//    bundled trusted keys, and rejects anything not newer than what is
//    installed (or bundled, or rolled back).
//  - Downloads only files whose sha256 changed, verifies size and sha256 of
//    every file, assembles the new set in a separate folder and switches to
//    it with one atomic rename of current.json. The previous set is kept for
//    rollback; older sets are deleted.
//  - Answers "which file do I use" by set name, choosing ICD-10-CM editions
//    by date of service. A null answer means: use the bundled asset.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Manifest format this client understands.
const String supportedManifestFormat = 'solis-codesets/1';

/// Fetches a URL and returns the body. Must throw on a non-200 status.
typedef HttpGetBytes = Future<Uint8List> Function(Uri url);

class CodesetVerificationException implements Exception {
  CodesetVerificationException(this.message);
  final String message;
  @override
  String toString() => 'CodesetVerificationException: $message';
}

// ---------------------------------------------------------------------------
// Canonical JSON (must match codeset_lib.canonical_json in Python)
// ---------------------------------------------------------------------------

/// Sorted keys, no whitespace, printable ASCII strings, integers only.
/// The manifest signature covers these bytes of the manifest without its
/// "signature" member.
String canonicalJson(Object? value) {
  final out = StringBuffer();
  _writeCanonical(out, value, r'$');
  return out.toString();
}

void _writeCanonical(StringBuffer out, Object? v, String where) {
  if (v == null) {
    out.write('null');
  } else if (v is bool) {
    out.write(v ? 'true' : 'false');
  } else if (v is int) {
    out.write(v.toString());
  } else if (v is double) {
    throw CodesetVerificationException('$where: floats are not allowed in a manifest');
  } else if (v is String) {
    _checkAscii(v, where);
    out.write(jsonEncode(v));
  } else if (v is List) {
    out.write('[');
    for (var i = 0; i < v.length; i++) {
      if (i > 0) out.write(',');
      _writeCanonical(out, v[i], '$where[$i]');
    }
    out.write(']');
  } else if (v is Map) {
    final keys = v.keys.map((k) {
      if (k is! String) throw CodesetVerificationException('$where: non-string key');
      _checkAscii(k, where);
      return k;
    }).toList()
      ..sort();
    out.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) out.write(',');
      out.write(jsonEncode(keys[i]));
      out.write(':');
      _writeCanonical(out, v[keys[i]], '$where.${keys[i]}');
    }
    out.write('}');
  } else {
    throw CodesetVerificationException('$where: unsupported JSON value ${v.runtimeType}');
  }
}

void _checkAscii(String s, String where) {
  for (final c in s.codeUnits) {
    if (c < 0x20 || c > 0x7e) {
      throw CodesetVerificationException('$where: manifest strings must be printable ASCII');
    }
  }
}

// ---------------------------------------------------------------------------
// Manifest model
// ---------------------------------------------------------------------------

class ManifestFile {
  ManifestFile({
    required this.name,
    required this.set,
    required this.sha256,
    required this.size,
    required this.path,
    required this.select,
    this.release,
    this.edition,
    this.effectiveFrom,
    this.effectiveTo,
    this.rows,
  });

  factory ManifestFile.fromJson(Map<String, dynamic> j) {
    final name = j['name'] as String;
    // File names become local paths: allow only plain asset names.
    if (!RegExp(r'^[a-z0-9_]+\.tsv\.gz$').hasMatch(name)) {
      throw CodesetVerificationException('bad file name $name');
    }
    final sha = j['sha256'] as String;
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
      throw CodesetVerificationException('bad sha256 for $name');
    }
    final path = j['path'] as String;
    if (path.contains('..') || path.startsWith('/') || path.contains('://')) {
      throw CodesetVerificationException('bad path for $name');
    }
    return ManifestFile(
      name: name,
      set: j['set'] as String,
      sha256: sha,
      size: j['size'] as int,
      path: path,
      select: (j['select'] as String?) ?? 'latest',
      release: j['release'] as String?,
      edition: j['edition'] as String?,
      effectiveFrom: _date(j['effective_from']),
      effectiveTo: _date(j['effective_to']),
      rows: j['rows'] as int?,
    );
  }

  final String name;
  final String set;
  final String sha256;
  final int size;
  final String path;

  /// 'date_of_service' (ICD-10-CM editions) or 'latest'.
  final String select;
  final String? release;
  final String? edition;
  final DateTime? effectiveFrom;
  final DateTime? effectiveTo;
  final int? rows;

  bool covers(DateTime day) {
    final d = DateTime.utc(day.year, day.month, day.day);
    if (effectiveFrom != null && d.isBefore(effectiveFrom!)) return false;
    if (effectiveTo != null && d.isAfter(effectiveTo!)) return false;
    return true;
  }

  static DateTime? _date(Object? v) {
    if (v == null) return null;
    final p = (v as String).split('-').map(int.parse).toList();
    return DateTime.utc(p[0], p[1], p[2]);
  }
}

class CodesetManifest {
  CodesetManifest._(this.raw, this.format, this.serial, this.generatedAt, this.sources, this.files, this.keyId);

  /// Parsed JSON as received (signature included).
  final Map<String, dynamic> raw;
  final String format;
  final int serial;
  final DateTime generatedAt;

  /// Release id -> CMS version label (what this set was built from).
  final Map<String, String> sources;
  final List<ManifestFile> files;
  final String keyId;

  ManifestFile? fileNamed(String name) {
    for (final f in files) {
      if (f.name == name) return f;
    }
    return null;
  }
}

/// Parses manifest bytes and verifies the Ed25519 signature.
/// [trustedKeys] maps key_id to the raw 32-byte public key.
Future<CodesetManifest> verifyManifest(List<int> bytes, Map<String, List<int>> trustedKeys) async {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes));
  } on FormatException catch (e) {
    throw CodesetVerificationException('manifest is not JSON: ${e.message}');
  }
  if (decoded is! Map<String, dynamic>) throw CodesetVerificationException('manifest is not an object');
  final sig = decoded['signature'];
  if (sig is! Map || sig['alg'] != 'Ed25519' || sig['value'] is! String || sig['key_id'] is! String) {
    throw CodesetVerificationException('missing or unsupported signature');
  }
  final key = trustedKeys[sig['key_id']];
  if (key == null) throw CodesetVerificationException('unknown signing key ${sig['key_id']}');
  final body = Map<String, dynamic>.of(decoded)..remove('signature');
  final message = utf8.encode(canonicalJson(body));
  final List<int> sigBytes;
  try {
    sigBytes = base64.decode(sig['value'] as String);
  } on FormatException {
    throw CodesetVerificationException('signature is not base64');
  }
  final ok = await Ed25519().verify(
    message,
    signature: Signature(sigBytes, publicKey: SimplePublicKey(key, type: KeyPairType.ed25519)),
  );
  if (!ok) throw CodesetVerificationException('bad manifest signature');

  try {
    final files = (decoded['files'] as List).map((f) => ManifestFile.fromJson(f as Map<String, dynamic>)).toList();
    final names = files.map((f) => f.name).toSet();
    if (names.length != files.length) throw CodesetVerificationException('duplicate file names');
    return CodesetManifest._(
      decoded,
      decoded['format'] as String,
      decoded['serial'] as int,
      DateTime.parse(decoded['generated_at'] as String),
      (decoded['sources'] as Map).map((k, v) => MapEntry(k as String, v as String)),
      files,
      sig['key_id'] as String,
    );
  } on TypeError {
    throw CodesetVerificationException('manifest fields have the wrong types');
  }
}

/// Parses public_key.txt (`<key_id> <base64>` per line, # comments).
Map<String, List<int>> parseTrustedKeys(String text) {
  final out = <String, List<int>>{};
  for (final raw in const LineSplitter().convert(text)) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final parts = line.split(RegExp(r'\s+'));
    final bytes = base64.decode(parts[1]);
    if (bytes.length != 32) throw ArgumentError('${parts[0]}: Ed25519 public key must be 32 bytes');
    out[parts[0]] = bytes;
  }
  return out;
}

Future<String> sha256Hex(List<int> bytes) async {
  final h = await Sha256().hash(bytes);
  return h.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

enum CodesetUpdateStatus { updated, upToDate, throttled, incompatible, failed }

class CodesetUpdateResult {
  CodesetUpdateResult(this.status, {this.serial, this.changedFiles = const [], this.message});
  final CodesetUpdateStatus status;
  final int? serial;
  final List<String> changedFiles;
  final String? message;
  @override
  String toString() => 'CodesetUpdateResult($status, serial: $serial, changed: $changedFiles, $message)';
}

class CodesetUpdateClient {
  CodesetUpdateClient({
    required this.root,
    required this.baseUrl,
    required this.trustedKeys,
    required this.httpGet,
    this.bundledSerial = 0,
    this.minInterval = const Duration(hours: 24),
    this.maxFileBytes = 64 * 1024 * 1024,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// App-private folder, for example `<applicationSupportDirectory>/codesets`.
  final Directory root;

  /// Public bucket URL, without a trailing slash.
  final Uri baseUrl;
  final Map<String, List<int>> trustedKeys;
  final HttpGetBytes httpGet;

  /// Serial of the set bundled in the app's assets. Manifests not newer are ignored.
  final int bundledSerial;
  final Duration minInterval;
  final int maxFileBytes;
  final DateTime Function() _clock;

  CodesetManifest? _installed;
  Directory? _installedDir;
  bool _loaded = false;

  /// The active downloaded set, or null when the app should use bundled assets.
  CodesetManifest? get installed => _installed;

  Directory get _sets => Directory('${root.path}/sets');
  File get _currentFile => File('${root.path}/current.json');
  File get _stateFile => File('${root.path}/state.json');
  Directory _setDir(int serial) => Directory('${_sets.path}/$serial');

  Uri _url(String relative) {
    final base = baseUrl.toString().replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$base/$relative');
  }

  /// Loads and re-verifies the installed set. Falls back to the previous set,
  /// then to bundled assets, if the current one is missing or damaged.
  Future<void> load() async {
    _loaded = true;
    _installed = null;
    _installedDir = null;
    final cur = await _readJson(_currentFile);
    if (cur == null) return;
    for (final serial in [cur['serial'], cur['previous']]) {
      if (serial is! int) continue;
      final m = await _loadSet(serial);
      if (m != null) {
        _installed = m;
        _installedDir = _setDir(serial);
        if (serial != cur['serial']) {
          await _writeJsonAtomic(_currentFile, {'serial': serial, 'previous': null});
        }
        return;
      }
    }
  }

  Future<CodesetManifest?> _loadSet(int serial) async {
    final dir = _setDir(serial);
    final mf = File('${dir.path}/manifest.json');
    if (!await mf.exists()) return null;
    try {
      final m = await verifyManifest(await mf.readAsBytes(), trustedKeys);
      if (m.serial != serial || m.format != supportedManifestFormat) return null;
      for (final f in m.files) {
        final file = File('${dir.path}/${f.name}');
        if (!await file.exists() || await file.length() != f.size) return null;
      }
      return m;
    } on CodesetVerificationException {
      return null;
    }
  }

  /// Checks for a newer signed set and installs it. Never throws: errors are
  /// reported as [CodesetUpdateStatus.failed] and the current set stays active.
  Future<CodesetUpdateResult> checkForUpdate({bool force = false}) async {
    if (!_loaded) await load();
    final state = await _readJson(_stateFile) ?? <String, dynamic>{};
    final now = _clock().toUtc();
    final last = state['last_check'] is String ? DateTime.tryParse(state['last_check'] as String) : null;
    if (!force && last != null && now.difference(last) < minInterval && !now.isBefore(last)) {
      return CodesetUpdateResult(CodesetUpdateStatus.throttled, serial: _installed?.serial);
    }
    state['last_check'] = now.toIso8601String();
    await root.create(recursive: true);
    await _writeJsonAtomic(_stateFile, state);

    Directory? partial;
    try {
      final bytes = await httpGet(_url('manifest.json'));
      final m = await verifyManifest(bytes, trustedKeys);
      if (m.format != supportedManifestFormat) {
        return CodesetUpdateResult(CodesetUpdateStatus.incompatible, serial: m.serial, message: 'format ${m.format}');
      }
      final minSerial = (state['min_serial'] as int?) ?? 0;
      final floor = math.max(math.max(_installed?.serial ?? 0, bundledSerial), minSerial - 1);
      if (m.serial <= floor) {
        return CodesetUpdateResult(CodesetUpdateStatus.upToDate, serial: _installed?.serial);
      }

      await _sets.create(recursive: true);
      partial = Directory('${_sets.path}/${m.serial}.partial');
      if (await partial.exists()) await partial.delete(recursive: true);
      await partial.create();
      final changed = <String>[];
      for (final f in m.files) {
        if (f.size > maxFileBytes) throw CodesetVerificationException('${f.name} is too large');
        final target = File('${partial.path}/${f.name}');
        final old = _installed?.fileNamed(f.name);
        if (old != null && old.sha256 == f.sha256 && _installedDir != null) {
          final oldBytes = await File('${_installedDir!.path}/${f.name}').readAsBytes();
          if (await sha256Hex(oldBytes) == f.sha256) {
            await target.writeAsBytes(oldBytes, flush: true);
            continue;
          }
        }
        final data = await httpGet(_url(f.path));
        if (data.length != f.size) throw CodesetVerificationException('${f.name}: size ${data.length} != ${f.size}');
        if (await sha256Hex(data) != f.sha256) throw CodesetVerificationException('${f.name}: sha256 mismatch');
        await target.writeAsBytes(data, flush: true);
        changed.add(f.name);
      }
      await File('${partial.path}/manifest.json').writeAsBytes(bytes, flush: true);

      final dest = _setDir(m.serial);
      if (await dest.exists()) await dest.delete(recursive: true);
      await partial.rename(dest.path);
      partial = null;

      final previous = _installed?.serial;
      // The switch: one atomic file replace.
      await _writeJsonAtomic(_currentFile, {'serial': m.serial, 'previous': previous});
      _installed = m;
      _installedDir = dest;
      await _prune(keep: {m.serial, ?previous});
      return CodesetUpdateResult(CodesetUpdateStatus.updated, serial: m.serial, changedFiles: changed);
    } catch (e) {
      if (partial != null && await partial.exists()) {
        await partial.delete(recursive: true);
      }
      return CodesetUpdateResult(CodesetUpdateStatus.failed, serial: _installed?.serial, message: e.toString());
    }
  }

  /// Switches back to the previous set (or to bundled assets when there is
  /// none) and refuses to reinstall the rolled-back serial.
  Future<bool> rollback() async {
    if (!_loaded) await load();
    final bad = _installed?.serial;
    if (bad == null) return false;
    final cur = await _readJson(_currentFile) ?? {};
    final prev = cur['previous'];
    await _blockThrough(bad);
    if (prev is int && await _loadSet(prev) != null) {
      await _writeJsonAtomic(_currentFile, {'serial': prev, 'previous': null});
    } else {
      if (await _currentFile.exists()) await _currentFile.delete();
    }
    final badDir = _setDir(bad);
    if (await badDir.exists()) await badDir.delete(recursive: true);
    await load();
    return true;
  }

  /// Drops every downloaded set and goes back to the bundled assets. The
  /// serials that were installed are not accepted again; a newer published
  /// serial is. Returns false when the bundled assets were already in use.
  Future<bool> useBundled() async {
    if (!_loaded) await load();
    final cur = await _readJson(_currentFile);
    final serials = [_installed?.serial, cur?['serial'], cur?['previous']].whereType<int>();
    if (serials.isEmpty) return false;
    await _blockThrough(serials.reduce(math.max));
    if (await _currentFile.exists()) await _currentFile.delete();
    if (await _sets.exists()) await _sets.delete(recursive: true);
    await load();
    return true;
  }

  /// Refuses [serial] and everything older. Never lowers an existing block,
  /// so rolling back twice cannot re-allow the first bad serial.
  Future<void> _blockThrough(int serial) async {
    final state = await _readJson(_stateFile) ?? <String, dynamic>{};
    final old = state['min_serial'] is int ? state['min_serial'] as int : 0;
    state['min_serial'] = math.max(old, serial + 1);
    await root.create(recursive: true);
    await _writeJsonAtomic(_stateFile, state);
  }

  /// When the last check against the server started, or null if never.
  Future<DateTime?> lastCheck() async {
    final state = await _readJson(_stateFile);
    final v = state?['last_check'];
    return v is String ? DateTime.tryParse(v) : null;
  }

  /// The serial current.json points at on disk. After a successful update in
  /// another client instance this is newer than [installed]: it is applied
  /// when the app next starts.
  Future<int?> storedSerial() async {
    final cur = await _readJson(_currentFile);
    final v = cur?['serial'];
    return v is int ? v : null;
  }

  /// The downloaded file to use for [set], or null to use the bundled asset.
  /// Sets selected by date of service (ICD-10-CM editions) need [dateOfService];
  /// without it today's date is used.
  File? fileForSet(String set, {DateTime? dateOfService}) {
    final m = _installed;
    final dir = _installedDir;
    if (m == null || dir == null) return null;
    final candidates = m.files.where((f) => f.set == set).toList();
    if (candidates.isEmpty) return null;
    ManifestFile? pick;
    if (candidates.first.select == 'date_of_service') {
      final day = dateOfService ?? _clock();
      for (final f in candidates) {
        if (f.covers(day)) pick = f;
      }
    } else {
      candidates.sort((a, b) => (a.effectiveFrom ?? DateTime.utc(0)).compareTo(b.effectiveFrom ?? DateTime.utc(0)));
      pick = candidates.last;
    }
    return pick == null ? null : File('${dir.path}/${pick.name}');
  }

  /// The downloaded ICD-10-CM file of [set] (`icd10cm` or `icd10cm_index`)
  /// for fiscal year [fiscalYear], or null to use the bundled asset. When the
  /// edition has more than one file (an April 1 update), the one in effect
  /// on today's date is used, clamped to that fiscal year.
  File? icdFileFor(String set, int fiscalYear) {
    final start = DateTime.utc(fiscalYear - 1, 10, 1);
    final end = DateTime.utc(fiscalYear, 9, 30);
    final now = _clock();
    final today = DateTime.utc(now.year, now.month, now.day);
    final day = today.isBefore(start) ? start : (today.isAfter(end) ? end : today);
    return fileForSet(set, dateOfService: day);
  }

  /// The downloaded file with this exact asset name, or null.
  File? fileNamed(String name) {
    final m = _installed;
    if (m == null || _installedDir == null || m.fileNamed(name) == null) return null;
    return File('${_installedDir!.path}/$name');
  }

  /// ICD-10-CM fiscal years available in the downloaded set (for example [2026, 2027]).
  List<int> icdEditions() {
    final m = _installed;
    if (m == null) return const [];
    return m.files
        .where((f) => f.set == 'icd10cm' && f.edition != null)
        .map((f) => int.parse(f.edition!.substring(2)))
        .toList()
      ..sort();
  }

  Future<void> _prune({required Set<int> keep}) async {
    if (!await _sets.exists()) return;
    await for (final e in _sets.list()) {
      if (e is! Directory) continue;
      final name = e.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final serial = int.tryParse(name);
      if (serial != null && keep.contains(serial)) continue;
      await e.delete(recursive: true);
    }
  }

  static Future<Map<String, dynamic>?> _readJson(File f) async {
    try {
      if (!await f.exists()) return null;
      final v = jsonDecode(await f.readAsString());
      return v is Map<String, dynamic> ? v : null;
    } on FormatException {
      return null;
    }
  }

  static Future<void> _writeJsonAtomic(File f, Map<String, dynamic> v) async {
    await f.parent.create(recursive: true);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(v), flush: true);
    await tmp.rename(f.path);
  }
}

/// A dart:io implementation of [HttpGetBytes] with a timeout and size cap.
HttpGetBytes ioHttpGet({Duration timeout = const Duration(seconds: 60), int maxBytes = 64 * 1024 * 1024}) {
  return (Uri url) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final req = await client.getUrl(url).timeout(timeout);
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw HttpException('HTTP ${res.statusCode}', uri: url);
      }
      final b = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(timeout)) {
        b.add(chunk);
        if (b.length > maxBytes) throw HttpException('response too large', uri: url);
      }
      return b.takeBytes();
    } finally {
      client.close(force: true);
    }
  };
}

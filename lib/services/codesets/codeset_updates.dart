// App wiring for signed code-set updates (docs/CODESET_UPDATES.md).
//
// Two client instances share one folder on purpose:
//  - [CodesetUpdates.active] is loaded once at startup and is what every
//    code-set read in this run uses. It changes only on rollback or when the
//    user switches to the built-in sets.
//  - [CodesetUpdates.checker] downloads and switches current.json. A new set
//    it installs is used from the next app start, so one run never checks a
//    claim against two different sets.
//
// Network: the R2 host is not on the TLS pin list (PinnedHttp). The data is
// public (US government code sets, no PHI, nothing sent but a GET) and its
// integrity comes from the Ed25519 signature on the manifest plus the sha256
// of every file, checked against a key compiled into the app; a serial that is
// not newer is refused, so a network attacker can at most delay an update.
// Pinning would add a failure mode (a CA change on r2.dev or on the later
// custom domain would silently stop updates) and no protection.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'code_set_loader.dart';
import 'codeset_update_client.dart';
import 'reference_data.dart';

/// Trusted manifest signing keys, from tool/codeset_updater/public_key.txt.
/// Never downloaded. To rotate, add the new line here, ship, then sign with it.
const String codesetPublicKeys = '''
solis-codesets-ad12fdbd VMYNKgjZgvq2gtoIfFPnLQ1f9Mui+Gwg9we8dsF9WGM=
''';

/// Public bucket with the signed manifest and files. Change together with
/// PUBLIC_BASE in update.py and verify_published.py when a custom domain is
/// attached.
const String codesetBaseUrl = 'https://pub-c522aa6f22b14c29b715aff2d857c424.r2.dev';

/// Published serial the bundled assets in assets/codes/ match. Bump it when
/// the bundled assets are rebuilt to equal a newer published serial.
const int bundledCodesetSerial = 2026101701;

/// Bundled asset name to manifest set, for sets selected as "latest". Names
/// with an edition in them (mce_v44, *_2027) can change in a later release;
/// looking them up by set finds the new file under its new name.
const Map<String, String> bundledFileSets = {
  CodeSetFiles.hcpcs: 'hcpcs',
  CodeSetFiles.pfsRvu: 'pfs_rvu',
  CodeSetFiles.muePractitioner: 'mue_practitioner',
  CodeSetFiles.addOnCodes: 'ncci_addon',
  CodeSetFiles.mce: 'mce',
  CodeSetFiles.excludes1: 'icd10cm_excludes1',
  CodeSetFiles.seventhCharacter: 'icd_7th',
  CodeSetFiles.icdNotes: 'icd_notes',
  CodeSetFiles.guidelines: 'guidelines',
  CodeSetFiles.ruleCatalog: 'rule_catalog',
};

final RegExp _icdFile = RegExp(r'^icd10cm(_index)?_(\d{4})\.tsv\.gz$');

/// Reads a downloaded file when the active set has one for the requested
/// asset, else the bundled asset.
class UpdatedCodeSetSource implements CodeSetSource {
  UpdatedCodeSetSource(this.client, [this.fallback = const AssetCodeSetSource()])
      : assert(fallback.compressed, 'downloaded files are gzip, so the fallback must be too');

  final CodesetUpdateClient client;
  final CodeSetSource fallback;

  /// Asset names served from the downloaded set in this run.
  final Set<String> servedFromDownload = {};

  @override
  bool get compressed => true;

  /// The downloaded file that stands in for the bundled asset [fileName].
  File? downloadedFileFor(String fileName) {
    final icd = _icdFile.firstMatch(fileName);
    if (icd != null) {
      final set = icd.group(1) == null ? 'icd10cm' : 'icd10cm_index';
      return client.icdFileFor(set, int.parse(icd.group(2)!));
    }
    final set = bundledFileSets[fileName];
    if (set != null) return client.fileForSet(set);
    return client.fileNamed(fileName);
  }

  @override
  Future<List<int>?> readBytes(String fileName) async {
    final f = downloadedFileFor(fileName);
    if (f != null) {
      try {
        final bytes = await f.readAsBytes();
        servedFromDownload.add(fileName);
        return bytes;
      } catch (e) {
        debugPrint('Downloaded code set $fileName unreadable (${e.runtimeType}); using built-in');
      }
    }
    return fallback.readBytes(fileName);
  }
}

/// What the Integrations screen shows about code sets.
class CodesetStatus {
  const CodesetStatus({
    required this.activeSerial,
    required this.usingBundled,
    required this.labels,
    this.pendingSerial,
    this.lastCheck,
    this.lastResult,
    this.checking = false,
  });

  /// Serial in use in this run (the bundled serial when [usingBundled]).
  final int activeSerial;
  final bool usingBundled;

  /// Release labels of the active downloaded set, for example
  /// "HCPCS Level II October 2026". Empty for the built-in sets.
  final List<String> labels;

  /// A newer set already downloaded, applied at the next start.
  final int? pendingSerial;
  final DateTime? lastCheck;
  final CodesetUpdateResult? lastResult;
  final bool checking;
}

class CodesetUpdates {
  CodesetUpdates({
    required Directory root,
    HttpGetBytes? httpGet,
    Map<String, List<int>>? trustedKeys,
    this.bundledSerial = bundledCodesetSerial,
    Uri? baseUrl,
    DateTime Function()? clock,
    this.fallback = const AssetCodeSetSource(),
    Future<void> Function()? loadReferenceData,
  }) : _loadAll = loadReferenceData ?? ReferenceData.load {
    final keys = trustedKeys ?? parseTrustedKeys(codesetPublicKeys);
    final get = httpGet ?? ioHttpGet(timeout: const Duration(seconds: 30));
    final base = baseUrl ?? Uri.parse(codesetBaseUrl);
    CodesetUpdateClient make() => CodesetUpdateClient(
          root: root,
          baseUrl: base,
          trustedKeys: keys,
          httpGet: get,
          bundledSerial: bundledSerial,
          clock: clock,
        );
    active = make();
    checker = make();
    source = UpdatedCodeSetSource(active, fallback);
  }

  /// The instance the app uses, set by [start].
  static CodesetUpdates? instance;

  late final CodesetUpdateClient active;
  late final CodesetUpdateClient checker;
  late UpdatedCodeSetSource source;
  final int bundledSerial;
  final CodeSetSource fallback;
  final Future<void> Function() _loadAll;

  /// Changes whenever a check or a switch finishes; drives the UI row.
  final ValueNotifier<int> changes = ValueNotifier(0);
  CodesetUpdateResult? _lastResult;
  Future<CodesetUpdateResult>? _check;
  final List<String> _parseFailures = [];

  /// Creates [instance] under the app support folder, loads the installed set
  /// and points the code-set loader at it. Never throws: on any problem the
  /// app keeps the bundled assets and null is returned.
  static Future<CodesetUpdates?> start() async {
    try {
      final support = await getApplicationSupportDirectory();
      final u = CodesetUpdates(root: Directory('${support.path}/codesets'));
      await u.activate();
      return instance = u;
    } catch (e) {
      debugPrint('Code-set updates unavailable (${e.runtimeType}); using built-in sets');
      return null;
    }
  }

  /// Loads the installed set (fast: reads current.json and re-verifies the
  /// stored manifest) and installs the layered source.
  Future<void> activate() async {
    await active.load();
    _install();
  }

  void _install() {
    source = UpdatedCodeSetSource(active, fallback);
    IcdEditions.useDownloaded(active.icdEditions());
    CodeSetLoader.useSource(source);
  }

  /// Loads [ReferenceData] through the layered source. When a downloaded file
  /// fails to parse, rolls back (previous set, else built-in), blocks that
  /// serial and loads again; a second failure goes to the built-in sets.
  Future<void> loadReferenceData() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      _parseFailures.clear();
      CodeSetLoader.onParseError = (file, _) => _parseFailures.add(file);
      try {
        await _loadAll();
      } finally {
        CodeSetLoader.onParseError = null;
      }
      final bad = _parseFailures.where(source.servedFromDownload.contains).toList();
      if (bad.isEmpty || active.installed == null) return;
      debugPrint('Downloaded code sets ${bad.join(', ')} failed to parse; rolling back serial ${active.installed!.serial}');
      if (attempt == 0) {
        await active.rollback();
      } else {
        await active.useBundled();
      }
      await checker.load();
      _install();
      changes.value++;
    }
  }

  /// After the first frame and after [after] (the reference-data load), waits
  /// a random 0 to [maxJitter] and checks for a newer set. The client itself
  /// allows one check per 24 hours.
  void scheduleCheck({Future<void>? after, Duration maxJitter = const Duration(seconds: 30)}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(() async {
        try {
          await after;
        } catch (_) {}
        final ms = math.Random().nextInt(maxJitter.inMilliseconds + 1);
        await Future<void>.delayed(Duration(milliseconds: ms));
        await check();
      }());
    });
  }

  /// Checks for a newer signed set. [force] skips the once-a-day limit (the
  /// "Check now" button). A set downloaded earlier in this run and not yet
  /// applied is not replaced, so the active set's files are never pruned
  /// while in use.
  Future<CodesetUpdateResult> check({bool force = false}) {
    final running = _check;
    if (running != null) return running;
    _checking = true;
    return _check = () async {
      changes.value++;
      try {
        final stored = await checker.storedSerial();
        final activeSerial = active.installed?.serial;
        if (stored != null && stored != activeSerial) {
          return _lastResult = CodesetUpdateResult(CodesetUpdateStatus.updated,
              serial: stored, message: 'Downloaded; applied when SOLIS next starts');
        }
        final r = await checker.checkForUpdate(force: force);
        if (r.status != CodesetUpdateStatus.throttled) _lastResult = r;
        return r;
      } finally {
        _check = null;
        _checking = false;
        changes.value++;
      }
    }();
  }

  bool _checking = false;
  bool get checking => _checking;

  /// Drops every downloaded set and uses the built-in assets from now on
  /// (reloaded right away). Newer published serials are still accepted.
  Future<void> useBuiltIn() async {
    await active.useBundled();
    await checker.load();
    _lastResult = null;
    _install();
    await loadReferenceData();
    changes.value++;
  }

  Future<CodesetStatus> status() async {
    final m = active.installed;
    final stored = await checker.storedSerial();
    final labels = <String>[];
    final releases = m?.raw['releases'];
    if (releases is List) {
      for (final r in releases) {
        if (r is Map && r['label'] is String) labels.add(r['label'] as String);
      }
    }
    return CodesetStatus(
      activeSerial: m?.serial ?? bundledSerial,
      usingBundled: m == null,
      labels: labels,
      pendingSerial: stored != null && stored != m?.serial ? stored : null,
      lastCheck: await checker.lastCheck(),
      lastResult: _lastResult,
      checking: checking,
    );
  }
}

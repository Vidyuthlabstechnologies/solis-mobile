/// Downloads, verifies and locates the on-device speech models used by
/// NativeSpeechProvider (sherpa-onnx on Android).
///
/// Models are not bundled in the APK. On first use they are fetched over
/// HTTPS from their official release URLs into app-private storage
/// (Context.noBackupFilesDir/speech_models, so they are never uploaded to
/// Android backup), checked against the SHA-256 values recorded below, and
/// unpacked natively. Interrupted downloads resume with HTTP Range requests and
/// failed attempts are retried with backoff. See docs/NATIVE_SPEECH.md.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

// -----------------------------------------------------------------------------
// Platform bridge (shared with native_speech_provider.dart)
// -----------------------------------------------------------------------------

/// Channel names registered by NativeSpeechPlugin.kt.
class NativeSpeechChannels {
  static const String method = 'com.solis.clinical/native_speech';
  static const String events = 'com.solis.clinical/native_speech/events';

  static const MethodChannel methodChannel = MethodChannel(method);
  static const EventChannel eventChannel = EventChannel(events);

  /// One shared native subscription; Dart listeners fan out from it, so a
  /// provider and the model manager can listen at the same time.
  static Stream<dynamic>? _shared;
  static Stream<dynamic> get eventStream => _shared ??= eventChannel.receiveBroadcastStream().asBroadcastStream();
}

/// Digest of one file produced by native extraction.
class FileDigest {
  final String path;
  final int size;
  final String sha256;
  const FileDigest({required this.path, required this.size, required this.sha256});
}

/// File operations the model manager needs from the platform. The Android
/// implementation hashes and unpacks on a background thread in Kotlin.
abstract class ModelPlatform {
  /// Directory the models live in (created if needed).
  Future<String> modelRoot();

  /// Lowercase hex SHA-256 of [path], or null when it does not exist.
  Future<String?> sha256(String path);

  /// Extracts [entries] (path inside the .tar.bz2 to destination file name)
  /// from [archive] into [destDir].
  Future<Map<String, FileDigest>> extract(String archive, String destDir, Map<String, String> entries);

  /// Free bytes on the model volume, or null if unknown.
  Future<int?> freeBytes();

  /// Native extraction progress events (done, total in compressed bytes).
  Stream<(int, int)> get extractProgress;
}

class MethodChannelModelPlatform implements ModelPlatform {
  final MethodChannel channel;
  final Stream<dynamic> events;

  MethodChannelModelPlatform({MethodChannel? channel, Stream<dynamic>? events})
      : channel = channel ?? NativeSpeechChannels.methodChannel,
        events = events ?? NativeSpeechChannels.eventStream;

  @override
  Future<String> modelRoot() async => (await channel.invokeMethod<String>('getModelRoot'))!;

  @override
  Future<String?> sha256(String path) => channel.invokeMethod<String>('sha256', {'path': path});

  @override
  Future<Map<String, FileDigest>> extract(String archive, String destDir, Map<String, String> entries) async {
    final raw = await channel.invokeMapMethod<String, dynamic>('extractArchive', {
      'archive': archive,
      'destDir': destDir,
      'entries': entries,
    });
    final out = <String, FileDigest>{};
    raw?.forEach((name, v) {
      final m = Map<String, dynamic>.from(v as Map);
      out[name] = FileDigest(path: m['path'] as String, size: (m['size'] as num).toInt(), sha256: m['sha256'] as String);
    });
    return out;
  }

  @override
  Future<int?> freeBytes() async {
    final caps = await channel.invokeMapMethod<String, dynamic>('getCapabilities');
    final v = caps?['freeBytes'];
    return v is num && v >= 0 ? v.toInt() : null;
  }

  @override
  Stream<(int, int)> get extractProgress => events
      .where((e) => e is Map && e['type'] == 'modelProgress')
      .map((e) => ((e['done'] as num).toInt(), (e['total'] as num).toInt()));
}

// -----------------------------------------------------------------------------
// Downloader
// -----------------------------------------------------------------------------

/// An open HTTP response body.
class ModelDownloadResponse {
  final int statusCode;

  /// Bytes in [body] (not the whole file for a 206 response), if known.
  final int? contentLength;
  final Stream<List<int>> body;

  const ModelDownloadResponse({required this.statusCode, required this.body, this.contentLength});
}

abstract class ModelDownloader {
  /// GETs [url]; when [fromByte] is above 0 asks for the rest of the file
  /// with a Range header. Servers may answer 206 (partial) or 200 (whole file).
  Future<ModelDownloadResponse> open(Uri url, {int fromByte = 0});
}

class HttpModelDownloader implements ModelDownloader {
  final http.Client _client;
  final Duration timeout;

  HttpModelDownloader({http.Client? client, this.timeout = const Duration(seconds: 30)}) : _client = client ?? http.Client();

  @override
  Future<ModelDownloadResponse> open(Uri url, {int fromByte = 0}) async {
    if (url.scheme != 'https') throw ArgumentError('Model downloads must use HTTPS: $url');
    final req = http.Request('GET', url)
      ..followRedirects = true
      ..maxRedirects = 8;
    if (fromByte > 0) req.headers['Range'] = 'bytes=$fromByte-';
    final res = await _client.send(req).timeout(timeout);
    return ModelDownloadResponse(
      statusCode: res.statusCode,
      contentLength: res.contentLength,
      // A stalled connection fails instead of hanging forever.
      body: res.stream.timeout(timeout),
    );
  }
}

// -----------------------------------------------------------------------------
// Catalog
// -----------------------------------------------------------------------------

/// Roles a model file plays in the engine; keys of [SpeechModelBundle.paths].
class SpeechModelRole {
  static const vad = 'vad';
  static const encoder = 'encoder';
  static const decoder = 'decoder';
  static const tokens = 'tokens';
  static const segmentation = 'segmentation';
  static const embedding = 'embedding';
}

/// A file as it sits on the phone after download (and extraction).
class SpeechModelFile {
  final String fileName;
  final int size;
  final String sha256;
  const SpeechModelFile(this.fileName, this.size, this.sha256);
}

/// One download from an official release URL.
class SpeechModelSource {
  final String id;
  final Uri url;
  final int size;
  final String sha256;
  final String license;

  /// For .tar.bz2 archives: path inside the archive to the file it becomes.
  /// Null for files that are used exactly as downloaded.
  final Map<String, SpeechModelFile>? archiveEntries;

  /// For direct files: the resulting file.
  final SpeechModelFile? file;

  const SpeechModelSource({
    required this.id,
    required this.url,
    required this.size,
    required this.sha256,
    required this.license,
    this.archiveEntries,
    this.file,
  });

  bool get isArchive => archiveEntries != null;

  List<SpeechModelFile> get outputs => isArchive ? archiveEntries!.values.toList() : [file!];
}

enum SpeechModelSet {
  /// Moonshine Tiny (v2): 67 MB download, 80 MB on disk. Fastest; for older
  /// or low-memory phones.
  compact,

  /// Moonshine Base (v2): 148 MB download, 178 MB on disk. Noticeably better
  /// on drug names and clinical vocabulary. Default.
  standard,
}

/// Everything one model set needs, with where each role's file lives.
class SpeechModelBundle {
  final SpeechModelSet set;
  final List<SpeechModelSource> sources;
  final Map<String, String> roleFiles;

  const SpeechModelBundle(this.set, this.sources, this.roleFiles);

  int get downloadBytes => sources.fold(0, (a, s) => a + s.size);
  int get diskBytes => sources.expand((s) => s.outputs).fold(0, (a, f) => a + f.size);
  List<SpeechModelFile> get files => sources.expand((s) => s.outputs).toList();

  /// Absolute path of each role's file inside [dir].
  Map<String, String> paths(String dir) => roleFiles.map((role, name) => MapEntry(role, '$dir${Platform.pathSeparator}$name'));
}

/// Pinned model versions. Sizes and SHA-256 values were measured from the
/// release files on 2026-10-16; docs/NATIVE_SPEECH.md lists the same data.
class SpeechModelCatalog {
  static const _gh = 'https://github.com/k2-fsa/sherpa-onnx/releases/download';

  static final vad = SpeechModelSource(
    id: 'silero-vad',
    url: Uri.parse('$_gh/asr-models/silero_vad.onnx'),
    size: 643854,
    sha256: '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6',
    license: 'MIT (snakers4/silero-vad)',
    file: const SpeechModelFile('silero_vad.onnx', 643854, '9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6'),
  );

  static final segmentation = SpeechModelSource(
    id: 'pyannote-segmentation-3.0',
    url: Uri.parse('$_gh/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2'),
    size: 6958444,
    sha256: '24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488',
    license: 'MIT (pyannote/segmentation-3.0)',
    archiveEntries: const {
      'sherpa-onnx-pyannote-segmentation-3-0/model.onnx':
          SpeechModelFile('pyannote-segmentation-3-0.onnx', 5992913, '220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079'),
      'sherpa-onnx-pyannote-segmentation-3-0/LICENSE':
          SpeechModelFile('pyannote-segmentation-LICENSE.txt', 1061, '14d7016ad68e7394d6e6b78d96cc2ae431c905287b89674cfdf021e79e62b8ba'),
    },
  );

  static final embedding = SpeechModelSource(
    id: '3dspeaker-campplus-en-voxceleb',
    url: Uri.parse('$_gh/speaker-recongition-models/3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx'),
    size: 29596978,
    sha256: '357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b',
    license: 'Apache-2.0 (modelscope/3D-Speaker)',
    file: const SpeechModelFile(
        '3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx', 29596978, '357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b'),
  );

  static const _tokens = SpeechModelFile('moonshine-en-tokens.txt', 549350, '2870d843e14c1e187bf1913a521562a63b53933814bd7f2145120468f494a049');
  static const _license = SpeechModelFile('moonshine-LICENSE.txt', 13344, '6148d7574a6554b7379b633cfd4c4fe5840c3f548d13bc83e00b52dc6fa00abd');

  static final moonshineTiny = SpeechModelSource(
    id: 'moonshine-tiny-en-v2',
    url: Uri.parse('$_gh/asr-models/sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27.tar.bz2'),
    size: 29858559,
    sha256: '9ec31b342d8fa3240c3b81b8f82e1cf7e3ac467c93ca5a999b741d5887164f8d',
    license: 'MIT (moonshine-ai/moonshine, English models)',
    archiveEntries: const {
      'sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27/encoder_model.ort':
          SpeechModelFile('moonshine-tiny-en-encoder.ort', 13281600, '94e90a4654fc45cdfedb77c4c08e1739f48862998e58fada384b25118134f221'),
      'sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27/decoder_model_merged.ort':
          SpeechModelFile('moonshine-tiny-en-decoder-merged.ort', 30412256, 'cf524c4862d36e9e5ab032eddc73637efd822d70e868ac575cf1a46e1e4708a0'),
      'sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27/tokens.txt': _tokens,
      'sherpa-onnx-moonshine-tiny-en-quantized-2026-02-27/LICENSE': _license,
    },
  );

  static final moonshineBase = SpeechModelSource(
    id: 'moonshine-base-en-v2',
    url: Uri.parse('$_gh/asr-models/sherpa-onnx-moonshine-base-en-quantized-2026-02-27.tar.bz2'),
    size: 111266225,
    sha256: '43232c1d13013d37317163baec3135bd771a186a4356f28c889bab453bb0e891',
    license: 'MIT (moonshine-ai/moonshine, English models)',
    archiveEntries: const {
      'sherpa-onnx-moonshine-base-en-quantized-2026-02-27/encoder_model.ort':
          SpeechModelFile('moonshine-base-en-encoder.ort', 31326816, '7c66495948d0d08ec1af454cd4b5514862ae6511e94712a60e6d83eaec8dc8cf'),
      'sherpa-onnx-moonshine-base-en-quantized-2026-02-27/decoder_model_merged.ort':
          SpeechModelFile('moonshine-base-en-decoder-merged.ort', 109424400, 'd9d7b333af34bc552580576ddcf248a1c6c839e0d3b43b09afb9376ed009899d'),
      'sherpa-onnx-moonshine-base-en-quantized-2026-02-27/tokens.txt': _tokens,
      'sherpa-onnx-moonshine-base-en-quantized-2026-02-27/LICENSE': _license,
    },
  );

  static SpeechModelBundle bundle(SpeechModelSet set) {
    final asr = set == SpeechModelSet.compact ? moonshineTiny : moonshineBase;
    final prefix = set == SpeechModelSet.compact ? 'moonshine-tiny-en' : 'moonshine-base-en';
    return SpeechModelBundle(set, [vad, segmentation, embedding, asr], {
      SpeechModelRole.vad: vad.file!.fileName,
      SpeechModelRole.encoder: '$prefix-encoder.ort',
      SpeechModelRole.decoder: '$prefix-decoder-merged.ort',
      SpeechModelRole.tokens: _tokens.fileName,
      SpeechModelRole.segmentation: 'pyannote-segmentation-3-0.onnx',
      SpeechModelRole.embedding: embedding.file!.fileName,
    });
  }
}

// -----------------------------------------------------------------------------
// Manager
// -----------------------------------------------------------------------------

enum ModelPrepareStage { checking, downloading, verifying, extracting, ready, failed }

/// Progress of [ModelManager.prepare]. Failures arrive as a [ModelPrepareStage.failed]
/// event with [error] set; the stream never emits an error.
class ModelPrepareProgress {
  final ModelPrepareStage stage;

  /// The source being worked on (null for whole-bundle events).
  final String? sourceId;

  /// Bytes downloaded across the bundle, including files already present.
  final int receivedBytes;
  final int totalBytes;
  final int attempt;
  final String? error;

  const ModelPrepareProgress({
    required this.stage,
    this.sourceId,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.attempt = 1,
    this.error,
  });

  double get fraction => totalBytes <= 0 ? 0 : (receivedBytes / totalBytes).clamp(0, 1).toDouble();
  bool get isDone => stage == ModelPrepareStage.ready || stage == ModelPrepareStage.failed;

  @override
  String toString() => 'ModelPrepareProgress($stage, $sourceId, $receivedBytes/$totalBytes, attempt $attempt${error == null ? '' : ', $error'})';
}

class ModelIntegrityException implements Exception {
  final String message;
  const ModelIntegrityException(this.message);
  @override
  String toString() => message;
}

/// Downloads and verifies one [SpeechModelBundle].
///
/// ```dart
/// final models = ModelManager();
/// if (!await models.isReady()) {
///   await for (final p in models.prepare()) { setState(() => progress = p); }
/// }
/// final paths = await models.modelPaths();
/// ```
class ModelManager {
  final SpeechModelBundle bundle;
  final ModelPlatform platform;
  final ModelDownloader downloader;
  final int maxAttempts;
  final Duration retryDelay;

  /// Manifest of verified files, so isReady() does not re-hash 150 MB on
  /// every launch.
  static const String manifestName = 'verified.json';

  ModelManager({
    SpeechModelSet set = SpeechModelSet.standard,
    SpeechModelBundle? bundle,
    ModelPlatform? platform,
    ModelDownloader? downloader,
    this.maxAttempts = 4,
    this.retryDelay = const Duration(seconds: 2),
  })  : bundle = bundle ?? SpeechModelCatalog.bundle(set),
        platform = platform ?? MethodChannelModelPlatform(),
        downloader = downloader ?? HttpModelDownloader();

  String? _dir;
  bool _preparing = false;

  Future<String> modelDir() async => _dir ??= await platform.modelRoot();

  /// Absolute path of each model role (vad, encoder, decoder, tokens,
  /// segmentation, embedding) for NativeSpeechProvider.
  Future<Map<String, String>> modelPaths() async => bundle.paths(await modelDir());

  /// True when every file of the bundle is present with the expected size
  /// and was verified against its SHA-256 (recorded in [manifestName]).
  Future<bool> isReady() async {
    final dir = await modelDir();
    final manifest = await _readManifest(dir);
    for (final f in bundle.files) {
      final file = File(_join(dir, f.fileName));
      if (!await file.exists() || await file.length() != f.size) return false;
      if (manifest[f.fileName] != f.sha256) return false;
    }
    return true;
  }

  /// Bytes still to download for this bundle (0 when ready).
  Future<int> remainingDownloadBytes() async {
    if (await isReady()) return 0;
    final dir = await modelDir();
    final manifest = await _readManifest(dir);
    var total = 0;
    for (final s in bundle.sources) {
      if (!await _sourceInstalled(dir, s, manifest)) total += s.size;
    }
    return total;
  }

  /// Downloads, verifies and unpacks whatever is missing. Safe to call again
  /// after a failure: finished files are kept and partial downloads resume.
  Stream<ModelPrepareProgress> prepare() {
    final out = StreamController<ModelPrepareProgress>();
    if (_preparing) {
      out
        ..add(const ModelPrepareProgress(stage: ModelPrepareStage.failed, error: 'A model download is already running.'))
        ..close();
      return out.stream;
    }
    _preparing = true;
    () async {
      try {
        await _prepare(out.add);
      } catch (e) {
        out.add(ModelPrepareProgress(stage: ModelPrepareStage.failed, error: _describe(e)));
      } finally {
        _preparing = false;
        await out.close();
      }
    }();
    return out.stream;
  }

  /// Deletes every file of this bundle (and partial downloads). Refused while
  /// a download is running, so the two never write the manifest at once.
  Future<void> delete() async {
    if (_preparing) throw StateError('A model download is running. Cancel it before removing the models.');
    final dir = await modelDir();
    final manifest = await _readManifest(dir);
    for (final s in bundle.sources) {
      for (final f in s.outputs) {
        await _deleteIfExists(File(_join(dir, f.fileName)));
        manifest.remove(f.fileName);
      }
      await _deleteIfExists(File(_partPath(dir, s)));
    }
    await _writeManifest(dir, manifest);
  }

  Future<void> _prepare(void Function(ModelPrepareProgress) emit) async {
    final dir = await modelDir();
    await Directory(dir).create(recursive: true);
    final total = bundle.downloadBytes;
    emit(ModelPrepareProgress(stage: ModelPrepareStage.checking, totalBytes: total));
    final manifest = await _readManifest(dir);

    final pending = <SpeechModelSource>[];
    var done = 0;
    for (final s in bundle.sources) {
      if (await _sourceInstalled(dir, s, manifest)) {
        done += s.size;
      } else {
        pending.add(s);
      }
    }
    if (pending.isNotEmpty) {
      final need = pending.fold<int>(0, (a, s) => a + s.size + (s.isArchive ? s.outputs.fold<int>(0, (b, f) => b + f.size) : 0));
      final free = await platform.freeBytes().catchError((_) => null);
      if (free != null && free < need + 20 * 1024 * 1024) {
        throw ModelIntegrityException(
            'Not enough storage for the speech models: ${_mb(need)} needed, ${_mb(free)} free.');
      }
    }

    for (final s in pending) {
      final base = done;
      await _withRetries(s, (attempt) async {
        await _installSource(dir, s, manifest, attempt, (received) {
          emit(ModelPrepareProgress(
            stage: ModelPrepareStage.downloading,
            sourceId: s.id,
            receivedBytes: base + received,
            totalBytes: total,
            attempt: attempt,
          ));
        }, emit, base, total);
      }, emit, base, total);
      done += s.size;
    }
    if (!await isReady()) {
      throw const ModelIntegrityException('Speech models could not be verified after download.');
    }
    emit(ModelPrepareProgress(stage: ModelPrepareStage.ready, receivedBytes: total, totalBytes: total));
  }

  Future<void> _withRetries(
    SpeechModelSource s,
    Future<void> Function(int attempt) body,
    void Function(ModelPrepareProgress) emit,
    int base,
    int total,
  ) async {
    Object? last;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        await body(attempt);
        return;
      } catch (e) {
        last = e;
        if (attempt == maxAttempts) break;
        emit(ModelPrepareProgress(
          stage: ModelPrepareStage.downloading,
          sourceId: s.id,
          receivedBytes: base,
          totalBytes: total,
          attempt: attempt + 1,
          error: 'Retrying ${s.id}: ${_describe(e)}',
        ));
        await Future<void>.delayed(retryDelay * attempt);
      }
    }
    throw ModelIntegrityException('Could not download ${s.id} after $maxAttempts attempts: ${_describe(last!)}');
  }

  Future<void> _installSource(
    String dir,
    SpeechModelSource s,
    Map<String, String> manifest,
    int attempt,
    void Function(int received) onBytes,
    void Function(ModelPrepareProgress) emit,
    int base,
    int total,
  ) async {
    final part = File(_partPath(dir, s));
    await _download(s, part, onBytes);

    emit(ModelPrepareProgress(stage: ModelPrepareStage.verifying, sourceId: s.id, receivedBytes: base + s.size, totalBytes: total, attempt: attempt));
    final length = await part.length();
    final digest = await platform.sha256(part.path);
    if (length != s.size || digest != s.sha256) {
      await _deleteIfExists(part);
      throw ModelIntegrityException('Checksum mismatch for ${s.id} (got ${digest ?? 'nothing'}, $length bytes).');
    }

    if (s.isArchive) {
      emit(ModelPrepareProgress(stage: ModelPrepareStage.extracting, sourceId: s.id, receivedBytes: base + s.size, totalBytes: total, attempt: attempt));
      final entries = s.archiveEntries!.map((k, v) => MapEntry(k, v.fileName));
      final Map<String, FileDigest> got;
      try {
        got = await platform.extract(part.path, dir, entries);
      } catch (e) {
        // A verified archive that will not unpack is not worth re-downloading
        // in a loop; drop it so the next attempt starts clean.
        await _deleteIfExists(part);
        rethrow;
      }
      for (final f in s.archiveEntries!.values) {
        final d = got[f.fileName];
        if (d == null || d.size != f.size || d.sha256 != f.sha256) {
          for (final g in s.outputs) {
            await _deleteIfExists(File(_join(dir, g.fileName)));
          }
          await _deleteIfExists(part);
          throw ModelIntegrityException('Unpacked ${f.fileName} does not match its checksum.');
        }
      }
      for (final f in s.outputs) {
        manifest[f.fileName] = f.sha256;
      }
      await _deleteIfExists(part);
    } else {
      final f = s.file!;
      final target = File(_join(dir, f.fileName));
      await _deleteIfExists(target);
      await part.rename(target.path);
      manifest[f.fileName] = f.sha256;
    }
    await _writeManifest(dir, manifest);
  }

  /// Downloads [s] into [part], resuming from its current length.
  Future<void> _download(SpeechModelSource s, File part, void Function(int received) onBytes) async {
    var have = await part.exists() ? await part.length() : 0;
    if (have > s.size) {
      await part.delete();
      have = 0;
    }
    if (have == s.size) {
      onBytes(have);
      return;
    }
    final res = await downloader.open(s.url, fromByte: have);
    if (res.statusCode == 416) {
      // Range not satisfiable: the partial file is unusable.
      await _drain(res.body);
      await _deleteIfExists(part);
      throw ModelIntegrityException('Server rejected the resume request for ${s.id}.');
    }
    if (res.statusCode != 200 && res.statusCode != 206) {
      await _drain(res.body);
      throw ModelIntegrityException('HTTP ${res.statusCode} while downloading ${s.id}.');
    }
    if (res.statusCode == 200 && have > 0) have = 0; // server ignored Range
    final sink = part.openWrite(mode: have == 0 ? FileMode.write : FileMode.append);
    var received = have;
    onBytes(received);
    try {
      await for (final chunk in res.body) {
        received += chunk.length;
        if (received > s.size) {
          throw ModelIntegrityException('${s.id} is larger than expected.');
        }
        sink.add(chunk);
        onBytes(received);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (received != s.size) {
      throw ModelIntegrityException('Download of ${s.id} ended early ($received of ${s.size} bytes).');
    }
  }

  Future<bool> _sourceInstalled(String dir, SpeechModelSource s, Map<String, String> manifest) async {
    for (final f in s.outputs) {
      final file = File(_join(dir, f.fileName));
      if (!await file.exists() || await file.length() != f.size || manifest[f.fileName] != f.sha256) return false;
    }
    return true;
  }

  Future<Map<String, String>> _readManifest(String dir) async {
    final f = File(_join(dir, manifestName));
    try {
      if (!await f.exists()) return {};
      final m = jsonDecode(await f.readAsString());
      return m is Map ? m.map((k, v) => MapEntry(k.toString(), v.toString())) : {};
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeManifest(String dir, Map<String, String> manifest) async {
    final f = File(_join(dir, manifestName));
    final tmp = File('${f.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    await tmp.writeAsString(jsonEncode(manifest), flush: true);
    await tmp.rename(f.path);
  }

  static Future<void> _drain(Stream<List<int>> s) async {
    try {
      await s.drain<void>();
    } catch (_) {}
  }

  static Future<void> _deleteIfExists(File f) async {
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static String _partPath(String dir, SpeechModelSource s) => _join(dir, '${s.id}.download');
  static String _join(String dir, String name) => '$dir${Platform.pathSeparator}$name';
  static String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB';

  static String _describe(Object e) {
    if (e is SocketException) return 'Network error (${e.message}).';
    if (e is TimeoutException) return 'The download timed out.';
    if (e is HttpException) return 'Network error (${e.message}).';
    if (e is PlatformException) return e.message ?? e.code;
    return e.toString();
  }
}

/// SHA-256 in Dart, streaming the file. Used by tests and as a fallback
/// where the native hasher is unavailable.
Future<String?> dartSha256(String path) async {
  final f = File(path);
  if (!await f.exists()) return null;
  final digest = await sha256.bind(f.openRead()).first;
  return digest.toString();
}

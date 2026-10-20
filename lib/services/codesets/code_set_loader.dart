// Loader for the official code-set assets in assets/codes/.
//
// The assets are gzip-compressed UTF-8 TSV files produced by
// tool/build_code_assets.py. Each file is read and decompressed at most once
// per source; catalogs built from them are cached by their own load() methods.
//
// Tests (or tools) can swap the source with [CodeSetLoader.useSource], using
// [DirectoryCodeSetSource] for real files on disk or [MemoryCodeSetSource] for
// raw TSV strings.

import 'dart:convert';
import 'dart:io' show File, gzip;
import 'dart:isolate';

import 'package:flutter/services.dart' show rootBundle;

/// File names of the assets written by tool/build_code_assets.py.
class CodeSetFiles {
  CodeSetFiles._();

  /// ICD-10-CM code descriptions for fiscal year [fy], e.g. icd10cm_2027.tsv.gz.
  static String icd10cm(int fy) => 'icd10cm_$fy.tsv.gz';

  /// ICD-10-CM Alphabetic Index for fiscal year [fy].
  static String icd10cmIndex(int fy) => 'icd10cm_index_$fy.tsv.gz';
  static const String hcpcs = 'hcpcs.tsv.gz';
  static const String pfsRvu = 'pfs_rvu.tsv.gz';
  static const String muePractitioner = 'mue_practitioner.tsv.gz';
  static const String ptpPractitioner = 'ptp_practitioner.tsv.gz';

  /// Tabular List Excludes1 notes, 7th character definitions and
  /// instructional notes of ICD-10-CM fiscal year [fy]. Every bundled edition
  /// has its own, so a claim is checked against the Tabular List of its date
  /// of service.
  static String excludes1For(int fy) => 'icd10cm_excludes1_$fy.tsv.gz';
  static String seventhCharacterFor(int fy) => 'icd_7th_$fy.tsv.gz';
  static String icdNotesFor(int fy) => 'icd_notes_$fy.tsv.gz';

  /// Coding-edit lists built from knowledge/rules/ (see SOURCES.md). The
  /// constants name the knowledge-base edition (FY2027).
  static const String excludes1 = 'icd10cm_excludes1_2027.tsv.gz';
  static const String seventhCharacter = 'icd_7th_2027.tsv.gz';
  static const String mce = 'mce_v44.tsv.gz';
  static const String addOnCodes = 'ncci_addon.tsv.gz';

  /// Knowledge-base assets: Tabular notes, guideline text and the rule
  /// catalog used to explain every claim check.
  static const String icdNotes = 'icd_notes_2027.tsv.gz';
  static const String guidelines = 'guidelines_fy2027.tsv.gz';
  static const String ruleCatalog = 'rule_catalog.tsv.gz';
}

/// ICD-10-CM fiscal-year editions bundled in assets/codes/.
///
/// FY N covers dates of service from October 1 of year N-1 through
/// September 30 of year N, so 2026-09-30 codes against FY2026 and 2026-10-01
/// against FY2027.
class IcdEditions {
  IcdEditions._();

  /// Bundled editions, oldest first. Keep in sync with ICD_EDITIONS in
  /// tool/build_code_assets.py.
  static const List<int> bundled = [2026, 2027];

  static List<int> _available = bundled;

  /// Editions this run can use, oldest first: the bundled ones plus those in
  /// the active downloaded code-set update (see CodesetUpdates). A future
  /// edition (FY2028 posted in the summer) is listed ahead of time but is
  /// only picked for dates of service in its own fiscal year.
  static List<int> get available => _available;

  /// Sets the downloaded editions; [available] becomes the sorted union with
  /// [bundled]. Pass an empty list to go back to the bundled editions.
  static void useDownloaded(Iterable<int> editions) {
    _available = List.unmodifiable({...bundled, ...editions}.toList()..sort());
  }

  static int get oldest => available.first;
  static int get latest => available.last;

  /// The ICD-10-CM fiscal year whose codes apply on [dateOfService].
  static int fiscalYearFor(DateTime dateOfService) =>
      dateOfService.month >= 10 ? dateOfService.year + 1 : dateOfService.year;

  /// True when the edition for [dateOfService] is bundled.
  static bool covers(DateTime dateOfService) =>
      available.contains(fiscalYearFor(dateOfService));

  /// The bundled edition to use for [dateOfService]. Dates outside the bundled
  /// range fall back to the nearest edition (oldest or latest); check
  /// [covers] first when that matters, for example to warn the user.
  static int resolve(DateTime dateOfService) {
    final fy = fiscalYearFor(dateOfService);
    if (fy < oldest) return oldest;
    if (fy > latest) return latest;
    return fy;
  }
}

/// Supplies the bytes of one code-set asset. Returns null when the asset is
/// not available (for example the optional PTP table).
abstract class CodeSetSource {
  Future<List<int>?> readBytes(String fileName);

  /// True when [readBytes] returns gzip data that must be decompressed.
  bool get compressed => true;
}

/// Reads assets from the Flutter asset bundle (the default in the app).
class AssetCodeSetSource implements CodeSetSource {
  const AssetCodeSetSource({this.prefix = 'assets/codes/'});

  final String prefix;

  @override
  bool get compressed => true;

  @override
  Future<List<int>?> readBytes(String fileName) async {
    try {
      final data = await rootBundle.load('$prefix$fileName');
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (_) {
      return null;
    }
  }
}

/// Reads the gzip assets from a directory on disk (used by tests).
class DirectoryCodeSetSource implements CodeSetSource {
  DirectoryCodeSetSource(this.directory);

  final String directory;

  @override
  bool get compressed => true;

  @override
  Future<List<int>?> readBytes(String fileName) async {
    final file = File('$directory/$fileName');
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }
}

/// Serves raw, uncompressed TSV strings keyed by asset file name.
class MemoryCodeSetSource implements CodeSetSource {
  MemoryCodeSetSource(this.files);

  final Map<String, String> files;

  @override
  bool get compressed => false;

  @override
  Future<List<int>?> readBytes(String fileName) async {
    final text = files[fileName];
    return text == null ? null : utf8.encode(text);
  }
}

/// Central access point for code-set text and parsed catalogs.
class CodeSetLoader {
  CodeSetLoader._();

  static CodeSetSource _source = const AssetCodeSetSource();
  static final Map<String, Future<Object?>> _cache = {};

  /// Replaces the asset source and clears every cached catalog.
  static void useSource(CodeSetSource source) {
    _source = source;
    _cache.clear();
  }

  /// Clears cached catalogs without changing the source.
  static void reset() => _cache.clear();

  /// The active source (for diagnostics and tests).
  static CodeSetSource get source => _source;

  /// Called when an asset was read but could not be decoded or parsed, before
  /// the error is rethrown. CodesetUpdates uses it to roll back a downloaded
  /// set that the parsers reject.
  static void Function(String fileName, Object error)? onParseError;

  /// Loads [fileName] once and parses it with [parse] off the UI isolate.
  /// Returns null when the asset does not exist.
  ///
  /// [parse] must be a top-level or static function so it can run in a
  /// background isolate.
  static Future<T?> load<T extends Object>(
    String fileName,
    T Function(String text) parse,
  ) {
    final key = '$fileName#$T';
    final cached = _cache[key];
    if (cached != null) return cached.then((v) => v as T?);
    final future = _loadAndParse<T>(fileName, parse);
    _cache[key] = future;
    return future;
  }

  static Future<T?> _loadAndParse<T extends Object>(
    String fileName,
    T Function(String text) parse,
  ) async {
    final bytes = await _source.readBytes(fileName);
    if (bytes == null) return null;
    final compressed = _source.compressed;
    try {
      return await Isolate.run(() => parse(decode(bytes, compressed: compressed)));
    } catch (e) {
      onParseError?.call(fileName, e);
      rethrow;
    }
  }

  /// Decompresses (when needed) and decodes UTF-8 bytes.
  static String decode(List<int> bytes, {bool compressed = true}) {
    final raw = compressed ? gzip.decode(bytes) : bytes;
    return utf8.decode(raw);
  }
}

/// Splits TSV text into rows of cells, skipping blank lines.
Iterable<List<String>> tsvRows(String text) sync* {
  for (final line in const LineSplitter().convert(text)) {
    if (line.isEmpty) continue;
    yield line.split('\t');
  }
}

/// Lowercases and splits text into alphanumeric words.
List<String> wordsOf(String text) {
  return text
      .toLowerCase()
      .replaceAll("'s", '')
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.isNotEmpty)
      .toList();
}

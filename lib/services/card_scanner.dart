import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import 'card_parser.dart';

class CardScanResult {
  final ScannedIdentity identity;
  final bool usedBarcode;
  final String rawText;
  final int pages;
  const CardScanResult(this.identity, {this.usedBarcode = false, this.rawText = '', this.pages = 1});
}

/// Captures a card and reads it on the device with Google ML Kit.
///
/// Capture uses the ML Kit Document Scanner: it finds the card's edges,
/// crops and straightens it, and can take the front and back in one go, which
/// is what makes OCR reliable on real cards under exam-room lighting. If the
/// scanner is unavailable (no Google Play services), the plain camera is used.
///
/// Nothing leaves the phone: text recognition and barcode decoding run
/// locally, and captured images are deleted as soon as they have been read.
class CardScanner {
  final ImagePicker _picker = ImagePicker();

  /// Returns null when the user cancels.
  Future<CardScanResult?> scan(CardType type, {bool fromGallery = false}) async {
    List<String> paths;
    var owned = true; // we created these files and must delete them

    if (fromGallery) {
      final photo = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 2200, imageQuality: 92);
      if (photo == null) return null;
      paths = [photo.path];
      owned = false;
    } else {
      Future<List<String>?> camera() async {
        final photo = await _picker.pickImage(source: ImageSource.camera, maxWidth: 2200, imageQuality: 92, preferredCameraDevice: CameraDevice.rear);
        return photo == null ? null : [photo.path];
      }

      // The ML Kit document scanner exists on Android only; iOS uses the camera.
      if (!Platform.isAndroid) {
        final shot = await camera();
        if (shot == null) return null;
        paths = shot;
      } else {
        try {
          paths = await _documentScan(type);
        } on PlatformException catch (e) {
          if ('${e.code} ${e.message}'.toLowerCase().contains('cancel')) return null;
          debugPrint('Document scanner unavailable, using camera: ${e.code}');
          final shot = await camera();
          if (shot == null) return null;
          paths = shot;
        } on MissingPluginException {
          final shot = await camera();
          if (shot == null) return null;
          paths = shot;
        }
      }
      if (paths.isEmpty) return null;
    }

    return _read(type, paths, owned: owned);
  }

  /// Bundled SAMPLE cards (fictional person, marked DEMO) for each card type.
  static const demoAssets = {
    CardType.insurance: ['assets/demo_cards/insurance_front.jpg', 'assets/demo_cards/insurance_back.jpg'],
    CardType.driverLicense: ['assets/demo_cards/license_back.jpg', 'assets/demo_cards/license_front.jpg'],
    CardType.ssnCard: ['assets/demo_cards/ssn_card.jpg'],
  };

  /// Runs the real on-device reader (barcode, then text recognition) on the
  /// bundled sample card, so the whole pipeline can be shown without a card.
  Future<CardScanResult> scanDemo(CardType type) async {
    final dir = await Directory.systemTemp.createTemp('solis_demo_card');
    final paths = <String>[];
    for (final asset in demoAssets[type]!) {
      final data = await rootBundle.load(asset);
      final f = File('${dir.path}/${asset.split('/').last}');
      await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      paths.add(f.path);
    }
    try {
      return await _read(type, paths, owned: true);
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<CardScanResult> _read(CardType type, List<String> paths, {required bool owned}) async {
    try {
      final inputs = [for (final p in paths) InputImage.fromFilePath(p)];

      if (type == CardType.driverLicense) {
        for (final input in inputs) {
          final barcode = await _readPdf417(input);
          if (barcode == null) continue;
          final parsed = CardParser.parseAamva(barcode);
          if (parsed != null && !parsed.isEmpty) return CardScanResult(parsed, usedBarcode: true, pages: inputs.length);
        }
      }

      final texts = <String>[];
      for (final input in inputs) {
        texts.add(await _readText(input));
      }
      final text = texts.join('\n');
      final identity = switch (type) {
        CardType.insurance => CardParser.parseInsuranceCard(text),
        CardType.driverLicense => CardParser.parseLicenseFront(text),
        CardType.ssnCard => CardParser.parseSsnCard(text),
      };
      return CardScanResult(identity, rawText: text, pages: inputs.length);
    } finally {
      if (owned) {
        for (final p in paths) {
          try {
            await File(p).delete();
          } catch (e) {
            debugPrint('Could not delete card image: $e');
          }
        }
      }
    }
  }

  /// Runs the ML Kit Document Scanner UI. Insurance cards and licenses allow
  /// two pages (front and back); an SSN card needs only the front.
  Future<List<String>> _documentScan(CardType type) async {
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        documentFormats: const {DocumentFormat.jpeg},
        mode: ScannerMode.full,
        pageLimit: type == CardType.ssnCard ? 1 : 2,
        isGalleryImport: false,
      ),
    );
    try {
      final result = await scanner.scanDocument();
      return [
        for (final p in result.images ?? const <String>[]) p.startsWith('file://') ? Uri.parse(p).toFilePath() : p,
      ];
    } finally {
      await scanner.close();
    }
  }

  Future<String> _readText(InputImage input) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(input);
      // Rebuild line by line, top to bottom, so label-value pairs stay together.
      final lines = <TextLine>[for (final b in result.blocks) ...b.lines]
        ..sort((a, b) {
          final dy = a.boundingBox.top.compareTo(b.boundingBox.top);
          return (a.boundingBox.top - b.boundingBox.top).abs() < 12 ? a.boundingBox.left.compareTo(b.boundingBox.left) : dy;
        });
      return lines.map((l) => l.text).join('\n');
    } finally {
      await recognizer.close();
    }
  }

  Future<String?> _readPdf417(InputImage input) async {
    final scanner = BarcodeScanner(formats: [BarcodeFormat.pdf417]);
    try {
      final codes = await scanner.processImage(input);
      for (final c in codes) {
        final raw = c.rawValue;
        if (raw != null && raw.length > 40) return raw;
      }
      return null;
    } finally {
      await scanner.close();
    }
  }
}

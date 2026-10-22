import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../models/product_model.dart';
import '../screens/receipt/receipt_scanner_screen.dart' show PickedReceiptImage, pickReceiptImageWithFilePicker;
import 'image_capture_service.dart';
import 'ocr/packaging_image_prep.dart';
import 'ocr/receipt_ocr_service.dart';

export 'ocr/packaging_image_prep.dart' show PreparedImage;
export '../screens/receipt/receipt_scanner_screen.dart' show PickedReceiptImage;

/// Reads text from a photo of product packaging with the app's existing OCR engines
/// (ML Kit on Android/iOS, self-hosted Tesseract.js on web).
///
/// This is plain text recognition. The open-jar PAO symbol itself is a drawing and is not
/// recognized; only a printed number such as "12M" next to or inside it can be read as
/// text, and the user must confirm it. Results are always shown for review before saving.
/// One OCR reading of a packaging image.
class OcrPass {
  final String label;
  final String text;
  final String? error;
  final List<String> steps;
  const OcrPass(this.label, this.text, {this.error, this.steps = const []});
  bool get ok => error == null;
}

/// All readings of one image (for the review screen and diagnostics).
class PackagingOcrRun {
  final List<OcrPass> passes;
  const PackagingOcrRun(this.passes);
  bool get anyText => passes.any((p) => p.text.trim().isNotEmpty);
  bool get allFailed => passes.every((p) => !p.ok);
  String? get firstError => passes.map((p) => p.error).whereType<String>().firstOrNull;
}

class PackagingOcrService {
  /// Tests only: replace the image picker.
  @visibleForTesting
  static Future<PickedReceiptImage?> Function()? debugPicker;

  /// Tests only: replace image preparation (dart:ui rendering needs real async time).
  @visibleForTesting
  static Future<PreparedImage> Function(Uint8List bytes, {int quarterTurns, ui.Rect? crop, bool enhance})? debugPrepare;

  /// Lets the user pick a packaging photo (via Camera or Gallery/Files, or debugPicker in tests).
  static Future<PickedReceiptImage?> pickImage({BuildContext? context}) {
    if (debugPicker != null) return debugPicker!();
    if (context != null) {
      return ImageCaptureService.pickImageWithSourceChoice(
        context,
        title: 'Packaging Photo',
        cameraLabel: 'Take Photo of Packaging',
        galleryLabel: 'Choose from Gallery / Files',
      );
    }
    return pickReceiptImageWithFilePicker();
  }

  /// Reads a packaging image in at most two passes with the platform OCR engine (ML Kit
  /// on Android/iOS, self-hosted Tesseract.js in the browser):
  ///
  /// 1. "as captured": the original file (its path on Android, so ML Kit applies the EXIF
  ///    rotation itself), or the user's rotated/cropped version of it;
  /// 2. "enhanced": the same region upscaled, grayscale and contrast-stretched.
  ///
  /// Each pass's text and any error are returned separately; a failure of one pass does not
  /// discard the other. Nothing leaves the device.
  static Future<PackagingOcrRun> readPackaging(PickedReceiptImage image, {int quarterTurns = 0, ui.Rect? crop}) async {
    final prepare = debugPrepare ?? PackagingImagePrep.prepare;
    final passes = <OcrPass>[];
    final adjusted = quarterTurns % 4 != 0 || crop != null;

    Future<void> run(String label, Future<(Uint8List?, String?, List<String>)> Function() input) async {
      final sw = Stopwatch()..start();
      List<String> steps = const [];
      try {
        final (bytes, path, s) = await input();
        steps = s;
        final text = await ReceiptOcrService.recognize(
          filePath: path,
          bytes: bytes,
          mimeType: path != null || bytes == image.bytes ? image.mimeType : 'image/png',
        );
        passes.add(OcrPass(label, text, steps: steps));
      } catch (e) {
        passes.add(OcrPass(label, '', error: e.toString().replaceFirst(RegExp(r'^\w*(Exception|Error): '), ''), steps: steps));
      }
      if (kDebugMode) {
        debugPrint('[packaging-ocr] pass "$label": ${passes.last.ok ? '${passes.last.text.length} chars' : 'failed'} '
            'in ${sw.elapsedMilliseconds} ms, steps=$steps');
      }
    }

    await run('as captured', () async {
      if (!adjusted) return (image.bytes, image.path, const <String>['original image']);
      final p = await prepare(image.bytes, quarterTurns: quarterTurns, crop: crop, enhance: false);
      return (p.pngBytes, null, p.steps);
    });
    await run('enhanced', () async {
      final p = await prepare(image.bytes, quarterTurns: quarterTurns, crop: crop, enhance: true);
      return (p.pngBytes, null, p.steps);
    });
    return PackagingOcrRun(passes);
  }

  /// Lets the user pick a packaging photo and returns its recognized text, or null if the
  /// user cancelled. Throws when OCR fails.
  static Future<String?> pickAndRead({BuildContext? context}) async {
    final image = await pickImage(context: context);
    if (image == null) return null;
    return ReceiptOcrService.recognize(filePath: image.path, bytes: image.bytes, mimeType: image.mimeType);
  }

  /// PAO values printed as text, e.g. "12M", "6 M", "24 months after opening".
  /// "50ml" or "M" inside words are not matched. Returned in order of appearance.
  static List<int> paoCandidates(String text) {
    final found = <int>[];
    final patterns = [
      RegExp(r'(?<![\w.,])(\d{1,3})\s?[mM](?![a-zA-Z])'),
      RegExp(r'(\d{1,3})\s*(months?|mois|monate|meses|mesi)\b', caseSensitive: false),
    ];
    for (final p in patterns) {
      for (final m in p.allMatches(text)) {
        final n = int.tryParse(m.group(1)!);
        if (n != null && n >= ProductModel.minPaoMonths && n <= ProductModel.maxPaoMonths && !found.contains(n)) {
          found.add(n);
        }
      }
    }
    return found;
  }
}

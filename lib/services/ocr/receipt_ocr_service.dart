import 'package:flutter/foundation.dart';
import 'receipt_ocr_stub.dart'
    if (dart.library.js_interop) 'receipt_ocr_web.dart'
    if (dart.library.io) 'receipt_ocr_native.dart';

/// Signature of an OCR engine: image path and/or bytes in, recognised text out.
typedef ReceiptOcrEngine = Future<String> Function({
  String? filePath,
  Uint8List? bytes,
  String? mimeType,
});

abstract class ReceiptOcrService {
  /// Test hook to replace the platform OCR engine (ML Kit on Android/iOS,
  /// self-hosted Tesseract.js on web).
  @visibleForTesting
  static ReceiptOcrEngine? debugEngineOverride;

  /// Platform-aware entry point for extracting text from image path or bytes.
  /// Returns trimmed text; '' means the engine ran but found no text.
  static Future<String> recognize({
    String? filePath,
    Uint8List? bytes,
    String? mimeType,
  }) async {
    final hasPath = filePath != null && filePath.isNotEmpty;
    final hasBytes = bytes != null && bytes.isNotEmpty;
    if (!hasPath && !hasBytes) {
      throw Exception('No receipt image path or data provided for OCR.');
    }
    final engine = debugEngineOverride ?? recognizeReceipt;
    final text = await engine(
      filePath: hasPath ? filePath : null,
      bytes: hasBytes ? bytes : null,
      mimeType: mimeType,
    );
    return text.trim();
  }

  /// Infers an image MIME type from a file extension (defaults to JPEG).
  static String mimeTypeForExtension(String? extension) {
    switch ((extension ?? '').toLowerCase().replaceAll('.', '')) {
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'bmp':
        return 'image/bmp';
      case 'gif':
        return 'image/gif';
      default:
        return 'image/jpeg';
    }
  }
}

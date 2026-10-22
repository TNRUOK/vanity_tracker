import 'dart:io';
import 'package:flutter/foundation.dart';
import '../batch_ocr_service.dart';

Future<String> recognizeReceipt({
  String? filePath,
  Uint8List? bytes,
  String? mimeType,
}) async {
  if (filePath != null && filePath.isNotEmpty) {
    return await BatchOcrService.recognizeTextFromImage(filePath);
  }

  if (bytes != null && bytes.isNotEmpty) {
    // Write bytes to temporary file for ML Kit processing on native device
    final tempDir = await Directory.systemTemp.createTemp('receipt_ocr_');
    final ext = switch (mimeType) {
      'image/png' => 'png',
      'image/webp' => 'webp',
      'image/bmp' => 'bmp',
      _ => 'jpg',
    };
    final tempFile = File('${tempDir.path}/temp_receipt.$ext');
    try {
      await tempFile.writeAsBytes(bytes, flush: true);
      return await BatchOcrService.recognizeTextFromImage(tempFile.path);
    } finally {
      try {
        if (await tempFile.exists()) await tempFile.delete();
        if (await tempDir.exists()) await tempDir.delete();
      } catch (e) {
        debugPrint('Error cleaning up temp OCR file: $e');
      }
    }
  }

  throw Exception('No receipt image path or data provided for OCR.');
}

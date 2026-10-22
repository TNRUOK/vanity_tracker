import 'dart:typed_data';

Future<String> recognizeReceipt({
  String? filePath,
  Uint8List? bytes,
  String? mimeType,
}) async {
  throw UnsupportedError('Receipt OCR is not supported on this platform.');
}

import 'dart:js_interop';
import 'dart:typed_data';

@JS('recognizeReceiptWeb')
external JSFunction? get _recognizeFn;

@JS('recognizeReceiptWeb')
external JSPromise<JSString> _jsRecognizeReceiptWeb(JSUint8Array bytes, JSString mimeType);

/// Browser OCR via the self-hosted Tesseract.js bridge in web/receipt_ocr.js.
/// Browsers give picked files as bytes (no filesystem path), so [bytes] is required.
Future<String> recognizeReceipt({
  String? filePath,
  Uint8List? bytes,
  String? mimeType,
}) async {
  if (bytes == null || bytes.isEmpty) {
    throw Exception('No receipt image data was provided for in-browser OCR.');
  }
  if (_recognizeFn == null) {
    throw Exception('In-browser OCR is unavailable: web/receipt_ocr.js was not loaded.');
  }

  try {
    final result = await _jsRecognizeReceiptWeb(bytes.toJS, (mimeType ?? 'image/jpeg').toJS).toDart;
    return result.toDart;
  } catch (e) {
    final message = e.toString().replaceFirst(RegExp(r'^(JavaScriptError|Error):\s*'), '');
    throw Exception('In-browser OCR failed: $message');
  }
}

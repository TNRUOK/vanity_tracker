import 'dart:js_interop';
import 'dart:typed_data';
import 'backup_file_types.dart';

@JS('vanityDownloadFile')
external JSFunction? get _downloadFn;

@JS('vanityDownloadFile')
external JSNumber _jsDownload(JSUint8Array bytes, JSString fileName, JSString mimeType);

/// Web: hands the file to the browser as a download (web/file_download.js). The browser
/// decides where it is stored (normally the Downloads folder); the page cannot confirm the
/// file was written to disk, only that the download was handed over.
Future<BackupSaveOutcome> saveBackupBytes(Uint8List bytes, String fileName) async {
  if (_downloadFn == null) {
    throw UnsupportedError('Downloads are unavailable: web/file_download.js was not loaded.');
  }
  final size = _jsDownload(bytes.toJS, fileName.toJS, 'application/json'.toJS).toDartInt;
  if (size != bytes.length) {
    throw StateError('The browser received $size of ${bytes.length} bytes.');
  }
  return BackupSaveOutcome(
    saved: true,
    location: 'your browser\'s Downloads folder',
    fileName: fileName,
    isBrowserDownload: true,
  );
}

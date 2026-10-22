import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'backup_file_types.dart';

/// Android/iOS/desktop: the system "save as" dialog (Storage Access Framework on Android).
/// A `null` result from the dialog means the user cancelled. For a `file:` result the
/// written file is checked (and written if the platform only returned a path).
Future<BackupSaveOutcome> saveBackupBytes(Uint8List bytes, String fileName) async {
  final uri = await FilePicker.saveFile(
    dialogTitle: 'Save Vanity Tracker backup',
    fileName: fileName,
    bytes: bytes,
    mimeType: 'application/json',
  );
  if (uri == null) {
    return BackupSaveOutcome(saved: false, cancelled: true, fileName: fileName);
  }
  if (uri.isScheme('file')) {
    final file = File(uri.toFilePath(windows: Platform.isWindows));
    if (!file.existsSync() || file.lengthSync() == 0) {
      await file.writeAsBytes(bytes, flush: true);
    }
    final written = file.lengthSync();
    if (written != bytes.length) {
      throw FileSystemException('Only $written of ${bytes.length} bytes were written', file.path);
    }
    return BackupSaveOutcome(saved: true, location: file.path, fileName: fileName);
  }
  // content:// (Android): the system wrote the bytes to the location the user chose.
  return BackupSaveOutcome(saved: true, location: uri.toString(), fileName: fileName);
}

import 'dart:typed_data';
import 'backup_file_types.dart';

Future<BackupSaveOutcome> saveBackupBytes(Uint8List bytes, String fileName) {
  throw UnsupportedError('Saving files is not supported on this platform.');
}

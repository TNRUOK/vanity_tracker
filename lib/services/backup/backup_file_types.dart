/// Result of saving a backup file.
class BackupSaveOutcome {
  /// True only when the platform save/download action completed.
  final bool saved;

  /// The user cancelled the save dialog.
  final bool cancelled;

  /// Where the file went, in words the user can act on (path, URI or "Downloads folder").
  final String? location;
  final String fileName;

  /// Web: the browser received the download (it cannot report the final disk write).
  final bool isBrowserDownload;

  const BackupSaveOutcome({
    required this.saved,
    this.cancelled = false,
    this.location,
    required this.fileName,
    this.isBrowserDownload = false,
  });
}

bool get backupFileDownloadSupported => false;

Future<bool> downloadBackupFile(String contents, String filename) async {
  throw UnsupportedError('Backup file export is not supported on this target');
}

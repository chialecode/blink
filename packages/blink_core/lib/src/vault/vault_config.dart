import 'dart:io';

import 'package:meta/meta.dart';

import '../models/blink_models.dart';

/// Configuration options for opening or initializing a `<BLINK_VAULT_DIR>` portable vault.
@immutable
final class VaultConfig {
  const VaultConfig({
    required this.vaultDir,
    required this.expectedChannel,
    this.deviceId,
    this.enableMirrorExporter = true,
    this.mirrorDebounce = const Duration(seconds: 5),
    this.trashRetention = const Duration(days: 30),
  });

  final Directory vaultDir;
  final BlinkChannel expectedChannel;
  final String? deviceId;
  final bool enableMirrorExporter;
  final Duration mirrorDebounce;
  final Duration trashRetention;
}

/// Result returned by `VaultManager.createHotBackup` (`VACUUM INTO`, `INV-07`).
@immutable
final class VaultBackupResult {
  const VaultBackupResult({
    required this.backupFile,
    required this.byteSize,
    required this.sha256,
    required this.createdAtUtc,
  });

  final File backupFile;
  final int byteSize;
  final String sha256;
  final DateTime createdAtUtc;
}

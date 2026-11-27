import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:blink_client/platform/file_picker.dart';

/// MethodChannel name exposed by Android `MainActivity.kt`.
const String kBlinkAndroidPlatformChannelName =
    'io.github.chialecode.blink/platform';

/// Private Android app sandbox directories returned by `MainActivity.kt`.
@immutable
class AndroidStorageDirs {
  const AndroidStorageDirs({
    required this.filesDir,
    required this.noBackupFilesDir,
    required this.cacheDir,
  });

  /// Persistent app-private files directory (`Context.getFilesDir()`).
  final String filesDir;

  /// Backup-excluded app-private directory (`Context.getNoBackupFilesDir()`).
  final String noBackupFilesDir;

  /// App-private cache directory (`Context.getCacheDir()`).
  final String cacheDir;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AndroidStorageDirs &&
          filesDir == other.filesDir &&
          noBackupFilesDir == other.noBackupFilesDir &&
          cacheDir == other.cacheDir;

  @override
  int get hashCode => Object.hash(filesDir, noBackupFilesDir, cacheDir);
}

/// Zero-extra-plugin Android platform bridge backed by `MainActivity.kt`
/// `MethodChannel('io.github.chialecode.blink/platform')`.
class AndroidPlatformBridge {
  const AndroidPlatformBridge({
    this.channel = const MethodChannel(kBlinkAndroidPlatformChannelName),
  });

  final MethodChannel channel;

  /// Queries Android private storage directories (`filesDir`,
  /// `noBackupFilesDir`, `cacheDir`).
  ///
  /// Throws [StateError] if any required directory is missing or empty so
  /// Android never falls back silently to ephemeral `systemTemp`.
  Future<AndroidStorageDirs> getStorageDirs() async {
    final raw = await channel.invokeMapMethod<String, dynamic>(
      'getStorageDirs',
    );
    final filesDir = (raw?['filesDir'] as String?)?.trim() ?? '';
    final noBackupFilesDir =
        (raw?['noBackupFilesDir'] as String?)?.trim() ?? '';
    final cacheDir = (raw?['cacheDir'] as String?)?.trim() ?? '';
    if (filesDir.isEmpty || noBackupFilesDir.isEmpty || cacheDir.isEmpty) {
      throw StateError(
        'Android platform bridge returned incomplete storage directories '
        '(filesDir=$filesDir, noBackupFilesDir=$noBackupFilesDir, '
        'cacheDir=$cacheDir).',
      );
    }
    return AndroidStorageDirs(
      filesDir: filesDir,
      noBackupFilesDir: noBackupFilesDir,
      cacheDir: cacheDir,
    );
  }

  /// Launches Android SAF `ACTION_OPEN_DOCUMENT`, streams the selected document
  /// safely into app cache, and returns the local staged file path (or `null`
  /// if cancelled).
  Future<String?> pickFileToOpen({String? title, String? mimeType}) async {
    try {
      final path = await channel.invokeMethod<String>(
        'pickFileToOpen',
        <String, Object?>{
          if (title != null && title.isNotEmpty) 'title': title,
          if (mimeType != null && mimeType.isNotEmpty) 'mimeType': mimeType,
        },
      );
      final trimmed = path?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Launches Android SAF `ACTION_CREATE_DOCUMENT` and returns the destination
  /// `content://` URI string (or `null` if cancelled).
  Future<String?> pickFileToSave({
    String? title,
    String? suggestedFileName,
    String? mimeType,
  }) async {
    try {
      final uri = await channel.invokeMethod<String>(
        'pickFileToSave',
        <String, Object?>{
          if (title != null && title.isNotEmpty) 'title': title,
          if (suggestedFileName != null && suggestedFileName.isNotEmpty)
            'suggestedFileName': suggestedFileName,
          if (mimeType != null && mimeType.isNotEmpty) 'mimeType': mimeType,
        },
      );
      final trimmed = uri?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Writes [bytes] into an Android SAF `content://` destination URI returned
  /// by [pickFileToSave].
  Future<bool> writeBytesToContentUri({
    required String uri,
    required Uint8List bytes,
  }) async {
    try {
      final ok = await channel.invokeMethod<bool>(
        'writeBytesToContentUri',
        <String, Object?>{'uri': uri, 'bytes': bytes},
      );
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Acquires `WifiManager.MulticastLock` for LAN mDNS discovery (M4).
  Future<bool> acquireMulticastLock() async {
    try {
      return await channel.invokeMethod<bool>('acquireMulticastLock') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Releases `WifiManager.MulticastLock` acquired by [acquireMulticastLock].
  Future<bool> releaseMulticastLock() async {
    try {
      return await channel.invokeMethod<bool>('releaseMulticastLock') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

/// Android Storage Access Framework implementation of [BlinkFilePicker] built
/// on [AndroidPlatformBridge] (zero extra Flutter plugins).
class AndroidBlinkFilePicker implements BlinkFilePicker {
  const AndroidBlinkFilePicker({this.bridge = const AndroidPlatformBridge()});

  final AndroidPlatformBridge bridge;

  @override
  Future<String?> pickFileToOpen({String? title}) =>
      bridge.pickFileToOpen(title: title);

  @override
  Future<String?> pickFileToSave({String? title, String? suggestedFileName}) =>
      bridge.pickFileToSave(title: title, suggestedFileName: suggestedFileName);

  @override
  Future<String?> pickDirectory({String? title}) async => null;

  /// Persists exported bytes into a SAF `content://` URI returned by
  /// [pickFileToSave].
  Future<bool> writeBytesToUri(String contentUri, Uint8List bytes) =>
      bridge.writeBytesToContentUri(uri: contentUri, bytes: bytes);
}

import 'dart:convert';
import 'dart:io';

import 'package:blink_core/blink_core.dart';

import 'package:blink_client/platform/android/android_platform.dart';
import 'package:blink_client/platform/android/keystore_secret_store.dart';
import 'package:blink_client/platform/atomic_io.dart';
import 'package:blink_client/platform/paths.dart';
import 'package:blink_client/platform/windows/dpapi_secret_store.dart';

/// Canonical secret key identifiers stored exclusively in OS native secret
/// storage (`INV-08` — zero secrets inside `<BLINK_VAULT_DIR>`).
abstract final class BlinkSecretKeys {
  static const String directDeviceToken = 'sync.direct.device_token';
  static const String relayMasterKey = 'sync.relay.master_key';
  static const String relayWebDavPassword = 'sync.relay.webdav_password';
  static const String relayWebDavBearerToken = 'sync.relay.webdav_bearer_token';
  static const String relayS3AccessKeyId = 'sync.relay.s3_access_key_id';
  static const String relayS3SecretAccessKey =
      'sync.relay.s3_secret_access_key';
  static const String relayS3SessionToken = 'sync.relay.s3_session_token';
}

/// Sanitized exception raised by [BlinkSecretStore] implementations.
/// Never embeds secret values in [message].
class BlinkSecretStoreException implements Exception {
  const BlinkSecretStoreException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'BlinkSecretStoreException($code: $message)';
}

final RegExp _validSecretKeyRe = RegExp(r'^[A-Za-z0-9._-]{1,96}$');

/// Validates a secret store key so file-backed and Keystore-backed stores never
/// suffer path traversal or invalid filename characters.
String validateBlinkSecretKey(String key) {
  final trimmed = key.trim();
  if (!_validSecretKeyRe.hasMatch(trimmed) ||
      trimmed.contains('..') ||
      trimmed.startsWith('.')) {
    throw BlinkSecretStoreException(
      'invalid_key',
      'Secret key must match [A-Za-z0-9._-]{1,96} without path traversal.',
    );
  }
  return trimmed;
}

/// Cross-platform OS-native secret storage abstraction (`INV-08`, `INV-06`).
///
/// All device bearer tokens, E2EE vault sync master keys, and WebDAV/S3
/// credentials live exclusively behind this interface, partitioned by channel
/// (`blink` vs `blink-dev`) and strictly outside `<BLINK_VAULT_DIR>`.
abstract interface class BlinkSecretStore {
  /// Active channel namespace (`blink` or `blink-dev`).
  String get channel;

  /// Reads the secret stored under [key], or `null` if absent.
  Future<String?> read(String key);

  /// Atomically encrypts and persists [value] under [key].
  Future<void> write(String key, String value);

  /// Removes any secret stored under [key].
  Future<void> delete(String key);

  /// Removes all secrets stored for [channel].
  Future<void> deleteAllForChannel();
}

/// Pure in-memory secret store used for quiet tests, CI, and smoke runs so
/// automated tests never touch real host credentials.
class InMemoryBlinkSecretStore implements BlinkSecretStore {
  InMemoryBlinkSecretStore({this.channel = 'blink-dev'});

  @override
  final String channel;

  final Map<String, String> _values = <String, String>{};

  bool get isEmpty => _values.isEmpty;

  Set<String> get keys => Set<String>.unmodifiable(_values.keys);

  @override
  Future<String?> read(String key) async {
    final safeKey = validateBlinkSecretKey(key);
    return _values[safeKey];
  }

  @override
  Future<void> write(String key, String value) async {
    final safeKey = validateBlinkSecretKey(key);
    _values[safeKey] = value;
  }

  @override
  Future<void> delete(String key) async {
    final safeKey = validateBlinkSecretKey(key);
    _values.remove(safeKey);
  }

  @override
  Future<void> deleteAllForChannel() async {
    _values.clear();
  }
}

/// Scoped file fallback secret store for Linux/macOS environments where native
/// plugins (such as `libsecret-1-dev` CMake dependencies) are intentionally
/// avoided so Linux CI remains dependency-free (`DEC-032`).
///
/// Stores channel-bound envelopes atomically inside `<credentialsDir>`
/// (outside `<BLINK_VAULT_DIR>`) and applies owner-only POSIX `0600`/`0700`
/// permissions best-effort.
class ScopedFileFallbackSecretStore implements BlinkSecretStore {
  ScopedFileFallbackSecretStore({
    required this.credentialsDir,
    required this.channel,
  });

  final Directory credentialsDir;

  @override
  final String channel;

  File _fileForKey(String safeKey) {
    final sep = Platform.pathSeparator;
    return File('${credentialsDir.path}$sep$safeKey.secret');
  }

  @override
  Future<String?> read(String key) async {
    final safeKey = validateBlinkSecretKey(key);
    final file = _fileForKey(safeKey);
    if (!await file.exists()) {
      return null;
    }
    try {
      final raw = await file.readAsString(encoding: utf8);
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const BlinkSecretStoreException(
          'corrupt_secret',
          'Stored secret envelope is not a JSON object.',
        );
      }
      final storedChannel = decoded['channel'] as String?;
      final storedKey = decoded['key'] as String?;
      final payload = decoded['payload'] as String?;
      if (storedChannel != channel || storedKey != safeKey || payload == null) {
        throw const BlinkSecretStoreException(
          'channel_mismatch',
          'Stored secret envelope does not match expected channel or key.',
        );
      }
      return utf8.decode(base64Decode(payload));
    } on BlinkSecretStoreException {
      rethrow;
    } catch (_) {
      throw const BlinkSecretStoreException(
        'read_failed',
        'Failed to decode scoped credential file.',
      );
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final safeKey = validateBlinkSecretKey(key);
    if (!await credentialsDir.exists()) {
      await credentialsDir.create(recursive: true);
      await _chmodBestEffort(credentialsDir.path, '700');
    }
    final envelope = jsonEncode(<String, Object?>{
      'version': 1,
      'channel': channel,
      'key': safeKey,
      'payload': base64Encode(utf8.encode(value)),
    });
    final file = _fileForKey(safeKey);
    writeStringAtomicallySync(file, '$envelope\n');
    await _chmodBestEffort(file.path, '600');
  }

  @override
  Future<void> delete(String key) async {
    final safeKey = validateBlinkSecretKey(key);
    final file = _fileForKey(safeKey);
    if (await file.exists()) {
      await file.delete();
    }
  }

  @override
  Future<void> deleteAllForChannel() async {
    if (!await credentialsDir.exists()) {
      return;
    }
    await for (final entity in credentialsDir.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.secret')) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }

  static Future<void> _chmodBestEffort(String path, String mode) async {
    if (Platform.isWindows) {
      return;
    }
    try {
      await Process.run('chmod', <String>[mode, path]);
    } catch (_) {
      // Best-effort POSIX permission hardening.
    }
  }
}

/// Platform factory selecting the appropriate channel-isolated
/// [BlinkSecretStore] without requiring any third-party native Flutter plugin.
BlinkSecretStore createDefaultBlinkSecretStore({
  required BlinkPaths paths,
  required BlinkChannel channel,
  bool quietOverride = false,
  bool? isWindowsOverride,
  bool? isAndroidOverride,
  AndroidPlatformBridge androidBridge = const AndroidPlatformBridge(),
}) {
  final channelWire = channel.wireValue;
  if (quietOverride) {
    return InMemoryBlinkSecretStore(channel: channelWire);
  }
  final isAndroid = isAndroidOverride ?? Platform.isAndroid;
  if (isAndroid) {
    return AndroidKeystoreSecretStore(
      channel: channelWire,
      bridge: androidBridge,
    );
  }
  final isWindows = isWindowsOverride ?? Platform.isWindows;
  if (isWindows) {
    return WindowsDpapiSecretStore(
      credentialsDir: paths.credentialsDir,
      channel: channelWire,
    );
  }
  return ScopedFileFallbackSecretStore(
    credentialsDir: paths.credentialsDir,
    channel: channelWire,
  );
}

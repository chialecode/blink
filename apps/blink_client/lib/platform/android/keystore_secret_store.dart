import 'package:flutter/services.dart';

import 'package:blink_client/platform/android/android_platform.dart';
import 'package:blink_client/platform/secret_store.dart';

/// Android Keystore AES-256-GCM implementation of [BlinkSecretStore]
/// (`architecture.md` §4.1, `INV-06`, `INV-08`).
///
/// Communicates with `MainActivity.kt` over
/// `MethodChannel('io.github.chialecode.blink/platform')`, which manages a
/// channel-scoped hardware-backed AES-256-GCM key (`blink_secret_key_<channel>`)
/// and persists ciphertext atomically under
/// `<noBackupFilesDir>/<channel>/credentials/<key>.enc` (strictly outside
/// `<AppFilesDir>/blink[-dev]` and excluded from Android Auto Backup).
class AndroidKeystoreSecretStore implements BlinkSecretStore {
  const AndroidKeystoreSecretStore({
    required this.channel,
    this.bridge = const AndroidPlatformBridge(),
  });

  @override
  final String channel;

  final AndroidPlatformBridge bridge;

  @override
  Future<String?> read(String key) async {
    final safeKey = validateBlinkSecretKey(key);
    try {
      return await bridge.secretRead(channel: channel, key: safeKey);
    } on PlatformException catch (error) {
      throw BlinkSecretStoreException(
        error.code,
        error.message ?? 'Android Keystore read failed.',
      );
    } on MissingPluginException {
      throw const BlinkSecretStoreException(
        'keystore_unavailable',
        'Android Keystore MethodChannel handler is unavailable.',
      );
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final safeKey = validateBlinkSecretKey(key);
    try {
      await bridge.secretWrite(channel: channel, key: safeKey, value: value);
    } on PlatformException catch (error) {
      throw BlinkSecretStoreException(
        error.code,
        error.message ?? 'Android Keystore write failed.',
      );
    } on MissingPluginException {
      throw const BlinkSecretStoreException(
        'keystore_unavailable',
        'Android Keystore MethodChannel handler is unavailable.',
      );
    }
  }

  @override
  Future<void> delete(String key) async {
    final safeKey = validateBlinkSecretKey(key);
    try {
      await bridge.secretDelete(channel: channel, key: safeKey);
    } on PlatformException catch (error) {
      throw BlinkSecretStoreException(
        error.code,
        error.message ?? 'Android Keystore delete failed.',
      );
    } on MissingPluginException {
      throw const BlinkSecretStoreException(
        'keystore_unavailable',
        'Android Keystore MethodChannel handler is unavailable.',
      );
    }
  }

  @override
  Future<void> deleteAllForChannel() async {
    try {
      await bridge.secretDeleteAllForChannel(channel: channel);
    } on PlatformException catch (error) {
      throw BlinkSecretStoreException(
        error.code,
        error.message ?? 'Android Keystore clear failed.',
      );
    } on MissingPluginException {
      throw const BlinkSecretStoreException(
        'keystore_unavailable',
        'Android Keystore MethodChannel handler is unavailable.',
      );
    }
  }
}

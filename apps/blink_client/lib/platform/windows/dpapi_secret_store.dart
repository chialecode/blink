import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'package:blink_client/platform/atomic_io.dart';
import 'package:blink_client/platform/secret_store.dart';

/// Win32 DPAPI flag forbidding any interactive OS UI prompts (`dpapi.h`).
const int kCryptProtectUiForbidden = 0x00000001;

/// Windows DPAPI implementation of [BlinkSecretStore] (`architecture.md` §4.1,
/// `INV-06`, `INV-08`).
///
/// Encrypts secrets for the current Windows user account via already-locked
/// `win32 6.4.0` (`CryptProtectData` / `CryptUnprotectData`) with
/// `CRYPTPROTECT_UI_FORBIDDEN` and channel-bound entropy (`blink` vs
/// `blink-dev`), persisted atomically to `<dataRoot>/credentials/<key>.dpapi`.
class WindowsDpapiSecretStore implements BlinkSecretStore {
  WindowsDpapiSecretStore({
    required this.credentialsDir,
    required this.channel,
  });

  final Directory credentialsDir;

  @override
  final String channel;

  Uint8List _entropyForKey(String safeKey) =>
      Uint8List.fromList(utf8.encode('blink-dpapi-v1:$channel:$safeKey'));

  File _fileForKey(String safeKey) {
    final sep = Platform.pathSeparator;
    return File('${credentialsDir.path}$sep$safeKey.dpapi');
  }

  /// Encrypts [plaintext] using Windows DPAPI `CryptProtectData` bound to the
  /// current user and optional [entropy] bytes.
  static Uint8List protectBytes(
    Uint8List plaintext, {
    required Uint8List entropy,
  }) {
    if (!Platform.isWindows) {
      throw const BlinkSecretStoreException(
        'unsupported_platform',
        'Windows DPAPI is only available on Windows.',
      );
    }

    final inLen = plaintext.length;
    final inBuf = calloc<Uint8>(inLen == 0 ? 1 : inLen);
    final inBlob = calloc<CRYPT_INTEGER_BLOB>();
    final entLen = entropy.length;
    final entBuf = calloc<Uint8>(entLen == 0 ? 1 : entLen);
    final entBlob = calloc<CRYPT_INTEGER_BLOB>();
    final outBlob = calloc<CRYPT_INTEGER_BLOB>();

    try {
      if (inLen > 0) {
        inBuf.asTypedList(inLen).setAll(0, plaintext);
      }
      inBlob.ref
        ..cbData = inLen
        ..pbData = inBuf;

      if (entLen > 0) {
        entBuf.asTypedList(entLen).setAll(0, entropy);
      }
      entBlob.ref
        ..cbData = entLen
        ..pbData = entBuf;

      final res = CryptProtectData(
        inBlob,
        null,
        entBlob,
        null,
        kCryptProtectUiForbidden,
        outBlob,
      );
      if (!res.value || outBlob.ref.pbData == nullptr) {
        throw BlinkSecretStoreException(
          'dpapi_protect_failed',
          'Windows DPAPI CryptProtectData failed (win32 error ${res.error}).',
        );
      }
      try {
        final outLen = outBlob.ref.cbData;
        return Uint8List.fromList(outBlob.ref.pbData.asTypedList(outLen));
      } finally {
        LocalFree(HLOCAL(outBlob.ref.pbData));
      }
    } finally {
      if (inLen > 0) {
        inBuf.asTypedList(inLen).fillRange(0, inLen, 0);
      }
      if (entLen > 0) {
        entBuf.asTypedList(entLen).fillRange(0, entLen, 0);
      }
      calloc.free(inBuf);
      calloc.free(inBlob);
      calloc.free(entBuf);
      calloc.free(entBlob);
      calloc.free(outBlob);
    }
  }

  /// Decrypts [ciphertext] using Windows DPAPI `CryptUnprotectData` verifying
  /// both current-user scope and matching [entropy] bytes.
  static Uint8List unprotectBytes(
    Uint8List ciphertext, {
    required Uint8List entropy,
  }) {
    if (!Platform.isWindows) {
      throw const BlinkSecretStoreException(
        'unsupported_platform',
        'Windows DPAPI is only available on Windows.',
      );
    }
    if (ciphertext.isEmpty) {
      throw const BlinkSecretStoreException(
        'dpapi_unprotect_failed',
        'Encrypted DPAPI payload is empty.',
      );
    }

    final inLen = ciphertext.length;
    final inBuf = calloc<Uint8>(inLen);
    final inBlob = calloc<CRYPT_INTEGER_BLOB>();
    final entLen = entropy.length;
    final entBuf = calloc<Uint8>(entLen == 0 ? 1 : entLen);
    final entBlob = calloc<CRYPT_INTEGER_BLOB>();
    final outBlob = calloc<CRYPT_INTEGER_BLOB>();

    try {
      inBuf.asTypedList(inLen).setAll(0, ciphertext);
      inBlob.ref
        ..cbData = inLen
        ..pbData = inBuf;

      if (entLen > 0) {
        entBuf.asTypedList(entLen).setAll(0, entropy);
      }
      entBlob.ref
        ..cbData = entLen
        ..pbData = entBuf;

      final res = CryptUnprotectData(
        inBlob,
        null,
        entBlob,
        null,
        kCryptProtectUiForbidden,
        outBlob,
      );
      if (!res.value || outBlob.ref.pbData == nullptr) {
        throw BlinkSecretStoreException(
          'dpapi_unprotect_failed',
          'Windows DPAPI CryptUnprotectData failed (win32 error ${res.error}).',
        );
      }
      try {
        final outLen = outBlob.ref.cbData;
        final outView = outBlob.ref.pbData.asTypedList(outLen);
        final copied = Uint8List.fromList(outView);
        if (outLen > 0) {
          outView.fillRange(0, outLen, 0);
        }
        return copied;
      } finally {
        LocalFree(HLOCAL(outBlob.ref.pbData));
      }
    } finally {
      if (entLen > 0) {
        entBuf.asTypedList(entLen).fillRange(0, entLen, 0);
      }
      calloc.free(inBuf);
      calloc.free(inBlob);
      calloc.free(entBuf);
      calloc.free(entBlob);
      calloc.free(outBlob);
    }
  }

  @override
  Future<String?> read(String key) async {
    final safeKey = validateBlinkSecretKey(key);
    final file = _fileForKey(safeKey);
    if (!await file.exists()) {
      return null;
    }
    final cipherBytes = await file.readAsBytes();
    final plainBytes = unprotectBytes(
      cipherBytes,
      entropy: _entropyForKey(safeKey),
    );
    try {
      return utf8.decode(plainBytes);
    } on FormatException {
      throw const BlinkSecretStoreException(
        'corrupt_secret',
        'Decrypted DPAPI secret is not valid UTF-8.',
      );
    } finally {
      if (plainBytes.isNotEmpty) {
        plainBytes.fillRange(0, plainBytes.length, 0);
      }
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final safeKey = validateBlinkSecretKey(key);
    final plainBytes = Uint8List.fromList(utf8.encode(value));
    try {
      final cipherBytes = protectBytes(
        plainBytes,
        entropy: _entropyForKey(safeKey),
      );
      writeBytesAtomicallySync(_fileForKey(safeKey), cipherBytes);
    } finally {
      if (plainBytes.isNotEmpty) {
        plainBytes.fillRange(0, plainBytes.length, 0);
      }
    }
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
      if (entity is File && entity.path.endsWith('.dpapi')) {
        try {
          await entity.delete();
        } catch (_) {}
      }
    }
  }
}

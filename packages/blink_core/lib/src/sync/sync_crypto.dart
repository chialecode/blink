import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' as cg;
import 'package:meta/meta.dart';

import '../errors/blink_error.dart';
import '../models/blink_models.dart';

const List<int> _envelopeMagic = <int>[0x42, 0x4C, 0x4B, 0x31]; // 'BLK1'
const int _envelopeVersion = 1;
const int _nonceLength = 24;
const int _macLength = 16;
const int _minEnvelopeLength = 4 + 1 + _nonceLength + _macLength;
const String _recoveryPrefix = 'BLINK1';
const String _base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

/// 256-bit Vault Sync Master Key held in memory / OS SecretStore (`INV-08`).
/// Never persisted inside `<BLINK_VAULT_DIR>`.
@immutable
final class SyncMasterKey {
  SyncMasterKey(Uint8List bytes) : bytes = Uint8List.fromList(bytes) {
    if (this.bytes.length != 32) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'SyncMasterKey must be exactly 32 bytes',
      );
    }
  }

  final Uint8List bytes;

  /// Non-secret 16-char hex fingerprint (`SHA-256('blink-key-id:' || key)[0..8)`).
  String get keyId {
    final prefix = utf8.encode('blink-key-id:');
    final combined = Uint8List(prefix.length + bytes.length)
      ..setAll(0, prefix)
      ..setAll(prefix.length, bytes);
    return crypto.sha256.convert(combined).toString().substring(0, 16);
  }

  String toBase64Url() => base64UrlEncode(bytes).replaceAll('=', '');

  factory SyncMasterKey.fromBase64Url(String encoded) {
    try {
      final normalized = base64Url.normalize(encoded.trim());
      final decoded = base64Url.decode(normalized);
      return SyncMasterKey(Uint8List.fromList(decoded));
    } catch (error) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Invalid base64url master key',
        cause: error,
      );
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! SyncMasterKey || other.bytes.length != bytes.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < bytes.length; i++) {
      diff |= bytes[i] ^ other.bytes[i];
    }
    return diff == 0;
  }

  @override
  int get hashCode => keyId.hashCode;

  @override
  String toString() => 'SyncMasterKey(keyId: $keyId)';
}

/// Decoded QR / recovery transfer payload for onboarding a new device (`AC-05`).
@immutable
final class SyncKeyBundle {
  SyncKeyBundle({
    required this.masterKey,
    required this.vaultId,
    required this.channel,
    Map<String, Object?>? relayHint,
  }) : relayHint = relayHint == null
           ? null
           : Map<String, Object?>.unmodifiable(relayHint);

  final SyncMasterKey masterKey;
  final String vaultId;
  final BlinkChannel channel;
  final Map<String, Object?>? relayHint;
}

/// Pure-Dart client-side E2EE engine for BLINK async relays (`AC-05`, `INV-03`, `INV-08`).
///
/// Uses `XChaCha20-Poly1305` AEAD (192-bit random nonces + AAD path binding),
/// `HKDF-SHA256` domain-separated subkey derivation, and `HMAC-SHA256` blinded blob IDs.
final class SyncCrypto {
  SyncCrypto({Random? secureRandom})
    : _random = secureRandom ?? Random.secure();

  final Random _random;

  static final cg.Xchacha20 _aead = cg.Xchacha20.poly1305Aead();
  static final cg.Hkdf _hkdf = cg.Hkdf(
    hmac: cg.Hmac.sha256(),
    outputLength: 32,
  );
  static final cg.Hmac _hmacSha256 = cg.Hmac.sha256();
  static final List<int> _hkdfSalt = utf8.encode('blink-e2ee-v1');

  /// Generates a fresh 256-bit cryptographically random Vault Sync Master Key.
  SyncMasterKey generateMasterKey() {
    final bytes = Uint8List.fromList(
      List<int>.generate(32, (_) => _random.nextInt(256), growable: false),
    );
    return SyncMasterKey(bytes);
  }

  /// Encodes [key] + 16-bit SHA-256 checksum into a printable grouped recovery code
  /// (`BLINK1-XXXX-XXXX-...`).
  String encodeRecoveryCode(SyncMasterKey key) {
    final checksum = _recoveryChecksum(key.bytes);
    final payload = Uint8List(34)
      ..setAll(0, key.bytes)
      ..setAll(32, checksum);
    final b32 = _base32Encode(payload);
    final groups = <String>[_recoveryPrefix];
    for (var i = 0; i < b32.length; i += 4) {
      final end = (i + 4 > b32.length) ? b32.length : i + 4;
      groups.add(b32.substring(i, end));
    }
    return groups.join('-');
  }

  /// Decodes and checksum-verifies a printable recovery code into a [SyncMasterKey].
  SyncMasterKey decodeRecoveryCode(String rawCode) {
    final cleaned = rawCode.toUpperCase().replaceAll(RegExp(r'[\s-]+'), '');
    if (!cleaned.startsWith(_recoveryPrefix)) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Recovery code must start with $_recoveryPrefix',
      );
    }
    final b32 = cleaned.substring(_recoveryPrefix.length);
    final decoded = _base32Decode(b32);
    if (decoded.length != 34) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Recovery code decoded length must be 34 bytes',
      );
    }
    final keyBytes = Uint8List.sublistView(decoded, 0, 32);
    final expectedChecksum = _recoveryChecksum(keyBytes);
    if (decoded[32] != expectedChecksum[0] ||
        decoded[33] != expectedChecksum[1]) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Recovery code checksum verification failed',
      );
    }
    return SyncMasterKey(keyBytes);
  }

  /// Encodes a [SyncKeyBundle] into a JSON string suitable for local QR transfer.
  String encodeQrPayload(SyncKeyBundle bundle) => jsonEncode(<String, Object?>{
    'format': 'blink_e2ee_v1',
    'vault_id': bundle.vaultId,
    'channel': bundle.channel.wireValue,
    'recovery_code': encodeRecoveryCode(bundle.masterKey),
    if (bundle.relayHint != null) 'relay_hint': bundle.relayHint,
  });

  /// Decodes a QR transfer payload into a [SyncKeyBundle].
  SyncKeyBundle decodeQrPayload(String payload) {
    Map<String, Object?> decoded;
    try {
      final raw = jsonDecode(payload);
      if (raw is! Map) {
        throw const FormatException('QR payload must be a JSON object');
      }
      decoded = raw.map((k, v) => MapEntry<String, Object?>(k.toString(), v));
    } catch (error) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Malformed QR key payload',
        cause: error,
      );
    }
    if (decoded['format'] != 'blink_e2ee_v1') {
      throw BlinkException(
        code: BlinkErrorCode.protocolMismatch,
        message: 'Unsupported QR key payload format',
      );
    }
    final vaultId = decoded['vault_id'] as String?;
    final channel = BlinkChannel.tryParse(decoded['channel'] as String?);
    final recoveryCode = decoded['recovery_code'] as String?;
    if (vaultId == null ||
        vaultId.isEmpty ||
        channel == null ||
        recoveryCode == null) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'QR key payload missing required fields',
      );
    }
    final rawHint = decoded['relay_hint'];
    Map<String, Object?>? hint;
    if (rawHint is Map) {
      hint = rawHint.map((k, v) => MapEntry<String, Object?>(k.toString(), v));
    }
    return SyncKeyBundle(
      masterKey: decodeRecoveryCode(recoveryCode),
      vaultId: vaultId,
      channel: channel,
      relayHint: hint,
    );
  }

  /// Derives the key protecting `vault.meta.enc` (independent of `vaultId` so a new
  /// device holding only the recovery code can discover the relay's `vaultId`).
  Future<cg.SecretKey> deriveVaultMetaKey(SyncMasterKey masterKey) =>
      _deriveSubkey(masterKey, info: 'vault-meta');

  /// Derives the domain-separated AEAD key for encrypted OpLog batches.
  Future<cg.SecretKey> deriveOplogKey({
    required SyncMasterKey masterKey,
    required String vaultId,
  }) => _deriveSubkey(masterKey, info: 'oplog:$vaultId');

  /// Derives the domain-separated AEAD key for encrypted content-addressed blobs.
  Future<cg.SecretKey> deriveBlobKey({
    required SyncMasterKey masterKey,
    required String vaultId,
  }) => _deriveSubkey(masterKey, info: 'blob:$vaultId');

  /// Derives the HMAC key used to blind blob SHA-256 identifiers on untrusted relays.
  Future<cg.SecretKey> deriveBlobIdHmacKey({
    required SyncMasterKey masterKey,
    required String vaultId,
  }) => _deriveSubkey(masterKey, info: 'blob-id:$vaultId');

  /// Computes deterministic 64-char hex blinded blob ID (`HMAC-SHA256(k_id, sha256)`).
  Future<String> blindBlobId({
    required SyncMasterKey masterKey,
    required String vaultId,
    required String sha256,
  }) async {
    final hmacKey = await deriveBlobIdHmacKey(
      masterKey: masterKey,
      vaultId: vaultId,
    );
    final mac = await _hmacSha256.calculateMac(
      utf8.encode(sha256),
      secretKey: hmacKey,
    );
    return _bytesToHex(mac.bytes);
  }

  /// Encrypts [plaintext] using `XChaCha20-Poly1305` with a fresh random 24-byte nonce
  /// and path-bound AAD (`BLK1:<aadContext>`).
  Future<Uint8List> encryptBytes({
    required Uint8List plaintext,
    required cg.SecretKey key,
    required String aadContext,
    Uint8List? nonceOverride,
  }) async {
    final nonce = nonceOverride ?? _generateNonce();
    if (nonce.length != _nonceLength) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'XChaCha20-Poly1305 nonce must be $_nonceLength bytes',
      );
    }
    final aad = utf8.encode('BLK1:$aadContext');
    final box = await _aead.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: aad,
    );
    final out = BytesBuilder(copy: false)
      ..add(_envelopeMagic)
      ..addByte(_envelopeVersion)
      ..add(box.nonce)
      ..add(box.cipherText)
      ..add(box.mac.bytes);
    return out.takeBytes();
  }

  /// Decrypts and authenticates an `XChaCha20-Poly1305` envelope.
  /// Throws [BlinkException] on magic/version mismatch, tampering, wrong key, or wrong AAD.
  Future<Uint8List> decryptBytes({
    required Uint8List envelope,
    required cg.SecretKey key,
    required String aadContext,
  }) async {
    if (envelope.length < _minEnvelopeLength) {
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'Encrypted relay object truncated',
      );
    }
    for (var i = 0; i < 4; i++) {
      if (envelope[i] != _envelopeMagic[i]) {
        throw BlinkException(
          code: BlinkErrorCode.ioError,
          message: 'Encrypted relay object has invalid magic header',
        );
      }
    }
    if (envelope[4] != _envelopeVersion) {
      throw BlinkException(
        code: BlinkErrorCode.protocolMismatch,
        message: 'Unsupported encrypted relay object version ${envelope[4]}',
      );
    }

    final nonce = Uint8List.sublistView(envelope, 5, 5 + _nonceLength);
    final cipherText = Uint8List.sublistView(
      envelope,
      5 + _nonceLength,
      envelope.length - _macLength,
    );
    final macBytes = Uint8List.sublistView(
      envelope,
      envelope.length - _macLength,
    );
    final box = cg.SecretBox(cipherText, nonce: nonce, mac: cg.Mac(macBytes));
    final aad = utf8.encode('BLK1:$aadContext');

    try {
      final clear = await _aead.decrypt(box, secretKey: key, aad: aad);
      return Uint8List.fromList(clear);
    } on cg.SecretBoxAuthenticationError catch (error) {
      throw BlinkException(
        code: BlinkErrorCode.authRequired,
        message: 'E2EE authentication failed: tampered ciphertext or wrong key',
        cause: error,
      );
    } catch (error) {
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'E2EE decryption failed',
        cause: error,
      );
    }
  }

  /// Gzip-compresses and AEAD-encrypts a JSON object (used for `vault.meta.enc` and OpLog batches).
  Future<Uint8List> encryptJsonObject({
    required Map<String, Object?> payload,
    required cg.SecretKey key,
    required String aadContext,
  }) async {
    final jsonBytes = utf8.encode(jsonEncode(payload));
    final compressed = Uint8List.fromList(gzip.encode(jsonBytes));
    return encryptBytes(
      plaintext: compressed,
      key: key,
      aadContext: aadContext,
    );
  }

  /// AEAD-decrypts and gunzips a JSON object.
  Future<Map<String, Object?>> decryptJsonObject({
    required Uint8List envelope,
    required cg.SecretKey key,
    required String aadContext,
  }) async {
    final compressed = await decryptBytes(
      envelope: envelope,
      key: key,
      aadContext: aadContext,
    );
    try {
      final decompressed = gzip.decode(compressed);
      final decoded = jsonDecode(utf8.decode(decompressed));
      if (decoded is Map) {
        return decoded.map(
          (k, v) => MapEntry<String, Object?>(k.toString(), v),
        );
      }
      throw const FormatException('Decrypted JSON root must be an object');
    } catch (error) {
      if (error is BlinkException) {
        rethrow;
      }
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'Failed to decode decrypted relay payload',
        cause: error,
      );
    }
  }

  Future<cg.SecretKey> _deriveSubkey(
    SyncMasterKey masterKey, {
    required String info,
  }) {
    return _hkdf.deriveKey(
      secretKey: cg.SecretKey(masterKey.bytes),
      nonce: _hkdfSalt,
      info: utf8.encode(info),
    );
  }

  Uint8List _generateNonce() => Uint8List.fromList(
    List<int>.generate(
      _nonceLength,
      (_) => _random.nextInt(256),
      growable: false,
    ),
  );

  static Uint8List _recoveryChecksum(Uint8List keyBytes) {
    final prefix = utf8.encode('blink-recovery-v1:');
    final input = Uint8List(prefix.length + keyBytes.length)
      ..setAll(0, prefix)
      ..setAll(prefix.length, keyBytes);
    final digest = crypto.sha256.convert(input).bytes;
    return Uint8List.fromList(<int>[digest[0], digest[1]]);
  }

  static String _base32Encode(Uint8List bytes) {
    final out = StringBuffer();
    var buffer = 0;
    var bitsLeft = 0;
    for (final byte in bytes) {
      buffer = (buffer << 8) | (byte & 0xFF);
      bitsLeft += 8;
      while (bitsLeft >= 5) {
        bitsLeft -= 5;
        out.write(_base32Alphabet[(buffer >> bitsLeft) & 0x1F]);
      }
    }
    if (bitsLeft > 0) {
      out.write(_base32Alphabet[(buffer << (5 - bitsLeft)) & 0x1F]);
    }
    return out.toString();
  }

  static Uint8List _base32Decode(String input) {
    final out = <int>[];
    var buffer = 0;
    var bitsLeft = 0;
    for (var i = 0; i < input.length; i++) {
      final idx = _base32Alphabet.indexOf(input[i]);
      if (idx < 0) {
        throw BlinkException(
          code: BlinkErrorCode.invalidArgument,
          message: 'Recovery code contains invalid Base32 character',
        );
      }
      buffer = (buffer << 5) | idx;
      bitsLeft += 5;
      if (bitsLeft >= 8) {
        bitsLeft -= 8;
        out.add((buffer >> bitsLeft) & 0xFF);
      }
    }
    if (bitsLeft > 0 && (buffer & ((1 << bitsLeft) - 1)) != 0) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Recovery code has non-canonical Base32 trailing bits',
      );
    }
    return Uint8List.fromList(out);
  }

  static String _bytesToHex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final b in bytes) {
      buffer.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}

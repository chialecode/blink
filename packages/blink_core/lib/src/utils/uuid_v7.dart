import 'dart:math';
import 'dart:typed_data';

final Random _secureRandom = Random.secure();

final RegExp _uuidV7Pattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

int _lastTimestampMs = -1;
int _monotonicSeq = 0;

/// Returns whether [value] is a canonical 36-character lowercase RFC 9562 UUIDv7.
bool isValidUuidV7(String value) => _uuidV7Pattern.hasMatch(value);

/// Generates a canonical 36-character lowercase RFC 9562 UUIDv7 using
/// a monotonic millisecond Unix timestamp and `Random.secure()` entropy.
String generateUuidV7({DateTime? timestamp}) {
  var tsMs = (timestamp ?? DateTime.now().toUtc()).millisecondsSinceEpoch;
  if (tsMs < 0) {
    tsMs = 0;
  }

  int randA;
  if (timestamp == null) {
    if (tsMs > _lastTimestampMs) {
      _lastTimestampMs = tsMs;
      _monotonicSeq = _secureRandom.nextInt(0x1000);
    } else {
      _monotonicSeq += 1;
      if (_monotonicSeq >= 0x1000) {
        _lastTimestampMs += 1;
        _monotonicSeq = 0;
      }
      tsMs = _lastTimestampMs;
    }
    randA = _monotonicSeq;
  } else {
    randA = _secureRandom.nextInt(0x1000);
  }

  final bytes = Uint8List(16);
  // 48-bit big-endian Unix timestamp in milliseconds.
  bytes[0] = (tsMs ~/ 0x10000000000) & 0xFF;
  bytes[1] = (tsMs ~/ 0x100000000) & 0xFF;
  bytes[2] = (tsMs >> 24) & 0xFF;
  bytes[3] = (tsMs >> 16) & 0xFF;
  bytes[4] = (tsMs >> 8) & 0xFF;
  bytes[5] = tsMs & 0xFF;

  // Version 7 (0b0111) + 12-bit rand_a.
  bytes[6] = 0x70 | ((randA >> 8) & 0x0F);
  bytes[7] = randA & 0xFF;

  // Variant 10xx + 62-bit secure random rand_b.
  for (var i = 8; i < 16; i++) {
    bytes[i] = _secureRandom.nextInt(256);
  }
  bytes[8] = (bytes[8] & 0x3F) | 0x80;

  return _formatUuid(bytes);
}

String _formatUuid(Uint8List bytes) {
  final buffer = StringBuffer();
  for (var i = 0; i < 16; i++) {
    if (i == 4 || i == 6 || i == 8 || i == 10) {
      buffer.write('-');
    }
    buffer.write(bytes[i].toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

import 'package:meta/meta.dart';

/// Unified error taxonomy shared across BLINK storage, sync, reader, and AI layers (`INV-11`).
enum BlinkErrorCode {
  authRequired('auth_required'),
  deviceRevoked('device_revoked'),
  protocolMismatch('protocol_mismatch'),
  channelMismatch('channel_mismatch'),
  privacyBlocked('privacy_blocked'),
  peerAsleep('peer_asleep'),
  missingOcr('missing_ocr'),
  antiBotOrPaywall('anti_bot_or_paywall'),
  unsupportedMedia('unsupported_media'),
  webviewUnavailable('webview_unavailable'),
  htmlSanitizeRejected('html_sanitize_rejected'),
  conflictPreserved('conflict_preserved'),
  notFound('not_found'),
  invalidArgument('invalid_argument'),
  storageFull('storage_full'),
  ioError('io_error');

  const BlinkErrorCode(this.wireCode);

  /// Stable machine-readable wire identifier.
  final String wireCode;
}

/// Structured diagnostic detail attached to a [BlinkException].
@immutable
final class BlinkDiagnostic {
  const BlinkDiagnostic({required this.code, required this.message, this.path});

  final String code;
  final String message;
  final String? path;

  Map<String, Object?> toJson() => <String, Object?>{
    'code': code,
    'message': message,
    if (path != null) 'path': path,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BlinkDiagnostic &&
          code == other.code &&
          message == other.message &&
          path == other.path;

  @override
  int get hashCode => Object.hash(code, message, path);

  @override
  String toString() => path == null
      ? 'BlinkDiagnostic($code: $message)'
      : 'BlinkDiagnostic($code @ $path: $message)';
}

/// Structured exception thrown across `blink_core` (`INV-11`).
@immutable
final class BlinkException implements Exception {
  BlinkException({
    required this.code,
    required this.message,
    this.retryable = false,
    List<BlinkDiagnostic> diagnostics = const <BlinkDiagnostic>[],
    this.cause,
  }) : diagnostics = List<BlinkDiagnostic>.unmodifiable(diagnostics);

  final BlinkErrorCode code;
  final String message;
  final bool retryable;
  final List<BlinkDiagnostic> diagnostics;
  final Object? cause;

  @override
  String toString() {
    final buffer = StringBuffer('BlinkException(${code.wireCode}: $message');
    if (retryable) {
      buffer.write(', retryable: true');
    }
    if (diagnostics.isNotEmpty) {
      buffer.write(', diagnostics: ${diagnostics.length}');
    }
    buffer.write(')');
    return buffer.toString();
  }
}

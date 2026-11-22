import 'dart:convert';

/// Maximum allowed UTF-8 byte length of a single line on the control pipe.
const int kMaxControlLineBytes = 4096;

/// Supported commands accepted on `\\.\pipe\<identity>-control`.
enum ControlCommand {
  focus('focus'),
  quitForUpdate('quit-for-update'),
  ping('ping');

  const ControlCommand(this.wireName);

  final String wireName;

  static ControlCommand? tryParse(String value) {
    for (final cmd in ControlCommand.values) {
      if (cmd.wireName == value) {
        return cmd;
      }
    }
    return null;
  }
}

/// Outbound JSON request message for the control pipe.
class ControlRequest {
  const ControlRequest(this.rawCmd);

  factory ControlRequest.fromCommand(ControlCommand command) =>
      ControlRequest(command.wireName);

  final String rawCmd;

  ControlCommand? get command => ControlCommand.tryParse(rawCmd);

  String encodeLine() => '${jsonEncode(<String, Object?>{'cmd': rawCmd})}\n';
}

/// Reply sent from the primary instance over the control pipe.
class ControlResponse {
  const ControlResponse._({required this.ok, this.reason});

  const ControlResponse.ok() : this._(ok: true);

  const ControlResponse.error(String reason)
    : this._(ok: false, reason: reason);

  final bool ok;
  final String? reason;

  Map<String, Object?> toJson() => ok
      ? const <String, Object?>{'ok': true}
      : <String, Object?>{'ok': false, 'reason': reason ?? 'invalid_request'};

  String encodeLine() => '${jsonEncode(toJson())}\n';

  /// Parses a single JSON reply line; returns null if malformed.
  static ControlResponse? tryDecodeLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) {
        return null;
      }
      final okValue = decoded['ok'];
      if (okValue is! bool) {
        return null;
      }
      if (okValue) {
        return const ControlResponse.ok();
      }
      final reasonValue = decoded['reason'];
      if (reasonValue is String && reasonValue.isNotEmpty) {
        return ControlResponse.error(reasonValue);
      }
      return const ControlResponse.error('invalid_request');
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }
    return other is ControlResponse && other.ok == ok && other.reason == reason;
  }

  @override
  int get hashCode => Object.hash(ok, reason);

  @override
  String toString() => encodeLine().trim();
}

/// Result of parsing a raw request line from the control pipe.
class ControlParseResult {
  const ControlParseResult.command(this.command) : errorResponse = null;

  const ControlParseResult.error(this.errorResponse) : command = null;

  final ControlCommand? command;
  final ControlResponse? errorResponse;

  bool get isValid => command != null;
}

/// Validates and parses one line of UTF-8 bytes from the control pipe.
///
/// Rejects oversized lines, invalid UTF-8, malformed JSON, missing `cmd`, and
/// unknown commands cleanly without throwing.
ControlParseResult parseControlRequestBytes(
  List<int> rawBytes, {
  int maxBytes = kMaxControlLineBytes,
}) {
  if (rawBytes.length > maxBytes) {
    return const ControlParseResult.error(
      ControlResponse.error('invalid_request'),
    );
  }

  final String text;
  try {
    text = utf8.decode(rawBytes, allowMalformed: false).trim();
  } on FormatException {
    return const ControlParseResult.error(
      ControlResponse.error('invalid_request'),
    );
  }

  if (text.isEmpty) {
    return const ControlParseResult.error(
      ControlResponse.error('invalid_request'),
    );
  }

  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return const ControlParseResult.error(
      ControlResponse.error('invalid_request'),
    );
  }

  if (decoded is! Map) {
    return const ControlParseResult.error(
      ControlResponse.error('invalid_request'),
    );
  }

  final rawCmd = decoded['cmd'];
  if (rawCmd is! String || rawCmd.trim().isEmpty) {
    return const ControlParseResult.error(
      ControlResponse.error('invalid_request'),
    );
  }

  final command = ControlCommand.tryParse(rawCmd);
  if (command == null) {
    return const ControlParseResult.error(
      ControlResponse.error('unknown_command'),
    );
  }

  return ControlParseResult.command(command);
}

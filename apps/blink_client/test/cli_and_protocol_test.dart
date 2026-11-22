import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:blink_client/platform/cli_args.dart';
import 'package:blink_client/platform/control_protocol.dart';

void main() {
  group('CLI argument parsing (M2-K03)', () {
    test('defaults to normal interactive mode when no args given', () {
      final opts = parseLaunchOptions(
        const <String>[],
        environment: const <String, String>{},
      );
      expect(opts.mode, LaunchMode.normal);
      expect(opts.isBackground, isFalse);
      expect(opts.isQuitForUpdate, isFalse);
      expect(opts.quiet, isFalse);
      expect(opts.unknownArgs, isEmpty);
    });

    test('parses --background and BLINK_QUIET=1', () {
      final opts = parseLaunchOptions(
        const <String>['--background'],
        environment: const <String, String>{'BLINK_QUIET': '1'},
      );
      expect(opts.mode, LaunchMode.background);
      expect(opts.isBackground, isTrue);
      expect(opts.quiet, isTrue);
    });

    test('parses --quit-for-update with priority over --background', () {
      final opts = parseLaunchOptions(
        const <String>['--background', '--quit-for-update', '--extra'],
        environment: const <String, String>{'BLINK_QUIET': '0'},
      );
      expect(opts.mode, LaunchMode.quitForUpdate);
      expect(opts.isQuitForUpdate, isTrue);
      expect(opts.quiet, isFalse);
      expect(opts.unknownArgs, const <String>['--extra']);
    });
  });

  group('Control pipe JSON protocol (M2-K03)', () {
    test('encodes and decodes all supported commands', () {
      for (final cmd in ControlCommand.values) {
        final encoded = ControlRequest.fromCommand(cmd).encodeLine();
        expect(encoded.endsWith('\n'), isTrue);
        final parsed = parseControlRequestBytes(utf8.encode(encoded));
        expect(parsed.isValid, isTrue);
        expect(parsed.command, cmd);
        expect(parsed.errorResponse, isNull);
      }
    });

    test('encodes and decodes ok and error responses', () {
      const ok = ControlResponse.ok();
      expect(ok.encodeLine(), '{"ok":true}\n');
      expect(ControlResponse.tryDecodeLine(ok.encodeLine()), ok);

      const busy = ControlResponse.error('busy');
      expect(busy.encodeLine(), '{"ok":false,"reason":"busy"}\n');
      expect(ControlResponse.tryDecodeLine(busy.encodeLine()), busy);

      expect(ControlResponse.tryDecodeLine(''), isNull);
      expect(ControlResponse.tryDecodeLine('not-json'), isNull);
      expect(ControlResponse.tryDecodeLine('{"ok":"yes"}'), isNull);
    });

    test('rejects unknown commands cleanly', () {
      final parsed = parseControlRequestBytes(
        utf8.encode('{"cmd":"restart"}\n'),
      );
      expect(parsed.isValid, isFalse);
      expect(
        parsed.errorResponse,
        const ControlResponse.error('unknown_command'),
      );
    });

    test('rejects malformed JSON, non-object JSON, and invalid UTF-8 without throwing', () {
      for (final sample in <List<int>>[
        utf8.encode(''),
        utf8.encode('   \r\n'),
        utf8.encode('{bad json'),
        utf8.encode('["focus"]'),
        utf8.encode('{"cmd": 123}'),
        utf8.encode('{"cmd": ""}'),
        utf8.encode('{}'),
        <int>[0xFF, 0xFE, 0xFD],
      ]) {
        final parsed = parseControlRequestBytes(sample);
        expect(parsed.isValid, isFalse);
        expect(
          parsed.errorResponse,
          const ControlResponse.error('invalid_request'),
        );
      }
    });

    test('rejects oversized lines exceeding kMaxControlLineBytes', () {
      final huge = List<int>.filled(kMaxControlLineBytes + 1, 0x61);
      final parsed = parseControlRequestBytes(huge);
      expect(parsed.isValid, isFalse);
      expect(
        parsed.errorResponse,
        const ControlResponse.error('invalid_request'),
      );
    });
  });
}

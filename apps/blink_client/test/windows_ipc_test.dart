import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';

import 'package:blink_client/platform/control_protocol.dart';
import 'package:blink_client/platform/windows/control_pipe.dart';
import 'package:blink_client/platform/windows/single_instance.dart';
import 'package:blink_client/platform/windows/win32_bindings.dart';

Future<ControlClientResult> _sendCommandInHelperIsolate(
  String pipeName,
  ControlCommand command,
) {
  return Isolate.run(() => ControlPipeClient.sendCommand(pipeName, command));
}

Future<ControlClientResult> _sendRawInHelperIsolate(
  String pipeName,
  List<int> bytes,
) {
  return Isolate.run(() => ControlPipeClient.sendRawBytes(pipeName, bytes));
}

void main() {
  final uniqueTag = 'blink-unit-$pid-${DateTime.now().microsecondsSinceEpoch}';

  group(
    'Windows Win32 SingleInstance & ControlPipe (M2-K03/M2-K05)',
    skip: !Platform.isWindows,
    () {
      test(
        'SingleInstanceLock acquires, detects duplicate, and releases cleanly',
        () {
          final mutexName = '$uniqueTag-instance';
          expect(SingleInstanceLock.isRunning(mutexName), isFalse);

          final first = SingleInstanceLock.acquire(mutexName);
          addTearDown(first.release);
          expect(first.isPrimary, isTrue);
          expect(SingleInstanceLock.isRunning(mutexName), isTrue);

          final second = SingleInstanceLock.acquire(mutexName);
          expect(second.isPrimary, isFalse);

          first.release();
          expect(SingleInstanceLock.isRunning(mutexName), isFalse);

          final third = SingleInstanceLock.acquire(mutexName);
          addTearDown(third.release);
          expect(third.isPrimary, isTrue);
        },
      );

      test('CurrentUserSecurityAttributes builds valid SID-bound DACL', () {
        final sec = CurrentUserSecurityAttributes.create();
        addTearDown(sec.dispose);
        expect(sec.userSid, startsWith('S-1-'));
      });

      test('ControlPipeServer serves ping/focus/busy/errors and rejects second server', () async {
        final pipeName = '\\\\.\\pipe\\$uniqueTag-control';
        final received = <ControlCommand>[];
        var pretendBusy = false;

        final server = await ControlPipeServer.start(
          pipeName: pipeName,
          onCommand: (cmd) async {
            received.add(cmd);
            if (cmd == ControlCommand.quitForUpdate && pretendBusy) {
              return const ControlResponse.error('busy');
            }
            return const ControlResponse.ok();
          },
        );
        addTearDown(server.stop);

        // Second server on same pipe MUST fail due to FILE_FLAG_FIRST_PIPE_INSTANCE.
        await expectLater(
          ControlPipeServer.start(
            pipeName: pipeName,
            onCommand: (_) async => const ControlResponse.ok(),
          ),
          throwsStateError,
        );

        final ping = await _sendCommandInHelperIsolate(
          pipeName,
          ControlCommand.ping,
        );
        expect(ping.status, ControlClientStatus.ok);
        expect(ping.response, const ControlResponse.ok());

        final focus = await _sendCommandInHelperIsolate(
          pipeName,
          ControlCommand.focus,
        );
        expect(focus.status, ControlClientStatus.ok);

        // Second-instance handoff path: grant foreground to the server PID
        // first (best effort, no window involved), then deliver `focus`.
        final focusWithGrant = await Isolate.run(
          () => ControlPipeClient.sendCommand(
            pipeName,
            ControlCommand.focus,
            grantForegroundToServer: true,
          ),
        );
        expect(focusWithGrant.status, ControlClientStatus.ok);
        expect(focusWithGrant.exitCodeForFocus, 0);

        pretendBusy = true;
        final busy = await _sendCommandInHelperIsolate(
          pipeName,
          ControlCommand.quitForUpdate,
        );
        expect(busy.status, ControlClientStatus.busy);
        expect(busy.exitCodeForQuitForUpdate, 2);

        // Unknown command rejected without crashing server.
        final unknown = await _sendRawInHelperIsolate(
          pipeName,
          utf8.encode('{"cmd":"nope"}\n'),
        );
        expect(unknown.status, ControlClientStatus.error);
        expect(unknown.response?.reason, 'unknown_command');

        // Invalid JSON rejected without crashing server.
        final badJson = await _sendRawInHelperIsolate(
          pipeName,
          utf8.encode('{bad-json\n'),
        );
        expect(badJson.status, ControlClientStatus.error);
        expect(badJson.response?.reason, 'invalid_request');

        // Oversized line rejected without crashing server.
        final oversized = await _sendRawInHelperIsolate(pipeName, <int>[
          ...List<int>.filled(kMaxControlLineBytes + 32, 0x78),
          0x0A,
        ]);
        expect(oversized.status, ControlClientStatus.error);
        expect(oversized.response?.reason, 'invalid_request');

        // Server remains healthy after hostile inputs.
        pretendBusy = false;
        final quit = await _sendCommandInHelperIsolate(
          pipeName,
          ControlCommand.quitForUpdate,
        );
        expect(quit.status, ControlClientStatus.ok);
        expect(quit.exitCodeForQuitForUpdate, 0);
        expect(received, const <ControlCommand>[
          ControlCommand.ping,
          ControlCommand.focus,
          ControlCommand.focus,
          ControlCommand.quitForUpdate,
          ControlCommand.quitForUpdate,
        ]);

        await server.stop();

        // After stopping, client reports noServer cleanly.
        final afterStop = await _sendCommandInHelperIsolate(
          pipeName,
          ControlCommand.ping,
        );
        expect(afterStop.status, ControlClientStatus.noServer);
        expect(afterStop.exitCodeForQuitForUpdate, 0);
      });

      test(
        'ControlPipeServer returns busy when UI isolate command times out',
        () async {
          final pipeName = '\\\\.\\pipe\\$uniqueTag-timeout-control';
          final releaseUi = Completer<ControlResponse>();

          final server = await ControlPipeServer.start(
            pipeName: pipeName,
            commandTimeout: const Duration(milliseconds: 150),
            onCommand: (_) => releaseUi.future,
          );
          addTearDown(() async {
            if (!releaseUi.isCompleted) {
              releaseUi.complete(const ControlResponse.ok());
            }
            await server.stop();
          });

          final result = await _sendCommandInHelperIsolate(
            pipeName,
            ControlCommand.quitForUpdate,
          );
          expect(result.status, ControlClientStatus.busy);
          expect(result.response, const ControlResponse.error('busy'));
          expect(result.exitCodeForQuitForUpdate, 2);
        },
      );
    },
  );
}

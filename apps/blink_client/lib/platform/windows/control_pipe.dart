import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'package:blink_client/platform/control_protocol.dart';
import 'package:blink_client/platform/windows/win32_bindings.dart';

/// Outcome status of a control-pipe client request.
enum ControlClientStatus { ok, busy, noServer, error }

/// Result returned by [ControlPipeClient].
class ControlClientResult {
  const ControlClientResult({required this.status, this.response, this.detail});

  final ControlClientStatus status;
  final ControlResponse? response;
  final String? detail;

  /// Exit code contract shared with `scripts/package.py`:
  /// - `0`: accepted (`{"ok": true}`) or no running instance
  /// - `2`: running instance replied `busy`
  /// - `1`: pipe/protocol error
  int get exitCodeForQuitForUpdate {
    switch (status) {
      case ControlClientStatus.ok:
      case ControlClientStatus.noServer:
        return 0;
      case ControlClientStatus.busy:
        return 2;
      case ControlClientStatus.error:
        return 1;
    }
  }

  int get exitCodeForFocus => status == ControlClientStatus.ok ? 0 : 1;
}

/// Win32 named pipe client for `\\.\pipe\<identity>-control`.
class ControlPipeClient {
  ControlPipeClient._();

  /// Sends a single structured [command] line to [pipeName] and parses the
  /// JSON reply.
  static Future<ControlClientResult> sendCommand(
    String pipeName,
    ControlCommand command, {
    bool retryOnNotFound = false,
    Duration connectTimeout = const Duration(seconds: 5),
    bool grantForegroundToServer = false,
  }) async {
    final payload = utf8.encode(
      ControlRequest.fromCommand(command).encodeLine(),
    );
    return sendRawBytes(
      pipeName,
      payload,
      retryOnNotFound: retryOnNotFound,
      connectTimeout: connectTimeout,
      grantForegroundToServer: grantForegroundToServer,
    );
  }

  /// Sends raw request bytes to [pipeName] and decodes the response line.
  ///
  /// Exposed for both production client calls and real named-pipe negative
  /// tests (invalid JSON, unknown commands, oversized lines).
  ///
  /// With [grantForegroundToServer], the connected server process is allowed
  /// to take the foreground (`AllowSetForegroundWindow`) before the request is
  /// written, so a `focus` handoff from a user-launched second instance can
  /// actually raise the tray-resident primary window.
  static Future<ControlClientResult> sendRawBytes(
    String pipeName,
    List<int> requestBytes, {
    bool retryOnNotFound = false,
    Duration connectTimeout = const Duration(seconds: 5),
    bool grantForegroundToServer = false,
  }) async {
    if (!Platform.isWindows) {
      return const ControlClientResult(
        status: ControlClientStatus.error,
        detail: 'Named pipes are only supported on Windows',
      );
    }

    final deadline = DateTime.now().add(connectTimeout);
    final pipeNamePtr = pipeName.toNativeUtf16();
    HANDLE? pipeHandle;

    try {
      while (true) {
        final created = CreateFile(
          PCWSTR(pipeNamePtr),
          GENERIC_READ | GENERIC_WRITE,
          FILE_SHARE_NONE,
          nullptr,
          OPEN_EXISTING,
          const FILE_FLAGS_AND_ATTRIBUTES(0),
          null,
        );

        if (created.value.isValid) {
          pipeHandle = created.value;
          break;
        }

        final remainingMs = deadline.difference(DateTime.now()).inMilliseconds;
        if (created.error == ERROR_PIPE_BUSY) {
          if (remainingMs <= 0) {
            return const ControlClientResult(
              status: ControlClientStatus.error,
              detail: 'Timed out waiting for busy control pipe',
            );
          }
          BlinkWin32.waitNamedPipeW(pipeNamePtr, remainingMs.clamp(50, 500));
          continue;
        }

        if (created.error == ERROR_FILE_NOT_FOUND) {
          if (!retryOnNotFound || remainingMs <= 0) {
            return const ControlClientResult(
              status: ControlClientStatus.noServer,
              detail: 'Control pipe server not running',
            );
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
          continue;
        }

        return ControlClientResult(
          status: ControlClientStatus.error,
          detail: 'CreateFile("$pipeName") failed (${created.error})',
        );
      }

      if (grantForegroundToServer) {
        BlinkWin32.allowPipeServerForeground(pipeHandle);
      }

      // Write full request payload.
      final writeBuf = calloc<Uint8>(requestBytes.length);
      final bytesWritten = calloc<Uint32>();
      try {
        writeBuf.asTypedList(requestBytes.length).setAll(0, requestBytes);
        var offset = 0;
        while (offset < requestBytes.length) {
          final remaining = requestBytes.length - offset;
          final res = WriteFile(
            pipeHandle,
            writeBuf + offset,
            remaining,
            bytesWritten,
            nullptr,
          );
          if (!res.value) {
            return ControlClientResult(
              status: ControlClientStatus.error,
              detail: 'WriteFile failed (${res.error})',
            );
          }
          final written = bytesWritten.value;
          if (written == 0) {
            return const ControlClientResult(
              status: ControlClientStatus.error,
              detail: 'WriteFile wrote 0 bytes',
            );
          }
          offset += written;
        }
        FlushFileBuffers(pipeHandle);
      } finally {
        calloc.free(writeBuf);
        calloc.free(bytesWritten);
      }

      // Read one line reply.
      final replyBytes = <int>[];
      final readBuf = calloc<Uint8>(512);
      final bytesRead = calloc<Uint32>();
      try {
        while (replyBytes.length <= kMaxControlLineBytes) {
          final res = ReadFile(pipeHandle, readBuf, 512, bytesRead, nullptr);
          final count = bytesRead.value;
          if (count > 0) {
            final chunk = readBuf.asTypedList(count);
            final nlIndex = chunk.indexOf(0x0A);
            if (nlIndex >= 0) {
              replyBytes.addAll(chunk.sublist(0, nlIndex));
              break;
            }
            replyBytes.addAll(chunk);
          }
          if (!res.value) {
            if (res.error == ERROR_BROKEN_PIPE || count == 0) {
              break;
            }
            return ControlClientResult(
              status: ControlClientStatus.error,
              detail: 'ReadFile failed (${res.error})',
            );
          }
          if (count == 0) {
            break;
          }
        }
      } finally {
        calloc.free(readBuf);
        calloc.free(bytesRead);
      }

      final line = utf8.decode(replyBytes, allowMalformed: true).trim();
      final response = ControlResponse.tryDecodeLine(line);
      if (response == null) {
        return ControlClientResult(
          status: ControlClientStatus.error,
          detail: 'Malformed control pipe reply: $line',
        );
      }

      if (response.ok) {
        return ControlClientResult(
          status: ControlClientStatus.ok,
          response: response,
        );
      }
      if (response.reason == 'busy') {
        return ControlClientResult(
          status: ControlClientStatus.busy,
          response: response,
        );
      }
      return ControlClientResult(
        status: ControlClientStatus.error,
        response: response,
        detail: response.reason,
      );
    } finally {
      if (pipeHandle != null && pipeHandle.isValid) {
        CloseHandle(pipeHandle);
      }
      calloc.free(pipeNamePtr);
    }
  }
}

typedef ControlCommandHandler = Future<ControlResponse> Function(
  ControlCommand command,
);

/// Single-instance Win32 named pipe server running on a dedicated [Isolate].
///
/// Enforces:
/// - `FILE_FLAG_FIRST_PIPE_INSTANCE` + `nMaxInstances = 1`
/// - `PIPE_REJECT_REMOTE_CLIENTS`
/// - Protected current-user-only DACL (`D:P(A;;GA;;;<currentUserSid>)`)
/// - UI isolate command dispatch with 60s timeout returning `busy`
/// - Clean overlapped-I/O stop via Win32 event handle
class ControlPipeServer {
  ControlPipeServer._({
    required this.pipeName,
    required this._isolate,
    required this._uiReceivePort,
    required this._isolateExited,
    required this._stopEventAddress,
  });

  final String pipeName;
  final Isolate _isolate;
  final ReceivePort _uiReceivePort;
  final Future<void> _isolateExited;
  final int _stopEventAddress;

  bool _stopped = false;

  /// Starts the control pipe server on a background [Isolate].
  static Future<ControlPipeServer> start({
    required String pipeName,
    required ControlCommandHandler onCommand,
    Duration commandTimeout = const Duration(seconds: 60),
  }) async {
    if (!Platform.isWindows) {
      throw UnsupportedError('ControlPipeServer is only supported on Windows');
    }

    final uiReceivePort = ReceivePort();
    final exitPort = ReceivePort();
    final exitCompleter = Completer<void>();
    exitPort.listen((_) {
      if (!exitCompleter.isCompleted) {
        exitCompleter.complete();
      }
      exitPort.close();
    });
    final readyCompleter = Completer<int>();

    uiReceivePort.listen((dynamic message) {
      if (message is List && message.isNotEmpty) {
        final tag = message[0];
        if (tag == 'ready' && message.length == 2 && message[1] is int) {
          if (!readyCompleter.isCompleted) {
            readyCompleter.complete(message[1] as int);
          }
          return;
        }
        if (tag == 'error' && message.length == 2) {
          if (!readyCompleter.isCompleted) {
            readyCompleter.completeError(
              StateError('ControlPipeServer failed: ${message[1]}'),
            );
          }
          return;
        }
        if (tag == 'cmd' &&
            message.length == 3 &&
            message[1] is String &&
            message[2] is SendPort) {
          final wireName = message[1] as String;
          final replyPort = message[2] as SendPort;
          final parsed = ControlCommand.tryParse(wireName);
          if (parsed == null) {
            replyPort.send(
              const ControlResponse.error('unknown_command').encodeLine(),
            );
            return;
          }
          unawaited(() async {
            try {
              final response = await onCommand(parsed);
              replyPort.send(response.encodeLine());
            } catch (_) {
              replyPort.send(
                const ControlResponse.error('invalid_request').encodeLine(),
              );
            }
          }());
        }
      }
    });

    final stopRes = CreateEvent(nullptr, true, false, null);
    if (!stopRes.value.isValid) {
      uiReceivePort.close();
      exitPort.close();
      throw StateError('CreateEvent(stop) failed (${stopRes.error})');
    }
    final stopEventAddress = stopRes.value.address;

    final isolate = await Isolate.spawn<List<Object?>>(
      _pipeServerIsolateMain,
      <Object?>[
        uiReceivePort.sendPort,
        pipeName,
        commandTimeout.inMilliseconds,
        stopEventAddress,
      ],
      onExit: exitPort.sendPort,
      debugName: 'blink_control_pipe',
    );

    try {
      await readyCompleter.future.timeout(const Duration(seconds: 5));
      return ControlPipeServer._(
        pipeName: pipeName,
        isolate: isolate,
        uiReceivePort: uiReceivePort,
        isolateExited: exitCompleter.future,
        stopEventAddress: stopEventAddress,
      );
    } catch (_) {
      SetEvent(HANDLE(Pointer<Void>.fromAddress(stopEventAddress)));
      isolate.kill(priority: Isolate.immediate);
      try {
        await exitCompleter.future.timeout(const Duration(seconds: 1));
      } catch (_) {}
      CloseHandle(HANDLE(Pointer<Void>.fromAddress(stopEventAddress)));
      uiReceivePort.close();
      exitPort.close();
      rethrow;
    }
  }

  /// Signals the pipe isolate to stop, waits cleanly for handle cleanup, and
  /// closes the isolate ports and stop event.
  Future<void> stop() async {
    if (_stopped) {
      return;
    }
    _stopped = true;

    final stopHandle = HANDLE(Pointer<Void>.fromAddress(_stopEventAddress));
    if (stopHandle.isValid) {
      SetEvent(stopHandle);
    }

    try {
      await _isolateExited.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      _isolate.kill(priority: Isolate.immediate);
      try {
        await _isolateExited.timeout(const Duration(seconds: 1));
      } catch (_) {}
    } finally {
      if (stopHandle.isValid) {
        CloseHandle(stopHandle);
      }
      _uiReceivePort.close();
    }
  }
}

Future<void> _pipeServerIsolateMain(List<Object?> args) async {
  final uiSendPort = args[0]! as SendPort;
  final pipeName = args[1]! as String;
  final commandTimeoutMs = args[2]! as int;
  final stopEventAddress = args[3]! as int;

  final stopEvent = HANDLE(Pointer<Void>.fromAddress(stopEventAddress));
  CurrentUserSecurityAttributes? security;
  HANDLE? ioEvent;
  HANDLE? pipe;
  Pointer<Utf16> pipeNamePtr = nullptr;
  Pointer<OVERLAPPED> overlapped = nullptr;
  Pointer<Pointer<Void>> waitHandles = nullptr;
  Pointer<Uint32> transferred = nullptr;
  Pointer<Uint8> readBuf = nullptr;

  try {
    final ioRes = CreateEvent(nullptr, true, false, null);
    if (!ioRes.value.isValid) {
      uiSendPort.send(<Object?>[
        'error',
        'CreateEvent(io) failed (${ioRes.error})',
      ]);
      return;
    }
    ioEvent = ioRes.value;

    security = CurrentUserSecurityAttributes.create();
    pipeNamePtr = pipeName.toNativeUtf16();

    final getLastError = BlinkWin32.getLastErrorRaw;
    final createdPipe = CreateNamedPipe(
      PCWSTR(pipeNamePtr),
      PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED,
      PIPE_TYPE_BYTE |
          PIPE_READMODE_BYTE |
          PIPE_WAIT |
          PIPE_REJECT_REMOTE_CLIENTS,
      1,
      4096,
      4096,
      5000,
      security.attributes,
    );
    if (!createdPipe.isValid) {
      final err = getLastError();
      uiSendPort.send(<Object?>[
        'error',
        'CreateNamedPipe("$pipeName") failed ($err)',
      ]);
      return;
    }
    pipe = createdPipe;

    overlapped = calloc<OVERLAPPED>();
    waitHandles = calloc<Pointer<Void>>(2);
    waitHandles[0] = stopEvent.cast<Void>();
    waitHandles[1] = ioEvent.cast<Void>();
    transferred = calloc<Uint32>();
    readBuf = calloc<Uint8>(256);

    uiSendPort.send(<Object?>['ready', stopEventAddress]);

    while (true) {
      // Check if stop was already signaled before waiting for next client.
      final preCheck = WaitForSingleObject(stopEvent, 0);
      if (preCheck.value == WAIT_OBJECT_0) {
        break;
      }

      _resetOverlapped(overlapped, ioEvent);
      final connectRes = ConnectNamedPipe(pipe, overlapped);
      if (!connectRes.value) {
        if (connectRes.error == ERROR_IO_PENDING) {
          final waitRes = WaitForMultipleObjects(
            2,
            waitHandles,
            false,
            INFINITE,
          );
          if (waitRes.value == WAIT_OBJECT_0) {
            _cancelAndDrainOverlapped(pipe, overlapped, transferred);
            break;
          }
          if (waitRes.value != WAIT_EVENT(WAIT_OBJECT_0 + 1)) {
            _cancelAndDrainOverlapped(pipe, overlapped, transferred);
            continue;
          }
          final ovRes = GetOverlappedResult(
            pipe,
            overlapped,
            transferred,
            false,
          );
          if (!ovRes.value) {
            DisconnectNamedPipe(pipe);
            continue;
          }
        } else if (connectRes.error != ERROR_PIPE_CONNECTED) {
          DisconnectNamedPipe(pipe);
          continue;
        }
      }

      // Connected: read one line (capped to kMaxControlLineBytes + 1).
      final lineRead = _readClientLineOverlapped(
        pipe: pipe,
        stopEvent: stopEvent,
        ioEvent: ioEvent,
        overlapped: overlapped,
        waitHandles: waitHandles,
        readBuf: readBuf,
        transferred: transferred,
      );

      if (lineRead.stopRequested) {
        DisconnectNamedPipe(pipe);
        break;
      }

      String responseLine;
      if (lineRead.timedOut || lineRead.ioError) {
        responseLine = const ControlResponse.error('invalid_request')
            .encodeLine();
      } else {
        final parsed = parseControlRequestBytes(lineRead.bytes);
        if (!parsed.isValid) {
          responseLine = parsed.errorResponse!.encodeLine();
        } else {
          final replyPort = ReceivePort();
          uiSendPort.send(<Object?>[
            'cmd',
            parsed.command!.wireName,
            replyPort.sendPort,
          ]);
          try {
            final reply = await replyPort.first.timeout(
              Duration(milliseconds: commandTimeoutMs),
            );
            responseLine = reply is String
                ? reply
                : const ControlResponse.error('invalid_request').encodeLine();
          } on TimeoutException {
            responseLine = const ControlResponse.error('busy').encodeLine();
          } finally {
            replyPort.close();
          }
        }
      }

      _writeClientLineOverlapped(
        pipe: pipe,
        stopEvent: stopEvent,
        ioEvent: ioEvent,
        overlapped: overlapped,
        waitHandles: waitHandles,
        transferred: transferred,
        responseLine: responseLine,
      );
      FlushFileBuffers(pipe);
      DisconnectNamedPipe(pipe);
    }
  } finally {
    if (pipe != null && pipe.isValid) {
      CloseHandle(pipe);
    }
    if (ioEvent != null && ioEvent.isValid) {
      CloseHandle(ioEvent);
    }
    security?.dispose();
    if (pipeNamePtr != nullptr) {
      calloc.free(pipeNamePtr);
    }
    if (overlapped != nullptr) {
      calloc.free(overlapped);
    }
    if (waitHandles != nullptr) {
      calloc.free(waitHandles);
    }
    if (transferred != nullptr) {
      calloc.free(transferred);
    }
    if (readBuf != nullptr) {
      calloc.free(readBuf);
    }
  }
}

class _PipeLineRead {
  const _PipeLineRead({
    required this.bytes,
    this.stopRequested = false,
    this.timedOut = false,
    this.ioError = false,
  });

  final List<int> bytes;
  final bool stopRequested;
  final bool timedOut;
  final bool ioError;
}

void _resetOverlapped(Pointer<OVERLAPPED> overlapped, HANDLE ioEvent) {
  ResetEvent(ioEvent);
  final raw = overlapped.cast<Uint8>().asTypedList(sizeOf<OVERLAPPED>());
  raw.fillRange(0, raw.length, 0);
  overlapped.ref.hEvent = ioEvent;
}

void _cancelAndDrainOverlapped(
  HANDLE pipe,
  Pointer<OVERLAPPED> overlapped,
  Pointer<Uint32> transferred,
) {
  final cancelRes = CancelIoEx(pipe, overlapped);
  // Wait for kernel cancellation completion before reusing or freeing
  // `overlapped` and any associated I/O buffers.
  if (cancelRes.value || cancelRes.error == ERROR_NOT_FOUND) {
    GetOverlappedResult(pipe, overlapped, transferred, true);
  }
}

_PipeLineRead _readClientLineOverlapped({
  required HANDLE pipe,
  required HANDLE stopEvent,
  required HANDLE ioEvent,
  required Pointer<OVERLAPPED> overlapped,
  required Pointer<Pointer<Void>> waitHandles,
  required Pointer<Uint8> readBuf,
  required Pointer<Uint32> transferred,
}) {
  final buffer = BytesBuilder(copy: false);
  const limit = kMaxControlLineBytes + 1;
  final deadline = DateTime.now().add(const Duration(seconds: 5));

  while (buffer.length < limit) {
    final remainingMs = deadline.difference(DateTime.now()).inMilliseconds;
    if (remainingMs <= 0) {
      return _PipeLineRead(bytes: buffer.takeBytes(), timedOut: true);
    }

    _resetOverlapped(overlapped, ioEvent);
    transferred.value = 0;
    final readRes = ReadFile(pipe, readBuf, 256, transferred, overlapped);
    int count;

    if (readRes.value) {
      count = transferred.value;
    } else if (readRes.error == ERROR_IO_PENDING) {
      final waitRes = WaitForMultipleObjects(
        2,
        waitHandles,
        false,
        remainingMs.clamp(1, 5000),
      );
      if (waitRes.value == WAIT_OBJECT_0) {
        _cancelAndDrainOverlapped(pipe, overlapped, transferred);
        return _PipeLineRead(bytes: buffer.takeBytes(), stopRequested: true);
      }
      if (waitRes.value == WAIT_TIMEOUT) {
        _cancelAndDrainOverlapped(pipe, overlapped, transferred);
        return _PipeLineRead(bytes: buffer.takeBytes(), timedOut: true);
      }
      if (waitRes.value != WAIT_EVENT(WAIT_OBJECT_0 + 1)) {
        _cancelAndDrainOverlapped(pipe, overlapped, transferred);
        return _PipeLineRead(bytes: buffer.takeBytes(), ioError: true);
      }
      final ovRes = GetOverlappedResult(pipe, overlapped, transferred, false);
      if (!ovRes.value) {
        if (ovRes.error == ERROR_BROKEN_PIPE) {
          return _PipeLineRead(bytes: buffer.takeBytes());
        }
        return _PipeLineRead(bytes: buffer.takeBytes(), ioError: true);
      }
      count = transferred.value;
    } else if (readRes.error == ERROR_BROKEN_PIPE) {
      return _PipeLineRead(bytes: buffer.takeBytes());
    } else {
      return _PipeLineRead(bytes: buffer.takeBytes(), ioError: true);
    }

    if (count == 0) {
      return _PipeLineRead(bytes: buffer.takeBytes());
    }

    final chunk = readBuf.asTypedList(count);
    final nlIndex = chunk.indexOf(0x0A);
    if (nlIndex >= 0) {
      buffer.add(chunk.sublist(0, nlIndex));
      return _PipeLineRead(bytes: buffer.takeBytes());
    }
    buffer.add(chunk);
  }

  // Exceeded kMaxControlLineBytes: return oversized bytes so parser produces
  // `invalid_request` deterministically.
  return _PipeLineRead(bytes: buffer.takeBytes());
}

void _writeClientLineOverlapped({
  required HANDLE pipe,
  required HANDLE stopEvent,
  required HANDLE ioEvent,
  required Pointer<OVERLAPPED> overlapped,
  required Pointer<Pointer<Void>> waitHandles,
  required Pointer<Uint32> transferred,
  required String responseLine,
}) {
  final bytes = utf8.encode(responseLine);
  final outBuf = calloc<Uint8>(bytes.length);
  try {
    outBuf.asTypedList(bytes.length).setAll(0, bytes);
    var offset = 0;
    while (offset < bytes.length) {
      _resetOverlapped(overlapped, ioEvent);
      transferred.value = 0;
      final remaining = bytes.length - offset;
      final writeRes = WriteFile(
        pipe,
        outBuf + offset,
        remaining,
        transferred,
        overlapped,
      );
      int written;
      if (writeRes.value) {
        written = transferred.value;
      } else if (writeRes.error == ERROR_IO_PENDING) {
        final waitRes = WaitForMultipleObjects(2, waitHandles, false, 5000);
        if (waitRes.value != WAIT_EVENT(WAIT_OBJECT_0 + 1)) {
          _cancelAndDrainOverlapped(pipe, overlapped, transferred);
          return;
        }
        final ovRes = GetOverlappedResult(pipe, overlapped, transferred, false);
        if (!ovRes.value) {
          return;
        }
        written = transferred.value;
      } else {
        return;
      }
      if (written <= 0) {
        return;
      }
      offset += written;
    }
  } finally {
    calloc.free(outBuf);
  }
}

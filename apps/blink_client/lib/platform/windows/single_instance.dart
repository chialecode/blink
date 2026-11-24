import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'package:blink_client/platform/windows/win32_bindings.dart';

/// Named Win32 mutex single-instance lock (`<identity>-instance`); the NSIS
/// installer and uninstaller probe it to ask a running copy to quit for the
/// update (architecture §4.3).
///
/// Source builds (`BLINK_IDENTITY == ""`) must NEVER call this class.
class SingleInstanceLock {
  SingleInstanceLock._({
    required this.mutexName,
    required this.isPrimary,
    this._handle,
  });

  final String mutexName;
  final bool isPrimary;
  HANDLE? _handle;

  /// Probes whether an instance holding [mutexName] is currently running,
  /// without creating or claiming the mutex.
  static bool isRunning(String mutexName) {
    if (!Platform.isWindows || mutexName.trim().isEmpty) {
      return false;
    }
    final namePtr = mutexName.toNativeUtf16();
    try {
      final raw = BlinkWin32.openMutexW(kWin32Synchronize, 0, namePtr);
      if (raw == nullptr) {
        return false;
      }
      CloseHandle(HANDLE(raw));
      return true;
    } finally {
      calloc.free(namePtr);
    }
  }

  /// Attempts to claim the named mutex [mutexName].
  ///
  /// When another instance already holds [mutexName], closes the duplicate
  /// handle immediately and returns a lock with `isPrimary == false`.
  static SingleInstanceLock acquire(String mutexName) {
    if (!Platform.isWindows) {
      return SingleInstanceLock._(mutexName: mutexName, isPrimary: true);
    }
    if (mutexName.trim().isEmpty) {
      throw ArgumentError.value(mutexName, 'mutexName', 'Must not be empty');
    }

    final namePtr = mutexName.toNativeUtf16();
    try {
      // Pre-resolve both FFI function pointers before calling CreateMutexW so
      // lazy lookup (GetProcAddress) cannot clobber thread-local LastError.
      final createMutex = BlinkWin32.createMutexW;
      final getLastError = BlinkWin32.getLastErrorRaw;
      final rawHandle = createMutex(nullptr, 1, namePtr);
      final lastError = getLastError();

      if (rawHandle == nullptr) {
        throw StateError(
          'CreateMutexW("$mutexName") failed with Win32 error $lastError',
        );
      }

      final handle = HANDLE(rawHandle);
      if (lastError == ERROR_ALREADY_EXISTS) {
        CloseHandle(handle);
        return SingleInstanceLock._(mutexName: mutexName, isPrimary: false);
      }

      return SingleInstanceLock._(
        mutexName: mutexName,
        isPrimary: true,
        handle: handle,
      );
    } finally {
      calloc.free(namePtr);
    }
  }

  /// Releases and closes the owned mutex handle. Safe to call multiple times.
  void release() {
    final handle = _handle;
    if (handle == null) {
      return;
    }
    _handle = null;
    BlinkWin32.releaseMutex(handle.cast<Void>());
    CloseHandle(handle);
  }
}

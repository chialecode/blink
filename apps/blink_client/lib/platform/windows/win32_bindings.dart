import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Win32 access right required by `OpenMutexW` to probe mutex existence.
const int kWin32Synchronize = 0x00100000;

/// SDDL revision 1 constant for
/// `ConvertStringSecurityDescriptorToSecurityDescriptorW`.
const int kWin32SddlRevision1 = 1;

typedef _CreateMutexWNative = Pointer<Void> Function(
  Pointer<SECURITY_ATTRIBUTES> lpMutexAttributes,
  Int32 bInitialOwner,
  Pointer<Utf16> lpName,
);
typedef CreateMutexWDart = Pointer<Void> Function(
  Pointer<SECURITY_ATTRIBUTES> lpMutexAttributes,
  int bInitialOwner,
  Pointer<Utf16> lpName,
);

typedef _OpenMutexWNative = Pointer<Void> Function(
  Uint32 dwDesiredAccess,
  Int32 bInheritHandle,
  Pointer<Utf16> lpName,
);
typedef OpenMutexWDart = Pointer<Void> Function(
  int dwDesiredAccess,
  int bInheritHandle,
  Pointer<Utf16> lpName,
);

typedef _ReleaseMutexNative = Int32 Function(Pointer<Void> hMutex);
typedef ReleaseMutexDart = int Function(Pointer<Void> hMutex);

typedef _WaitNamedPipeWNative = Int32 Function(
  Pointer<Utf16> lpNamedPipeName,
  Uint32 nTimeOut,
);
typedef WaitNamedPipeWDart = int Function(
  Pointer<Utf16> lpNamedPipeName,
  int nTimeOut,
);

typedef _ConvertSidToStringSidWNative = Int32 Function(
  Pointer<Void> sid,
  Pointer<Pointer<Utf16>> stringSid,
);
typedef ConvertSidToStringSidWDart = int Function(
  Pointer<Void> sid,
  Pointer<Pointer<Utf16>> stringSid,
);

typedef _ConvertStringSdToSdWNative = Int32 Function(
  Pointer<Utf16> stringSecurityDescriptor,
  Uint32 stringSDRevision,
  Pointer<Pointer<Void>> securityDescriptor,
  Pointer<Uint32> securityDescriptorSize,
);
typedef ConvertStringSdToSdWDart = int Function(
  Pointer<Utf16> stringSecurityDescriptor,
  int stringSDRevision,
  Pointer<Pointer<Void>> securityDescriptor,
  Pointer<Uint32> securityDescriptorSize,
);

typedef _GetNamedPipeServerProcessIdNative = Int32 Function(
  Pointer<Void> pipe,
  Pointer<Uint32> serverProcessId,
);
typedef GetNamedPipeServerProcessIdDart = int Function(
  Pointer<Void> pipe,
  Pointer<Uint32> serverProcessId,
);

typedef _GetLastErrorNative = Uint32 Function();
typedef GetLastErrorDart = int Function();

/// Minimal Win32 FFI bindings supplementing `package:win32` 6.4.0 for named
/// mutexes, pipe waiting, and current-user SDDL security descriptors.
class BlinkWin32 {
  BlinkWin32._();

  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final DynamicLibrary _advapi32 = DynamicLibrary.open('advapi32.dll');

  static final GetLastErrorDart getLastErrorRaw = _kernel32
      .lookupFunction<_GetLastErrorNative, GetLastErrorDart>(
        'GetLastError',
        isLeaf: true,
      );

  static final CreateMutexWDart createMutexW = _kernel32
      .lookupFunction<_CreateMutexWNative, CreateMutexWDart>('CreateMutexW');

  static final OpenMutexWDart openMutexW = _kernel32
      .lookupFunction<_OpenMutexWNative, OpenMutexWDart>('OpenMutexW');

  static final ReleaseMutexDart releaseMutex = _kernel32
      .lookupFunction<_ReleaseMutexNative, ReleaseMutexDart>('ReleaseMutex');

  static final WaitNamedPipeWDart waitNamedPipeW = _kernel32
      .lookupFunction<_WaitNamedPipeWNative, WaitNamedPipeWDart>(
        'WaitNamedPipeW',
      );

  static final GetNamedPipeServerProcessIdDart getNamedPipeServerProcessId =
      _kernel32.lookupFunction<
        _GetNamedPipeServerProcessIdNative,
        GetNamedPipeServerProcessIdDart
      >('GetNamedPipeServerProcessId');

  /// Lets the primary instance behind [pipe] take the foreground for the
  /// `focus` handoff. Only the process the user just launched (holding
  /// foreground rights) can grant this, and only to that one server PID.
  /// Best effort: failure merely means Windows flashes the taskbar instead.
  static void allowPipeServerForeground(HANDLE pipe) {
    final pid = calloc<Uint32>();
    try {
      if (getNamedPipeServerProcessId(pipe.cast<Void>(), pid) != 0 &&
          pid.value != 0) {
        AllowSetForegroundWindow(pid.value);
      }
    } finally {
      calloc.free(pid);
    }
  }

  static final ConvertSidToStringSidWDart convertSidToStringSidW = _advapi32
      .lookupFunction<
        _ConvertSidToStringSidWNative,
        ConvertSidToStringSidWDart
      >('ConvertSidToStringSidW');

  static final ConvertStringSdToSdWDart
  convertStringSecurityDescriptorToSecurityDescriptorW = _advapi32
      .lookupFunction<_ConvertStringSdToSdWNative, ConvertStringSdToSdWDart>(
        'ConvertStringSecurityDescriptorToSecurityDescriptorW',
      );
}

/// Owns a Win32 `SECURITY_ATTRIBUTES` structure whose protected DACL grants
/// access strictly to the current process user's SID (`D:P(A;;GA;;;<sid>)`).
class CurrentUserSecurityAttributes {
  CurrentUserSecurityAttributes._({
    required this.attributes,
    required this.securityDescriptor,
    required this.userSid,
  });

  final Pointer<SECURITY_ATTRIBUTES> attributes;
  final Pointer<Void> securityDescriptor;
  final String userSid;

  bool _disposed = false;

  /// Builds a current-user-only protected DACL via `GetTokenInformation`
  /// (`TokenUser`) and `ConvertStringSecurityDescriptorToSecurityDescriptorW`.
  static CurrentUserSecurityAttributes create() {
    if (!Platform.isWindows) {
      throw UnsupportedError('Windows-only security descriptor API');
    }

    final sidString = queryCurrentUserSid();
    final sddl = 'D:P(A;;GA;;;$sidString)';
    final sddlPtr = sddl.toNativeUtf16();
    final sdOutPtr = calloc<Pointer<Void>>();

    try {
      final convertSd =
          BlinkWin32.convertStringSecurityDescriptorToSecurityDescriptorW;
      final getLastError = BlinkWin32.getLastErrorRaw;
      final ok = convertSd(sddlPtr, kWin32SddlRevision1, sdOutPtr, nullptr);
      if (ok == 0 || sdOutPtr.value == nullptr) {
        final err = getLastError();
        throw StateError(
          'ConvertStringSecurityDescriptorToSecurityDescriptorW failed '
          '(error $err)',
        );
      }

      final sd = sdOutPtr.value;
      final sa = calloc<SECURITY_ATTRIBUTES>();
      sa.ref
        ..nLength = sizeOf<SECURITY_ATTRIBUTES>()
        ..lpSecurityDescriptor = sd
        ..bInheritHandle = false;

      return CurrentUserSecurityAttributes._(
        attributes: sa,
        securityDescriptor: sd,
        userSid: sidString,
      );
    } finally {
      calloc.free(sddlPtr);
      calloc.free(sdOutPtr);
    }
  }

  /// Queries the string SID (e.g. `S-1-5-21-...`) of the current process user.
  static String queryCurrentUserSid() {
    final tokenPtr = calloc<Pointer<Void>>();
    final lengthPtr = calloc<Uint32>();
    Pointer<Uint8> tokenBuf = nullptr;
    final sidStrPtr = calloc<Pointer<Utf16>>();

    try {
      final opened = OpenProcessToken(
        GetCurrentProcess(),
        TOKEN_QUERY,
        tokenPtr,
      );
      if (!opened.value || tokenPtr.value == nullptr) {
        throw StateError('OpenProcessToken failed (error ${opened.error})');
      }

      final token = HANDLE(tokenPtr.value);
      try {
        // First call retrieves the required buffer size.
        GetTokenInformation(token, TokenUser, nullptr, 0, lengthPtr);
        final requiredLen = lengthPtr.value;
        if (requiredLen == 0) {
          throw StateError('GetTokenInformation returned zero length');
        }

        tokenBuf = calloc<Uint8>(requiredLen);
        final queried = GetTokenInformation(
          token,
          TokenUser,
          tokenBuf,
          requiredLen,
          lengthPtr,
        );
        if (!queried.value) {
          throw StateError(
            'GetTokenInformation(TokenUser) failed (error ${queried.error})',
          );
        }

        // TOKEN_USER starts with `SID_AND_ATTRIBUTES User { PSID Sid; DWORD Attributes; }`.
        final psid = tokenBuf.cast<Pointer<Void>>().value;
        if (psid == nullptr) {
          throw StateError('TokenUser SID pointer was null');
        }

        final convertSid = BlinkWin32.convertSidToStringSidW;
        final getLastError = BlinkWin32.getLastErrorRaw;
        final converted = convertSid(psid, sidStrPtr);
        if (converted == 0 || sidStrPtr.value == nullptr) {
          final err = getLastError();
          throw StateError('ConvertSidToStringSidW failed (error $err)');
        }

        try {
          return sidStrPtr.value.toDartString();
        } finally {
          LocalFree(HLOCAL(sidStrPtr.value));
        }
      } finally {
        CloseHandle(token);
      }
    } finally {
      if (tokenBuf != nullptr) {
        calloc.free(tokenBuf);
      }
      calloc.free(tokenPtr);
      calloc.free(lengthPtr);
      calloc.free(sidStrPtr);
    }
  }

  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    LocalFree(HLOCAL(securityDescriptor));
    calloc.free(attributes);
  }
}

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Testable file and folder picker interface (`INV-02`, quiet-test safe).
abstract interface class BlinkFilePicker {
  Future<String?> pickFileToOpen({String? title});

  Future<String?> pickFileToSave({String? title, String? suggestedFileName});

  Future<String?> pickDirectory({String? title});
}

/// Returns the platform-appropriate [BlinkFilePicker] implementation.
///
/// When `BLINK_QUIET=1` is set (automated smoke/tests), returns a no-op picker
/// that never spawns native OS dialogs.
BlinkFilePicker createDefaultBlinkFilePicker({bool? quietOverride}) {
  final isQuiet =
      quietOverride ?? (Platform.environment['BLINK_QUIET']?.trim() == '1');
  if (isQuiet || !Platform.isWindows) {
    return const NoopBlinkFilePicker();
  }
  return const Win32BlinkFilePicker();
}

/// Safe no-op picker used in quiet runs and non-Windows fallback until M4/M5.
class NoopBlinkFilePicker implements BlinkFilePicker {
  const NoopBlinkFilePicker();

  @override
  Future<String?> pickFileToOpen({String? title}) async => null;

  @override
  Future<String?> pickFileToSave({
    String? title,
    String? suggestedFileName,
  }) async => null;

  @override
  Future<String?> pickDirectory({String? title}) async => null;
}

/// Native Windows COM `IFileOpenDialog` / `IFileSaveDialog` implementation built
/// directly on existing `win32 6.4.0` bindings (zero extra native plugins).
class Win32BlinkFilePicker implements BlinkFilePicker {
  const Win32BlinkFilePicker();

  // CLSID_FileOpenDialog: {DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7}
  static final GUID _clsidFileOpenDialog = GUID.fromComponents(
    0xDC1C5A9C,
    0xE88A,
    0x4DDE,
    Uint8List.fromList(const <int>[
      0xA5,
      0xA1,
      0x60,
      0xF8,
      0x2A,
      0x20,
      0xAE,
      0xF7,
    ]),
  );

  // CLSID_FileSaveDialog: {C0B4E2F3-BA21-4773-8DBA-335EC946EB8B}
  static final GUID _clsidFileSaveDialog = GUID.fromComponents(
    0xC0B4E2F3,
    0xBA21,
    0x4773,
    Uint8List.fromList(const <int>[
      0x8D,
      0xBA,
      0x33,
      0x5E,
      0xC9,
      0x46,
      0xEB,
      0x8B,
    ]),
  );

  @override
  Future<String?> pickFileToOpen({String? title}) async {
    return _showOpenDialog(title: title, pickFolders: false);
  }

  @override
  Future<String?> pickDirectory({String? title}) async {
    return _showOpenDialog(title: title, pickFolders: true);
  }

  @override
  Future<String?> pickFileToSave({
    String? title,
    String? suggestedFileName,
  }) async {
    if (!Platform.isWindows) {
      return null;
    }
    return _withComInitialized<String?>(() {
      final dialog = createInstance<IFileSaveDialog>(_clsidFileSaveDialog);
      try {
        final options = dialog.getOptions();
        dialog.setOptions(
          options | FOS_FORCEFILESYSTEM | FOS_OVERWRITEPROMPT | FOS_NOCHANGEDIR,
        );
        if (title != null && title.isNotEmpty) {
          using((arena) {
            dialog.setTitle(PCWSTR(title.toNativeUtf16(allocator: arena)));
          });
        }
        if (suggestedFileName != null && suggestedFileName.isNotEmpty) {
          using((arena) {
            dialog.setFileName(
              PCWSTR(suggestedFileName.toNativeUtf16(allocator: arena)),
            );
          });
        }
        try {
          dialog.show(null);
        } on WindowsException {
          return null;
        }
        return _extractResultPath(dialog);
      } finally {
        dialog.release();
      }
    });
  }

  String? _showOpenDialog({String? title, required bool pickFolders}) {
    if (!Platform.isWindows) {
      return null;
    }
    return _withComInitialized<String?>(() {
      final dialog = createInstance<IFileOpenDialog>(_clsidFileOpenDialog);
      try {
        var options =
            dialog.getOptions() |
            FOS_FORCEFILESYSTEM |
            FOS_PATHMUSTEXIST |
            FOS_NOCHANGEDIR;
        if (pickFolders) {
          options = options | FOS_PICKFOLDERS;
        } else {
          options = options | FOS_FILEMUSTEXIST;
        }
        dialog.setOptions(options);
        if (title != null && title.isNotEmpty) {
          using((arena) {
            dialog.setTitle(PCWSTR(title.toNativeUtf16(allocator: arena)));
          });
        }
        try {
          dialog.show(null);
        } on WindowsException {
          return null;
        }
        return _extractResultPath(dialog);
      } finally {
        dialog.release();
      }
    });
  }

  String? _extractResultPath(IFileDialog dialog) {
    final item = dialog.getResult();
    if (item == null) {
      return null;
    }
    try {
      final pwstr = item.getDisplayName(SIGDN_FILESYSPATH);
      if (pwstr == nullptr) {
        return null;
      }
      try {
        return pwstr.toDartString();
      } finally {
        CoTaskMemFree(pwstr);
      }
    } finally {
      item.release();
    }
  }

  T? _withComInitialized<T>(T? Function() action) {
    final hr = CoInitializeEx(
      COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE,
    );
    final shouldUninit = hr == S_OK || hr == S_FALSE;
    if (hr.isError && hr != RPC_E_CHANGED_MODE) {
      return null;
    }
    try {
      return action();
    } catch (_) {
      return null;
    } finally {
      if (shouldUninit) {
        CoUninitialize();
      }
    }
  }
}

import 'dart:async';

import 'package:blink_core/blink_core.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/file_picker.dart';
import 'package:blink_client/platform/lifecycle.dart';
import 'package:blink_client/ui/blink_workspace_shell.dart';

/// Root Flutter application for BLINK's M3 adaptive workspace (`INV-02`).
class BlinkApp extends StatefulWidget {
  const BlinkApp({
    required this.controller,
    this.workspaceController,
    this.initialVault,
    this.filePicker,
    this.initialDestination = BlinkNavDestination.stream,
    this.enableMirrorExporter = true,
    this.themeMode = ThemeMode.system,
    super.key,
  });

  final DesktopLifecycleController controller;
  final BlinkWorkspaceController? workspaceController;
  final VaultManager? initialVault;
  final BlinkFilePicker? filePicker;
  final BlinkNavDestination initialDestination;
  final bool enableMirrorExporter;
  final ThemeMode themeMode;

  @override
  State<BlinkApp> createState() => _BlinkAppState();
}

class _BlinkAppState extends State<BlinkApp> {
  late final BlinkWorkspaceController _workspace;
  late final bool _ownsWorkspace;

  @override
  void initState() {
    super.initState();
    if (widget.workspaceController != null) {
      _workspace = widget.workspaceController!;
      _ownsWorkspace = false;
    } else {
      _workspace = BlinkWorkspaceController(
        lifecycle: widget.controller,
        filePicker: widget.filePicker,
        initialVault: widget.initialVault,
        initialDestination: widget.initialDestination,
        enableMirrorExporter: widget.enableMirrorExporter,
      );
      _ownsWorkspace = true;
      unawaited(_workspace.initialize());
    }
  }

  @override
  void dispose() {
    if (_ownsWorkspace) {
      _workspace.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final buildInfo = widget.controller.buildInfo;

    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final pref = widget.controller.settings.surfaceMode;
        final lightTheme = pref == DesktopSurfacePreference.sepia
            ? BlinkTheme.sepia()
            : BlinkTheme.day();
        final resolvedThemeMode = switch (pref) {
          null => widget.themeMode,
          DesktopSurfacePreference.day => ThemeMode.light,
          DesktopSurfacePreference.sepia => ThemeMode.light,
          DesktopSurfacePreference.dark => ThemeMode.dark,
        };

        return MaterialApp(
          title: buildInfo.productName,
          debugShowCheckedModeBanner: false,
          theme: lightTheme,
          darkTheme: BlinkTheme.dark(),
          themeMode: resolvedThemeMode,
          home: BlinkWorkspaceShell(workspace: _workspace),
        );
      },
    );
  }
}

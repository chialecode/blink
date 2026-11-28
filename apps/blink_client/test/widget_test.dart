import 'dart:async';
import 'dart:io';

import 'package:blink_core/blink_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_app.dart';
import 'package:blink_client/app/blink_brand_mark.dart';
import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/sync_controller.dart';
import 'package:blink_client/application/workspace_controller.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/cli_args.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/file_picker.dart';
import 'package:blink_client/platform/lifecycle.dart';
import 'package:blink_client/platform/paths.dart';
import 'package:blink_client/platform/secret_store.dart';
import 'package:blink_client/ui/desktop_window_chrome.dart';
import 'package:blink_client/ui/sync_status_capsule.dart';

class _NoopWindowAdapter implements DesktopWindowAdapter {
  @override
  Future<WindowGeometrySnapshot?> captureGeometry() async => null;

  @override
  Future<void> configure({
    required String title,
    required double minWidth,
    required double minHeight,
    required VoidCallback onCloseRequested,
  }) async {}

  @override
  Future<void> destroy() async {}

  @override
  Future<void> hideToTray() async {}

  @override
  Future<bool> isVisible() async => true;

  @override
  Future<void> minimizeToTaskbar() async {}

  @override
  Future<void> showAndFocus() async {}
}

class _FakeChromeWindowAdapter extends _NoopWindowAdapter
    implements DesktopWindowChromeAdapter {
  _FakeChromeWindowAdapter({this.usesLeadingSystemWindowControls = false});

  @override
  bool get supportsCustomWindowChrome => true;

  @override
  final bool usesLeadingSystemWindowControls;

  final StreamController<bool> _maximizedController =
      StreamController<bool>.broadcast();
  bool maximized = false;
  int minimizeCalls = 0;
  int hideToTrayCalls = 0;
  int startDraggingCalls = 0;
  int toggleMaximizeCalls = 0;
  int destroyCalls = 0;
  final List<Rect?> reportedMaximizeBounds = <Rect?>[];

  void emitMaximized(bool value) {
    maximized = value;
    if (!_maximizedController.isClosed) {
      _maximizedController.add(value);
    }
  }

  @override
  Stream<bool> get maximizedChanges => _maximizedController.stream;

  @override
  Future<void> minimizeToTaskbar() async {
    minimizeCalls++;
  }

  @override
  Future<void> hideToTray() async {
    hideToTrayCalls++;
  }

  @override
  Future<void> startDragging() async {
    startDraggingCalls++;
  }

  @override
  Future<void> toggleMaximize() async {
    toggleMaximizeCalls++;
    maximized = !maximized;
  }

  @override
  Future<bool> isMaximized() async => maximized;

  @override
  Future<void> showSystemMenu(Offset position) async {}

  @override
  void setMaximizeButtonBounds(Rect? bounds) {
    reportedMaximizeBounds.add(bounds);
  }

  @override
  Future<void> destroy() async {
    destroyCalls++;
    if (!_maximizedController.isClosed) {
      await _maximizedController.close();
    }
  }
}

class _NoopTrayAdapter implements DesktopTrayAdapter {
  @override
  Future<void> destroy() async {}

  @override
  Future<bool> init({
    required String iconAssetPath,
    required String tooltip,
    required VoidCallback onOpen,
    required VoidCallback onQuit,
  }) async => true;

  @override
  Future<void> recreate() async {}
}

void main() {
  group('BlinkApp desktop shell widget tests (M2-K02 preserved)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('blink_widget_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    testWidgets(
      'renders dev build metadata and persists close behavior toggle at 760x560',
      (tester) async {
        tester.view.physicalSize = const Size(760, 560);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final buildInfo = BlinkBuildInfo.normalized(
          channel: 'blink-dev',
          identity: 'blink-dev',
          version: '0.1.0-dev.202611221600',
          gitSha: 'a1b2c3d4e5f6',
        );
        final paths = BlinkPaths(dataRoot: tempDir);
        final store = DesktopSettingsStore(file: paths.desktopSettingsFile);
        final controller = DesktopLifecycleController(
          buildInfo: buildInfo,
          paths: paths,
          settingsStore: store,
          windowAdapter: _NoopWindowAdapter(),
          trayAdapter: _NoopTrayAdapter(),
        );
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: false),
        );

        final vault = await tester.runAsync(
          () => VaultManager.open(
            VaultConfig(
              vaultDir: paths.vaultDir,
              expectedChannel: BlinkChannel.blinkDev,
              enableMirrorExporter: false,
            ),
          ),
        );
        addTearDown(() async {
          await tester.runAsync(() async {
            await vault!.checkpointAndClose();
          });
        });

        await tester.pumpWidget(
          BlinkApp(
            controller: controller,
            initialVault: vault,
            filePicker: const NoopBlinkFilePicker(),
            enableMirrorExporter: false,
            initialDestination: BlinkNavDestination.settings,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(AppBar), findsNothing);
        expect(find.byKey(const Key('settings_section')), findsOneWidget);

        final materialApp = tester.widget<MaterialApp>(
          find.byType(MaterialApp),
        );
        expect(materialApp.themeMode, ThemeMode.system);
        expect(
          materialApp.theme?.colorScheme.primary,
          BlinkColorTokens.day.accentPrimary,
        );
        expect(
          materialApp.darkTheme?.colorScheme.primary,
          BlinkColorTokens.dark.accentPrimary,
        );

        // Default close behavior is hide-to-tray.
        expect(
          controller.settings.closeButtonBehavior,
          CloseButtonBehavior.hideToTray,
        );

        // Toggle to direct exit and verify atomic persistence.
        await tester.tap(find.text('直接退出'));
        await tester.pumpAndSettle();

        expect(
          controller.settings.closeButtonBehavior,
          CloseButtonBehavior.exitApp,
        );
        expect(paths.desktopSettingsFile.existsSync(), isTrue);
        expect(
          store.loadSync().settings.closeButtonBehavior,
          CloseButtonBehavior.exitApp,
        );

        // Switch to Storage & Backup category via compact switcher at 760x560.
        await tester.tap(find.byKey(const Key('settings_compact_cat_storage')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('vault_settings_section')), findsOneWidget);
        expect(find.text('数据文件夹'), findsWidgets);
        expect(find.byKey(const Key('vault_path_value')), findsOneWidget);
        expect(find.byKey(const Key('vault_onedrive_hint')), findsNothing);

        // Switch to About BLINK category and verify build metadata & styling.
        await tester.tap(find.byKey(const Key('settings_compact_cat_about')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('about_section')), findsOneWidget);
        expect(find.text('BLINK Dev'), findsOneWidget);
        expect(find.text('DEV 开发通道'), findsOneWidget);
        expect(find.text('0.1.0-dev.202611221600'), findsOneWidget);
        expect(find.text('blink-dev'), findsNWidgets(2));
        expect(find.text('a1b2c3d'), findsOneWidget);
        expect(find.text(tempDir.path), findsOneWidget);

        // Brand mark, unified brand blue accent, and dev channel pill styling.
        final brandMarkFinder = find.byKey(const Key('brand_mark'));
        expect(brandMarkFinder, findsOneWidget);
        expect(tester.getSize(brandMarkFinder), const Size(28, 28));
        expect(
          tester.widget<BlinkBrandMark>(brandMarkFinder).size,
          equals(28.0),
        );

        final devBadgeText = tester.widget<Text>(find.text('DEV 开发通道'));
        expect(devBadgeText.style?.color, BlinkBrandColors.devPillText);
        final devBadgeContainer = tester.widget<Container>(
          find
              .ancestor(
                of: find.text('DEV 开发通道'),
                matching: find.byType(Container),
              )
              .first,
        );
        expect(
          (devBadgeContainer.decoration as BoxDecoration).color,
          BlinkBrandColors.devPill,
        );

        // Typography weights, tabular figures, and monospace stacks.
        expect(
          tester.widget<Text>(find.text('BLINK Dev')).style?.fontWeight,
          FontWeight.w700,
        );

        final versionText = tester.widget<SelectableText>(
          find.byKey(const Key('about_version')),
        );
        expect(
          versionText.style?.fontFeatures,
          contains(const FontFeature.tabularFigures()),
        );

        final shaText = tester.widget<SelectableText>(
          find.byKey(const Key('about_git_sha')),
        );
        expect(shaText.style?.fontFamily, BlinkTypography.monoFontFamily);
        expect(
          shaText.style?.fontFeatures,
          contains(const FontFeature.tabularFigures()),
        );

        final dataRootText = tester.widget<SelectableText>(
          find.byKey(const Key('about_data_root')),
        );
        expect(dataRootText.style?.fontFamily, BlinkTypography.monoFontFamily);
        expect(find.text('应用配置目录'), findsOneWidget);
      },
    );

    testWidgets(
      'renders production channel metadata and corrupt recovery notice',
      (tester) async {
        tester.view.physicalSize = const Size(960, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final paths = BlinkPaths(dataRoot: tempDir);
        paths.desktopSettingsFile.parent.createSync(recursive: true);
        paths.desktopSettingsFile.writeAsStringSync('corrupted');

        final buildInfo = BlinkBuildInfo.normalized(
          channel: 'blink',
          identity: 'blink',
          version: '0.1.0',
          gitSha: '9988776655',
        );
        final store = DesktopSettingsStore(file: paths.desktopSettingsFile);
        final controller = DesktopLifecycleController(
          buildInfo: buildInfo,
          paths: paths,
          settingsStore: store,
          windowAdapter: _NoopWindowAdapter(),
          trayAdapter: _NoopTrayAdapter(),
        );
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: false),
        );

        final vault = await tester.runAsync(
          () => VaultManager.open(
            VaultConfig(
              vaultDir: paths.vaultDir,
              expectedChannel: BlinkChannel.blink,
              enableMirrorExporter: false,
            ),
          ),
        );
        addTearDown(() async {
          await tester.runAsync(() async {
            await vault!.checkpointAndClose();
          });
        });

        await tester.pumpWidget(
          BlinkApp(
            controller: controller,
            initialVault: vault,
            filePicker: const NoopBlinkFilePicker(),
            enableMirrorExporter: false,
            initialDestination: BlinkNavDestination.settings,
          ),
        );
        await tester.pumpAndSettle();

        expect(
          find.byKey(const Key('corrupt_settings_notice')),
          findsOneWidget,
        );
        final corruptNotice = tester.widget<Text>(
          find.byKey(const Key('corrupt_settings_notice')),
        );
        expect(corruptNotice.style?.color, BlinkColorTokens.day.statusWarn);

        // Navigate to About category in Feishu Settings sidebar at 960x640.
        await tester.tap(find.byKey(const Key('settings_cat_about')));
        await tester.pumpAndSettle();

        expect(find.text('BLINK'), findsOneWidget);
        expect(find.text('正式通道'), findsOneWidget);
        expect(find.text('0.1.0'), findsOneWidget);
        expect(find.text('9988776'), findsOneWidget);
        expect(find.byKey(const Key('brand_mark')), findsOneWidget);

        final prodBadgeText = tester.widget<Text>(find.text('正式通道'));
        expect(prodBadgeText.style?.color, BlinkColorTokens.day.accentPrimary);
        final prodBadgeContainer = tester.widget<Container>(
          find
              .ancestor(of: find.text('正式通道'), matching: find.byType(Container))
              .first,
        );
        expect(
          (prodBadgeContainer.decoration as BoxDecoration).color,
          BlinkColorTokens.day.accentSubtle,
        );
      },
    );

    testWidgets(
      'adapts to system dark mode without overflow at 760x560 and 960x640',
      (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final paths = BlinkPaths(dataRoot: tempDir);
        paths.desktopSettingsFile.parent.createSync(recursive: true);
        paths.desktopSettingsFile.writeAsStringSync('{invalid');

        final buildInfo = BlinkBuildInfo.normalized(
          channel: 'blink-dev',
          identity: 'blink-dev',
          version: '0.1.0-dev.202611240000',
          gitSha: 'deadbeefcafe',
        );
        final store = DesktopSettingsStore(file: paths.desktopSettingsFile);
        final controller = DesktopLifecycleController(
          buildInfo: buildInfo,
          paths: paths,
          settingsStore: store,
          windowAdapter: _NoopWindowAdapter(),
          trayAdapter: _NoopTrayAdapter(),
        );
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: false),
        );

        final vault = await tester.runAsync(
          () => VaultManager.open(
            VaultConfig(
              vaultDir: paths.vaultDir,
              expectedChannel: BlinkChannel.blinkDev,
              enableMirrorExporter: false,
            ),
          ),
        );
        addTearDown(() async {
          await tester.runAsync(() async {
            await vault!.checkpointAndClose();
          });
        });

        for (final viewport in const <Size>[Size(760, 560), Size(960, 640)]) {
          tester.view.physicalSize = viewport;
          await tester.pumpWidget(
            BlinkApp(
              controller: controller,
              initialVault: vault,
              filePicker: const NoopBlinkFilePicker(),
              enableMirrorExporter: false,
              initialDestination: BlinkNavDestination.settings,
            ),
          );
          await tester.pumpAndSettle();

          expect(tester.takeException(), isNull);
          final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
          expect(scaffold.backgroundColor, BlinkColorTokens.dark.canvas);

          final corruptNotice = tester.widget<Text>(
            find.byKey(const Key('corrupt_settings_notice')),
          );
          expect(corruptNotice.style?.color, BlinkColorTokens.dark.statusWarn);
        }
      },
    );
  });

  group('Immersive desktop window chrome', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('blink_chrome_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    testWidgets(
      'extends panes and vertical dividers from y=0 to bottom with working caption controls and drag areas',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final paths = BlinkPaths(dataRoot: tempDir);
        final buildInfo = BlinkBuildInfo.normalized(
          channel: 'blink-dev',
          identity: 'blink-dev',
          version: '0.1.0-dev.202611271800',
          gitSha: 'abcdef123456',
        );
        final store = DesktopSettingsStore(file: paths.desktopSettingsFile);
        final windowAdapter = _FakeChromeWindowAdapter();
        final exitCodes = <int>[];
        final controller = DesktopLifecycleController(
          buildInfo: buildInfo,
          paths: paths,
          settingsStore: store,
          windowAdapter: windowAdapter,
          trayAdapter: _NoopTrayAdapter(),
          exitProcess: exitCodes.add,
        );
        addTearDown(controller.dispose);
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: false),
        );

        final vault = await tester.runAsync(
          () => VaultManager.open(
            VaultConfig(
              vaultDir: paths.vaultDir,
              expectedChannel: BlinkChannel.blinkDev,
              enableMirrorExporter: false,
            ),
          ),
        );
        addTearDown(() async {
          await tester.runAsync(() async {
            await vault!.checkpointAndClose();
          });
        });

        await tester.pumpWidget(
          BlinkApp(
            controller: controller,
            initialVault: vault,
            filePicker: const NoopBlinkFilePicker(),
            enableMirrorExporter: false,
            initialDestination: BlinkNavDestination.settings,
          ),
        );
        await tester.pumpAndSettle();

        // Full-height panes and vertical hairline dividers run uninterrupted
        // from the very top edge (y = 0) to the bottom edge (y = 800).
        final railRect = tester.getRect(
          find.byKey(const Key('desktop_nav_rail')),
        );
        final railDividerRect = tester.getRect(
          find.byKey(const Key('pane_divider_rail')),
        );
        final sidebarRect = tester.getRect(
          find.byKey(const Key('resource_sidebar_pane')),
        );
        final sidebarDividerRect = tester.getRect(
          find.byKey(const Key('pane_divider_sidebar')),
        );
        expect(railRect.top, 0.0);
        expect(railRect.bottom, 800.0);
        expect(railDividerRect.top, 0.0);
        expect(railDividerRect.bottom, 800.0);
        expect(sidebarRect.top, 0.0);
        expect(sidebarRect.bottom, 800.0);
        expect(sidebarDividerRect.top, 0.0);
        expect(sidebarDividerRect.bottom, 800.0);

        // Windows 11-proportioned caption controls (138 x 44) sit flush at top-right.
        final captionRect = tester.getRect(
          find.byKey(const Key('window_caption_buttons')),
        );
        expect(captionRect.top, 0.0);
        expect(captionRect.right, 1280.0);
        expect(captionRect.width, kBlinkWindowCaptionWidth);
        expect(captionRect.height, kBlinkWindowChromeHeaderHeight);

        // Windows 11 Snap Layouts maximize button bounds were reported.
        expect(
          windowAdapter.reportedMaximizeBounds.whereType<Rect>(),
          isNotEmpty,
        );

        // Minimize button delegates cleanly.
        await tester.tap(find.byKey(const Key('window_minimize_button')));
        await tester.pump();
        expect(windowAdapter.minimizeCalls, 1);

        // Maximize/Restore button toggles state and updates tooltip live.
        expect(find.byTooltip('最大化'), findsOneWidget);
        await tester.tap(find.byKey(const Key('window_maximize_button')));
        await tester.pumpAndSettle();
        expect(windowAdapter.toggleMaximizeCalls, 1);
        expect(controller.isWindowMaximized, isTrue);
        expect(find.byTooltip('向下还原'), findsOneWidget);

        // Native restore signal syncs icon state back to maximize.
        windowAdapter.emitMaximized(false);
        await tester.pumpAndSettle();
        expect(controller.isWindowMaximized, isFalse);
        expect(find.byTooltip('最大化'), findsOneWidget);

        // Dragging and double-clicking the top rail drag strip invoke native ops.
        final railTopCenter = Offset(railRect.center.dx, 20);
        await tester.dragFrom(railTopCenter, const Offset(30, 0));
        await tester.pump();
        expect(windowAdapter.startDraggingCalls, greaterThanOrEqualTo(1));

        await tester.tapAt(railTopCenter);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(railTopCenter);
        await tester.pumpAndSettle();
        expect(windowAdapter.toggleMaximizeCalls, 2);

        // Close button respects default hide-to-tray policy without exiting.
        await tester.tap(find.byKey(const Key('window_close_button')));
        await tester.pump();
        expect(windowAdapter.hideToTrayCalls, 1);
        expect(exitCodes, isEmpty);

        // Verify zero overflow across Settings, Tasks, and Files at 960x640 and 760x560.
        for (final size in const <Size>[Size(960, 640), Size(760, 560)]) {
          tester.view.physicalSize = size;
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          for (final navKey in const <Key>[
            Key('nav_tasks'),
            Key('nav_files'),
            Key('nav_settings'),
          ]) {
            await tester.tap(find.byKey(navKey));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        }

        // Trigger a top status banner on Files and verify its dismiss button
        // stays strictly to the left of the top-right caption controls.
        await tester.tap(find.byKey(const Key('nav_files')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('files_gc_button')));
        await tester.pumpAndSettle();
        final dismissFinder = find.byTooltip('关闭提示');
        if (dismissFinder.evaluate().isNotEmpty) {
          final dismissRect = tester.getRect(dismissFinder);
          final narrowCaptionRect = tester.getRect(
            find.byKey(const Key('window_caption_buttons')),
          );
          expect(dismissRect.right, lessThanOrEqualTo(narrowCaptionRect.left));
          await tester.tap(dismissFinder);
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);

        // Mobile viewport (<600px) hides desktop caption controls completely.
        tester.view.physicalSize = const Size(390, 844);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('window_caption_buttons')), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'omits trailing caption controls and reserves leading inset on macOS-style chrome',
      (tester) async {
        tester.view.physicalSize = const Size(960, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final paths = BlinkPaths(dataRoot: tempDir);
        final buildInfo = BlinkBuildInfo.normalized(
          channel: 'blink-dev',
          identity: 'blink-dev',
          version: '0.1.0-dev.202611271800',
          gitSha: 'abcdef123456',
        );
        final store = DesktopSettingsStore(file: paths.desktopSettingsFile);
        final macAdapter = _FakeChromeWindowAdapter(
          usesLeadingSystemWindowControls: true,
        );
        final controller = DesktopLifecycleController(
          buildInfo: buildInfo,
          paths: paths,
          settingsStore: store,
          windowAdapter: macAdapter,
          trayAdapter: _NoopTrayAdapter(),
        );
        addTearDown(controller.dispose);
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: false),
        );

        final vault = await tester.runAsync(
          () => VaultManager.open(
            VaultConfig(
              vaultDir: paths.vaultDir,
              expectedChannel: BlinkChannel.blinkDev,
              enableMirrorExporter: false,
            ),
          ),
        );
        addTearDown(() async {
          await tester.runAsync(() async {
            await vault!.checkpointAndClose();
          });
        });

        await tester.pumpWidget(
          BlinkApp(
            controller: controller,
            initialVault: vault,
            filePicker: const NoopBlinkFilePicker(),
            enableMirrorExporter: false,
            initialDestination: BlinkNavDestination.settings,
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('window_caption_buttons')), findsNothing);
        final brandRect = tester.getRect(
          find.byKey(const Key('rail_brand_mark')),
        );
        expect(
          brandRect.top,
          greaterThanOrEqualTo(kBlinkMacTrafficLightTopInset),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'header buttons fire with zero delay and rapid double-click never triggers toggleMaximize while blank space still drags',
      (tester) async {
        tester.view.physicalSize = const Size(960, 640);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        var buttonTaps = 0;
        var dragStarts = 0;
        var maximizeToggles = 0;

        await tester.pumpWidget(
          MaterialApp(
            theme: BlinkTheme.day(),
            home: BlinkWindowChromeScope(
              enabled: true,
              trailingCaptionInset: kBlinkWindowCaptionWidth,
              onStartDrag: () => dragStarts++,
              onToggleMaximize: () => maximizeToggles++,
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    key: const Key('test_header_bar'),
                    height: kBlinkWindowChromeHeaderHeight,
                    color: BlinkColorTokens.day.canvas,
                    child: BlinkWindowDragArea(
                      child: Row(
                        children: <Widget>[
                          IconButton(
                            key: const Key('test_header_btn'),
                            onPressed: () => buttonTaps++,
                            icon: const Icon(Icons.format_bold_rounded),
                          ),
                          const Expanded(
                            child: IgnorePointer(child: Text('测试标题栏')),
                          ),
                          const SizedBox(width: kBlinkWindowCaptionWidth),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );

        // Single-tap fires immediately on the next frame (no 300ms double-tap stall).
        await tester.tap(find.byKey(const Key('test_header_btn')));
        await tester.pump();
        expect(buttonTaps, 1);
        expect(maximizeToggles, 0);

        // Rapid double-click (<50ms) on the header button activates it twice
        // and NEVER fires toggleMaximize().
        await tester.tap(find.byKey(const Key('test_header_btn')));
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tap(find.byKey(const Key('test_header_btn')));
        await tester.pump(const Duration(milliseconds: 40));
        await tester.pumpAndSettle();
        expect(buttonTaps, 3);
        expect(maximizeToggles, 0);

        // Dragging and double-clicking blank header space (and IgnorePointer title)
        // still invokes startDragging() and toggleMaximize().
        final headerRect = tester.getRect(
          find.byKey(const Key('test_header_bar')),
        );
        final blankPoint = Offset(headerRect.center.dx, headerRect.center.dy);
        await tester.dragFrom(blankPoint, const Offset(36, 0));
        await tester.pump();
        expect(dragStarts, greaterThanOrEqualTo(1));

        await tester.tapAt(blankPoint);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(blankPoint);
        await tester.pumpAndSettle();
        expect(maximizeToggles, 1);

        final titleCenter = tester.getCenter(find.text('测试标题栏'));
        await tester.tapAt(titleCenter);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(titleCenter);
        await tester.pumpAndSettle();
        expect(maximizeToggles, 2);
      },
    );

    testWidgets(
      'shell header buttons fire immediately without hijack and sync banner spans full width under caption buttons',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final paths = BlinkPaths(dataRoot: tempDir);
        final buildInfo = BlinkBuildInfo.normalized(
          channel: 'blink-dev',
          identity: 'blink-dev',
          version: '0.1.0-dev.202611271800',
          gitSha: 'abcdef123456',
        );
        final store = DesktopSettingsStore(file: paths.desktopSettingsFile);
        final windowAdapter = _FakeChromeWindowAdapter();
        final controller = DesktopLifecycleController(
          buildInfo: buildInfo,
          paths: paths,
          settingsStore: store,
          windowAdapter: windowAdapter,
          trayAdapter: _NoopTrayAdapter(),
        );
        addTearDown(controller.dispose);
        await controller.initializeStartup(
          const LaunchOptions(mode: LaunchMode.normal, quiet: false),
        );

        final vault = await tester.runAsync(
          () => VaultManager.open(
            VaultConfig(
              vaultDir: paths.vaultDir,
              expectedChannel: BlinkChannel.blinkDev,
              enableMirrorExporter: false,
            ),
          ),
        );
        addTearDown(() async {
          await tester.runAsync(() async {
            await vault!.checkpointAndClose();
          });
        });

        await tester.pumpWidget(
          BlinkApp(
            controller: controller,
            initialVault: vault,
            filePicker: const NoopBlinkFilePicker(),
            enableMirrorExporter: false,
            initialDestination: BlinkNavDestination.settings,
          ),
        );
        await tester.pumpAndSettle();

        // Single-tap on Settings sidebar collapse button fires immediately (0ms).
        await tester.tap(
          find.byKey(const Key('settings_sidebar_collapse_button')),
        );
        await tester.pump();
        expect(find.byKey(const Key('resource_sidebar_pane')), findsNothing);
        expect(
          find.byKey(const Key('settings_sidebar_expand_button')),
          findsOneWidget,
        );
        expect(windowAdapter.toggleMaximizeCalls, 0);

        // Expand immediately on single-tap too.
        await tester.tap(
          find.byKey(const Key('settings_sidebar_expand_button')),
        );
        await tester.pump();
        expect(find.byKey(const Key('resource_sidebar_pane')), findsOneWidget);
        expect(windowAdapter.toggleMaximizeCalls, 0);

        // Rapid double-click on Files GC button in the 44px header never maximizes.
        await tester.tap(find.byKey(const Key('nav_files')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('files_gc_button')));
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tap(find.byKey(const Key('files_gc_button')));
        await tester.pump(const Duration(milliseconds: 40));
        await tester.pumpAndSettle();
        expect(windowAdapter.toggleMaximizeCalls, 0);

        // Blank area of Settings header still drags and double-clicks to maximize.
        await tester.tap(find.byKey(const Key('nav_settings')));
        await tester.pumpAndSettle();
        final settingsHeaderPos = const Offset(760, 22);
        await tester.dragFrom(settingsHeaderPos, const Offset(30, 0));
        await tester.pump();
        expect(windowAdapter.startDraggingCalls, greaterThanOrEqualTo(1));

        await tester.tapAt(settingsHeaderPos);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(settingsHeaderPos);
        await tester.pumpAndSettle();
        expect(windowAdapter.toggleMaximizeCalls, 1);

        // Verify BlinkSyncStatusCapsule spans full width seamlessly under
        // trailing caption buttons without overlapping action buttons.
        final sync = BlinkSyncController(
          paths: paths,
          expectedChannel: BlinkChannel.blinkDev,
          secretStore: InMemoryBlinkSecretStore(),
          isQuiet: true,
        );
        addTearDown(sync.dispose);
        var settingsOpened = 0;
        var bannerDrags = 0;
        var bannerMaxToggles = 0;

        await tester.pumpWidget(
          MaterialApp(
            theme: BlinkTheme.day(),
            home: BlinkWindowChromeScope(
              enabled: true,
              trailingCaptionInset: kBlinkWindowCaptionWidth,
              onStartDrag: () => bannerDrags++,
              onToggleMaximize: () => bannerMaxToggles++,
              child: Scaffold(
                body: Stack(
                  children: <Widget>[
                    Align(
                      alignment: Alignment.topCenter,
                      child: BlinkSyncStatusCapsule(
                        sync: sync,
                        trailingChromeInset: kBlinkWindowCaptionWidth,
                        enableWindowDrag: true,
                        onOpenConflicts: () {},
                        onOpenSyncSettings: () => settingsOpened++,
                      ),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      height: kBlinkWindowChromeHeaderHeight,
                      child: BlinkWindowCaptionButtons(
                        isMaximized: false,
                        onMinimize: () {},
                        onToggleMaximize: () {},
                        onClose: () {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final capsuleRect = tester.getRect(
          find.byKey(const Key('sync_status_capsule')),
        );
        final captionRect = tester.getRect(
          find.byKey(const Key('window_caption_buttons')),
        );
        final settingsBtnRect = tester.getRect(
          find.byKey(const Key('sync_capsule_settings_button')),
        );
        // Full-width tinted container runs seamlessly under caption buttons.
        expect(capsuleRect.right, 1280.0);
        expect(capsuleRect.height, greaterThanOrEqualTo(44.0));
        // Action button stays strictly to the left of caption controls.
        expect(settingsBtnRect.right, lessThanOrEqualTo(captionRect.left));

        // Immediate single-tap & rapid double-click on banner button never maximizes.
        await tester.tap(find.byKey(const Key('sync_capsule_settings_button')));
        await tester.pump();
        expect(settingsOpened, 1);
        await tester.tap(find.byKey(const Key('sync_capsule_settings_button')));
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tap(find.byKey(const Key('sync_capsule_settings_button')));
        await tester.pump(const Duration(milliseconds: 40));
        await tester.pumpAndSettle();
        expect(settingsOpened, 3);
        expect(bannerMaxToggles, 0);

        // Dragging and double-clicking the banner label still works.
        final labelCenter = tester.getCenter(
          find.byKey(const Key('sync_status_capsule_label')),
        );
        await tester.dragFrom(labelCenter, const Offset(25, 0));
        await tester.pump();
        expect(bannerDrags, greaterThanOrEqualTo(1));

        await tester.tapAt(labelCenter);
        await tester.pump(const Duration(milliseconds: 40));
        await tester.tapAt(labelCenter);
        await tester.pumpAndSettle();
        expect(bannerMaxToggles, 1);
      },
    );
  });
}

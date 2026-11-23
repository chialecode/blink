import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:blink_client/platform/atomic_io.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/paths.dart';

void main() {
  group('BlinkBuildInfo (M2-K02)', () {
    test('source build defaults leave identity, mutex, and pipe empty', () {
      final info = BlinkBuildInfo.normalized();
      expect(info.channel, 'blink-dev');
      expect(info.identity, '');
      expect(info.isSourceBuild, isTrue);
      expect(info.isDevChannel, isTrue);
      expect(info.isProductionChannel, isFalse);
      expect(info.productName, 'BLINK Dev');
      expect(info.displayIdentity, '源码构建（无安装身份）');
      expect(info.mutexName, isNull);
      expect(info.controlPipeName, isNull);
      expect(info.pathSegment, 'blink-dev');
      expect(info.trayIconAssetPath, 'assets/icons/blink-dev.ico');
      expect(info.shortGitSha, 'unknown');
    });

    test('production channel blink metadata', () {
      final info = BlinkBuildInfo.normalized(
        channel: 'blink',
        identity: 'blink',
        version: '0.1.0',
        gitSha: 'abcdef1234567890',
      );
      expect(info.isSourceBuild, isFalse);
      expect(info.isProductionChannel, isTrue);
      expect(info.isDevChannel, isFalse);
      expect(info.productName, 'BLINK');
      expect(info.displayIdentity, 'blink');
      expect(info.shortGitSha, 'abcdef1');
      expect(info.mutexName, 'blink-instance');
      expect(info.controlPipeName, r'\\.\pipe\blink-control');
      expect(info.pathSegment, 'blink');
      expect(info.trayIconAssetPath, 'assets/icons/blink.ico');
    });

    test('dev and rehearsal identities resolve distinct names and pipes', () {
      final dev = BlinkBuildInfo.normalized(
        channel: 'blink-dev',
        identity: 'blink-dev',
        version: '0.1.0-dev.202611221600',
        gitSha: '1234567',
      );
      expect(dev.productName, 'BLINK Dev');
      expect(dev.mutexName, 'blink-dev-instance');
      expect(dev.controlPipeName, r'\\.\pipe\blink-dev-control');
      expect(dev.trayIconAssetPath, 'assets/icons/blink-dev.ico');

      final rehearsal = BlinkBuildInfo.normalized(
        channel: 'blink-dev',
        identity: 'blink-dev-test',
        version: '0.1.0-dev.202611221605',
        gitSha: 'fedcba987654',
      );
      expect(rehearsal.productName, 'BLINK Dev Test');
      expect(rehearsal.mutexName, 'blink-dev-test-instance');
      expect(rehearsal.controlPipeName, r'\\.\pipe\blink-dev-test-control');
      expect(rehearsal.pathSegment, 'blink-dev-test');
      expect(rehearsal.shortGitSha, 'fedcba9');
    });
  });

  group('BlinkPaths (M2-K02)', () {
    test('BLINK_DATA_DIR override takes precedence over OS env', () {
      final info = BlinkBuildInfo.normalized(
        channel: 'blink-dev',
        identity: 'blink-dev-test',
      );
      final paths = BlinkPaths.resolve(
        info,
        environment: const <String, String>{
          'BLINK_DATA_DIR': 'sandbox_override_dir',
          'LOCALAPPDATA': 'ignored_local_app_data',
          'APPDATA': 'ignored_roaming_app_data',
        },
        isWindows: true,
        isMacOS: false,
        isLinux: false,
      );
      expect(paths.dataRoot.path, 'sandbox_override_dir');
    });

    test('Windows uses LOCALAPPDATA and never APPDATA or home dotdir', () {
      final dev = BlinkBuildInfo.normalized(
        channel: 'blink-dev',
        identity: 'blink-dev',
      );
      final devPaths = BlinkPaths.resolve(
        dev,
        environment: const <String, String>{
          'LOCALAPPDATA': 'virtual_local_appdata',
          'APPDATA': 'virtual_roaming_appdata',
        },
        isWindows: true,
        isMacOS: false,
        isLinux: false,
      );
      expect(devPaths.dataRoot.path, r'virtual_local_appdata\blink-dev');

      final prod = BlinkBuildInfo.normalized(
        channel: 'blink',
        identity: 'blink',
      );
      final prodPaths = BlinkPaths.resolve(
        prod,
        environment: const <String, String>{
          'LOCALAPPDATA': 'virtual_local_appdata',
        },
        isWindows: true,
        isMacOS: false,
        isLinux: false,
      );
      expect(prodPaths.dataRoot.path, r'virtual_local_appdata\blink');
    });

    test('Linux honors XDG_DATA_HOME and macOS uses Application Support', () {
      final info = BlinkBuildInfo.normalized(channel: 'blink-dev');
      final linuxPaths = BlinkPaths.resolve(
        info,
        environment: const <String, String>{
          'XDG_DATA_HOME': 'virtual_xdg_data',
        },
        isWindows: false,
        isMacOS: false,
        isLinux: true,
      );
      expect(linuxPaths.dataRoot.path, 'virtual_xdg_data/blink-dev');

      final macPaths = BlinkPaths.resolve(
        info,
        environment: const <String, String>{'HOME': 'virtual_mac_home'},
        isWindows: false,
        isMacOS: true,
        isLinux: false,
      );
      expect(
        macPaths.dataRoot.path,
        'virtual_mac_home/Library/Application Support/blink-dev',
      );
    });
  });

  group('Atomic IO & DesktopSettingsStore (M2-K02)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('blink_settings_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('atomic write creates and cleanly replaces existing file', () {
      final target = File(
        '${tempDir.path}${Platform.pathSeparator}nested${Platform.pathSeparator}sample.json',
      );
      writeStringAtomicallySync(target, '{"step": 1}\n');
      expect(target.existsSync(), isTrue);
      expect(target.readAsStringSync(), '{"step": 1}\n');
      expect(File('${target.path}.blink-tmp').existsSync(), isFalse);

      writeStringAtomicallySync(target, '{"step": 2}\n');
      expect(target.readAsStringSync(), '{"step": 2}\n');
      expect(File('${target.path}.blink-tmp').existsSync(), isFalse);
    });

    test('persists and reloads DesktopSettings round-trip', () {
      final paths = BlinkPaths(dataRoot: tempDir);
      final store = DesktopSettingsStore(file: paths.desktopSettingsFile);

      final initial = store.loadSync();
      expect(initial.recoveredFromCorrupt, isFalse);
      expect(
        initial.settings.closeButtonBehavior,
        CloseButtonBehavior.hideToTray,
      );

      store.saveSync(
        const DesktopSettings(
          closeButtonBehavior: CloseButtonBehavior.exitApp,
          windowWidth: 960,
          windowHeight: 640,
          windowMaximized: false,
        ),
      );

      final reloaded = store.loadSync();
      expect(reloaded.recoveredFromCorrupt, isFalse);
      expect(
        reloaded.settings.closeButtonBehavior,
        CloseButtonBehavior.exitApp,
      );
      expect(reloaded.settings.windowWidth, 960);
      expect(reloaded.settings.windowHeight, 640);
      expect(reloaded.settings.windowMaximized, isFalse);
    });

    test(
      'corrupt JSON desktop.json is renamed and preserved, returning default',
      () {
        final paths = BlinkPaths(dataRoot: tempDir);
        paths.desktopSettingsFile.parent.createSync(recursive: true);
        paths.desktopSettingsFile.writeAsStringSync('{not-valid-json');

        final fixedNow = DateTime.utc(2026, 11, 22, 16, 30, 45);
        final store = DesktopSettingsStore(
          file: paths.desktopSettingsFile,
          nowUtc: () => fixedNow,
        );

        final result = store.loadSync();
        expect(result.recoveredFromCorrupt, isTrue);
        expect(
          result.settings.closeButtonBehavior,
          CloseButtonBehavior.hideToTray,
        );
        expect(paths.desktopSettingsFile.existsSync(), isFalse);
        expect(result.preservedCorruptFile, isNotNull);
        expect(
          result.preservedCorruptFile!.path,
          endsWith('desktop.json.corrupt-20261122T163045Z'),
        );
        expect(
          result.preservedCorruptFile!.readAsStringSync(),
          '{not-valid-json',
        );
      },
    );

    test('schema-invalid desktop.json is also preserved as corrupt', () {
      final paths = BlinkPaths(dataRoot: tempDir);
      paths.desktopSettingsFile.parent.createSync(recursive: true);
      paths.desktopSettingsFile.writeAsStringSync(
        jsonEncode(<String, Object?>{'closeButtonBehavior': 'invalid_mode'}),
      );

      final store = DesktopSettingsStore(
        file: paths.desktopSettingsFile,
        nowUtc: () => DateTime.utc(2026, 11, 22, 17, 0, 0),
      );

      final result = store.loadSync();
      expect(result.recoveredFromCorrupt, isTrue);
      expect(
        result.settings.closeButtonBehavior,
        CloseButtonBehavior.hideToTray,
      );
      expect(result.preservedCorruptFile?.existsSync(), isTrue);
    });
  });
}

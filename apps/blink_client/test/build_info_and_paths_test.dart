import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:blink_client/platform/atomic_io.dart';
import 'package:blink_client/platform/build_info.dart';
import 'package:blink_client/platform/desktop_settings.dart';
import 'package:blink_client/platform/paths.dart';
import 'package:blink_client/platform/windows/win32_bindings.dart';

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

  group('BlinkPaths 3-root layout & channel isolation (DEC-031, #21)', () {
    test('BLINK_DATA_DIR override takes precedence over OS env and isolates default vault', () {
      final info = BlinkBuildInfo.normalized(
        channel: 'blink-dev',
        identity: 'blink-dev-test',
      );
      final paths = BlinkPaths.resolve(
        info,
        environment: const <String, String>{
          'BLINK_DATA_DIR': 'sandbox_override_dir',
          'BLINK_DOCUMENTS_DIR': 'ignored_documents_dir',
          'LOCALAPPDATA': 'ignored_local_app_data',
          'APPDATA': 'ignored_roaming_app_data',
        },
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        resolveSystemDocumentsDir: () => 'ignored_system_documents',
      );
      expect(paths.dataRoot.path, 'sandbox_override_dir');
      expect(paths.defaultVaultDir.path, r'sandbox_override_dir\vault');
      expect(paths.vaultDir.path, r'sandbox_override_dir\vault');
    });

    test('Windows installed builds split LOCALAPPDATA app-local state and Documents portable vault', () {
      final dev = BlinkBuildInfo.normalized(
        channel: 'blink-dev',
        identity: 'blink-dev',
      );
      final devPaths = BlinkPaths.resolve(
        dev,
        environment: const <String, String>{
          'LOCALAPPDATA': 'virtual_local_appdata',
          'APPDATA': 'virtual_roaming_appdata',
          'USERPROFILE': 'virtual_profile',
        },
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        resolveSystemDocumentsDir: () => 'virtual_known_documents',
      );
      expect(devPaths.dataRoot.path, r'virtual_local_appdata\blink-dev');
      expect(
        devPaths.defaultVaultDir.path,
        r'virtual_known_documents\blink-dev',
      );
      expect(devPaths.vaultDir.path, r'virtual_known_documents\blink-dev');

      final prod = BlinkBuildInfo.normalized(
        channel: 'blink',
        identity: 'blink',
      );
      final prodPaths = BlinkPaths.resolve(
        prod,
        environment: const <String, String>{
          'LOCALAPPDATA': 'virtual_local_appdata',
          'USERPROFILE': 'virtual_profile',
        },
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        resolveSystemDocumentsDir: () =>
            'virtual_onedrive_root\\OneDrive\\Documents',
      );
      expect(prodPaths.dataRoot.path, r'virtual_local_appdata\blink');
      expect(
        prodPaths.defaultVaultDir.path,
        r'virtual_onedrive_root\OneDrive\Documents\blink',
      );
      expect(BlinkPaths.isOneDrivePath(prodPaths.defaultVaultDir.path), isTrue);

      final testId = BlinkBuildInfo.normalized(
        channel: 'blink',
        identity: 'blink-test',
      );
      final testPaths = BlinkPaths.resolve(
        testId,
        environment: const <String, String>{
          'LOCALAPPDATA': 'virtual_local_appdata',
          'USERPROFILE': 'virtual_profile',
        },
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        resolveSystemDocumentsDir: () => 'virtual_known_documents',
      );
      expect(testPaths.dataRoot.path, r'virtual_local_appdata\blink-test');
      expect(
        testPaths.defaultVaultDir.path,
        r'virtual_known_documents\blink-test',
      );
    });

    test('Windows Documents fallback chain: BLINK_DOCUMENTS_DIR > KnownFolder > USERPROFILE\\Documents > dataRoot\\vault', () {
      final dev = BlinkBuildInfo.normalized(
        channel: 'blink-dev',
        identity: 'blink-dev',
      );

      final withEnvDocs = BlinkPaths.resolve(
        dev,
        environment: const <String, String>{
          'LOCALAPPDATA': 'virtual_local_appdata',
          'USERPROFILE': 'virtual_profile',
          'BLINK_DOCUMENTS_DIR': 'virtual_env_documents',
        },
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        resolveSystemDocumentsDir: () => 'virtual_known_documents',
      );
      expect(
        withEnvDocs.defaultVaultDir.path,
        r'virtual_env_documents\blink-dev',
      );

      final withUserProfileFallback = BlinkPaths.resolve(
        dev,
        environment: const <String, String>{
          'LOCALAPPDATA': 'virtual_local_appdata',
          'USERPROFILE': 'virtual_profile',
        },
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        resolveSystemDocumentsDir: () => null,
      );
      expect(
        withUserProfileFallback.defaultVaultDir.path,
        r'virtual_profile\Documents\blink-dev',
      );

      final withDataRootFallback = BlinkPaths.resolve(
        dev,
        environment: const <String, String>{
          'LOCALAPPDATA': 'virtual_local_appdata',
        },
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        resolveSystemDocumentsDir: () => null,
      );
      expect(
        withDataRootFallback.defaultVaultDir.path,
        r'virtual_local_appdata\blink-dev\vault',
      );
    });

    test('Linux honors XDG_DATA_HOME/XDG_DOCUMENTS_DIR and macOS uses Application Support/Documents', () {
      final installedDev = BlinkBuildInfo.normalized(
        channel: 'blink-dev',
        identity: 'blink-dev',
      );
      final linuxXdg = BlinkPaths.resolve(
        installedDev,
        environment: const <String, String>{
          'XDG_DATA_HOME': 'virtual_xdg_data',
          'XDG_DOCUMENTS_DIR': 'virtual_xdg_docs',
        },
        isWindows: false,
        isMacOS: false,
        isLinux: true,
      );
      expect(linuxXdg.dataRoot.path, 'virtual_xdg_data/blink-dev');
      expect(linuxXdg.defaultVaultDir.path, 'virtual_xdg_docs/blink-dev');

      final linuxHomeFallback = BlinkPaths.resolve(
        installedDev,
        environment: const <String, String>{'HOME': 'virtual_linux_home'},
        isWindows: false,
        isMacOS: false,
        isLinux: true,
      );
      expect(
        linuxHomeFallback.dataRoot.path,
        'virtual_linux_home/.local/share/blink-dev',
      );
      expect(
        linuxHomeFallback.defaultVaultDir.path,
        'virtual_linux_home/Documents/blink-dev',
      );

      final macPaths = BlinkPaths.resolve(
        installedDev,
        environment: const <String, String>{'HOME': 'virtual_mac_home'},
        isWindows: false,
        isMacOS: true,
        isLinux: false,
      );
      expect(
        macPaths.dataRoot.path,
        'virtual_mac_home/Library/Application Support/blink-dev',
      );
      expect(
        macPaths.defaultVaultDir.path,
        'virtual_mac_home/Documents/blink-dev',
      );
    });

    test('BLINK_VAULT_DIR override takes precedence over customVaultPath and defaultVaultDir', () {
      final info = BlinkBuildInfo.normalized(
        channel: 'blink-dev',
        identity: 'blink-dev',
      );
      final overridden = BlinkPaths.resolve(
        info,
        environment: const <String, String>{
          'BLINK_DATA_DIR': 'sandbox_data',
          'BLINK_VAULT_DIR': 'sandbox_portable_vault',
        },
        isWindows: true,
        isMacOS: false,
        isLinux: false,
      );
      expect(overridden.hasVaultDirOverride, isTrue);
      expect(overridden.vaultDir.path, 'sandbox_portable_vault');
      expect(
        overridden
            .resolveEffectiveVaultDir(customVaultPath: 'ignored_custom')
            .path,
        'sandbox_portable_vault',
      );

      final standard = BlinkPaths.resolve(
        info,
        environment: const <String, String>{'BLINK_DATA_DIR': 'sandbox_data'},
        isWindows: true,
        isMacOS: false,
        isLinux: false,
      );
      expect(standard.hasVaultDirOverride, isFalse);
      expect(standard.vaultDir.path, r'sandbox_data\vault');
      expect(
        standard.webview2Dir.path,
        'sandbox_data${Platform.pathSeparator}webview2',
      );
      expect(
        standard
            .resolveEffectiveVaultDir(customVaultPath: 'custom_vault_dir')
            .path,
        'custom_vault_dir',
      );

      final installedWithDocs = BlinkPaths.resolve(
        info,
        environment: const <String, String>{
          'LOCALAPPDATA': 'virtual_local_appdata',
        },
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        resolveSystemDocumentsDir: () => 'virtual_documents',
      );
      expect(
        installedWithDocs.resolveEffectiveVaultDir().path,
        r'virtual_documents\blink-dev',
      );
      expect(
        installedWithDocs
            .resolveEffectiveVaultDir(customVaultPath: 'custom_vault_dir')
            .path,
        'custom_vault_dir',
      );
    });

    test('source builds isolate into <repoRoot>/.local/blink-dev/{app,vault} across default, dev, and custom channels (#21)', () {
      final tempRoot = Directory.systemTemp.createTempSync('blink_src_repo_');
      addTearDown(() {
        if (tempRoot.existsSync()) {
          tempRoot.deleteSync(recursive: true);
        }
      });

      // Workspace root marker (`.git` file simulating worktree + workspace pubspec).
      File('${tempRoot.path}${Platform.pathSeparator}.git')
          .writeAsStringSync('gitdir: mock\n');
      final nestedClientDir = Directory(
        '${tempRoot.path}${Platform.pathSeparator}apps${Platform.pathSeparator}blink_client',
      )..createSync(recursive: true);
      File('${nestedClientDir.path}${Platform.pathSeparator}pubspec.yaml')
          .writeAsStringSync('name: blink_client\nresolution: workspace\n');

      for (final channel in const <String>['', 'blink-dev', 'blink-staging']) {
        final sourceInfo = BlinkBuildInfo.normalized(channel: channel);
        expect(sourceInfo.isSourceBuild, isTrue);

        final resolved = BlinkPaths.resolve(
          sourceInfo,
          environment: const <String, String>{
            'LOCALAPPDATA': 'virtual_local_appdata',
            'USERPROFILE': 'virtual_profile',
          },
          isWindows: Platform.isWindows,
          isMacOS: Platform.isMacOS,
          isLinux: Platform.isLinux,
          resolveSystemDocumentsDir: () => 'virtual_documents',
          currentDirectoryOverride: nestedClientDir,
        );

        final sep = Platform.isWindows ? r'\' : '/';
        expect(
          resolved.dataRoot.path,
          '${tempRoot.path}$sep.local${sep}blink-dev${sep}app',
        );
        expect(
          resolved.defaultVaultDir.path,
          '${tempRoot.path}$sep.local${sep}blink-dev${sep}vault',
        );
        expect(
          resolved.dataRoot.path,
          isNot(contains('virtual_local_appdata')),
        );
        expect(
          resolved.defaultVaultDir.path,
          isNot(contains('virtual_documents')),
        );
      }

      // Workspace pubspec.yaml alone (without .git) also discovers repo root.
      final wsOnly = Directory.systemTemp.createTempSync('blink_ws_only_');
      addTearDown(() {
        if (wsOnly.existsSync()) {
          wsOnly.deleteSync(recursive: true);
        }
      });
      File('${wsOnly.path}${Platform.pathSeparator}pubspec.yaml')
          .writeAsStringSync(
            'name: blink_workspace\nworkspace:\n  - apps/blink_client\n',
          );
      final wsChild = Directory(
        '${wsOnly.path}${Platform.pathSeparator}apps${Platform.pathSeparator}blink_client',
      )..createSync(recursive: true);
      File('${wsChild.path}${Platform.pathSeparator}pubspec.yaml')
          .writeAsStringSync('name: blink_client\nresolution: workspace\n');

      final wsResolved = BlinkPaths.resolve(
        BlinkBuildInfo.normalized(channel: 'blink-dev'),
        environment: const <String, String>{},
        isWindows: false,
        isMacOS: false,
        isLinux: true,
        currentDirectoryOverride: wsChild,
      );
      expect(wsResolved.dataRoot.path, '${wsOnly.path}/.local/blink-dev/app');
      expect(
        wsResolved.defaultVaultDir.path,
        '${wsOnly.path}/.local/blink-dev/vault',
      );
    });

    test('source build falls back to <temp>/blink-source-dev/{app,vault} when outside any repository (#21)', () {
      final outsideDir = Directory.systemTemp.createTempSync('blink_no_repo_');
      addTearDown(() {
        if (outsideDir.existsSync()) {
          outsideDir.deleteSync(recursive: true);
        }
      });

      final resolved = BlinkPaths.resolve(
        BlinkBuildInfo.normalized(channel: 'blink-dev'),
        environment: const <String, String>{
          'LOCALAPPDATA': 'virtual_local_appdata',
        },
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        fallbackTempPath: 'virtual_temp',
        currentDirectoryOverride: outsideDir,
      );
      expect(resolved.dataRoot.path, r'virtual_temp\blink-source-dev\app');
      expect(
        resolved.defaultVaultDir.path,
        r'virtual_temp\blink-source-dev\vault',
      );
    });

    test('source build targeting production channel blink requires explicit opt-in and isolated BLINK_DATA_DIR (#21)', () {
      final sourceProd = BlinkBuildInfo.normalized(channel: 'blink');
      expect(sourceProd.isSourceBuild, isTrue);
      expect(sourceProd.isProductionChannel, isTrue);

      // Default: rejected.
      expect(
        () => BlinkPaths.resolve(
          sourceProd,
          environment: const <String, String>{
            'LOCALAPPDATA': 'virtual_local_appdata',
          },
          isWindows: true,
          isMacOS: false,
          isLinux: false,
          resolveSystemDocumentsDir: () => 'virtual_documents',
        ),
        throwsStateError,
      );

      // Opt-in without explicit BLINK_DATA_DIR: rejected.
      expect(
        () => BlinkPaths.resolve(
          sourceProd,
          environment: const <String, String>{
            'BLINK_ALLOW_SOURCE_PROD': '1',
            'LOCALAPPDATA': 'virtual_local_appdata',
          },
          isWindows: true,
          isMacOS: false,
          isLinux: false,
          resolveSystemDocumentsDir: () => 'virtual_documents',
        ),
        throwsStateError,
      );

      // Explicit BLINK_DATA_DIR without opt-in: rejected.
      expect(
        () => BlinkPaths.resolve(
          sourceProd,
          environment: const <String, String>{
            'BLINK_DATA_DIR': 'isolated_source_prod_data',
            'LOCALAPPDATA': 'virtual_local_appdata',
          },
          isWindows: true,
          isMacOS: false,
          isLinux: false,
          resolveSystemDocumentsDir: () => 'virtual_documents',
        ),
        throwsStateError,
      );

      // Opt-in + BLINK_DATA_DIR overlapping real prod LOCALAPPDATA\blink: rejected.
      expect(
        () => BlinkPaths.resolve(
          sourceProd,
          environment: const <String, String>{
            'BLINK_ALLOW_SOURCE_PROD': '1',
            'BLINK_DATA_DIR': r'virtual_local_appdata\blink-dev\..\BLINK',
            'LOCALAPPDATA': 'virtual_local_appdata',
          },
          isWindows: true,
          isMacOS: false,
          isLinux: false,
          resolveSystemDocumentsDir: () => 'virtual_documents',
        ),
        throwsStateError,
      );

      // Opt-in + BLINK_DATA_DIR safe, but BLINK_VAULT_DIR overlapping real <Documents>\blink: rejected.
      expect(
        () => BlinkPaths.resolve(
          sourceProd,
          environment: const <String, String>{
            'BLINK_ALLOW_SOURCE_PROD': '1',
            'BLINK_DATA_DIR': 'isolated_source_prod_data',
            'BLINK_VAULT_DIR': r'virtual_documents\blink\sub',
            'LOCALAPPDATA': 'virtual_local_appdata',
          },
          isWindows: true,
          isMacOS: false,
          isLinux: false,
          resolveSystemDocumentsDir: () => 'virtual_documents',
        ),
        throwsStateError,
      );

      // Opt-in + isolated BLINK_DATA_DIR: succeeds!
      final allowed = BlinkPaths.resolve(
        sourceProd,
        environment: const <String, String>{
          'BLINK_ALLOW_SOURCE_PROD': '1',
          'BLINK_DATA_DIR': 'isolated_source_prod_data',
          'LOCALAPPDATA': 'virtual_local_appdata',
        },
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        resolveSystemDocumentsDir: () => 'virtual_documents',
      );
      expect(allowed.dataRoot.path, 'isolated_source_prod_data');
      expect(allowed.defaultVaultDir.path, r'isolated_source_prod_data\vault');
    });

    test('channel isolation guard blocks non-prod from prod roots and test identities from dev roots', () {
      final dev = BlinkBuildInfo.normalized(
        channel: 'blink-dev',
        identity: 'blink-dev',
      );

      // Dev build targeting prod LOCALAPPDATA\blink (exact, child, ancestor, .. traversal).
      for (final badData in const <String>[
        r'virtual_local_appdata\blink',
        r'virtual_local_appdata\BLINK\nested',
        r'virtual_local_appdata\blink-dev\..\blink',
        'virtual_local_appdata',
      ]) {
        expect(
          () => BlinkPaths.resolve(
            dev,
            environment: <String, String>{
              'LOCALAPPDATA': 'virtual_local_appdata',
              'BLINK_DATA_DIR': badData,
            },
            isWindows: true,
            isMacOS: false,
            isLinux: false,
            resolveSystemDocumentsDir: () => 'virtual_documents',
          ),
          throwsStateError,
          reason: 'Expected dev BLINK_DATA_DIR=$badData to be rejected',
        );
      }

      // Dev build targeting prod <Documents>\blink via BLINK_VAULT_DIR.
      expect(
        () => BlinkPaths.resolve(
          dev,
          environment: const <String, String>{
            'LOCALAPPDATA': 'virtual_local_appdata',
            'BLINK_VAULT_DIR': r'virtual_documents\blink',
          },
          isWindows: true,
          isMacOS: false,
          isLinux: false,
          resolveSystemDocumentsDir: () => 'virtual_documents',
        ),
        throwsStateError,
      );

      // Test identities (`blink-test` & `blink-dev-test`) and source builds
      // reject BOTH installed prod (`blink`) and installed dev (`blink-dev`) roots.
      for (final guardedBuild in <BlinkBuildInfo>[
        BlinkBuildInfo.normalized(channel: 'blink', identity: 'blink-test'),
        BlinkBuildInfo.normalized(
          channel: 'blink-dev',
          identity: 'blink-dev-test',
        ),
        BlinkBuildInfo.normalized(channel: 'blink-dev'),
      ]) {
        for (final badPath in const <String>[
          r'virtual_local_appdata\blink',
          r'virtual_local_appdata\blink-dev',
          r'virtual_documents\blink',
          r'virtual_documents\blink-dev',
        ]) {
          expect(
            () => BlinkPaths.resolve(
              guardedBuild,
              environment: <String, String>{
                'LOCALAPPDATA': 'virtual_local_appdata',
                'BLINK_DATA_DIR': 'isolated_test_root',
                'BLINK_VAULT_DIR': badPath,
              },
              isWindows: true,
              isMacOS: false,
              isLinux: false,
              resolveSystemDocumentsDir: () => 'virtual_documents',
            ),
            throwsStateError,
            reason:
                'Expected ${guardedBuild.identity.isEmpty ? "source" : guardedBuild.identity} BLINK_VAULT_DIR=$badPath to be rejected',
          );
        }
      }

      // Source build also rejects BLINK_DATA_DIR targeting installed blink-dev
      // and flags installed blink-dev as forbidden for customVaultPath.
      final sourceDev = BlinkBuildInfo.normalized(channel: 'blink-dev');
      expect(
        () => BlinkPaths.resolve(
          sourceDev,
          environment: const <String, String>{
            'LOCALAPPDATA': 'virtual_local_appdata',
            'BLINK_DATA_DIR': r'virtual_local_appdata\blink-dev',
          },
          isWindows: true,
          isMacOS: false,
          isLinux: false,
          resolveSystemDocumentsDir: () => 'virtual_documents',
        ),
        throwsStateError,
      );
      final safeSource = BlinkPaths.resolve(
        sourceDev,
        environment: const <String, String>{
          'LOCALAPPDATA': 'virtual_local_appdata',
        },
        isWindows: true,
        isMacOS: false,
        isLinux: false,
        resolveSystemDocumentsDir: () => 'virtual_documents',
        repoRootOverride: Directory('virtual_repo'),
      );
      expect(
        safeSource.isForbiddenTargetPath(r'virtual_local_appdata\blink-dev'),
        isTrue,
      );
      expect(
        safeSource.isForbiddenTargetPath(r'virtual_documents\blink-dev'),
        isTrue,
      );
      expect(
        safeSource.isForbiddenTargetPath(
          r'virtual_repo\.local\blink-dev\vault',
        ),
        isFalse,
      );
    });

    test('channel isolation guard resolves existing symlinks/junctions including relative symlink + non-existent child', () {
      final tempRoot = Directory.systemTemp.createTempSync('blink_link_guard_');
      addTearDown(() {
        if (tempRoot.existsSync()) {
          tempRoot.deleteSync(recursive: true);
        }
      });

      final fakeLocalAppData = Directory(
        '${tempRoot.path}${Platform.pathSeparator}lad',
      )..createSync(recursive: true);
      final fakeProdDir = Directory(
        '${fakeLocalAppData.path}${Platform.pathSeparator}blink',
      )..createSync(recursive: true);
      final linkPath = '${tempRoot.path}${Platform.pathSeparator}sneaky_link';

      var linkCreated = false;
      try {
        Link(linkPath).createSync(fakeProdDir.path);
        linkCreated = true;
      } on FileSystemException {
        linkCreated = false;
      }

      if (linkCreated) {
        final dev = BlinkBuildInfo.normalized(
          channel: 'blink-dev',
          identity: 'blink-dev',
        );
        final sep = Platform.isWindows ? r'\' : '/';
        expect(
          () => BlinkPaths.resolve(
            dev,
            environment: <String, String>{
              'LOCALAPPDATA': fakeLocalAppData.path,
              'XDG_DATA_HOME': fakeLocalAppData.path,
              'BLINK_DATA_DIR': linkPath,
            },
            isWindows: Platform.isWindows,
            isMacOS: Platform.isMacOS,
            isLinux: Platform.isLinux,
            resolveSystemDocumentsDir: () =>
                '${tempRoot.path}${Platform.pathSeparator}docs',
          ),
          throwsStateError,
        );
        expect(
          () => BlinkPaths.resolve(
            dev,
            environment: <String, String>{
              'LOCALAPPDATA': fakeLocalAppData.path,
              'XDG_DATA_HOME': fakeLocalAppData.path,
              'BLINK_DATA_DIR': 'sneaky_link${sep}nonexistent_child',
            },
            isWindows: Platform.isWindows,
            isMacOS: Platform.isMacOS,
            isLinux: Platform.isLinux,
            resolveSystemDocumentsDir: () =>
                '${tempRoot.path}${Platform.pathSeparator}docs',
            currentDirectoryOverride: tempRoot,
          ),
          throwsStateError,
        );
      }
    });

    test('isOneDrivePath detects OneDrive folders accurately without false positives', () {
      expect(
        BlinkPaths.isOneDrivePath(r'virtual_profile\OneDrive\Documents\blink'),
        isTrue,
      );
      expect(
        BlinkPaths.isOneDrivePath(
          r'virtual_profile\OneDrive - Personal\Documents\blink-dev',
        ),
        isTrue,
      );
      expect(
        BlinkPaths.isOneDrivePath('virtual_home/OneDrive/Documents/blink'),
        isTrue,
      );
      expect(
        BlinkPaths.isOneDrivePath(r'virtual_profile\Documents\blink'),
        isFalse,
      );
      expect(
        BlinkPaths.isOneDrivePath(r'virtual_profile\MyOneDriveClone\blink'),
        isFalse,
      );
    });

    test('queryKnownFolderDocuments returns a non-empty path on Windows and null elsewhere', () {
      final result = queryKnownFolderDocuments();
      if (Platform.isWindows) {
        expect(result, isNotNull);
        expect(result!.trim(), isNotEmpty);
      } else {
        expect(result, isNull);
      }
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
          surfaceMode: DesktopSurfacePreference.sepia,
          customVaultPath: 'portable_custom_vault',
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
      expect(reloaded.settings.surfaceMode, DesktopSurfacePreference.sepia);
      expect(reloaded.settings.customVaultPath, 'portable_custom_vault');
    });

    test(
      'invalid surfaceMode in desktop.json triggers corrupt preservation',
      () {
        final paths = BlinkPaths(dataRoot: tempDir);
        paths.desktopSettingsFile.parent.createSync(recursive: true);
        paths.desktopSettingsFile.writeAsStringSync(
          jsonEncode(<String, Object?>{'surfaceMode': 'neon_pink'}),
        );

        final store = DesktopSettingsStore(
          file: paths.desktopSettingsFile,
          nowUtc: () => DateTime.utc(2026, 11, 25, 10, 0, 0),
        );
        final result = store.loadSync();
        expect(result.recoveredFromCorrupt, isTrue);
        expect(result.settings.surfaceMode, isNull);
        expect(result.preservedCorruptFile?.existsSync(), isTrue);
      },
    );

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

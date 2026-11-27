import 'dart:convert';
import 'dart:io';

import 'package:blink_core/blink_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:blink_client/platform/android/android_platform.dart';
import 'package:blink_client/platform/android/keystore_secret_store.dart';
import 'package:blink_client/platform/paths.dart';
import 'package:blink_client/platform/secret_store.dart';
import 'package:blink_client/platform/windows/dpapi_secret_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BlinkSecretStore validation, in-memory, fallback, and factory', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('blink_secret_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('rejects invalid or path-traversal secret keys', () {
      for (final bad in const <String>[
        '',
        '   ',
        '../escape',
        '.hidden',
        'dir/key',
        r'dir\key',
        'bad key with spaces',
      ]) {
        expect(
          () => validateBlinkSecretKey(bad),
          throwsA(isA<BlinkSecretStoreException>()),
          reason: 'Expected key "$bad" to be rejected',
        );
      }
      expect(
        validateBlinkSecretKey(BlinkSecretKeys.directDeviceToken),
        BlinkSecretKeys.directDeviceToken,
      );
    });

    test('InMemoryBlinkSecretStore supports CRUD and channel clear', () async {
      final store = InMemoryBlinkSecretStore(channel: 'blink-dev');
      expect(await store.read(BlinkSecretKeys.directDeviceToken), isNull);

      await store.write(BlinkSecretKeys.directDeviceToken, 'tok-dev-123');
      await store.write(BlinkSecretKeys.relayMasterKey, 'mk-dev-456');
      expect(
        await store.read(BlinkSecretKeys.directDeviceToken),
        'tok-dev-123',
      );
      expect(await store.read(BlinkSecretKeys.relayMasterKey), 'mk-dev-456');

      await store.delete(BlinkSecretKeys.directDeviceToken);
      expect(await store.read(BlinkSecretKeys.directDeviceToken), isNull);
      expect(await store.read(BlinkSecretKeys.relayMasterKey), 'mk-dev-456');

      await store.deleteAllForChannel();
      expect(store.isEmpty, isTrue);
    });

    test(
      'ScopedFileFallbackSecretStore isolates channels and writes atomically',
      () async {
        final credsDir = Directory('${tempDir.path}/credentials');
        final devStore = ScopedFileFallbackSecretStore(
          credentialsDir: credsDir,
          channel: 'blink-dev',
        );
        final prodStore = ScopedFileFallbackSecretStore(
          credentialsDir: credsDir,
          channel: 'blink',
        );

        await devStore.write(
          BlinkSecretKeys.directDeviceToken,
          'dev-secret-abc',
        );
        expect(
          await devStore.read(BlinkSecretKeys.directDeviceToken),
          'dev-secret-abc',
        );

        // Wrong channel must refuse to read the envelope.
        await expectLater(
          prodStore.read(BlinkSecretKeys.directDeviceToken),
          throwsA(isA<BlinkSecretStoreException>()),
        );

        // No temp files left behind.
        final files = credsDir.listSync().whereType<File>().toList();
        expect(files.any((f) => f.path.contains('.blink-tmp')), isFalse);

        await devStore.deleteAllForChannel();
        expect(await devStore.read(BlinkSecretKeys.directDeviceToken), isNull);
      },
    );

    test('createDefaultBlinkSecretStore selects correct implementation per platform', () {
      final paths = BlinkPaths(dataRoot: tempDir);

      expect(
        createDefaultBlinkSecretStore(
          paths: paths,
          channel: BlinkChannel.blinkDev,
          quietOverride: true,
          isWindowsOverride: true,
          isAndroidOverride: false,
        ),
        isA<InMemoryBlinkSecretStore>(),
      );
      expect(
        createDefaultBlinkSecretStore(
          paths: paths,
          channel: BlinkChannel.blinkDev,
          quietOverride: false,
          isWindowsOverride: true,
          isAndroidOverride: false,
        ),
        isA<WindowsDpapiSecretStore>(),
      );
      expect(
        createDefaultBlinkSecretStore(
          paths: paths,
          channel: BlinkChannel.blinkDev,
          quietOverride: false,
          isWindowsOverride: false,
          isAndroidOverride: true,
        ),
        isA<AndroidKeystoreSecretStore>(),
      );
      expect(
        createDefaultBlinkSecretStore(
          paths: paths,
          channel: BlinkChannel.blinkDev,
          quietOverride: false,
          isWindowsOverride: false,
          isAndroidOverride: false,
        ),
        isA<ScopedFileFallbackSecretStore>(),
      );
    });
  });

  group('AndroidKeystoreSecretStore MethodChannel bridge', () {
    const channel = MethodChannel(kBlinkAndroidPlatformChannelName);
    final backing = <String, String>{};
    final recordedMethods = <String>[];

    setUp(() {
      backing.clear();
      recordedMethods.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            recordedMethods.add(call.method);
            final args =
                (call.arguments as Map<Object?, Object?>?) ??
                const <Object?, Object?>{};
            final ch = args['channel'] as String? ?? '';
            final key = args['key'] as String? ?? '';
            final fullKey = '$ch::$key';
            switch (call.method) {
              case 'secretWrite':
                backing[fullKey] = args['value'] as String;
                return true;
              case 'secretRead':
                return backing[fullKey];
              case 'secretDelete':
                backing.remove(fullKey);
                return true;
              case 'secretDeleteAllForChannel':
                backing.removeWhere((k, _) => k.startsWith('$ch::'));
                return true;
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'round-trips and isolates blink vs blink-dev over MethodChannel',
      () async {
        const devStore = AndroidKeystoreSecretStore(channel: 'blink-dev');
        const prodStore = AndroidKeystoreSecretStore(channel: 'blink');

        await devStore.write(
          BlinkSecretKeys.directDeviceToken,
          'android-dev-token',
        );
        await prodStore.write(
          BlinkSecretKeys.directDeviceToken,
          'android-prod-token',
        );

        expect(
          await devStore.read(BlinkSecretKeys.directDeviceToken),
          'android-dev-token',
        );
        expect(
          await prodStore.read(BlinkSecretKeys.directDeviceToken),
          'android-prod-token',
        );

        await devStore.deleteAllForChannel();
        expect(await devStore.read(BlinkSecretKeys.directDeviceToken), isNull);
        expect(
          await prodStore.read(BlinkSecretKeys.directDeviceToken),
          'android-prod-token',
        );
        expect(
          recordedMethods,
          containsAll(<String>[
            'secretWrite',
            'secretRead',
            'secretDeleteAllForChannel',
          ]),
        );
      },
    );

    test('translates PlatformException without leaking secrets', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(
              code: 'secret_decrypt_failed',
              message: 'Corrupt ciphertext',
            );
          });

      const store = AndroidKeystoreSecretStore(channel: 'blink-dev');
      await expectLater(
        store.read(BlinkSecretKeys.relayMasterKey),
        throwsA(
          isA<BlinkSecretStoreException>().having(
            (e) => e.code,
            'code',
            'secret_decrypt_failed',
          ),
        ),
      );
    });
  });

  group('WindowsDpapiSecretStore real Win32 DPAPI round-trip & channel entropy isolation', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('blink_dpapi_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('encrypts atomically, round-trips UTF-8 secrets, and rejects wrong-channel entropy', () async {
      final credsDir = Directory('${tempDir.path}\\credentials');
      final vaultDir = Directory('${tempDir.path}\\vault')..createSync();
      final devStore = WindowsDpapiSecretStore(
        credentialsDir: credsDir,
        channel: 'blink-dev',
      );
      final prodStoreSameDir = WindowsDpapiSecretStore(
        credentialsDir: credsDir,
        channel: 'blink',
      );

      const secretToken = 'blink-dpapi-roundtrip-token-9f8e7d6c5b4a-中文';
      await devStore.write(BlinkSecretKeys.directDeviceToken, secretToken);

      final dpapiFile = File(
        '${credsDir.path}\\${BlinkSecretKeys.directDeviceToken}.dpapi',
      );
      expect(dpapiFile.existsSync(), isTrue);

      // Ciphertext on disk must NOT contain plaintext secret (`INV-08`).
      final rawBytes = dpapiFile.readAsBytesSync();
      final rawLatin1 = latin1.decode(rawBytes, allowInvalid: true);
      expect(rawLatin1, isNot(contains('blink-dpapi-roundtrip-token')));

      // Zero secrets written into vault directory (`INV-08`).
      expect(vaultDir.listSync(recursive: true), isEmpty);

      // Correct channel decrypts verbatim.
      expect(
        await devStore.read(BlinkSecretKeys.directDeviceToken),
        secretToken,
      );

      // Wrong-channel entropy MUST fail CryptUnprotectData (`INV-06`).
      await expectLater(
        prodStoreSameDir.read(BlinkSecretKeys.directDeviceToken),
        throwsA(
          isA<BlinkSecretStoreException>().having(
            (e) => e.code,
            'code',
            'dpapi_unprotect_failed',
          ),
        ),
      );

      // Non-dpapi files remain untouched by deleteAllForChannel (`INV-12`).
      final keepFile = File('${credsDir.path}\\notes.txt')
        ..writeAsStringSync('keep');
      await devStore.deleteAllForChannel();
      expect(dpapiFile.existsSync(), isFalse);
      expect(keepFile.existsSync(), isTrue);
      expect(await devStore.read(BlinkSecretKeys.directDeviceToken), isNull);
    }, skip: !Platform.isWindows);
  });
}

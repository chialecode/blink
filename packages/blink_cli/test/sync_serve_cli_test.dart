import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:blink_cli/blink_cli.dart';
import 'package:blink_core/blink_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempRoot;

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('blink_cli_sync_test_');
  });

  tearDown(() async {
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('AC-04: Headless `blink sync serve`, device pairing/revocation & channel guard', () {
    test('serves loopback direct sync via CLI runner, pairs, syncs entries, and enforces zero vault secrets', () async {
      final serverVaultDir = Directory(p.join(tempRoot.path, 'headless-vault'));
      final clientVaultDir = Directory(p.join(tempRoot.path, 'client-vault'));

      final shutdownCompleter = Completer<void>();
      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();
      final cli = BlinkCliRunner(
        stdoutSink: stdoutBuf,
        stderrSink: stderrBuf,
        environment: const <String, String>{'BLINK_QUIET': '1'},
        shutdownSignal: () => shutdownCompleter.future,
      );

      final serveFuture = cli.run(<String>[
        'sync',
        'serve',
        '--vault',
        serverVaultDir.path,
        '--host',
        '127.0.0.1',
        '--port',
        '0',
        '--channel',
        'blink-dev',
        '--device-name',
        'NAS-Headless',
        '--no-mdns',
        '--pair-code',
      ]);

      // Wait until the startup JSON banner is written.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (stdoutBuf.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      final banner =
          jsonDecode(stdoutBuf.toString().trim()) as Map<String, Object?>;
      expect(banner['status'], equals('listening'));
      expect(banner['channel'], equals('blink-dev'));
      expect(banner['mdns_enabled'], isFalse);
      final baseUri = Uri.parse(banner['url'] as String);
      final pairingCode = banner['pairing_code'] as String;
      expect(pairingCode, isNotEmpty);

      // Pair a client vault and run full sync against the headless server.
      final clientVault = await VaultManager.open(
        VaultConfig(
          vaultDir: clientVaultDir,
          expectedChannel: BlinkChannel.blinkDev,
          deviceName: 'CLI-Client',
          enableMirrorExporter: false,
        ),
      );
      try {
        final unauth = DirectShelfTransport(
          baseUri: baseUri,
          expectedChannel: BlinkChannel.blinkDev,
        );
        final paired = await unauth.pair(
          pairingCode: pairingCode,
          deviceId: clientVault.localDeviceId,
          deviceName: clientVault.localDeviceName,
        );
        final authed = unauth.withDeviceToken(paired.deviceToken);
        try {
          await clientVault.raw.createEntry(bodyMd: '同步到无头节点的笔记 #headless');
          final syncRes = await clientVault.syncEngine.syncWithTransport(
            authed,
          );
          expect(syncRes.pushedOps, equals(1));
          expect(clientVault.pendingOutboxCount, equals(0));
        } finally {
          authed.close();
          unauth.close();
        }
      } finally {
        await clientVault.checkpointAndClose();
      }

      // Trigger clean shutdown and verify exit code 0.
      shutdownCompleter.complete();
      expect(await serveFuture, equals(0));
      expect(stderrBuf.toString(), isEmpty);

      // INV-08: Verify neither pairing code nor raw secrets exist in vault files.
      for (final file
          in serverVaultDir.listSync(recursive: true).whereType<File>()) {
        final name = p.basename(file.path);
        expect(name, isNot(equals('ipc.json')));
        if (name.endsWith('.json')) {
          final content = await file.readAsString();
          expect(content, isNot(contains(pairingCode)));
        }
      }

      // Verify `blink sync devices` and `blink sync revoke` work cleanly on the vault.
      final listOut = StringBuffer();
      final listCli = BlinkCliRunner(
        stdoutSink: listOut,
        stderrSink: StringBuffer(),
      );
      expect(
        await listCli.run(<String>[
          'sync',
          'devices',
          '--vault',
          serverVaultDir.path,
          '--channel',
          'blink-dev',
        ]),
        equals(0),
      );
      final listJson =
          jsonDecode(listOut.toString().trim()) as Map<String, Object?>;
      final devices = listJson['devices'] as List<Object?>;
      expect(devices, hasLength(1));
      final pairedDeviceId =
          (devices.single as Map<String, Object?>)['device_id'] as String;

      final revokeOut = StringBuffer();
      final revokeCli = BlinkCliRunner(
        stdoutSink: revokeOut,
        stderrSink: StringBuffer(),
      );
      expect(
        await revokeCli.run(<String>[
          'sync',
          'revoke',
          '--vault',
          serverVaultDir.path,
          '--channel',
          'blink-dev',
          '--device-id',
          pairedDeviceId,
        ]),
        equals(0),
      );
      final revokeJson =
          jsonDecode(revokeOut.toString().trim()) as Map<String, Object?>;
      expect(revokeJson['revoked'], isTrue);
    });

    test(
      'rejects opening a blink-dev vault with --channel blink (INV-06)',
      () async {
        final devVaultDir = Directory(p.join(tempRoot.path, 'dev-only-vault'));
        final v = await VaultManager.open(
          VaultConfig(
            vaultDir: devVaultDir,
            expectedChannel: BlinkChannel.blinkDev,
            enableMirrorExporter: false,
          ),
        );
        await v.checkpointAndClose();

        final errBuf = StringBuffer();
        final cli = BlinkCliRunner(
          stdoutSink: StringBuffer(),
          stderrSink: errBuf,
        );
        final code = await cli.run(<String>[
          'sync',
          'serve',
          '--vault',
          devVaultDir.path,
          '--host',
          '127.0.0.1',
          '--port',
          '0',
          '--channel',
          'blink',
          '--no-mdns',
        ]);
        expect(code, equals(2));
        expect(errBuf.toString(), contains('channel_mismatch'));
      },
    );
  });
}

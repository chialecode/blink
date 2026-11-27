import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:blink_core/blink_core.dart';
import 'package:path/path.dart' as p;

/// Runtime options for [BlinkSyncServeRunner].
final class BlinkSyncServeConfig {
  const BlinkSyncServeConfig({
    required this.vaultDir,
    required this.channel,
    this.host = '127.0.0.1',
    this.port = 8765,
    this.deviceName,
    this.enableMdns = true,
    this.issueInitialPairCode = false,
    this.enableMirrorExporter = false,
  });

  final Directory vaultDir;
  final BlinkChannel channel;
  final String host;
  final int port;
  final String? deviceName;
  final bool enableMdns;
  final bool issueInitialPairCode;
  final bool enableMirrorExporter;
}

/// Active headless sync server handle exposing bound URI, initial pairing code,
/// and clean shutdown (`INV-07`).
final class BlinkSyncServeHandle {
  BlinkSyncServeHandle._({
    required this.vault,
    required this.server,
    required this.discovery,
    this.initialPairingCode,
  });

  final VaultManager vault;
  final DirectShelfServer server;
  final LanDiscovery discovery;
  final PairingCodeInfo? initialPairingCode;

  Uri get baseUri => server.baseUri;

  int get port => server.port;

  Future<void> stop() async {
    try {
      await discovery.dispose();
    } finally {
      try {
        await server.stop();
      } finally {
        await vault.checkpointAndClose();
      }
    }
  }
}

/// Embeddable runner backing `blink sync serve` (and quiet loopback tests).
final class BlinkSyncServeRunner {
  static Future<BlinkSyncServeHandle> start(
    BlinkSyncServeConfig config, {
    LanDiscoveryAdapter? discoveryAdapter,
    Map<String, String>? environment,
  }) async {
    final vault = await VaultManager.open(
      VaultConfig(
        vaultDir: config.vaultDir,
        expectedChannel: config.channel,
        deviceName: config.deviceName,
        enableMirrorExporter: config.enableMirrorExporter,
      ),
    );
    DirectShelfServer? server;
    LanDiscovery? discovery;
    try {
      server = DirectShelfServer(vault: vault, deviceName: config.deviceName);
      await server.start(host: config.host, port: config.port);

      final initialPair = config.issueInitialPairCode
          ? server.createPairingCode()
          : null;

      discovery = LanDiscovery(
        adapter: discoveryAdapter,
        enabled: config.enableMdns,
        environment: environment,
      );
      if (config.enableMdns) {
        final instanceName =
            'blink-${config.channel.wireValue}-${vault.localDeviceId.substring(0, 8)}';
        await discovery.startAdvertising(
          LanPeerAnnouncement(
            instanceName: instanceName,
            channel: config.channel,
            vaultId: vault.metadata.vaultId,
            deviceId: vault.localDeviceId,
            deviceName: server.deviceName,
            port: server.port,
            hostAddress: server.host,
          ),
        );
      }

      return BlinkSyncServeHandle._(
        vault: vault,
        server: server,
        discovery: discovery,
        initialPairingCode: initialPair,
      );
    } catch (_) {
      await discovery?.dispose();
      await server?.stop();
      await vault.checkpointAndClose();
      rethrow;
    }
  }
}

/// Top-level `blink` CLI command runner.
final class BlinkCliRunner {
  BlinkCliRunner({
    StringSink? stdoutSink,
    StringSink? stderrSink,
    Map<String, String>? environment,
    this._shutdownSignal,
  }) : _stdout = stdoutSink ?? stdout,
       _stderr = stderrSink ?? stderr,
       _environment = environment ?? Platform.environment {
    _runner =
        CommandRunner<int>(
          'blink',
          'BLINK headless pure-Dart CLI and multi-device sync server.',
        )..addCommand(
          SyncCommand(
            stdoutSink: _stdout,
            stderrSink: _stderr,
            environment: _environment,
            shutdownSignal: _shutdownSignal,
          ),
        );
  }

  final StringSink _stdout;
  final StringSink _stderr;
  final Map<String, String> _environment;
  final Future<void> Function()? _shutdownSignal;
  late final CommandRunner<int> _runner;

  Future<int> run(List<String> args) async {
    try {
      final result = await _runner.run(args);
      return result ?? 0;
    } on UsageException catch (error) {
      _stderr.writeln(error.message);
      _stderr.writeln(error.usage);
      return 64;
    } on BlinkException catch (error) {
      _stderr.writeln(
        jsonEncode(<String, Object?>{
          'error': error.code.wireCode,
          'message': error.message,
          'retryable': error.retryable,
        }),
      );
      return _exitCodeForBlinkError(error.code);
    } catch (error) {
      _stderr.writeln('blink cli error: $error');
      return 1;
    }
  }

  static int _exitCodeForBlinkError(BlinkErrorCode code) => switch (code) {
    BlinkErrorCode.channelMismatch || BlinkErrorCode.protocolMismatch => 2,
    BlinkErrorCode.invalidArgument => 64,
    BlinkErrorCode.notFound => 3,
    _ => 1,
  };
}

/// Parent command: `blink sync <serve|devices|revoke>`.
final class SyncCommand extends Command<int> {
  SyncCommand({
    required StringSink stdoutSink,
    required StringSink stderrSink,
    required Map<String, String> environment,
    Future<void> Function()? shutdownSignal,
  }) {
    addSubcommand(
      SyncServeCommand(
        stdoutSink: stdoutSink,
        stderrSink: stderrSink,
        environment: environment,
        shutdownSignal: shutdownSignal,
      ),
    );
    addSubcommand(
      SyncDevicesCommand(stdoutSink: stdoutSink, environment: environment),
    );
    addSubcommand(
      SyncRevokeCommand(stdoutSink: stdoutSink, environment: environment),
    );
  }

  @override
  String get name => 'sync';

  @override
  String get description =>
      'Run the headless BLINK direct sync server or manage paired sync devices.';
}

/// Subcommand: `blink sync serve --vault <dir> --host <ip> --port <port> ...`.
final class SyncServeCommand extends Command<int> {
  SyncServeCommand({
    required StringSink stdoutSink,
    required StringSink stderrSink,
    required this._environment,
    this._shutdownSignal,
  }) : _stdout = stdoutSink,
       _stderr = stderrSink {
    argParser
      ..addOption(
        'vault',
        abbr: 'v',
        help: 'Path to <BLINK_VAULT_DIR> (defaults to \$BLINK_VAULT_DIR or .local/blink-dev/vault).',
      )
      ..addOption(
        'host',
        defaultsTo: '127.0.0.1',
        help: 'Bind host address (e.g. 127.0.0.1, LAN IP, or Tailscale IP).',
      )
      ..addOption(
        'port',
        abbr: 'p',
        defaultsTo: '8765',
        help: 'TCP listen port (use 0 for an ephemeral port).',
      )
      ..addOption(
        'channel',
        allowed: const <String>['blink', 'blink-dev'],
        defaultsTo: 'blink-dev',
        help: 'Expected vault channel lock (blink or blink-dev).',
      )
      ..addOption(
        'device-name',
        help: 'Human-readable node name advertised during pairing.',
      )
      ..addFlag(
        'mdns',
        defaultsTo: true,
        negatable: true,
        help: 'Advertise _blink-sync._tcp over LAN mDNS (pass --no-mdns to disable).',
      )
      ..addFlag(
        'pair-code',
        defaultsTo: false,
        negatable: false,
        help: 'Generate and print a single-use short-lived pairing code on startup (never stored in vault).',
      );
  }

  final StringSink _stdout;
  final StringSink _stderr;
  final Map<String, String> _environment;
  final Future<void> Function()? _shutdownSignal;

  @override
  String get name => 'serve';

  @override
  String get description =>
      'Serve direct BLINK LAN/Tailscale sync endpoints over a portable vault.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final channelRaw = results['channel'] as String;
    final channel = BlinkChannel.tryParse(channelRaw);
    if (channel == null) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Unknown channel "$channelRaw"',
      );
    }

    final vaultDir = _resolveVaultDir(
      cliOption: results['vault'] as String?,
      channel: channel,
      environment: _environment,
    );
    final host = (results['host'] as String).trim();
    final port = int.tryParse((results['port'] as String).trim());
    if (host.isEmpty || port == null || port < 0 || port > 65535) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Invalid --host or --port option',
      );
    }

    final enableMdns =
        (results['mdns'] as bool) && _environment['BLINK_QUIET'] != '1';
    final issuePairCode = results['pair-code'] as bool;
    final deviceName = results['device-name'] as String?;

    final handle = await BlinkSyncServeRunner.start(
      BlinkSyncServeConfig(
        vaultDir: vaultDir,
        channel: channel,
        host: host,
        port: port,
        deviceName: deviceName,
        enableMdns: enableMdns,
        issueInitialPairCode: issuePairCode,
      ),
      environment: _environment,
    );

    try {
      final banner = <String, Object?>{
        'status': 'listening',
        'url': handle.baseUri.toString(),
        'host': handle.server.host,
        'port': handle.port,
        'channel': handle.vault.metadata.channel.wireValue,
        'vault_id': handle.vault.metadata.vaultId,
        'device_id': handle.vault.localDeviceId,
        'device_name': handle.server.deviceName,
        'protocol_version': currentSyncProtocolVersion,
        'mdns_enabled': enableMdns,
        if (handle.initialPairingCode != null) ...<String, Object?>{
          'pairing_code': handle.initialPairingCode!.code,
          'pairing_code_expires_utc': handle.initialPairingCode!.expiresAtUtc
              .toIso8601String(),
        },
      };
      _stdout.writeln(jsonEncode(banner));
      if (identical(_stdout, stdout)) {
        await stdout.flush();
      }

      if (_shutdownSignal != null) {
        await _shutdownSignal();
      } else {
        await _waitForProcessTerminationSignal();
      }
      return 0;
    } catch (error) {
      _stderr.writeln('sync serve interrupted: $error');
      rethrow;
    } finally {
      await handle.stop();
    }
  }
}

/// Subcommand: `blink sync devices --vault <dir> [--channel blink|blink-dev]`.
final class SyncDevicesCommand extends Command<int> {
  SyncDevicesCommand({
    required StringSink stdoutSink,
    required this._environment,
  }) : _stdout = stdoutSink {
    argParser
      ..addOption('vault', abbr: 'v', help: 'Path to <BLINK_VAULT_DIR>.')
      ..addOption(
        'channel',
        allowed: const <String>['blink', 'blink-dev'],
        defaultsTo: 'blink-dev',
        help: 'Expected vault channel lock.',
      );
  }

  final StringSink _stdout;
  final Map<String, String> _environment;

  @override
  String get name => 'devices';

  @override
  String get description => 'List paired sync devices registered in a vault.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final channel = BlinkChannel.tryParse(results['channel'] as String)!;
    final vaultDir = _resolveVaultDir(
      cliOption: results['vault'] as String?,
      channel: channel,
      environment: _environment,
    );
    final vault = await VaultManager.open(
      VaultConfig(
        vaultDir: vaultDir,
        expectedChannel: channel,
        enableMirrorExporter: false,
      ),
    );
    try {
      final devices = await vault.syncEngine.listDevices();
      _stdout.writeln(
        jsonEncode(<String, Object?>{
          'devices': devices
              .map((d) => d.toPublicJson())
              .toList(growable: false),
        }),
      );
      return 0;
    } finally {
      await vault.checkpointAndClose();
    }
  }
}

/// Subcommand: `blink sync revoke --vault <dir> --device-id <id> [--channel blink|blink-dev]`.
final class SyncRevokeCommand extends Command<int> {
  SyncRevokeCommand({
    required StringSink stdoutSink,
    required this._environment,
  }) : _stdout = stdoutSink {
    argParser
      ..addOption('vault', abbr: 'v', help: 'Path to <BLINK_VAULT_DIR>.')
      ..addOption(
        'device-id',
        mandatory: true,
        help: 'Device ID to revoke immediately.',
      )
      ..addOption(
        'channel',
        allowed: const <String>['blink', 'blink-dev'],
        defaultsTo: 'blink-dev',
        help: 'Expected vault channel lock.',
      );
  }

  final StringSink _stdout;
  final Map<String, String> _environment;

  @override
  String get name => 'revoke';

  @override
  String get description =>
      'Revoke a paired sync device token hash in a vault.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final channel = BlinkChannel.tryParse(results['channel'] as String)!;
    final deviceId = (results['device-id'] as String).trim();
    final vaultDir = _resolveVaultDir(
      cliOption: results['vault'] as String?,
      channel: channel,
      environment: _environment,
    );
    final vault = await VaultManager.open(
      VaultConfig(
        vaultDir: vaultDir,
        expectedChannel: channel,
        enableMirrorExporter: false,
      ),
    );
    try {
      final revoked = await vault.syncEngine.revokeDevice(deviceId);
      if (!revoked) {
        throw BlinkException(
          code: BlinkErrorCode.notFound,
          message: 'Device $deviceId not found',
        );
      }
      _stdout.writeln(
        jsonEncode(<String, Object?>{'revoked': true, 'device_id': deviceId}),
      );
      return 0;
    } finally {
      await vault.checkpointAndClose();
    }
  }
}

Directory _resolveVaultDir({
  required String? cliOption,
  required BlinkChannel channel,
  required Map<String, String> environment,
}) {
  final raw = cliOption?.trim();
  if (raw != null && raw.isNotEmpty) {
    return Directory(raw);
  }
  final envDir = environment['BLINK_VAULT_DIR']?.trim();
  if (envDir != null && envDir.isNotEmpty) {
    return Directory(envDir);
  }
  if (channel == BlinkChannel.blinkDev) {
    return Directory(
      p.join(Directory.current.path, '.local', 'blink-dev', 'vault'),
    );
  }
  throw BlinkException(
    code: BlinkErrorCode.invalidArgument,
    message: 'Production channel "blink" requires explicit --vault <dir> or \$BLINK_VAULT_DIR',
  );
}

Future<void> _waitForProcessTerminationSignal() async {
  final completer = Completer<void>();
  StreamSubscription<ProcessSignal>? sigIntSub;
  StreamSubscription<ProcessSignal>? sigTermSub;

  void finish() {
    if (!completer.isCompleted) {
      completer.complete();
    }
  }

  sigIntSub = ProcessSignal.sigint.watch().listen((_) => finish());
  if (!Platform.isWindows) {
    sigTermSub = ProcessSignal.sigterm.watch().listen((_) => finish());
  }

  try {
    await completer.future;
  } finally {
    await sigIntSub.cancel();
    await sigTermSub?.cancel();
  }
}

import 'dart:io';

import 'package:mdns_dart/mdns_dart.dart';
import 'package:meta/meta.dart';

import '../models/blink_models.dart';
import 'sync_models.dart';

/// mDNS service type advertised by BLINK desktop nodes and headless `blink sync serve`.
const String blinkSyncMdnsServiceType = '_blink-sync._tcp';

/// Metadata advertised over LAN mDNS (`_blink-sync._tcp`, channel-isolated per `INV-06`).
@immutable
final class LanPeerAnnouncement {
  const LanPeerAnnouncement({
    required this.instanceName,
    required this.channel,
    required this.vaultId,
    required this.deviceId,
    required this.deviceName,
    required this.port,
    this.protocolVersion = currentSyncProtocolVersion,
    this.hostAddress,
  });

  final String instanceName;
  final BlinkChannel channel;
  final String vaultId;
  final String deviceId;
  final String deviceName;
  final int port;
  final int protocolVersion;
  final String? hostAddress;

  Map<String, String> toTxtMap() => <String, String>{
    'channel': channel.wireValue,
    'vault_id': vaultId,
    'device_id': deviceId,
    'device_name': deviceName,
    'proto': protocolVersion.toString(),
  };

  List<String> toTxtRecords() => MDNSService.createTXTRecords(toTxtMap());
}

/// Discovered BLINK LAN sync peer parsed from mDNS SRV + A/AAAA + TXT records.
@immutable
final class DiscoveredLanPeer {
  const DiscoveredLanPeer({
    required this.instanceName,
    required this.host,
    required this.port,
    required this.channel,
    required this.vaultId,
    required this.deviceId,
    required this.deviceName,
    required this.protocolVersion,
  });

  final String instanceName;
  final String host;
  final int port;
  final BlinkChannel channel;
  final String vaultId;
  final String deviceId;
  final String deviceName;
  final int protocolVersion;

  Uri get baseUri {
    final formattedHost = host.contains(':') ? '[$host]' : host;
    return Uri.parse('http://$formattedHost:$port');
  }

  /// Parses an `mdns_dart` [ServiceEntry] strictly enforcing [expectedChannel] (`INV-06`)
  /// and protocol version compatibility.
  static DiscoveredLanPeer? tryFromServiceEntry(
    ServiceEntry entry, {
    required BlinkChannel expectedChannel,
    int expectedProtocolVersion = currentSyncProtocolVersion,
  }) {
    final addr = entry.primaryAddress;
    if (addr == null || entry.port <= 0) {
      return null;
    }
    final txt = MDNSService.parseTXTRecords(entry.infoFields);
    final channel = BlinkChannel.tryParse(txt['channel']);
    final proto = int.tryParse(txt['proto'] ?? '');
    final vaultId = txt['vault_id'] ?? '';
    final deviceId = txt['device_id'] ?? '';
    final deviceName = txt['device_name'] ?? entry.name;
    if (channel != expectedChannel ||
        proto != expectedProtocolVersion ||
        vaultId.isEmpty ||
        deviceId.isEmpty) {
      return null;
    }
    return DiscoveredLanPeer(
      instanceName: entry.name,
      host: addr.address,
      port: entry.port,
      channel: channel!,
      vaultId: vaultId,
      deviceId: deviceId,
      deviceName: deviceName,
      protocolVersion: proto!,
    );
  }
}

/// Pluggable adapter behind [LanDiscovery] so automated quiet tests never touch
/// real LAN multicast sockets (`docs/dev-rules/engineering.md#quiet-tests`).
abstract interface class LanDiscoveryAdapter {
  Future<void> startAdvertising(LanPeerAnnouncement announcement);

  Future<void> stopAdvertising();

  Future<List<DiscoveredLanPeer>> discover({
    required BlinkChannel expectedChannel,
    Duration timeout = const Duration(milliseconds: 800),
  });

  Future<void> dispose();
}

/// Zero-socket no-op adapter used when `--no-mdns` or `BLINK_QUIET=1` is active.
final class NoopLanDiscoveryAdapter implements LanDiscoveryAdapter {
  const NoopLanDiscoveryAdapter();

  @override
  Future<void> startAdvertising(LanPeerAnnouncement announcement) async {}

  @override
  Future<void> stopAdvertising() async {}

  @override
  Future<List<DiscoveredLanPeer>> discover({
    required BlinkChannel expectedChannel,
    Duration timeout = const Duration(milliseconds: 800),
  }) async => const <DiscoveredLanPeer>[];

  @override
  Future<void> dispose() async {}
}

/// Deterministic in-memory adapter for quiet unit tests covering channel isolation
/// and TXT record round-tripping without real LAN broadcasts.
final class InMemoryLanDiscoveryAdapter implements LanDiscoveryAdapter {
  InMemoryLanDiscoveryAdapter({List<LanPeerAnnouncement>? sharedRegistry})
    : _registry = sharedRegistry ?? <LanPeerAnnouncement>[];

  final List<LanPeerAnnouncement> _registry;
  LanPeerAnnouncement? _current;

  @override
  Future<void> startAdvertising(LanPeerAnnouncement announcement) async {
    await stopAdvertising();
    _current = announcement;
    _registry.add(announcement);
  }

  @override
  Future<void> stopAdvertising() async {
    if (_current != null) {
      _registry.remove(_current);
      _current = null;
    }
  }

  @override
  Future<List<DiscoveredLanPeer>> discover({
    required BlinkChannel expectedChannel,
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    final results = <DiscoveredLanPeer>[];
    for (final item in _registry) {
      final addr =
          InternetAddress.tryParse(item.hostAddress ?? '127.0.0.1') ??
          InternetAddress.loopbackIPv4;
      final synthetic = ServiceEntry(
        name: item.instanceName,
        host: '${item.instanceName}.local.',
        addrsV4: <InternetAddress>[addr],
        port: item.port,
        infoFields: item.toTxtRecords(),
      );
      final parsed = DiscoveredLanPeer.tryFromServiceEntry(
        synthetic,
        expectedChannel: expectedChannel,
      );
      if (parsed != null) {
        results.add(parsed);
      }
    }
    return results;
  }

  @override
  Future<void> dispose() => stopAdvertising();
}

/// Production pure-Dart mDNS adapter backed by `mdns_dart 2.2.2` (MIT, zero Flutter deps).
final class MdnsDartDiscoveryAdapter implements LanDiscoveryAdapter {
  MDNSServer? _server;

  @override
  Future<void> startAdvertising(LanPeerAnnouncement announcement) async {
    await stopAdvertising();
    List<InternetAddress>? explicitIps;
    if (announcement.hostAddress != null &&
        announcement.hostAddress!.isNotEmpty) {
      final parsed = InternetAddress.tryParse(announcement.hostAddress!);
      if (parsed != null &&
          parsed != InternetAddress.anyIPv4 &&
          parsed != InternetAddress.anyIPv6) {
        explicitIps = <InternetAddress>[parsed];
      }
    }
    final service = await MDNSService.create(
      instance: announcement.instanceName,
      service: blinkSyncMdnsServiceType,
      port: announcement.port,
      ips: explicitIps,
      txt: announcement.toTxtRecords(),
    );
    final server = MDNSServer(MDNSServerConfig(zone: service));
    await server.start();
    _server = server;
  }

  @override
  Future<void> stopAdvertising() async {
    final server = _server;
    _server = null;
    if (server != null) {
      await server.stop();
    }
  }

  @override
  Future<List<DiscoveredLanPeer>> discover({
    required BlinkChannel expectedChannel,
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    final entries = await MDNSClient.discover(
      blinkSyncMdnsServiceType,
      timeout: timeout,
    );
    final peers = <DiscoveredLanPeer>[];
    final seenDeviceIds = <String>{};
    for (final entry in entries) {
      final peer = DiscoveredLanPeer.tryFromServiceEntry(
        entry,
        expectedChannel: expectedChannel,
      );
      if (peer != null && seenDeviceIds.add(peer.deviceId)) {
        peers.add(peer);
      }
    }
    return peers;
  }

  @override
  Future<void> dispose() => stopAdvertising();
}

/// High-level LAN discovery facade honoring `BLINK_QUIET=1` and `--no-mdns`.
final class LanDiscovery {
  LanDiscovery({
    LanDiscoveryAdapter? adapter,
    bool enabled = true,
    Map<String, String>? environment,
  }) : _adapter = _selectAdapter(
         adapter: adapter,
         enabled: enabled,
         environment: environment,
       );

  final LanDiscoveryAdapter _adapter;
  bool _advertising = false;

  bool get isAdvertising => _advertising;

  Future<void> startAdvertising(LanPeerAnnouncement announcement) async {
    await _adapter.startAdvertising(announcement);
    _advertising = true;
  }

  Future<void> stopAdvertising() async {
    await _adapter.stopAdvertising();
    _advertising = false;
  }

  Future<List<DiscoveredLanPeer>> discover({
    required BlinkChannel expectedChannel,
    Duration timeout = const Duration(milliseconds: 800),
  }) => _adapter.discover(expectedChannel: expectedChannel, timeout: timeout);

  Future<void> dispose() async {
    await _adapter.dispose();
    _advertising = false;
  }

  static LanDiscoveryAdapter _selectAdapter({
    required LanDiscoveryAdapter? adapter,
    required bool enabled,
    required Map<String, String>? environment,
  }) {
    if (!enabled) {
      return const NoopLanDiscoveryAdapter();
    }
    if (adapter != null) {
      return adapter;
    }
    final env = environment ?? Platform.environment;
    if (env['BLINK_QUIET'] == '1') {
      return const NoopLanDiscoveryAdapter();
    }
    return MdnsDartDiscoveryAdapter();
  }
}

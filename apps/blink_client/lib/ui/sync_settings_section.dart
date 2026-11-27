import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/sync_controller.dart';

/// Flat hairline-grouped Multi-Device Sync settings section (`docs/ui.md` §4.4):
/// - Desktop Embedded Direct Sync Host (toggle, port/LAN+Tailscale IPs,
///   one-time pairing code, paired devices & revoke)
/// - Direct Peer Pairing & LAN Discovery (auto-sync toggle, scan LAN peers,
///   manual URL/code pair, manual Sync Now)
/// - E2EE WebDAV / S3 Async Relay (protocol, endpoint/bucket/credentials,
///   recovery key generate/export/import, `#private` relay exclusion ON)
class BlinkSyncSettingsSection extends StatefulWidget {
  const BlinkSyncSettingsSection({
    required this.sync,
    required this.isMobilePlatform,
    required this.compactPadding,
    required this.labelWidth,
    this.onOpenConflicts,
    super.key,
  });

  final BlinkSyncController sync;
  final bool isMobilePlatform;
  final bool compactPadding;
  final double labelWidth;
  final VoidCallback? onOpenConflicts;

  @override
  State<BlinkSyncSettingsSection> createState() =>
      _BlinkSyncSettingsSectionState();
}

class _BlinkSyncSettingsSectionState extends State<BlinkSyncSettingsSection> {
  final TextEditingController _hostPortController = TextEditingController();
  final TextEditingController _peerUrlController = TextEditingController();
  final TextEditingController _pairingCodeController = TextEditingController();
  final TextEditingController _relayEndpointController =
      TextEditingController();
  final TextEditingController _relayUsernameController =
      TextEditingController();
  final TextEditingController _relayPasswordController =
      TextEditingController();
  final TextEditingController _relayBearerController = TextEditingController();
  final TextEditingController _relayBucketController = TextEditingController();
  final TextEditingController _relayRegionController = TextEditingController();
  final TextEditingController _relayPrefixController = TextEditingController();
  final TextEditingController _relayAccessKeyController =
      TextEditingController();
  final TextEditingController _relaySecretKeyController =
      TextEditingController();
  final TextEditingController _importRecoveryController =
      TextEditingController();

  RelayProtocol _selectedRelayProtocol = RelayProtocol.webdav;
  bool _relayUsePathStyle = true;
  String? _revealedRecoveryCode;
  String? _inlineNotice;
  bool _inlineNoticeIsError = false;
  bool _busyAction = false;

  @override
  void initState() {
    super.initState();
    _syncControllersFromConfig();
  }

  void _syncControllersFromConfig() {
    final cfg = widget.sync.config;
    _hostPortController.text = cfg.desktopServerPort.toString();
    _peerUrlController.text = cfg.directPeerUrl ?? '';
    _relayEndpointController.text = cfg.relayEndpoint ?? '';
    _relayUsernameController.text = cfg.relayUsername ?? '';
    _relayBucketController.text = cfg.relayBucket ?? '';
    _relayRegionController.text = cfg.relayRegion;
    _relayPrefixController.text = cfg.relayKeyPrefix;
    _selectedRelayProtocol = cfg.relayProtocol;
    _relayUsePathStyle = cfg.relayUsePathStyle;
  }

  @override
  void dispose() {
    _hostPortController.dispose();
    _peerUrlController.dispose();
    _pairingCodeController.dispose();
    _relayEndpointController.dispose();
    _relayUsernameController.dispose();
    _relayPasswordController.dispose();
    _relayBearerController.dispose();
    _relayBucketController.dispose();
    _relayRegionController.dispose();
    _relayPrefixController.dispose();
    _relayAccessKeyController.dispose();
    _relaySecretKeyController.dispose();
    _importRecoveryController.dispose();
    super.dispose();
  }

  void _setNotice(String message, {bool isError = false}) {
    if (!mounted) {
      return;
    }
    setState(() {
      _inlineNotice = message;
      _inlineNoticeIsError = isError;
    });
  }

  Future<void> _copyText(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    _setNotice('已复制 $label 到剪贴板。');
  }

  Future<void> _toggleDesktopHost(bool enabled) async {
    setState(() => _busyAction = true);
    try {
      final parsedPort =
          int.tryParse(_hostPortController.text.trim()) ??
          kDefaultDirectSyncPort;
      final ok = await widget.sync.setDesktopServerEnabled(
        enabled,
        port: parsedPort,
      );
      if (ok) {
        _setNotice(enabled ? '桌面直连同步服务已启动。' : '桌面直连同步服务已停止。');
      } else {
        _setNotice(
          widget.sync.lastErrorMessage ?? '无法切换桌面同步服务状态。',
          isError: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busyAction = false);
      }
    }
  }

  Future<void> _pairDirectPeer() async {
    setState(() => _busyAction = true);
    try {
      final res = await widget.sync.pairWithDirectPeer(
        baseUrl: _peerUrlController.text,
        pairingCode: _pairingCodeController.text,
      );
      if (res != null) {
        _pairingCodeController.clear();
        _setNotice('配对成功，设备令牌已安全写入系统密钥库并完成首次同步。');
      } else {
        _setNotice(
          widget.sync.lastErrorMessage ?? '配对失败，请检查地址和配对码。',
          isError: true,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busyAction = false);
      }
    }
  }

  Future<void> _saveRelaySettings({bool? enabledOverride}) async {
    setState(() => _busyAction = true);
    try {
      final enabled = enabledOverride ?? widget.sync.config.relayEnabled;
      final ok = await widget.sync.saveRelayConfiguration(
        enabled: enabled,
        protocol: _selectedRelayProtocol,
        endpoint: _relayEndpointController.text,
        username: _relayUsernameController.text,
        password: _relayPasswordController.text.isNotEmpty
            ? _relayPasswordController.text
            : null,
        bearerToken: _relayBearerController.text.isNotEmpty
            ? _relayBearerController.text
            : null,
        bucket: _relayBucketController.text,
        region: _relayRegionController.text,
        keyPrefix: _relayPrefixController.text,
        usePathStyle: _relayUsePathStyle,
        accessKeyId: _relayAccessKeyController.text.isNotEmpty
            ? _relayAccessKeyController.text
            : null,
        secretAccessKey: _relaySecretKeyController.text.isNotEmpty
            ? _relaySecretKeyController.text
            : null,
      );
      if (ok) {
        // Clear plaintext secret inputs after persisting into OS SecretStore.
        _relayPasswordController.clear();
        _relayBearerController.clear();
        _relayAccessKeyController.clear();
        _relaySecretKeyController.clear();
        _setNotice('E2EE 异步中继配置已保存（凭据仅存系统安全密钥库，便携库零凭据）。');
      } else {
        _setNotice(widget.sync.lastErrorMessage ?? '保存中继配置失败。', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _busyAction = false);
      }
    }
  }

  Future<void> _generateMasterKey() async {
    setState(() => _busyAction = true);
    try {
      final recoveryCode = await widget.sync.generateAndStoreRelayMasterKey();
      if (mounted) {
        setState(() => _revealedRecoveryCode = recoveryCode);
      }
      _setNotice('已生成 256 位主同步密钥并存入系统安全密钥库，请妥善抄录或复制恢复码。');
    } catch (_) {
      _setNotice('生成主同步密钥失败。', isError: true);
    } finally {
      if (mounted) {
        setState(() => _busyAction = false);
      }
    }
  }

  Future<void> _exportRecoveryCode() async {
    final code = await widget.sync.exportRelayRecoveryCode();
    if (!mounted) {
      return;
    }
    if (code == null) {
      _setNotice('尚未生成 E2EE 主同步密钥，请先点击“生成主密钥”。', isError: true);
      return;
    }
    setState(() => _revealedRecoveryCode = code);
  }

  Future<void> _importRecoveryCode() async {
    setState(() => _busyAction = true);
    try {
      final ok = await widget.sync.importRelayRecoveryCode(
        _importRecoveryController.text,
      );
      if (ok) {
        _importRecoveryController.clear();
        _revealedRecoveryCode = null;
        _setNotice('已验证并导入 E2EE 主同步密钥至系统安全密钥库。');
      } else {
        _setNotice(widget.sync.lastErrorMessage ?? '恢复码校验失败。', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _busyAction = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final pad = widget.compactPadding ? 16.0 : 20.0;

    return ListenableBuilder(
      listenable: widget.sync,
      builder: (context, _) {
        final cfg = widget.sync.config;
        final activeCode = widget.sync.activePairingCode;

        return Card(
          key: const Key('sync_settings_section'),
          child: Padding(
            padding: EdgeInsets.all(pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '多端同步（直连与异步中继）',
                        style: BlinkTypography.sectionHeading(tokens),
                      ),
                    ),
                    if (widget.sync.openConflictCount > 0 &&
                        widget.onOpenConflicts != null)
                      OutlinedButton.icon(
                        key: const Key('sync_settings_conflicts_button'),
                        onPressed: widget.onOpenConflicts,
                        icon: Icon(
                          Icons.compare_arrows_rounded,
                          size: 16,
                          color: tokens.statusErr,
                        ),
                        label: Text(
                          '处理冲突 (${widget.sync.openConflictCount})',
                          style: BlinkTypography.metaLabel(
                            tokens,
                            color: tokens.statusErr,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                _buildSummaryRow(tokens),
                if (widget.sync.recoveredCorruptSyncSettings) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    '检测到损坏的 sync.json，已改名保留原文件并恢复默认同步配置。',
                    key: const Key('corrupt_sync_settings_notice'),
                    style: BlinkTypography.metaLabel(
                      tokens,
                      color: tokens.statusWarn,
                    ),
                  ),
                ],
                if (widget.sync.lastErrorMessage != null) ...<Widget>[
                  const SizedBox(height: 10),
                  _InlineNoticeBox(
                    key: const Key('sync_error_notice'),
                    message: widget.sync.lastErrorMessage!,
                    isError:
                        widget.sync.uiStatus != BlinkSyncUiStatus.peerAsleep &&
                        widget.sync.uiStatus !=
                            BlinkSyncUiStatus.privacyBlocked,
                    accentOverride:
                        widget.sync.uiStatus == BlinkSyncUiStatus.privacyBlocked
                        ? tokens.privacyPrivate
                        : (widget.sync.uiStatus == BlinkSyncUiStatus.peerAsleep
                              ? tokens.statusWarn
                              : null),
                  ),
                ],
                if (_inlineNotice != null) ...<Widget>[
                  const SizedBox(height: 10),
                  _InlineNoticeBox(
                    key: const Key('sync_action_notice'),
                    message: _inlineNotice!,
                    isError: _inlineNoticeIsError,
                  ),
                ],

                // -----------------------------------------------------------
                // Subsection A: Desktop Embedded Direct Sync Host
                // -----------------------------------------------------------
                if (!widget.isMobilePlatform) ...<Widget>[
                  const SizedBox(height: 16),
                  Divider(height: 1, color: tokens.borderHairline),
                  const SizedBox(height: 14),
                  Text(
                    '桌面内嵌直连同步服务（局域网 / Tailscale）',
                    style: BlinkTypography.controlLabel(tokens),
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    key: const Key('sync_host_toggle'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '开启桌面内嵌直连同步服务',
                      style: BlinkTypography.body(tokens),
                    ),
                    subtitle: Text(
                      widget.sync.isHostRunning
                          ? '服务运行中 · 端口 ${widget.sync.activeServerPort}'
                                '${widget.sync.isLanAdvertising ? ' · mDNS 局域网广播已开启' : ' · 安静/无广播模式'}'
                          : '开启后可供手机端与其他设备经局域网或 Tailscale 直连高速同步（含 #private）',
                      style: BlinkTypography.metaLabel(tokens),
                    ),
                    value: widget.sync.isHostRunning,
                    onChanged: _busyAction ? null : _toggleDesktopHost,
                  ),
                  Row(
                    children: <Widget>[
                      SizedBox(
                        width: 140,
                        child: TextField(
                          key: const Key('sync_host_port_input'),
                          controller: _hostPortController,
                          keyboardType: TextInputType.number,
                          style: BlinkTypography.monoValue(
                            tokens,
                            tabular: true,
                          ),
                          decoration: InputDecoration(
                            labelText: '监听端口',
                            isDense: true,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      if (widget.sync.isHostRunning)
                        OutlinedButton.icon(
                          key: const Key('sync_generate_pairing_code_button'),
                          onPressed: () {
                            widget.sync.generatePairingCode();
                          },
                          icon: const Icon(Icons.key_outlined, size: 16),
                          label: const Text('生成一次性配对码'),
                        ),
                    ],
                  ),
                  if (widget.sync.isHostRunning) ...<Widget>[
                    const SizedBox(height: 10),
                    _KeyValueRow(
                      label: '本机同步地址',
                      labelWidth: widget.labelWidth,
                      value: widget.sync.localHostAddresses
                          .map(
                            (ip) =>
                                'http://$ip:${widget.sync.activeServerPort}',
                          )
                          .join('\n'),
                      valueKey: const Key('sync_host_addresses'),
                      mono: true,
                    ),
                    if (activeCode != null) ...<Widget>[
                      const SizedBox(height: 8),
                      Container(
                        key: const Key('sync_active_pairing_code'),
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: tokens.accentSubtle,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: tokens.borderHairline),
                        ),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    '一次性配对码（5 分钟有效 · 仅内存持有）',
                                    style: BlinkTypography.metaLabel(
                                      tokens,
                                      color: tokens.accentPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  SelectableText(
                                    activeCode.code,
                                    style: BlinkTypography.monoValue(
                                      tokens,
                                      tabular: true,
                                    ).copyWith(fontSize: 18),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: '复制配对码',
                              onPressed: () =>
                                  _copyText(activeCode.code, '一次性配对码'),
                              icon: Icon(
                                Icons.copy_rounded,
                                size: 18,
                                color: tokens.accentPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Text(
                        '已配对设备（${widget.sync.pairedDevices.length}）',
                        style: BlinkTypography.metaLabel(tokens),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () =>
                            unawaited(widget.sync.refreshPairedDevices()),
                        child: const Text('刷新列表'),
                      ),
                    ],
                  ),
                  if (widget.sync.pairedDevices.isEmpty)
                    Text(
                      '暂无已配对设备（服务端仅保存令牌 SHA-256 哈希，不保存明文令牌）。',
                      style: BlinkTypography.metaLabel(
                        tokens,
                        color: tokens.textMuted,
                      ),
                    )
                  else
                    Column(
                      key: const Key('sync_paired_devices_list'),
                      children: <Widget>[
                        for (final device in widget.sync.pairedDevices)
                          Container(
                            margin: const EdgeInsets.only(top: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: tokens.sidebar,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: tokens.borderHairline),
                            ),
                            child: Row(
                              children: <Widget>[
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        device.deviceName,
                                        style: BlinkTypography.controlLabel(
                                          tokens,
                                        ),
                                      ),
                                      Text(
                                        '${device.deviceId.length > 12 ? device.deviceId.substring(0, 12) : device.deviceId}… · '
                                        '${device.isRevoked ? '已吊销' : '正常'}',
                                        style: BlinkTypography.metaLabel(
                                          tokens,
                                          color: device.isRevoked
                                              ? tokens.statusErr
                                              : tokens.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                if (!device.isRevoked)
                                  TextButton(
                                    key: Key(
                                      'sync_revoke_device_${device.deviceId}',
                                    ),
                                    style: TextButton.styleFrom(
                                      foregroundColor: tokens.statusErr,
                                    ),
                                    onPressed: () async {
                                      await widget.sync.revokePairedDevice(
                                        device.deviceId,
                                      );
                                      _setNotice(
                                        '已吊销设备 ${device.deviceName} 的同步权限。',
                                      );
                                    },
                                    child: const Text('吊销'),
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                ],

                // -----------------------------------------------------------
                // Subsection B: Direct Peer Pairing & LAN Discovery
                // -----------------------------------------------------------
                const SizedBox(height: 16),
                Divider(height: 1, color: tokens.borderHairline),
                const SizedBox(height: 14),
                Text(
                  '直连节点配对与局域网发现',
                  style: BlinkTypography.controlLabel(tokens),
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  key: const Key('sync_auto_toggle'),
                  contentPadding: EdgeInsets.zero,
                  title: Text('启用自动同步', style: BlinkTypography.body(tokens)),
                  subtitle: Text(
                    '启动、切回前台、写入防抖、局域网发现与对端 SSE 唤醒时在后台自动同步，不阻塞本地 0ms 写作',
                    style: BlinkTypography.metaLabel(tokens),
                  ),
                  value: cfg.autoSyncEnabled,
                  onChanged: (val) =>
                      unawaited(widget.sync.setAutoSyncEnabled(val)),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    OutlinedButton.icon(
                      key: const Key('sync_settings_sync_now_button'),
                      onPressed:
                          widget.sync.isConfigured && !widget.sync.isSyncing
                          ? () => unawaited(widget.sync.syncNow(manual: true))
                          : null,
                      icon: const Icon(Icons.sync_rounded, size: 16),
                      label: const Text('立即同步'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('sync_discover_lan_button'),
                      onPressed: widget.sync.isDiscoveringPeers
                          ? null
                          : () => unawaited(widget.sync.discoverLanPeers()),
                      icon: const Icon(Icons.radar_rounded, size: 16),
                      label: Text(
                        widget.sync.isDiscoveringPeers ? '扫描局域网中…' : '扫描局域网设备',
                      ),
                    ),
                  ],
                ),
                if (widget.sync.discoveredPeers.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 10),
                  Column(
                    key: const Key('sync_discovered_peers_list'),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        '发现的同通道局域网节点（点击填入地址）：',
                        style: BlinkTypography.metaLabel(tokens),
                      ),
                      const SizedBox(height: 4),
                      for (final peer in widget.sync.discoveredPeers)
                        InkWell(
                          key: Key('sync_discovered_peer_${peer.deviceId}'),
                          borderRadius: BorderRadius.circular(8),
                          onTap: () {
                            _peerUrlController.text = peer.baseUri.toString();
                            _setNotice('已填入局域网节点 ${peer.deviceName} 的地址。');
                          },
                          child: Container(
                            margin: const EdgeInsets.only(top: 4),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: tokens.sidebar,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: tokens.borderHairline),
                            ),
                            child: Row(
                              children: <Widget>[
                                Icon(
                                  Icons.computer_rounded,
                                  size: 16,
                                  color: tokens.accentPrimary,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    '${peer.deviceName} · ${peer.baseUri}',
                                    style: BlinkTypography.monoValue(tokens),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
                if (widget.sync.isDirectConfigured) ...<Widget>[
                  const SizedBox(height: 10),
                  Container(
                    key: const Key('sync_paired_peer_summary'),
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: tokens.sidebar,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: tokens.borderHairline),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '已配对直连节点：${cfg.directPeerDeviceName ?? cfg.directPeerUrl}',
                          style: BlinkTypography.controlLabel(tokens),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          cfg.directPeerUrl ?? '',
                          style: BlinkTypography.monoValue(tokens),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '设备令牌已加密保存于操作系统原生安全密钥库，便携库零凭据（INV-08）。',
                          style: BlinkTypography.metaLabel(
                            tokens,
                            color: tokens.statusOk,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            key: const Key('sync_disconnect_peer_button'),
                            style: TextButton.styleFrom(
                              foregroundColor: tokens.statusErr,
                            ),
                            onPressed: () async {
                              await widget.sync.disconnectDirectPeer();
                              _peerUrlController.clear();
                              _setNotice('已断开直连节点并从系统密钥库移除设备令牌。');
                            },
                            child: const Text('断开配对'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                TextField(
                  key: const Key('sync_peer_url_input'),
                  controller: _peerUrlController,
                  style: BlinkTypography.monoValue(tokens),
                  decoration: InputDecoration(
                    labelText: '桌面 / 无头节点地址（局域网或 Tailscale）',
                    hintText: 'http://192.168.1.10:48231',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: TextField(
                        key: const Key('sync_pairing_code_input'),
                        controller: _pairingCodeController,
                        style: BlinkTypography.monoValue(tokens),
                        decoration: InputDecoration(
                          labelText: '一次性配对码',
                          hintText: 'XXXX-XXXX',
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      key: const Key('sync_pair_button'),
                      onPressed: _busyAction ? null : _pairDirectPeer,
                      child: const Text('配对并同步'),
                    ),
                  ],
                ),

                // -----------------------------------------------------------
                // Subsection C: E2EE WebDAV / S3 Async Relay
                // -----------------------------------------------------------
                const SizedBox(height: 16),
                Divider(height: 1, color: tokens.borderHairline),
                const SizedBox(height: 14),
                Text(
                  'E2EE WebDAV / S3 异步中继（主力电脑休眠时可用）',
                  style: BlinkTypography.controlLabel(tokens),
                ),
                const SizedBox(height: 4),
                SwitchListTile(
                  key: const Key('sync_relay_toggle'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    '启用 E2EE 异步中继',
                    style: BlinkTypography.body(tokens),
                  ),
                  subtitle: Text(
                    '采用 XChaCha20-Poly1305 客户端端到端加密，仅上传不可变密文段，永不上传活库 blink.db',
                    style: BlinkTypography.metaLabel(tokens),
                  ),
                  value: cfg.relayEnabled,
                  onChanged: _busyAction
                      ? null
                      : (val) => _saveRelaySettings(enabledOverride: val),
                ),
                Material(
                  color: tokens.privacySubtle,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(color: tokens.borderHairline),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: SwitchListTile(
                      key: const Key('sync_exclude_private_relay_toggle'),
                      contentPadding: EdgeInsets.zero,
                      secondary: Icon(
                        Icons.lock_outline_rounded,
                        size: 18,
                        color: tokens.privacyPrivate,
                      ),
                      title: Text(
                        '禁止通过 WebDAV/S3 中继 #private',
                        style: BlinkTypography.controlLabel(tokens)
                            .copyWith(color: tokens.privacyPrivate),
                      ),
                      subtitle: Text(
                        '默认开启：所有 #private 记录与附件 0 字节发往云端中继，仅经局域网或 Tailscale 直连同步（INV-03）',
                        style: BlinkTypography.metaLabel(tokens),
                      ),
                      value: cfg.excludePrivateFromRelay,
                      onChanged: (val) => unawaited(
                        widget.sync.setExcludePrivateFromRelay(val),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<RelayProtocol>(
                    key: const Key('sync_relay_protocol_toggle'),
                    showSelectedIcon: false,
                    segments: const <ButtonSegment<RelayProtocol>>[
                      ButtonSegment<RelayProtocol>(
                        value: RelayProtocol.webdav,
                        label: Text('WebDAV'),
                      ),
                      ButtonSegment<RelayProtocol>(
                        value: RelayProtocol.s3,
                        label: Text('S3 兼容'),
                      ),
                    ],
                    selected: <RelayProtocol>{_selectedRelayProtocol},
                    onSelectionChanged: (selection) {
                      if (selection.isNotEmpty) {
                        setState(
                          () => _selectedRelayProtocol = selection.first,
                        );
                      }
                    },
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  key: const Key('sync_relay_endpoint_input'),
                  controller: _relayEndpointController,
                  style: BlinkTypography.monoValue(tokens),
                  decoration: InputDecoration(
                    labelText: _selectedRelayProtocol == RelayProtocol.webdav
                        ? 'WebDAV 目录地址'
                        : 'S3 Endpoint 地址',
                    hintText: _selectedRelayProtocol == RelayProtocol.webdav
                        ? 'https://dav.example.com/blink/'
                        : 'https://s3.example.com',
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                if (_selectedRelayProtocol == RelayProtocol.webdav) ...<Widget>[
                  TextField(
                    key: const Key('sync_relay_username_input'),
                    controller: _relayUsernameController,
                    style: BlinkTypography.body(tokens),
                    decoration: InputDecoration(
                      labelText: 'WebDAV 用户名（可选）',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('sync_relay_password_input'),
                    controller: _relayPasswordController,
                    obscureText: true,
                    style: BlinkTypography.body(tokens),
                    decoration: InputDecoration(
                      labelText: widget.sync.hasRelayCredentials
                          ? 'WebDAV 密码（已存密钥库 · 留空保持不变）'
                          : 'WebDAV 密码（仅存系统密钥库）',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('sync_relay_bearer_input'),
                    controller: _relayBearerController,
                    obscureText: true,
                    style: BlinkTypography.body(tokens),
                    decoration: InputDecoration(
                      labelText: 'Bearer Token（可选，仅存系统密钥库）',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ] else ...<Widget>[
                  TextField(
                    key: const Key('sync_relay_bucket_input'),
                    controller: _relayBucketController,
                    style: BlinkTypography.monoValue(tokens),
                    decoration: InputDecoration(
                      labelText: 'Bucket 名称',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          key: const Key('sync_relay_region_input'),
                          controller: _relayRegionController,
                          style: BlinkTypography.monoValue(tokens),
                          decoration: InputDecoration(
                            labelText: 'Region',
                            isDense: true,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          key: const Key('sync_relay_prefix_input'),
                          controller: _relayPrefixController,
                          style: BlinkTypography.monoValue(tokens),
                          decoration: InputDecoration(
                            labelText: '对象前缀',
                            isDense: true,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('sync_relay_access_key_input'),
                    controller: _relayAccessKeyController,
                    obscureText: true,
                    style: BlinkTypography.monoValue(tokens),
                    decoration: InputDecoration(
                      labelText: widget.sync.hasRelayCredentials
                          ? 'Access Key ID（已存密钥库 · 留空保持不变）'
                          : 'Access Key ID（仅存系统密钥库）',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    key: const Key('sync_relay_secret_key_input'),
                    controller: _relaySecretKeyController,
                    obscureText: true,
                    style: BlinkTypography.monoValue(tokens),
                    decoration: InputDecoration(
                      labelText: widget.sync.hasRelayCredentials
                          ? 'Secret Access Key（已存密钥库 · 留空保持不变）'
                          : 'Secret Access Key（仅存系统密钥库）',
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: tokens.sidebar,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: tokens.borderHairline),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        widget.sync.hasRelayMasterKey
                            ? 'E2EE 主同步密钥已就绪（指纹 ${widget.sync.relayMasterKeyId}）'
                            : '尚未配置 E2EE 主同步密钥（仅存于设备系统密钥库）',
                        key: const Key('sync_master_key_status'),
                        style: BlinkTypography.controlLabel(tokens),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          OutlinedButton.icon(
                            key: const Key('sync_generate_master_key_button'),
                            onPressed: _busyAction ? null : _generateMasterKey,
                            icon: const Icon(Icons.vpn_key_outlined, size: 16),
                            label: Text(
                              widget.sync.hasRelayMasterKey
                                  ? '重新生成主密钥'
                                  : '生成主密钥',
                            ),
                          ),
                          if (widget.sync.hasRelayMasterKey)
                            OutlinedButton.icon(
                              key: const Key('sync_export_recovery_key_button'),
                              onPressed: _exportRecoveryCode,
                              icon: const Icon(
                                Icons.visibility_outlined,
                                size: 16,
                              ),
                              label: const Text('导出恢复码'),
                            ),
                        ],
                      ),
                      if (_revealedRecoveryCode != null) ...<Widget>[
                        const SizedBox(height: 8),
                        Container(
                          key: const Key('sync_recovery_code_display'),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: tokens.canvas,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: tokens.borderHairline),
                          ),
                          child: Row(
                            children: <Widget>[
                              Expanded(
                                child: SelectableText(
                                  _revealedRecoveryCode!,
                                  style: BlinkTypography.monoValue(tokens),
                                ),
                              ),
                              IconButton(
                                tooltip: '复制恢复码',
                                onPressed: () => _copyText(
                                  _revealedRecoveryCode!,
                                  'E2EE 恢复码',
                                ),
                                icon: const Icon(Icons.copy_rounded, size: 16),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 10),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              key: const Key('sync_import_recovery_key_input'),
                              controller: _importRecoveryController,
                              style: BlinkTypography.monoValue(tokens),
                              decoration: InputDecoration(
                                labelText: '导入已有恢复码（BLINK1-...）',
                                isDense: true,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton(
                            key: const Key('sync_import_recovery_key_button'),
                            onPressed: _busyAction ? null : _importRecoveryCode,
                            child: const Text('导入'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    key: const Key('sync_save_relay_button'),
                    onPressed: _busyAction ? null : _saveRelaySettings,
                    child: const Text('保存中继配置'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSummaryRow(BlinkColorTokens tokens) {
    final lastAt = widget.sync.lastSyncedAtUtc;
    final lastText = lastAt == null
        ? '尚未同步'
        : lastAt.toLocal().toIso8601String().substring(0, 19);
    return _KeyValueRow(
      label: '同步概况',
      labelWidth: widget.labelWidth,
      value:
          '待传 ${widget.sync.pendingOutboxCount} 项 · '
          '未裁定冲突 ${widget.sync.openConflictCount} 条 · '
          '最近同步：$lastText',
      valueKey: const Key('sync_status_summary'),
    );
  }
}

class _KeyValueRow extends StatelessWidget {
  const _KeyValueRow({
    required this.label,
    required this.value,
    required this.labelWidth,
    this.valueKey,
    this.mono = false,
  });

  final String label;
  final String value;
  final double labelWidth;
  final Key? valueKey;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: labelWidth,
            child: Text(label, style: BlinkTypography.metaLabel(tokens)),
          ),
          Expanded(
            child: SelectableText(
              value,
              key: valueKey,
              style: mono
                  ? BlinkTypography.monoValue(tokens, tabular: true)
                  : BlinkTypography.metaValue(tokens, tabular: true),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineNoticeBox extends StatelessWidget {
  const _InlineNoticeBox({
    required this.message,
    required this.isError,
    this.accentOverride,
    super.key,
  });

  final String message;
  final bool isError;
  final Color? accentOverride;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final fg =
        accentOverride ?? (isError ? tokens.statusErr : tokens.accentPrimary);
    final bg = accentOverride != null
        ? accentOverride!.withValues(alpha: 0.12)
        : (isError ? tokens.statusErrSubtle : tokens.accentSubtle);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: fg.withValues(alpha: 0.4)),
      ),
      child: Text(message, style: BlinkTypography.metaLabel(tokens, color: fg)),
    );
  }
}

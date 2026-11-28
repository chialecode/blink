import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'package:blink_client/app/blink_theme.dart';
import 'package:blink_client/application/sync_controller.dart';
import 'package:blink_client/application/workspace_controller.dart';

/// Flat hairline-grouped Multi-Device Sync settings section (`docs/ui.md`):
/// - Desktop LAN Direct Sync Service (toggle, port/addresses, one-time pairing
///   code, paired devices & removal)
/// - Device Pairing & Auto Sync (auto-sync toggle, LAN scan, manual pair, Sync Now)
/// - Encrypted Cloud Sync via WebDAV / S3 (protocol, endpoint/credentials,
///   master encryption key generate/export/import, and `#private` exclusion ON)
class BlinkSyncSettingsSection extends StatefulWidget {
  const BlinkSyncSettingsSection({
    BlinkWorkspaceController? workspace,
    BlinkSyncController? sync,
    this.isMobilePlatform,
    this.compactPadding = false,
    this.labelWidth = 120,
    this.onOpenConflicts,
    super.key,
  }) : assert(
         workspace != null || sync != null,
         'Either workspace or sync must be provided.',
       ),
       _workspace = workspace,
       _sync = sync;

  final BlinkWorkspaceController? _workspace;
  final BlinkSyncController? _sync;
  final bool? isMobilePlatform;
  final bool compactPadding;
  final double labelWidth;
  final VoidCallback? onOpenConflicts;

  BlinkSyncController get sync => _sync ?? _workspace!.sync;

  bool get effectiveIsMobilePlatform =>
      isMobilePlatform ?? (Platform.isAndroid || Platform.isIOS);

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
  bool _showAdvancedRelayFields = false;
  String? _revealedRecoveryCode;
  String? _inlineNotice;
  bool _inlineNoticeIsError = false;
  bool _busyAction = false;

  BlinkSyncController get _sync => widget.sync;

  @override
  void initState() {
    super.initState();
    _syncControllersFromConfig();
  }

  void _syncControllersFromConfig() {
    final cfg = _sync.config;
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
      final ok = await _sync.setDesktopServerEnabled(enabled, port: parsedPort);
      if (ok) {
        _setNotice(enabled ? '局域网直连服务已开启。' : '局域网直连服务已关闭。');
      } else {
        _setNotice(_sync.lastErrorMessage ?? '无法切换局域网直连服务状态。', isError: true);
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
      final res = await _sync.pairWithDirectPeer(
        baseUrl: _peerUrlController.text,
        pairingCode: _pairingCodeController.text,
      );
      if (res != null) {
        _pairingCodeController.clear();
        _setNotice('配对成功，凭据已安全保存至系统密钥库并完成首次同步。');
      } else {
        _setNotice(_sync.lastErrorMessage ?? '配对失败，请检查地址和配对码。', isError: true);
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
      final enabled = enabledOverride ?? _sync.config.relayEnabled;
      final ok = await _sync.saveRelayConfiguration(
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
        _setNotice('云端加密同步配置已保存，凭据仅存于系统安全密钥库。');
      } else {
        _setNotice(_sync.lastErrorMessage ?? '保存云端同步配置失败。', isError: true);
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
      final recoveryCode = await _sync.generateAndStoreRelayMasterKey();
      if (mounted) {
        setState(() => _revealedRecoveryCode = recoveryCode);
      }
      _setNotice('已生成加密主密钥并保存至系统安全密钥库，请妥善抄录或复制恢复码。');
    } catch (_) {
      _setNotice('生成加密主密钥失败。', isError: true);
    } finally {
      if (mounted) {
        setState(() => _busyAction = false);
      }
    }
  }

  Future<void> _exportRecoveryCode() async {
    final code = await _sync.exportRelayRecoveryCode();
    if (!mounted) {
      return;
    }
    if (code == null) {
      _setNotice('尚未生成加密主密钥，请先点击“生成主密钥”。', isError: true);
      return;
    }
    setState(() => _revealedRecoveryCode = code);
  }

  Future<void> _importRecoveryCode() async {
    setState(() => _busyAction = true);
    try {
      final ok = await _sync.importRelayRecoveryCode(
        _importRecoveryController.text,
      );
      if (ok) {
        _importRecoveryController.clear();
        _revealedRecoveryCode = null;
        _setNotice('已验证并导入加密主密钥至系统安全密钥库。');
      } else {
        _setNotice(_sync.lastErrorMessage ?? '恢复码校验失败。', isError: true);
      }
    } finally {
      if (mounted) {
        setState(() => _busyAction = false);
      }
    }
  }

  static String _formatLocalTime(DateTime utc) {
    final local = utc.toLocal();
    final y = local.year.toString().padLeft(4, '0');
    final m = local.month.toString().padLeft(2, '0');
    final d = local.day.toString().padLeft(2, '0');
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    final pad = widget.compactPadding ? 14.0 : 18.0;
    final isMobilePlatform = widget.effectiveIsMobilePlatform;

    return ListenableBuilder(
      listenable: _sync,
      builder: (context, _) {
        final cfg = _sync.config;
        final activeCode = _sync.activePairingCode;

        return Column(
          key: const Key('sync_settings_section'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // ---------------------------------------------------------------
            // Section 1: Overview & Auto Sync
            // ---------------------------------------------------------------
            _FlatSectionContainer(
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          '同步状态',
                          style: BlinkTypography.sectionHeading(tokens),
                        ),
                      ),
                      if (_sync.openConflictCount > 0 &&
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
                            '处理冲突 (${_sync.openConflictCount})',
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
                  if (_sync.recoveredCorruptSyncSettings) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      '检测到损坏的同步配置文件，已保留原文件并恢复默认配置。',
                      key: const Key('corrupt_sync_settings_notice'),
                      style: BlinkTypography.metaLabel(
                        tokens,
                        color: tokens.statusWarn,
                      ),
                    ),
                  ],
                  if (_sync.lastErrorMessage != null) ...<Widget>[
                    const SizedBox(height: 10),
                    _InlineNoticeBox(
                      key: const Key('sync_error_notice'),
                      message: _sync.lastErrorMessage!,
                      isError:
                          _sync.uiStatus != BlinkSyncUiStatus.peerAsleep &&
                          _sync.uiStatus != BlinkSyncUiStatus.privacyBlocked,
                      accentOverride:
                          _sync.uiStatus == BlinkSyncUiStatus.privacyBlocked
                          ? tokens.privacyPrivate
                          : (_sync.uiStatus == BlinkSyncUiStatus.peerAsleep
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
                  const SizedBox(height: 8),
                  Divider(height: 1, color: tokens.borderHairline),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    key: const Key('sync_auto_toggle'),
                    contentPadding: EdgeInsets.zero,
                    title: Text('自动同步', style: BlinkTypography.body(tokens)),
                    subtitle: Text(
                      '打开应用、编辑保存或发现局域网设备时在后台自动同步，不影响离线写作',
                      style: BlinkTypography.metaLabel(tokens),
                    ),
                    value: cfg.autoSyncEnabled,
                    onChanged: (val) =>
                        unawaited(_sync.setAutoSyncEnabled(val)),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      FilledButton.icon(
                        key: const Key('sync_settings_sync_now_button'),
                        onPressed: _sync.isConfigured && !_sync.isSyncing
                            ? () => unawaited(_sync.syncNow(manual: true))
                            : null,
                        icon: const Icon(Icons.sync_rounded, size: 16),
                        label: const Text('立即同步'),
                      ),
                      OutlinedButton.icon(
                        key: const Key('sync_discover_lan_button'),
                        onPressed: _sync.isDiscoveringPeers
                            ? null
                            : () => unawaited(_sync.discoverLanPeers()),
                        icon: const Icon(Icons.radar_rounded, size: 16),
                        label: Text(
                          _sync.isDiscoveringPeers ? '扫描局域网中…' : '扫描局域网设备',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ---------------------------------------------------------------
            // Section 2: Desktop LAN Direct Sync Service
            // ---------------------------------------------------------------
            if (!isMobilePlatform) ...<Widget>[
              const SizedBox(height: 14),
              _FlatSectionContainer(
                padding: EdgeInsets.all(pad),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '局域网直连服务',
                      style: BlinkTypography.sectionHeading(tokens),
                    ),
                    const SizedBox(height: 4),
                    SwitchListTile(
                      key: const Key('sync_host_toggle'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '开启局域网直连服务',
                        style: BlinkTypography.body(tokens),
                      ),
                      subtitle: Text(
                        _sync.isHostRunning
                            ? '运行中 · 端口 ${_sync.activeServerPort}'
                                  '${_sync.isLanAdvertising ? ' · 已开启局域网发现' : ''}'
                            : '开启后，手机和其他设备可通过同一局域网或私人网络直接高速同步（包含私密内容）',
                        style: BlinkTypography.metaLabel(tokens),
                      ),
                      value: _sync.isHostRunning,
                      onChanged: _busyAction ? null : _toggleDesktopHost,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        SizedBox(
                          width: 132,
                          child: TextField(
                            key: const Key('sync_host_port_input'),
                            controller: _hostPortController,
                            keyboardType: TextInputType.number,
                            style: BlinkTypography.monoValue(
                              tokens,
                              tabular: true,
                            ),
                            decoration: InputDecoration(
                              labelText: '服务端口',
                              isDense: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                        if (_sync.isHostRunning)
                          OutlinedButton.icon(
                            key: const Key('sync_generate_pairing_code_button'),
                            onPressed: () {
                              _sync.generatePairingCode();
                            },
                            icon: const Icon(Icons.key_outlined, size: 16),
                            label: const Text('生成一次性配对码'),
                          ),
                      ],
                    ),
                    if (_sync.isHostRunning) ...<Widget>[
                      const SizedBox(height: 10),
                      _KeyValueRow(
                        label: '本机连接地址',
                        labelWidth: widget.labelWidth,
                        value: _sync.localHostAddresses
                            .map((ip) => 'http://$ip:${_sync.activeServerPort}')
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
                                      '一次性配对码（5 分钟内有效）',
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
                    Divider(height: 1, color: tokens.borderHairline),
                    const SizedBox(height: 8),
                    Row(
                      children: <Widget>[
                        Text(
                          '已配对设备（${_sync.pairedDevices.length}）',
                          style: BlinkTypography.metaLabel(tokens),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () =>
                              unawaited(_sync.refreshPairedDevices()),
                          child: const Text('刷新'),
                        ),
                      ],
                    ),
                    if (_sync.pairedDevices.isEmpty)
                      Text(
                        '暂无已配对设备，其他设备连接后会显示在这里。',
                        style: BlinkTypography.metaLabel(
                          tokens,
                          color: tokens.textMuted,
                        ),
                      )
                    else
                      Column(
                        key: const Key('sync_paired_devices_list'),
                        children: <Widget>[
                          for (final device in _sync.pairedDevices)
                            Container(
                              margin: const EdgeInsets.only(top: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: tokens.sidebar,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: tokens.borderHairline,
                                ),
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
                                          device.isRevoked ? '已取消配对' : '已配对',
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
                                        await _sync.revokePairedDevice(
                                          device.deviceId,
                                        );
                                        _setNotice(
                                          '已取消设备 ${device.deviceName} 的同步权限。',
                                        );
                                      },
                                      child: const Text('取消配对'),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ],

            // ---------------------------------------------------------------
            // Section 3: Connect / Pair with Direct Peer
            // ---------------------------------------------------------------
            const SizedBox(height: 14),
            _FlatSectionContainer(
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '连接局域网设备',
                    style: BlinkTypography.sectionHeading(tokens),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '与已开启局域网直连服务的电脑配对，支持高速双向同步全部内容（含私密内容）。',
                    style: BlinkTypography.metaLabel(tokens),
                  ),
                  if (_sync.discoveredPeers.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    Column(
                      key: const Key('sync_discovered_peers_list'),
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Text(
                          '发现的局域网设备（点击填入地址）：',
                          style: BlinkTypography.metaLabel(tokens),
                        ),
                        const SizedBox(height: 4),
                        for (final peer in _sync.discoveredPeers)
                          InkWell(
                            key: Key('sync_discovered_peer_${peer.deviceId}'),
                            borderRadius: BorderRadius.circular(8),
                            onTap: () {
                              _peerUrlController.text = peer.baseUri.toString();
                              _setNotice('已填入设备 ${peer.deviceName} 的地址。');
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
                                border: Border.all(
                                  color: tokens.borderHairline,
                                ),
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
                  if (_sync.isDirectConfigured) ...<Widget>[
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
                            '已连接设备：${cfg.directPeerDeviceName ?? cfg.directPeerUrl}',
                            style: BlinkTypography.controlLabel(tokens),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            cfg.directPeerUrl ?? '',
                            style: BlinkTypography.monoValue(tokens),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '配对凭据仅加密保存于系统安全密钥库，不写入数据文件夹。',
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
                                await _sync.disconnectDirectPeer();
                                _peerUrlController.clear();
                                _setNotice('已断开设备连接并移除本机配对凭据。');
                              },
                              child: const Text('断开配对'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('sync_peer_url_input'),
                    controller: _peerUrlController,
                    style: BlinkTypography.monoValue(tokens),
                    decoration: InputDecoration(
                      labelText: '目标设备地址（局域网或私人网络）',
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
                ],
              ),
            ),

            // ---------------------------------------------------------------
            // Section 4: Encrypted Cloud Sync (WebDAV / S3)
            // ---------------------------------------------------------------
            const SizedBox(height: 14),
            _FlatSectionContainer(
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '云端加密同步（WebDAV / S3）',
                    style: BlinkTypography.sectionHeading(tokens),
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    key: const Key('sync_relay_toggle'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '启用云端加密同步',
                      style: BlinkTypography.body(tokens),
                    ),
                    subtitle: Text(
                      '电脑不在线时通过自有网盘或对象存储同步，内容在本机端到端加密后上传',
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
                          '私密内容不上传云端',
                          style: BlinkTypography.controlLabel(tokens)
                              .copyWith(color: tokens.privacyPrivate),
                        ),
                        subtitle: Text(
                          '带 #private 的内容仅通过局域网或私人网络同步，绝不上传云端',
                          style: BlinkTypography.metaLabel(tokens),
                        ),
                        value: cfg.excludePrivateFromRelay,
                        onChanged: (val) =>
                            unawaited(_sync.setExcludePrivateFromRelay(val)),
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
                          : 'S3 服务地址',
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
                  if (_selectedRelayProtocol ==
                      RelayProtocol.webdav) ...<Widget>[
                    TextField(
                      key: const Key('sync_relay_username_input'),
                      controller: _relayUsernameController,
                      style: BlinkTypography.body(tokens),
                      decoration: InputDecoration(
                        labelText: '用户名（可选）',
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
                        labelText: _sync.hasWebDavCredentials
                            ? '密码（已存系统密钥库 · 留空保持不变）'
                            : '密码（仅存系统密钥库）',
                        isDense: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => setState(
                        () => _showAdvancedRelayFields =
                            !_showAdvancedRelayFields,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(
                              _showAdvancedRelayFields
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 16,
                              color: tokens.textSecondary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '高级认证选项',
                              style: BlinkTypography.metaLabel(tokens),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_showAdvancedRelayFields) ...<Widget>[
                      const SizedBox(height: 6),
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
                    ],
                  ] else ...<Widget>[
                    TextField(
                      key: const Key('sync_relay_bucket_input'),
                      controller: _relayBucketController,
                      style: BlinkTypography.monoValue(tokens),
                      decoration: InputDecoration(
                        labelText: '存储桶名称（Bucket）',
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
                              labelText: '区域（Region）',
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
                              labelText: '目录前缀',
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
                        labelText: _sync.hasS3Credentials
                            ? 'Access Key ID（已存系统密钥库 · 留空保持不变）'
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
                        labelText: _sync.hasS3Credentials
                            ? 'Secret Access Key（已存系统密钥库 · 留空保持不变）'
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
                          _sync.hasRelayMasterKey
                              ? '加密主密钥已就绪（标识 ${_sync.relayMasterKeyId}）'
                              : '尚未创建加密主密钥（仅保存在本机系统密钥库）',
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
                              onPressed: _busyAction
                                  ? null
                                  : _generateMasterKey,
                              icon: const Icon(
                                Icons.vpn_key_outlined,
                                size: 16,
                              ),
                              label: Text(
                                _sync.hasRelayMasterKey ? '重新生成主密钥' : '生成主密钥',
                              ),
                            ),
                            if (_sync.hasRelayMasterKey)
                              OutlinedButton.icon(
                                key: const Key(
                                  'sync_export_recovery_key_button',
                                ),
                                onPressed: _exportRecoveryCode,
                                icon: const Icon(
                                  Icons.visibility_outlined,
                                  size: 16,
                                ),
                                label: const Text('查看恢复码'),
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
                                  onPressed: () =>
                                      _copyText(_revealedRecoveryCode!, '恢复码'),
                                  icon: const Icon(
                                    Icons.copy_rounded,
                                    size: 16,
                                  ),
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
                                key: const Key(
                                  'sync_import_recovery_key_input',
                                ),
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
                              onPressed: _busyAction
                                  ? null
                                  : _importRecoveryCode,
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
                      child: const Text('保存云端同步配置'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildSummaryRow(BlinkColorTokens tokens) {
    final lastAt = _sync.lastSyncedAtUtc;
    final lastText = lastAt == null ? '尚未同步' : _formatLocalTime(lastAt);
    return _KeyValueRow(
      label: '同步概况',
      labelWidth: widget.labelWidth,
      value:
          '待同步 ${_sync.pendingOutboxCount} 项 · '
          '待处理冲突 ${_sync.openConflictCount} 条 · '
          '最近同步：$lastText',
      valueKey: const Key('sync_status_summary'),
    );
  }
}

class _FlatSectionContainer extends StatelessWidget {
  const _FlatSectionContainer({required this.padding, required this.child});

  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = BlinkColorTokens.of(context);
    return Material(
      color: tokens.canvas,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: tokens.borderHairline, width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
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

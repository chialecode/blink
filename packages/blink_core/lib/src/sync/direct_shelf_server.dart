import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../errors/blink_error.dart';
import '../storage/blob_store.dart';
import '../vault/vault_manager.dart';
import 'sync_models.dart';

const String _pairingAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

final class _ActivePairingCode {
  _ActivePairingCode({required this.code, required this.expiresAtUtc});

  final String code;
  final DateTime expiresAtUtc;
}

/// Embedded pure-Dart `shelf` HTTP/SSE direct sync server (Channel A).
///
/// Serves the BLINK direct sync contract (`docs/design/architecture.md#contracts`):
/// - `GET /api/v1/health`
/// - `GET /api/v1/capabilities`
/// - `POST /api/v1/auth/pair`, `GET /api/v1/auth/devices`, `DELETE /api/v1/auth/devices/<id>`
/// - `POST /api/v1/sync/push`, `GET /api/v1/sync/pull`
/// - `GET /api/v1/events/stream` (SSE)
/// - `HEAD`/`PUT`/`GET /api/v1/media/blobs/<sha256>` (`Range` + `sha256` verify)
final class DirectShelfServer {
  DirectShelfServer({
    required this.vault,
    String? deviceName,
    this.defaultPairingCodeTtl = const Duration(minutes: 5),
    this.maxBatchSize = 500,
    Random? secureRandom,
  }) : deviceName = (deviceName != null && deviceName.trim().isNotEmpty)
           ? deviceName.trim()
           : vault.localDeviceName,
       _random = secureRandom ?? Random.secure();

  final VaultManager vault;
  final String deviceName;
  final Duration defaultPairingCodeTtl;
  final int maxBatchSize;
  final Random _random;

  HttpServer? _httpServer;
  final Map<String, _ActivePairingCode> _pairingCodes =
      <String, _ActivePairingCode>{};
  final Set<StreamController<List<int>>> _activeSseStreams =
      <StreamController<List<int>>>{};

  bool get isRunning => _httpServer != null;

  String get host => _httpServer?.address.address ?? '';

  int get port => _httpServer?.port ?? 0;

  Uri get baseUri {
    final server = _httpServer;
    if (server == null) {
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'DirectShelfServer is not running',
      );
    }
    final boundHost = server.address.address;
    final formattedHost = boundHost.contains(':') ? '[$boundHost]' : boundHost;
    return Uri.parse('http://$formattedHost:${server.port}');
  }

  /// Generates a short-lived single-use pairing code stored strictly in memory (`INV-08`).
  PairingCodeInfo createPairingCode({Duration? ttl}) {
    _purgeExpiredPairingCodes();
    final nowUtc = DateTime.now().toUtc();
    final expiresAtUtc = nowUtc.add(ttl ?? defaultPairingCodeTtl);
    final rawChars = List<String>.generate(
      8,
      (_) => _pairingAlphabet[_random.nextInt(_pairingAlphabet.length)],
      growable: false,
    ).join();
    final formatted = '${rawChars.substring(0, 4)}-${rawChars.substring(4)}';
    _pairingCodes[formatted] = _ActivePairingCode(
      code: formatted,
      expiresAtUtc: expiresAtUtc,
    );
    return PairingCodeInfo(code: formatted, expiresAtUtc: expiresAtUtc);
  }

  /// Lists registered peer devices (returns metadata only; zero secrets).
  Future<List<SyncDeviceRecord>> listDevices() =>
      vault.syncEngine.listDevices();

  /// Revokes a paired device immediately; subsequent requests fail with `401 device_revoked`.
  Future<bool> revokeDevice(String deviceId) =>
      vault.syncEngine.revokeDevice(deviceId);

  /// Starts listening on [host]:[port] (defaults to quiet loopback `127.0.0.1:0`).
  Future<void> start({String host = '127.0.0.1', int port = 0}) async {
    if (_httpServer != null) {
      return;
    }
    final handler = _buildHandler();
    _httpServer = await shelf_io.serve(handler, host, port);
    _httpServer!.autoCompress = false;
  }

  /// Closes active SSE streams and shuts down the HTTP server cleanly.
  Future<void> stop() async {
    final controllers = _activeSseStreams.toList(growable: false);
    _activeSseStreams.clear();
    for (final controller in controllers) {
      if (!controller.isClosed) {
        await controller.close();
      }
    }
    _pairingCodes.clear();
    final server = _httpServer;
    _httpServer = null;
    if (server != null) {
      await server.close(force: true);
    }
  }

  Handler _buildHandler() {
    final router = Router()
      ..get('/api/v1/health', _handleHealth)
      ..post('/api/v1/auth/pair', _handlePair)
      ..get(
        '/api/v1/capabilities',
        (Request req) => _requireAuth(req, _handleCapabilities),
      )
      ..get(
        '/api/v1/auth/devices',
        (Request req) => _requireAuth(req, _handleListDevices),
      )
      ..delete(
        '/api/v1/auth/devices/<deviceId>',
        (Request req, String deviceId) => _requireAuth(
          req,
          (r, device) => _handleRevokeDevice(r, device, deviceId),
        ),
      )
      ..post(
        '/api/v1/sync/push',
        (Request req) => _requireAuth(req, _handleSyncPush),
      )
      ..get(
        '/api/v1/sync/pull',
        (Request req) => _requireAuth(req, _handleSyncPull),
      )
      ..get(
        '/api/v1/events/stream',
        (Request req) => _requireAuth(req, _handleEventsStream),
      )
      ..add(
        'HEAD',
        '/api/v1/media/blobs/<sha256>',
        (Request req, String sha256) => _requireAuth(
          req,
          (r, device) => _handleHeadBlob(r, device, sha256),
        ),
      )
      ..put(
        '/api/v1/media/blobs/<sha256>',
        (Request req, String sha256) =>
            _requireAuth(req, (r, device) => _handlePutBlob(r, device, sha256)),
      )
      ..get(
        '/api/v1/media/blobs/<sha256>',
        (Request req, String sha256) =>
            _requireAuth(req, (r, device) => _handleGetBlob(r, device, sha256)),
      );

    return Pipeline().addHandler((Request request) async {
      try {
        return await router.call(request);
      } on BlinkException catch (error) {
        return _errorResponse(
          _httpStatusForError(error.code),
          error.code,
          error.message,
          retryable: error.retryable,
        );
      } catch (_) {
        // Never leak stack traces, tokens, or private content over HTTP (`INV-08`).
        return _errorResponse(
          500,
          BlinkErrorCode.ioError,
          'Internal sync server error',
          retryable: true,
        );
      }
    });
  }

  Response _handleHealth(Request request) {
    final health = SyncPeerHealth(
      channel: vault.metadata.channel,
      protocolVersion: currentSyncProtocolVersion,
      vaultId: vault.metadata.vaultId,
      deviceId: vault.localDeviceId,
      deviceName: deviceName,
      latestSeqId: vault.syncEngine.getLatestSeqId(),
    );
    return _jsonResponse(200, health.toJson());
  }

  Future<Response> _handlePair(Request request) async {
    final guardError = _checkProtocolAndChannelHeaders(request);
    if (guardError != null) {
      return guardError;
    }

    final body = await _readJsonObject(request);
    if (body == null) {
      return _errorResponse(
        400,
        BlinkErrorCode.invalidArgument,
        'Pairing request body must be a JSON object',
      );
    }

    final submittedCode = (body['pairing_code'] as String?)?.trim() ?? '';
    final peerDeviceId = (body['device_id'] as String?)?.trim() ?? '';
    final peerDeviceName = (body['device_name'] as String?)?.trim() ?? '';

    if (submittedCode.isEmpty || peerDeviceId.isEmpty) {
      return _errorResponse(
        400,
        BlinkErrorCode.invalidArgument,
        'pairing_code and device_id are required',
      );
    }

    final consumed = _consumePairingCodeConstantTime(submittedCode);
    if (!consumed) {
      return _errorResponse(
        401,
        BlinkErrorCode.authRequired,
        'Invalid or expired pairing code',
      );
    }

    final tokenBytes = Uint8List.fromList(
      List<int>.generate(32, (_) => _random.nextInt(256), growable: false),
    );
    final issuedToken = base64UrlEncode(tokenBytes).replaceAll('=', '');
    final tokenSha256 = crypto.sha256
        .convert(utf8.encode(issuedToken))
        .toString();

    await vault.syncEngine.registerOrUpdateDevice(
      deviceId: peerDeviceId,
      deviceName: peerDeviceName.isEmpty ? peerDeviceId : peerDeviceName,
      tokenSha256: tokenSha256,
    );

    final result = PairingResult(
      deviceId: peerDeviceId,
      deviceName: peerDeviceName.isEmpty ? peerDeviceId : peerDeviceName,
      deviceToken: issuedToken,
      vaultId: vault.metadata.vaultId,
      channel: vault.metadata.channel,
      protocolVersion: currentSyncProtocolVersion,
    );
    return _jsonResponse(200, result.toJson());
  }

  Future<Response> _requireAuth(
    Request request,
    FutureOr<Response> Function(Request req, SyncDeviceRecord device) next,
  ) async {
    final guardError = _checkProtocolAndChannelHeaders(request);
    if (guardError != null) {
      return guardError;
    }

    final authHeader = request.headers['authorization'];
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      return _errorResponse(
        401,
        BlinkErrorCode.authRequired,
        'Missing Bearer device token',
      );
    }
    final token = authHeader.substring('Bearer '.length).trim();
    if (token.isEmpty) {
      return _errorResponse(
        401,
        BlinkErrorCode.authRequired,
        'Empty Bearer device token',
      );
    }

    final tokenSha256 = crypto.sha256.convert(utf8.encode(token)).toString();
    final device = await vault.syncEngine.findDeviceByTokenSha256(tokenSha256);
    if (device == null) {
      return _errorResponse(
        401,
        BlinkErrorCode.authRequired,
        'Unknown device token',
      );
    }
    if (device.isRevoked) {
      return _errorResponse(
        401,
        BlinkErrorCode.deviceRevoked,
        'Device access has been revoked; re-pair required',
      );
    }

    await vault.syncEngine.touchDeviceLastSeen(device.deviceId);
    return await next(request, device);
  }

  Response? _checkProtocolAndChannelHeaders(Request request) {
    final protoHeader = request.headers['x-blink-protocol']?.trim();
    if (protoHeader != currentSyncProtocolVersion.toString()) {
      return _errorResponse(
        426,
        BlinkErrorCode.protocolMismatch,
        'Expected X-Blink-Protocol: $currentSyncProtocolVersion',
      );
    }

    final channelHeader = request.headers['x-blink-channel']?.trim();
    if (channelHeader == null ||
        channelHeader != vault.metadata.channel.wireValue) {
      return _errorResponse(
        409,
        BlinkErrorCode.channelMismatch,
        'Channel mismatch: vault runs on "${vault.metadata.channel.wireValue}"',
      );
    }
    return null;
  }

  Response _handleCapabilities(Request request, SyncDeviceRecord device) {
    final caps = SyncCapabilities(
      protocolVersion: currentSyncProtocolVersion,
      channel: vault.metadata.channel,
      supportsSse: true,
      supportsBlobRange: true,
      supportsE2eeRelay: true,
      maxBatchSize: maxBatchSize,
    );
    return _jsonResponse(200, caps.toJson());
  }

  Future<Response> _handleListDevices(
    Request request,
    SyncDeviceRecord device,
  ) async {
    final devices = await vault.syncEngine.listDevices();
    return _jsonResponse(200, <String, Object?>{
      'devices': devices.map((d) => d.toPublicJson()).toList(growable: false),
    });
  }

  Future<Response> _handleRevokeDevice(
    Request request,
    SyncDeviceRecord caller,
    String targetDeviceId,
  ) async {
    final revoked = await vault.syncEngine.revokeDevice(targetDeviceId);
    if (!revoked) {
      return _errorResponse(
        404,
        BlinkErrorCode.notFound,
        'Device $targetDeviceId not found',
      );
    }
    return _jsonResponse(200, <String, Object?>{
      'revoked': true,
      'device_id': targetDeviceId,
    });
  }

  Future<Response> _handleSyncPush(
    Request request,
    SyncDeviceRecord device,
  ) async {
    final body = await _readJsonObject(request);
    if (body == null || body['ops'] is! List) {
      return _errorResponse(
        400,
        BlinkErrorCode.invalidArgument,
        'Push body must contain an "ops" array',
      );
    }
    final rawOps = body['ops'] as List<Object?>;
    if (rawOps.length > maxBatchSize) {
      return _errorResponse(
        400,
        BlinkErrorCode.invalidArgument,
        'Batch size ${rawOps.length} exceeds limit $maxBatchSize',
      );
    }

    final envelopes = <SyncOpEnvelope>[];
    for (final item in rawOps) {
      if (item is! Map) {
        return _errorResponse(
          400,
          BlinkErrorCode.invalidArgument,
          'Each op in "ops" must be a JSON object',
        );
      }
      try {
        final mapped = item.map(
          (k, v) => MapEntry<String, Object?>(k.toString(), v),
        );
        final parsed = SyncOpEnvelope.fromJson(mapped);
        envelopes.add(
          parsed.deviceName != null && parsed.deviceName!.isNotEmpty
              ? parsed
              : SyncOpEnvelope(
                  seqId: parsed.seqId,
                  deviceId: parsed.deviceId,
                  deviceName: device.deviceName,
                  clientOpId: parsed.clientOpId,
                  hlcTs: parsed.hlcTs,
                  baseRevision: parsed.baseRevision,
                  entityLayer: parsed.entityLayer,
                  entityType: parsed.entityType,
                  entityId: parsed.entityId,
                  opType: parsed.opType,
                  opOrigin: parsed.opOrigin,
                  privacyLevel: parsed.privacyLevel,
                  payload: parsed.payload,
                  createdAtUtc: parsed.createdAtUtc,
                ),
        );
      } on FormatException catch (err) {
        return _errorResponse(
          400,
          BlinkErrorCode.invalidArgument,
          'Invalid op envelope: ${err.message}',
        );
      }
    }

    final ingest = await vault.syncEngine.ingestRemoteOps(envelopes);
    final result = PushOpsResult(
      acceptedCount: ingest.acceptedCount,
      duplicateCount: ingest.duplicateCount,
      latestSeqId: ingest.latestSeqId,
      acceptedClientOpIds: ingest.acceptedClientOpIds,
    );
    return _jsonResponse(200, result.toJson());
  }

  Future<Response> _handleSyncPull(
    Request request,
    SyncDeviceRecord device,
  ) async {
    final sinceRaw = request.url.queryParameters['since'] ?? '0';
    final limitRaw = request.url.queryParameters['limit'] ?? '200';
    final since = int.tryParse(sinceRaw);
    final limit = int.tryParse(limitRaw);
    if (since == null || since < 0 || limit == null || limit <= 0) {
      return _errorResponse(
        400,
        BlinkErrorCode.invalidArgument,
        'Query parameters since (>= 0) and limit (> 0) must be valid integers',
      );
    }

    final result = await vault.syncEngine.readOplogSince(
      sinceSeq: since,
      limit: limit.clamp(1, maxBatchSize),
    );
    return _jsonResponse(200, result.toJson());
  }

  Response _handleEventsStream(Request request, SyncDeviceRecord device) {
    late StreamController<List<int>> controller;
    StreamSubscription<int>? seqSub;

    void sendFrame(String event, Map<String, Object?> data) {
      if (controller.isClosed) {
        return;
      }
      final payload = 'event: $event\ndata: ${jsonEncode(data)}\n\n';
      controller.add(utf8.encode(payload));
    }

    controller = StreamController<List<int>>(
      onListen: () {
        _activeSseStreams.add(controller);
        sendFrame('ready', <String, Object?>{
          'latest_seq_id': vault.syncEngine.getLatestSeqId(),
        });
        seqSub = vault.syncEngine.seqStream.listen((seqId) {
          sendFrame('seq_advanced', <String, Object?>{'seq_id': seqId});
        });
      },
      onCancel: () async {
        _activeSseStreams.remove(controller);
        await seqSub?.cancel();
        seqSub = null;
        if (!controller.isClosed) {
          await controller.close();
        }
      },
    );

    return Response.ok(
      controller.stream,
      headers: const <String, String>{
        'content-type': 'text/event-stream; charset=utf-8',
        'cache-control': 'no-cache, no-store',
        'connection': 'keep-alive',
      },
      context: const <String, Object>{'shelf.io.buffer_output': false},
    );
  }

  Future<Response> _handleHeadBlob(
    Request request,
    SyncDeviceRecord device,
    String sha256,
  ) async {
    if (!isValidBlobSha256(sha256)) {
      return _errorResponse(
        400,
        BlinkErrorCode.invalidArgument,
        'Invalid blob SHA-256 digest',
      );
    }
    final meta = await vault.blobs.getMetadata(sha256);
    final file = await vault.blobs.resolveFile(sha256);
    if (meta == null || file == null) {
      return _errorResponse(404, BlinkErrorCode.notFound, 'Blob not found');
    }
    final length = await file.length();
    return Response.ok(
      null,
      headers: <String, String>{
        'content-type': meta.mimeType,
        'content-length': length.toString(),
        'accept-ranges': 'bytes',
        'etag': '"$sha256"',
      },
    );
  }

  Future<Response> _handlePutBlob(
    Request request,
    SyncDeviceRecord device,
    String sha256,
  ) async {
    if (!isValidBlobSha256(sha256)) {
      return _errorResponse(
        400,
        BlinkErrorCode.invalidArgument,
        'Invalid blob SHA-256 digest',
      );
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in request.read()) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    final actualSha = crypto.sha256.convert(bytes).toString();
    if (actualSha != sha256) {
      return _errorResponse(
        400,
        BlinkErrorCode.invalidArgument,
        'Blob SHA-256 integrity mismatch (rejected)',
      );
    }

    final rawContentType =
        request.headers['content-type']?.split(';').first.trim() ?? '';
    final mimeType = rawContentType.isEmpty
        ? 'application/octet-stream'
        : rawContentType;
    final stored = await vault.blobs.putBytes(bytes, mimeType: mimeType);
    return _jsonResponse(200, <String, Object?>{
      'sha256': stored.sha256,
      'byte_size': stored.byteSize,
      'mime_type': stored.mimeType,
    });
  }

  Future<Response> _handleGetBlob(
    Request request,
    SyncDeviceRecord device,
    String sha256,
  ) async {
    if (!isValidBlobSha256(sha256)) {
      return _errorResponse(
        400,
        BlinkErrorCode.invalidArgument,
        'Invalid blob SHA-256 digest',
      );
    }
    final meta = await vault.blobs.getMetadata(sha256);
    final file = await vault.blobs.resolveFile(sha256);
    if (meta == null || file == null) {
      return _errorResponse(404, BlinkErrorCode.notFound, 'Blob not found');
    }

    final totalLength = await file.length();
    final rangeHeader = request.headers['range']?.trim();
    if (rangeHeader == null || rangeHeader.isEmpty) {
      return Response.ok(
        file.openRead(),
        headers: <String, String>{
          'content-type': meta.mimeType,
          'content-length': totalLength.toString(),
          'accept-ranges': 'bytes',
          'etag': '"$sha256"',
        },
      );
    }

    final parsedRange = _parseSingleByteRange(rangeHeader, totalLength);
    if (parsedRange == null) {
      return Response(
        416,
        headers: <String, String>{
          'content-range': 'bytes */$totalLength',
          'content-type': 'application/json; charset=utf-8',
        },
        body: jsonEncode(<String, Object?>{
          'code': BlinkErrorCode.invalidArgument.wireCode,
          'message': 'Requested Range not satisfiable',
          'retryable': false,
        }),
      );
    }

    final sliceLen = parsedRange.endInclusive - parsedRange.start + 1;
    return Response(
      206,
      body: file.openRead(parsedRange.start, parsedRange.endInclusive + 1),
      headers: <String, String>{
        'content-type': meta.mimeType,
        'content-length': sliceLen.toString(),
        'content-range':
            'bytes ${parsedRange.start}-${parsedRange.endInclusive}/$totalLength',
        'accept-ranges': 'bytes',
        'etag': '"$sha256"',
      },
    );
  }

  bool _consumePairingCodeConstantTime(String submitted) {
    _purgeExpiredPairingCodes();
    final normalizedSubmitted = submitted.trim().toUpperCase();
    String? matchedKey;
    for (final entry in _pairingCodes.entries) {
      if (_constantTimeEquals(entry.key, normalizedSubmitted)) {
        matchedKey = entry.key;
      }
    }
    if (matchedKey == null) {
      return false;
    }
    // Single-use: immediately consume upon first valid match.
    _pairingCodes.remove(matchedKey);
    return true;
  }

  void _purgeExpiredPairingCodes() {
    final nowUtc = DateTime.now().toUtc();
    _pairingCodes.removeWhere(
      (_, active) => !nowUtc.isBefore(active.expiresAtUtc),
    );
  }

  static ({int start, int endInclusive})? _parseSingleByteRange(
    String header,
    int totalLength,
  ) {
    if (totalLength <= 0) {
      return null;
    }
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(header);
    if (match == null) {
      return null;
    }
    final startStr = match.group(1)!;
    final endStr = match.group(2)!;
    if (startStr.isEmpty && endStr.isEmpty) {
      return null;
    }
    int start;
    int end;
    if (startStr.isEmpty) {
      final suffix = int.tryParse(endStr);
      if (suffix == null || suffix <= 0) {
        return null;
      }
      start = (totalLength - suffix).clamp(0, totalLength - 1);
      end = totalLength - 1;
    } else {
      final parsedStart = int.tryParse(startStr);
      if (parsedStart == null ||
          parsedStart < 0 ||
          parsedStart >= totalLength) {
        return null;
      }
      start = parsedStart;
      if (endStr.isEmpty) {
        end = totalLength - 1;
      } else {
        final parsedEnd = int.tryParse(endStr);
        if (parsedEnd == null || parsedEnd < start) {
          return null;
        }
        end = parsedEnd >= totalLength ? totalLength - 1 : parsedEnd;
      }
    }
    return (start: start, endInclusive: end);
  }

  static Future<Map<String, Object?>?> _readJsonObject(Request request) async {
    try {
      final raw = await request.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (k, v) => MapEntry<String, Object?>(k.toString(), v),
        );
      }
    } catch (_) {}
    return null;
  }

  static Response _jsonResponse(int statusCode, Map<String, Object?> body) =>
      Response(
        statusCode,
        body: jsonEncode(body),
        headers: const <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );

  static Response _errorResponse(
    int statusCode,
    BlinkErrorCode code,
    String message, {
    bool retryable = false,
  }) => _jsonResponse(statusCode, <String, Object?>{
    'code': code.wireCode,
    'message': message,
    'retryable': retryable,
  });

  static int _httpStatusForError(BlinkErrorCode code) => switch (code) {
    BlinkErrorCode.authRequired || BlinkErrorCode.deviceRevoked => 401,
    BlinkErrorCode.privacyBlocked => 403,
    BlinkErrorCode.notFound => 404,
    BlinkErrorCode.channelMismatch || BlinkErrorCode.conflictPreserved => 409,
    BlinkErrorCode.protocolMismatch => 426,
    BlinkErrorCode.invalidArgument => 400,
    BlinkErrorCode.peerAsleep => 503,
    _ => 500,
  };

  static bool _constantTimeEquals(String a, String b) {
    final bytesA = utf8.encode(a);
    final bytesB = utf8.encode(b);
    if (bytesA.length != bytesB.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < bytesA.length; i++) {
      diff |= bytesA[i] ^ bytesB[i];
    }
    return diff == 0;
  }
}

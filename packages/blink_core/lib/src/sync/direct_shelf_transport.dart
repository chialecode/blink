import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../errors/blink_error.dart';
import '../models/blink_models.dart';
import '../storage/blob_store.dart';
import 'sync_models.dart';
import 'sync_transport.dart';

/// Pure-Dart `dart:io` HTTP/SSE client implementing [SyncTransport] against
/// [DirectShelfServer] or headless `blink sync serve` (Channel A).
final class DirectShelfTransport implements SyncTransport {
  DirectShelfTransport({
    required this.baseUri,
    required this.expectedChannel,
    this.deviceToken,
    String? transportId,
    this.protocolVersion = currentSyncProtocolVersion,
    this.requestTimeout = const Duration(seconds: 15),
    HttpClient? httpClient,
  }) : transportId = transportId ?? 'direct:${baseUri.host}:${baseUri.port}',
       _ownsClient = httpClient == null,
       _client = httpClient ?? HttpClient() {
    _client.connectionTimeout = requestTimeout;
  }

  final Uri baseUri;
  final BlinkChannel expectedChannel;
  final String? deviceToken;
  final int protocolVersion;
  final Duration requestTimeout;
  final bool _ownsClient;
  final HttpClient _client;

  @override
  final String transportId;

  @override
  bool get isRelayTransport => false;

  @override
  bool get excludesPrivateOps => false;

  /// Releases the underlying [HttpClient] if owned by this transport.
  void close({bool force = false}) {
    if (_ownsClient) {
      _client.close(force: force);
    }
  }

  /// Creates a copy of this transport authenticated with [token].
  DirectShelfTransport withDeviceToken(String token, {String? transportId}) =>
      DirectShelfTransport(
        baseUri: baseUri,
        expectedChannel: expectedChannel,
        deviceToken: token,
        transportId: transportId ?? this.transportId,
        protocolVersion: protocolVersion,
        requestTimeout: requestTimeout,
      );

  @override
  Future<SyncPeerHealth> checkHealth() async {
    final json = await _sendJsonRequest('GET', '/api/v1/health');
    final health = SyncPeerHealth.fromJson(json);
    if (health.channel != expectedChannel) {
      throw BlinkException(
        code: BlinkErrorCode.channelMismatch,
        message:
            'Peer runs channel "${health.channel.wireValue}" != expected "${expectedChannel.wireValue}"',
      );
    }
    if (health.protocolVersion != protocolVersion) {
      throw BlinkException(
        code: BlinkErrorCode.protocolMismatch,
        message:
            'Peer protocol v${health.protocolVersion} != expected v$protocolVersion',
      );
    }
    return health;
  }

  Future<SyncCapabilities> getCapabilities() async {
    final json = await _sendJsonRequest('GET', '/api/v1/capabilities');
    return SyncCapabilities.fromJson(json);
  }

  /// Exchanges a one-time [pairingCode] for a long-lived device bearer token.
  /// Callers must store `PairingResult.deviceToken` strictly in OS SecretStore (`INV-08`).
  Future<PairingResult> pair({
    required String pairingCode,
    required String deviceId,
    required String deviceName,
  }) async {
    final json = await _sendJsonRequest(
      'POST',
      '/api/v1/auth/pair',
      body: <String, Object?>{
        'pairing_code': pairingCode,
        'device_id': deviceId,
        'device_name': deviceName,
      },
      includeAuth: false,
    );
    return PairingResult.fromJson(json);
  }

  Future<List<SyncDeviceRecord>> listDevices() async {
    final json = await _sendJsonRequest('GET', '/api/v1/auth/devices');
    final raw = json['devices'];
    if (raw is! List) {
      return const <SyncDeviceRecord>[];
    }
    return raw
        .whereType<Map<Object?, Object?>>()
        .map(
          (m) => SyncDeviceRecord.fromPublicJson(
            m.map((k, v) => MapEntry<String, Object?>(k.toString(), v)),
          ),
        )
        .toList(growable: false);
  }

  Future<bool> revokeDevice(String deviceId) async {
    final json = await _sendJsonRequest(
      'DELETE',
      '/api/v1/auth/devices/${Uri.encodeComponent(deviceId)}',
    );
    return json['revoked'] == true;
  }

  @override
  Future<PushOpsResult> pushOps(List<SyncOpEnvelope> ops) async {
    final json = await _sendJsonRequest(
      'POST',
      '/api/v1/sync/push',
      body: <String, Object?>{
        'ops': ops.map((op) => op.toJson()).toList(growable: false),
      },
    );
    return PushOpsResult.fromJson(json);
  }

  @override
  Future<PullOpsResult> pullOps({
    required int sinceSeq,
    int limit = 200,
  }) async {
    final json = await _sendJsonRequest(
      'GET',
      '/api/v1/sync/pull',
      queryParameters: <String, String>{
        'since': sinceSeq.toString(),
        'limit': limit.toString(),
      },
    );
    return PullOpsResult.fromJson(json);
  }

  @override
  Future<void> commitPullCursor(int nextCursorSeq) async {
    // Direct sync persists cursor directly inside SyncEngine `sync_state`.
  }

  @override
  Future<bool> hasBlob(String sha256) async {
    if (!isValidBlobSha256(sha256)) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Invalid blob SHA-256 digest',
      );
    }
    final response = await _openRequest('HEAD', '/api/v1/media/blobs/$sha256');
    await response.drain<void>();
    if (response.statusCode == 200) {
      return true;
    }
    if (response.statusCode == 404) {
      return false;
    }
    final headerCode = response.headers.value('x-blink-error-code');
    final headerRetryable =
        response.headers.value('x-blink-retryable') == 'true';
    throw _mapHttpStatusError(response.statusCode, <String, Object?>{
      if (headerCode != null && headerCode.isNotEmpty) 'code': headerCode,
      'retryable': headerRetryable,
    });
  }

  @override
  Future<void> uploadBlob({
    required String sha256,
    required Uint8List bytes,
    required String mimeType,
  }) async {
    if (!isValidBlobSha256(sha256)) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Invalid blob SHA-256 digest',
      );
    }
    final response = await _openRequest(
      'PUT',
      '/api/v1/media/blobs/$sha256',
      rawBody: bytes,
      contentType: mimeType,
    );
    final rawText = await utf8.decodeStream(response);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return;
    }
    throw _parseErrorBody(response.statusCode, rawText);
  }

  @override
  Future<BlobRangeResponse> downloadBlobRange({
    required String sha256,
    int startOffset = 0,
    int? endOffsetInclusive,
  }) async {
    if (!isValidBlobSha256(sha256)) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Invalid blob SHA-256 digest',
      );
    }
    final headers = <String, String>{};
    if (startOffset > 0 || endOffsetInclusive != null) {
      final endPart = endOffsetInclusive != null ? '$endOffsetInclusive' : '';
      headers['range'] = 'bytes=$startOffset-$endPart';
    }
    final response = await _openRequest(
      'GET',
      '/api/v1/media/blobs/$sha256',
      extraHeaders: headers,
    );
    final builder = BytesBuilder(copy: false);
    await for (final chunk in response) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();

    if (response.statusCode != 200 && response.statusCode != 206) {
      final rawText = utf8.decode(bytes, allowMalformed: true);
      throw _parseErrorBody(response.statusCode, rawText);
    }

    final mimeType =
        response.headers
            .value(HttpHeaders.contentTypeHeader)
            ?.split(';')
            .first
            .trim() ??
        'application/octet-stream';
    var totalLength = bytes.length;
    var parsedStart = startOffset;
    final isPartial = response.statusCode == 206;

    if (isPartial) {
      final contentRange = response.headers.value('content-range') ?? '';
      final match = RegExp(r'^bytes\s+(\d+)-(\d+)/(\d+)$')
          .firstMatch(contentRange.trim());
      if (match != null) {
        parsedStart = int.parse(match.group(1)!);
        totalLength = int.parse(match.group(3)!);
      }
    } else {
      parsedStart = 0;
      totalLength = bytes.length;
    }

    return BlobRangeResponse(
      bytes: bytes,
      startOffset: parsedStart,
      totalLength: totalLength,
      isPartial: isPartial,
      mimeType: mimeType,
    );
  }

  /// Downloads a full blob using chunked `Range` requests and enforces SHA-256 verification (`INV-07`).
  Future<({Uint8List bytes, String mimeType})> downloadBlobVerified(
    String sha256, {
    int chunkSize = 262144,
  }) async {
    final buffer = BytesBuilder(copy: false);
    var offset = 0;
    int? totalLength;
    var mimeType = 'application/octet-stream';

    while (true) {
      final res = await downloadBlobRange(
        sha256: sha256,
        startOffset: offset,
        endOffsetInclusive: offset + chunkSize - 1,
      );
      mimeType = res.mimeType;
      totalLength ??= res.totalLength;
      buffer.add(res.bytes);
      offset += res.bytes.length;
      if (!res.isPartial || res.bytes.isEmpty || offset >= totalLength) {
        break;
      }
    }

    final bytes = buffer.takeBytes();
    final actualSha = crypto.sha256.convert(bytes).toString();
    if (actualSha != sha256) {
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'Downloaded blob SHA-256 verification failed',
      );
    }
    return (bytes: bytes, mimeType: mimeType);
  }

  /// Connects to `GET /api/v1/events/stream` and emits `seq_id` notifications in real time.
  Stream<int> watchSeqEvents() {
    late StreamController<int> controller;
    HttpClient? sseClient;
    StreamSubscription<String>? lineSub;

    Future<void> connect() async {
      sseClient = HttpClient()..connectionTimeout = requestTimeout;
      try {
        final uri = _resolveUri('/api/v1/events/stream');
        final req = await sseClient!.getUrl(uri).timeout(requestTimeout);
        _applyStandardHeaders(req, includeAuth: true);
        req.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
        final resp = await req.close().timeout(requestTimeout);
        if (resp.statusCode != 200) {
          final body = await utf8.decodeStream(resp);
          throw _parseErrorBody(resp.statusCode, body);
        }

        lineSub = resp
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              (line) {
                if (controller.isClosed) {
                  return;
                }
                if (line.startsWith('data:')) {
                  final dataStr = line.substring('data:'.length).trim();
                  try {
                    final decoded = jsonDecode(dataStr);
                    if (decoded is Map) {
                      final seq = decoded['seq_id'] ?? decoded['latest_seq_id'];
                      if (seq is int) {
                        controller.add(seq);
                      }
                    }
                  } catch (_) {}
                }
              },
              onError: (Object error, StackTrace stackTrace) {
                if (!controller.isClosed) {
                  controller.addError(_mapNetworkError(error), stackTrace);
                }
              },
              onDone: () {
                if (!controller.isClosed) {
                  unawaited(controller.close());
                }
              },
              cancelOnError: true,
            );
      } catch (error, stackTrace) {
        if (!controller.isClosed) {
          controller.addError(
            error is BlinkException ? error : _mapNetworkError(error),
            stackTrace,
          );
          await controller.close();
        }
      }
    }

    controller = StreamController<int>(
      onListen: () {
        unawaited(connect());
      },
      onCancel: () async {
        await lineSub?.cancel();
        lineSub = null;
        sseClient?.close(force: true);
        sseClient = null;
      },
    );
    return controller.stream;
  }

  Future<Map<String, Object?>> _sendJsonRequest(
    String method,
    String path, {
    Map<String, String>? queryParameters,
    Map<String, Object?>? body,
    bool includeAuth = true,
  }) async {
    final encodedBody = body == null
        ? null
        : Uint8List.fromList(utf8.encode(jsonEncode(body)));
    final response = await _openRequest(
      method,
      path,
      queryParameters: queryParameters,
      rawBody: encodedBody,
      contentType: body == null ? null : 'application/json; charset=utf-8',
      includeAuth: includeAuth,
    );
    final rawText = await utf8.decodeStream(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _parseErrorBody(response.statusCode, rawText);
    }
    try {
      final decoded = jsonDecode(rawText);
      if (decoded is Map) {
        return decoded.map(
          (k, v) => MapEntry<String, Object?>(k.toString(), v),
        );
      }
    } catch (_) {}
    throw BlinkException(
      code: BlinkErrorCode.ioError,
      message: 'Sync peer returned non-JSON response',
      retryable: true,
    );
  }

  Future<HttpClientResponse> _openRequest(
    String method,
    String path, {
    Map<String, String>? queryParameters,
    Uint8List? rawBody,
    String? contentType,
    Map<String, String>? extraHeaders,
    bool includeAuth = true,
  }) async {
    final uri = _resolveUri(path, queryParameters: queryParameters);
    try {
      final req = await _client.openUrl(method, uri).timeout(requestTimeout);
      _applyStandardHeaders(req, includeAuth: includeAuth);
      if (contentType != null) {
        req.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }
      if (extraHeaders != null) {
        extraHeaders.forEach((key, value) {
          req.headers.set(key, value);
        });
      }
      if (rawBody != null) {
        req.contentLength = rawBody.length;
        req.add(rawBody);
      }
      return await req.close().timeout(requestTimeout);
    } catch (error) {
      if (error is BlinkException) {
        rethrow;
      }
      throw _mapNetworkError(error);
    }
  }

  void _applyStandardHeaders(
    HttpClientRequest request, {
    required bool includeAuth,
  }) {
    request.headers.set('x-blink-protocol', protocolVersion.toString());
    request.headers.set('x-blink-channel', expectedChannel.wireValue);
    if (includeAuth && deviceToken != null && deviceToken!.isNotEmpty) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $deviceToken',
      );
    }
  }

  Uri _resolveUri(String path, {Map<String, String>? queryParameters}) {
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final basePath = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    return baseUri.replace(
      path: '$basePath$normalizedPath',
      queryParameters: queryParameters,
    );
  }

  static BlinkException _mapNetworkError(Object error) {
    if (error is BlinkException) {
      return error;
    }
    if (error is SocketException ||
        error is TimeoutException ||
        error is HandshakeException ||
        error is HttpException) {
      return BlinkException(
        code: BlinkErrorCode.peerAsleep,
        message: 'Direct sync peer unreachable or asleep',
        retryable: true,
        cause: error,
      );
    }
    return BlinkException(
      code: BlinkErrorCode.ioError,
      message: 'Direct sync transport error',
      retryable: true,
      cause: error,
    );
  }

  static BlinkException _parseErrorBody(int statusCode, String rawText) {
    try {
      final decoded = jsonDecode(rawText);
      if (decoded is Map) {
        final mapped = decoded.map(
          (k, v) => MapEntry<String, Object?>(k.toString(), v),
        );
        return _mapHttpStatusError(statusCode, mapped);
      }
    } catch (_) {}
    return _mapHttpStatusError(statusCode, const <String, Object?>{});
  }

  static BlinkException _mapHttpStatusError(
    int statusCode,
    Map<String, Object?> json,
  ) {
    final wireCode = json['code'] as String?;
    final message =
        (json['message'] as String?) ?? 'Sync peer returned HTTP $statusCode';
    final retryable = json['retryable'] == true || statusCode >= 500;

    final parsedCode = _tryParseErrorCode(wireCode);
    if (parsedCode != null) {
      return BlinkException(
        code: parsedCode,
        message: message,
        retryable: retryable,
      );
    }

    final fallbackCode = switch (statusCode) {
      401 => BlinkErrorCode.authRequired,
      403 => BlinkErrorCode.privacyBlocked,
      404 => BlinkErrorCode.notFound,
      409 => BlinkErrorCode.channelMismatch,
      426 => BlinkErrorCode.protocolMismatch,
      503 => BlinkErrorCode.peerAsleep,
      >= 400 && < 500 => BlinkErrorCode.invalidArgument,
      _ => BlinkErrorCode.ioError,
    };
    return BlinkException(
      code: fallbackCode,
      message: message,
      retryable: retryable,
    );
  }

  static BlinkErrorCode? _tryParseErrorCode(String? wireCode) {
    if (wireCode == null) {
      return null;
    }
    for (final value in BlinkErrorCode.values) {
      if (value.wireCode == wireCode) {
        return value;
      }
    }
    return null;
  }
}

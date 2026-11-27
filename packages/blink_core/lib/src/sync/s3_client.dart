import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:xml/xml.dart';

import '../errors/blink_error.dart';
import 'encrypted_relay_transport.dart';
import 's3_sigv4.dart';

/// Pure-Dart S3-compatible object store client (`ListObjectsV2`/`GET`/`PUT`/`HEAD`/`DELETE`)
/// built on `dart:io` `HttpClient` + `xml 7.1.0` + [S3SigV4Signer] (`AC-05`).
final class S3Client implements RelayObjectStore {
  S3Client({
    required this.endpoint,
    required this.bucket,
    required this.region,
    required String accessKeyId,
    required String secretAccessKey,
    String? sessionToken,
    String keyPrefix = '',
    this.usePathStyle = true,
    this.requestTimeout = const Duration(seconds: 20),
    HttpClient? httpClient,
  }) : keyPrefix = _normalizePrefix(keyPrefix),
       _signer = S3SigV4Signer(
         accessKeyId: accessKeyId,
         secretAccessKey: secretAccessKey,
         region: region,
         service: 's3',
         sessionToken: sessionToken,
       ),
       _ownsClient = httpClient == null,
       _client = httpClient ?? HttpClient() {
    _client.connectionTimeout = requestTimeout;
  }

  final Uri endpoint;
  final String bucket;
  final String region;
  final String keyPrefix;
  final bool usePathStyle;
  final Duration requestTimeout;
  final S3SigV4Signer _signer;
  final bool _ownsClient;
  final HttpClient _client;

  @override
  String get storeId {
    final hash = crypto.sha256
        .convert(utf8.encode('s3:${endpoint.origin}/$bucket/$keyPrefix'))
        .toString()
        .substring(0, 12);
    return 's3:$hash';
  }

  @override
  void close() {
    if (_ownsClient) {
      _client.close(force: false);
    }
  }

  @override
  Future<void> checkConnection() async {
    final uri = _bucketUri(
      queryParameters: <String, String>{
        'list-type': '2',
        'max-keys': '1',
        if (keyPrefix.isNotEmpty) 'prefix': keyPrefix,
      },
    );
    final resp = await _sendSigned('GET', uri);
    await resp.drain<void>();
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return;
    }
    throw _mapStatusError(resp.statusCode, 'S3 bucket check failed');
  }

  @override
  Future<void> ensurePrefix(String prefix) async {
    // S3 uses flat key prefixes; no directory creation required.
  }

  @override
  Future<List<String>> listKeys(String prefix) async {
    final normalized = _normalizeKey(prefix);
    final fullPrefix = keyPrefix.isEmpty
        ? normalized
        : (normalized.isEmpty ? keyPrefix : '$keyPrefix$normalized');

    final results = <String>[];
    String? continuationToken;

    while (true) {
      final query = <String, String>{
        'list-type': '2',
        if (fullPrefix.isNotEmpty) 'prefix': fullPrefix,
        'continuation-token': ?continuationToken,
      };
      final uri = _bucketUri(queryParameters: query);
      final resp = await _sendSigned('GET', uri);
      final rawXml = await utf8.decodeStream(resp);
      if (resp.statusCode == 404) {
        return const <String>[];
      }
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw _mapStatusError(resp.statusCode, 'S3 ListObjectsV2 failed');
      }

      final page = _parseListObjectsV2Xml(rawXml);
      for (final fullKey in page.keys) {
        final relative = _stripKeyPrefix(fullKey);
        if (relative != null && relative.isNotEmpty) {
          results.add(relative);
        }
      }

      if (!page.isTruncated ||
          page.nextContinuationToken == null ||
          page.nextContinuationToken!.isEmpty) {
        break;
      }
      continuationToken = page.nextContinuationToken;
    }

    results.sort();
    return results;
  }

  @override
  Future<bool> exists(String key) async {
    final resp = await _sendSigned('HEAD', _objectUri(key));
    await resp.drain<void>();
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return true;
    }
    if (resp.statusCode == 404) {
      return false;
    }
    throw _mapStatusError(resp.statusCode, 'S3 HEAD failed');
  }

  @override
  Future<void> putBytes(
    String key,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
  }) async {
    final resp = await _sendSigned(
      'PUT',
      _objectUri(key),
      headers: <String, String>{'content-type': contentType},
      body: bytes,
    );
    await resp.drain<void>();
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return;
    }
    throw _mapStatusError(resp.statusCode, 'S3 PUT failed');
  }

  @override
  Future<Uint8List?> getBytes(String key) async {
    final resp = await _sendSigned('GET', _objectUri(key));
    final builder = BytesBuilder(copy: false);
    await for (final chunk in resp) {
      builder.add(chunk);
    }
    if (resp.statusCode == 404) {
      return null;
    }
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return builder.takeBytes();
    }
    throw _mapStatusError(resp.statusCode, 'S3 GET failed');
  }

  @override
  Future<void> deleteKey(String key) async {
    final resp = await _sendSigned('DELETE', _objectUri(key));
    await resp.drain<void>();
    if (resp.statusCode == 404 ||
        (resp.statusCode >= 200 && resp.statusCode < 300)) {
      return;
    }
    throw _mapStatusError(resp.statusCode, 'S3 DELETE failed');
  }

  Future<HttpClientResponse> _sendSigned(
    String method,
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    Uint8List? body,
  }) async {
    final signed = _signer.signRequest(
      method: method,
      uri: uri,
      headers: headers,
      payload: body,
      doubleEncodePath: false,
      includeContentSha256Header: true,
    );
    try {
      final req = await _client.openUrl(method, uri).timeout(requestTimeout);
      signed.headers.forEach((k, v) {
        req.headers.set(k, v);
      });
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }
      return await req.close().timeout(requestTimeout);
    } catch (error) {
      if (error is BlinkException) {
        rethrow;
      }
      if (error is SocketException ||
          error is TimeoutException ||
          error is HandshakeException) {
        throw BlinkException(
          code: BlinkErrorCode.peerAsleep,
          message: 'S3 relay unreachable',
          retryable: true,
          cause: error,
        );
      }
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'S3 transport error',
        retryable: true,
        cause: error,
      );
    }
  }

  Uri _bucketUri({Map<String, String>? queryParameters}) {
    final basePath = endpoint.path.endsWith('/')
        ? endpoint.path.substring(0, endpoint.path.length - 1)
        : endpoint.path;
    if (usePathStyle) {
      return endpoint.replace(
        path: '$basePath/$bucket',
        queryParameters: queryParameters,
      );
    }
    return endpoint.replace(
      host: '$bucket.${endpoint.host}',
      path: basePath.isEmpty ? '/' : basePath,
      queryParameters: queryParameters,
    );
  }

  Uri _objectUri(String relativeKey) {
    final fullKey = '$keyPrefix${_normalizeKey(relativeKey)}';
    final encodedKey = fullKey
        .split('/')
        .map((s) => S3SigV4Signer.awsUriEncode(s, encodeSlash: true))
        .join('/');
    final basePath = endpoint.path.endsWith('/')
        ? endpoint.path.substring(0, endpoint.path.length - 1)
        : endpoint.path;
    if (usePathStyle) {
      return endpoint.replace(path: '$basePath/$bucket/$encodedKey');
    }
    return endpoint.replace(
      host: '$bucket.${endpoint.host}',
      path: '$basePath/$encodedKey',
    );
  }

  String? _stripKeyPrefix(String fullKey) {
    if (keyPrefix.isEmpty) {
      return _normalizeKey(fullKey);
    }
    if (!fullKey.startsWith(keyPrefix)) {
      return null;
    }
    return _normalizeKey(fullKey.substring(keyPrefix.length));
  }

  static ({List<String> keys, bool isTruncated, String? nextContinuationToken})
  _parseListObjectsV2Xml(String rawXml) {
    if (rawXml.trim().isEmpty) {
      return (
        keys: const <String>[],
        isTruncated: false,
        nextContinuationToken: null,
      );
    }
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(rawXml);
    } catch (error) {
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'S3 returned malformed ListObjectsV2 XML',
        cause: error,
      );
    }

    final keys = <String>[];
    for (final contents in doc.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'Contents',
    )) {
      final keyEl = contents.childElements.where((e) => e.name.local == 'Key');
      if (keyEl.isNotEmpty) {
        final keyText = keyEl.first.innerText;
        if (keyText.isNotEmpty) {
          keys.add(keyText);
        }
      }
    }

    final truncatedEl = doc.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'IsTruncated',
    );
    final isTruncated =
        truncatedEl.isNotEmpty &&
        truncatedEl.first.innerText.trim().toLowerCase() == 'true';

    final tokenEl = doc.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'NextContinuationToken',
    );
    final nextToken = tokenEl.isNotEmpty
        ? tokenEl.first.innerText.trim()
        : null;

    return (
      keys: keys,
      isTruncated: isTruncated,
      nextContinuationToken: nextToken,
    );
  }

  static String _normalizePrefix(String prefix) {
    final trimmed = _normalizeKey(prefix);
    return trimmed.isEmpty ? '' : '$trimmed/';
  }

  static String _normalizeKey(String key) {
    var result = key.trim();
    while (result.startsWith('/')) {
      result = result.substring(1);
    }
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  static BlinkException _mapStatusError(int statusCode, String message) {
    if (statusCode == 401 || statusCode == 403) {
      return BlinkException(
        code: BlinkErrorCode.authRequired,
        message: '$message (HTTP $statusCode)',
      );
    }
    if (statusCode == 507) {
      return BlinkException(
        code: BlinkErrorCode.storageFull,
        message: '$message (HTTP 507)',
      );
    }
    return BlinkException(
      code: BlinkErrorCode.ioError,
      message: '$message (HTTP $statusCode)',
      retryable: statusCode >= 500,
    );
  }
}

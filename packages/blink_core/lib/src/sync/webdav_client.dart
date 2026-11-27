import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:xml/xml.dart';

import '../errors/blink_error.dart';
import 'encrypted_relay_transport.dart';

/// Pure-Dart WebDAV client (`PROPFIND`/`MKCOL`/`GET`/`PUT`/`HEAD`/`DELETE`)
/// built on `dart:io` `HttpClient` + `xml 7.1.0` for Channel B E2EE relay (`AC-05`).
final class WebDavClient implements RelayObjectStore {
  WebDavClient({
    required Uri baseUri,
    this.username,
    this.password,
    this.bearerToken,
    this.requestTimeout = const Duration(seconds: 20),
    HttpClient? httpClient,
  }) : baseUri = _normalizeBaseUri(baseUri),
       _ownsClient = httpClient == null,
       _client = httpClient ?? HttpClient() {
    _client.connectionTimeout = requestTimeout;
  }

  final Uri baseUri;
  final String? username;
  final String? password;
  final String? bearerToken;
  final Duration requestTimeout;
  final bool _ownsClient;
  final HttpClient _client;

  @override
  String get storeId {
    final hash = crypto.sha256
        .convert(utf8.encode('webdav:${baseUri.origin}${baseUri.path}'))
        .toString()
        .substring(0, 12);
    return 'webdav:$hash';
  }

  @override
  void close() {
    if (_ownsClient) {
      _client.close(force: false);
    }
  }

  @override
  Future<void> checkConnection() async {
    final resp = await _send(
      'PROPFIND',
      '',
      headers: const <String, String>{
        'depth': '0',
        'content-type': 'application/xml; charset=utf-8',
      },
      body: _propfindBody,
    );
    await resp.drain<void>();
    if (resp.statusCode == 207 ||
        (resp.statusCode >= 200 && resp.statusCode < 300)) {
      return;
    }
    throw _mapStatusError(resp.statusCode, 'WebDAV connection check failed');
  }

  @override
  Future<void> ensurePrefix(String prefix) async {
    final normalized = _normalizeKey(prefix);
    if (normalized.isEmpty) {
      return;
    }
    final segments = normalized.split('/').where((s) => s.isNotEmpty).toList();
    final current = StringBuffer();
    for (final segment in segments) {
      if (current.isNotEmpty) {
        current.write('/');
      }
      current.write(segment);
      final resp = await _send('MKCOL', '${current.toString()}/');
      await resp.drain<void>();
      // 201 Created, 405 Already Exists, 301/302 Redirect to collection, 200 OK.
      if (resp.statusCode == 201 ||
          resp.statusCode == 200 ||
          resp.statusCode == 204 ||
          resp.statusCode == 405 ||
          resp.statusCode == 301) {
        continue;
      }
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        throw _mapStatusError(resp.statusCode, 'WebDAV MKCOL unauthorized');
      }
    }
  }

  @override
  Future<List<String>> listKeys(String prefix) async {
    final normalizedPrefix = _normalizeKey(prefix);
    final keys = <String>[];
    final visitedDirs = <String>{};

    Future<void> walkDir(String dirRelPath) async {
      final cleanDir = _normalizeKey(dirRelPath);
      if (!visitedDirs.add(cleanDir)) {
        return;
      }
      final requestPath = cleanDir.isEmpty ? '' : '$cleanDir/';
      final resp = await _send(
        'PROPFIND',
        requestPath,
        headers: const <String, String>{
          'depth': '1',
          'content-type': 'application/xml; charset=utf-8',
        },
        body: _propfindBody,
      );
      final rawXml = await utf8.decodeStream(resp);
      if (resp.statusCode == 404) {
        return;
      }
      if (resp.statusCode != 207 &&
          (resp.statusCode < 200 || resp.statusCode >= 300)) {
        throw _mapStatusError(resp.statusCode, 'WebDAV PROPFIND failed');
      }

      final entries = _parsePropfindMultistatus(rawXml);
      for (final entry in entries) {
        final rel = _hrefToRelativeKey(entry.href);
        if (rel == null || rel == cleanDir) {
          continue;
        }
        if (entry.isCollection) {
          if (cleanDir.isEmpty || rel.startsWith('$cleanDir/')) {
            await walkDir(rel);
          }
        } else {
          if (normalizedPrefix.isEmpty ||
              rel == normalizedPrefix ||
              rel.startsWith('$normalizedPrefix/')) {
            keys.add(rel);
          }
        }
      }
    }

    await walkDir(normalizedPrefix);
    keys.sort();
    return keys;
  }

  @override
  Future<bool> exists(String key) async {
    final resp = await _send('HEAD', _normalizeKey(key));
    await resp.drain<void>();
    if (resp.statusCode == 200 || resp.statusCode == 204) {
      return true;
    }
    if (resp.statusCode == 404) {
      return false;
    }
    throw _mapStatusError(resp.statusCode, 'WebDAV HEAD failed');
  }

  @override
  Future<void> putBytes(
    String key,
    Uint8List bytes, {
    String contentType = 'application/octet-stream',
  }) async {
    final normalized = _normalizeKey(key);
    final slash = normalized.lastIndexOf('/');
    if (slash > 0) {
      await ensurePrefix(normalized.substring(0, slash));
    }

    final resp = await _send(
      'PUT',
      normalized,
      headers: <String, String>{'content-type': contentType},
      body: bytes,
    );
    await resp.drain<void>();
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      return;
    }
    throw _mapStatusError(resp.statusCode, 'WebDAV PUT failed');
  }

  @override
  Future<Uint8List?> getBytes(String key) async {
    final resp = await _send('GET', _normalizeKey(key));
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
    throw _mapStatusError(resp.statusCode, 'WebDAV GET failed');
  }

  @override
  Future<void> deleteKey(String key) async {
    final resp = await _send('DELETE', _normalizeKey(key));
    await resp.drain<void>();
    if (resp.statusCode == 404 ||
        (resp.statusCode >= 200 && resp.statusCode < 300)) {
      return;
    }
    throw _mapStatusError(resp.statusCode, 'WebDAV DELETE failed');
  }

  Future<HttpClientResponse> _send(
    String method,
    String relativePath, {
    Map<String, String>? headers,
    Uint8List? body,
  }) async {
    final uri = _resolveKeyUri(relativePath);
    try {
      final req = await _client.openUrl(method, uri).timeout(requestTimeout);
      _applyAuthHeaders(req);
      headers?.forEach((k, v) => req.headers.set(k, v));
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
          message: 'WebDAV relay unreachable',
          retryable: true,
          cause: error,
        );
      }
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'WebDAV transport error',
        retryable: true,
        cause: error,
      );
    }
  }

  void _applyAuthHeaders(HttpClientRequest request) {
    if (bearerToken != null && bearerToken!.isNotEmpty) {
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $bearerToken',
      );
    } else if (username != null) {
      final credentials = '$username:${password ?? ''}';
      final encoded = base64Encode(utf8.encode(credentials));
      request.headers.set(HttpHeaders.authorizationHeader, 'Basic $encoded');
    }
  }

  Uri _resolveKeyUri(String relativePath) {
    final cleanBase = baseUri.path.endsWith('/')
        ? baseUri.path
        : '${baseUri.path}/';
    final cleanRel = relativePath.startsWith('/')
        ? relativePath.substring(1)
        : relativePath;
    return baseUri.replace(path: '$cleanBase$cleanRel');
  }

  String? _hrefToRelativeKey(String rawHref) {
    String pathPart;
    try {
      final parsed = Uri.parse(rawHref);
      pathPart = parsed.path;
    } catch (_) {
      pathPart = rawHref;
    }
    final decodedPath = Uri.decodeFull(pathPart);
    final basePath = Uri.decodeFull(baseUri.path);
    final normalizedBase = basePath.endsWith('/') ? basePath : '$basePath/';
    if (decodedPath == normalizedBase || '$decodedPath/' == normalizedBase) {
      return '';
    }
    if (!decodedPath.startsWith(normalizedBase)) {
      return null;
    }
    final rel = decodedPath.substring(normalizedBase.length);
    return _normalizeKey(rel);
  }

  static List<({String href, bool isCollection})> _parsePropfindMultistatus(
    String rawXml,
  ) {
    if (rawXml.trim().isEmpty) {
      return const <({String href, bool isCollection})>[];
    }
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(rawXml);
    } catch (error) {
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'WebDAV returned malformed XML multistatus',
        cause: error,
      );
    }

    final results = <({String href, bool isCollection})>[];
    for (final responseEl in doc.descendants.whereType<XmlElement>().where(
      (e) => e.name.local.toLowerCase() == 'response',
    )) {
      final hrefEl = responseEl.descendants.whereType<XmlElement>().where(
        (e) => e.name.local.toLowerCase() == 'href',
      );
      if (hrefEl.isEmpty) {
        continue;
      }
      final href = hrefEl.first.innerText.trim();
      if (href.isEmpty) {
        continue;
      }
      final hasCollectionTag = responseEl.descendants
          .whereType<XmlElement>()
          .any((e) => e.name.local.toLowerCase() == 'collection');
      final isCollection = hasCollectionTag || href.endsWith('/');
      results.add((href: href, isCollection: isCollection));
    }
    return results;
  }

  static Uri _normalizeBaseUri(Uri uri) {
    final path = uri.path.isEmpty
        ? '/'
        : (uri.path.endsWith('/') ? uri.path : '${uri.path}/');
    return uri.replace(path: path);
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
        message: '$message (HTTP 507 Insufficient Storage)',
      );
    }
    return BlinkException(
      code: BlinkErrorCode.ioError,
      message: '$message (HTTP $statusCode)',
      retryable: statusCode >= 500,
    );
  }

  static final Uint8List _propfindBody = Uint8List.fromList(
    utf8.encode(
      '<?xml version="1.0" encoding="utf-8"?>'
      '<d:propfind xmlns:d="DAV:">'
      '<d:prop><d:resourcetype/></d:prop>'
      '</d:propfind>',
    ),
  );
}

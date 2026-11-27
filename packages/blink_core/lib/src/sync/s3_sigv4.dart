import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:meta/meta.dart';

/// Signed AWS Signature Version 4 output produced by [S3SigV4Signer].
@immutable
final class S3SignedRequest {
  S3SignedRequest({
    required Map<String, String> headers,
    required this.authorizationHeader,
    required this.amzDate,
    required this.payloadSha256,
    required this.canonicalRequest,
    required this.stringToSign,
    required this.signedHeaders,
    required this.signature,
  }) : headers = Map<String, String>.unmodifiable(headers);

  final Map<String, String> headers;
  final String authorizationHeader;
  final String amzDate;
  final String payloadSha256;
  final String canonicalRequest;
  final String stringToSign;
  final String signedHeaders;
  final String signature;
}

/// Pure-Dart AWS Signature Version 4 signer using `package:crypto` (`SHA-256` + `HMAC-SHA256`).
final class S3SigV4Signer {
  const S3SigV4Signer({
    required this.accessKeyId,
    required this.secretAccessKey,
    required this.region,
    this.service = 's3',
    this.sessionToken,
  });

  final String accessKeyId;
  final String secretAccessKey;
  final String region;
  final String service;
  final String? sessionToken;

  /// Canonical SHA-256 hex digest of an empty byte payload.
  static const String emptyPayloadSha256 =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

  /// Signs an HTTP request according to AWS Signature Version 4.
  ///
  /// For Amazon S3, keep [doubleEncodePath] `false` and [includeContentSha256Header] `true`.
  S3SignedRequest signRequest({
    required String method,
    required Uri uri,
    Map<String, String> headers = const <String, String>{},
    Uint8List? payload,
    String? payloadSha256Hex,
    DateTime? timestampUtc,
    bool doubleEncodePath = false,
    bool includeContentSha256Header = true,
  }) {
    final utc = (timestampUtc ?? DateTime.now().toUtc()).toUtc();
    final dateStamp = _formatDateStamp(utc);
    final amzDate = _formatAmzDate(utc);
    final upperMethod = method.toUpperCase();

    final contentSha256 =
        payloadSha256Hex ??
        (payload == null || payload.isEmpty
            ? emptyPayloadSha256
            : crypto.sha256.convert(payload).toString());

    final normalizedHeaders = <String, String>{};
    headers.forEach((key, value) {
      normalizedHeaders[key.toLowerCase().trim()] = _trimCollapseSpaces(value);
    });
    normalizedHeaders.putIfAbsent('host', () => _formatHostHeader(uri));
    normalizedHeaders.putIfAbsent('x-amz-date', () => amzDate);
    if (includeContentSha256Header) {
      normalizedHeaders.putIfAbsent(
        'x-amz-content-sha256',
        () => contentSha256,
      );
    }
    if (sessionToken != null && sessionToken!.isNotEmpty) {
      normalizedHeaders.putIfAbsent(
        'x-amz-security-token',
        () => sessionToken!.trim(),
      );
    }

    final sortedKeys = normalizedHeaders.keys.toList()..sort();
    final canonicalHeadersBuf = StringBuffer();
    for (final key in sortedKeys) {
      canonicalHeadersBuf.write('$key:${normalizedHeaders[key]}\n');
    }
    final signedHeaders = sortedKeys.join(';');

    final canonicalUri = _buildCanonicalUri(
      uri,
      doubleEncodePath: doubleEncodePath,
    );
    final canonicalQuery = _buildCanonicalQuery(uri);

    final canonicalRequest = <String>[
      upperMethod,
      canonicalUri,
      canonicalQuery,
      canonicalHeadersBuf.toString(),
      signedHeaders,
      contentSha256,
    ].join('\n');

    final credentialScope = '$dateStamp/$region/$service/aws4_request';
    final canonicalRequestHash = crypto.sha256
        .convert(utf8.encode(canonicalRequest))
        .toString();

    final stringToSign = <String>[
      'AWS4-HMAC-SHA256',
      normalizedHeaders['x-amz-date']!,
      credentialScope,
      canonicalRequestHash,
    ].join('\n');

    final signingKey = _deriveSigningKey(
      secretAccessKey: secretAccessKey,
      dateStamp: dateStamp,
      region: region,
      service: service,
    );
    final signature = _hmacSha256Hex(signingKey, utf8.encode(stringToSign));

    final authorization =
        'AWS4-HMAC-SHA256 Credential=$accessKeyId/$credentialScope, '
        'SignedHeaders=$signedHeaders, '
        'Signature=$signature';

    final outputHeaders = Map<String, String>.of(normalizedHeaders)
      ..['authorization'] = authorization;

    return S3SignedRequest(
      headers: outputHeaders,
      authorizationHeader: authorization,
      amzDate: normalizedHeaders['x-amz-date']!,
      payloadSha256: contentSha256,
      canonicalRequest: canonicalRequest,
      stringToSign: stringToSign,
      signedHeaders: signedHeaders,
      signature: signature,
    );
  }

  static List<int> _deriveSigningKey({
    required String secretAccessKey,
    required String dateStamp,
    required String region,
    required String service,
  }) {
    final kDate = _hmacSha256(
      utf8.encode('AWS4$secretAccessKey'),
      utf8.encode(dateStamp),
    );
    final kRegion = _hmacSha256(kDate, utf8.encode(region));
    final kService = _hmacSha256(kRegion, utf8.encode(service));
    return _hmacSha256(kService, utf8.encode('aws4_request'));
  }

  static List<int> _hmacSha256(List<int> key, List<int> message) =>
      crypto.Hmac(crypto.sha256, key).convert(message).bytes;

  static String _hmacSha256Hex(List<int> key, List<int> message) =>
      crypto.Hmac(crypto.sha256, key).convert(message).toString();

  static String _formatHostHeader(Uri uri) {
    final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
    if (!uri.hasPort) {
      return host;
    }
    final isDefault =
        (uri.scheme == 'http' && uri.port == 80) ||
        (uri.scheme == 'https' && uri.port == 443);
    return isDefault ? host : '$host:${uri.port}';
  }

  static String _buildCanonicalUri(Uri uri, {required bool doubleEncodePath}) {
    final rawPath = uri.path;
    if (rawPath.isEmpty || rawPath == '/') {
      return '/';
    }
    final hasTrailingSlash = rawPath.endsWith('/');
    final segments = rawPath.split('/').where((s) => s.isNotEmpty).toList();
    final encodedSegments = segments.map((segment) {
      final decoded = doubleEncodePath ? segment : Uri.decodeComponent(segment);
      return awsUriEncode(decoded, encodeSlash: true);
    });
    final joined = '/${encodedSegments.join('/')}';
    return hasTrailingSlash && !joined.endsWith('/') ? '$joined/' : joined;
  }

  static String _buildCanonicalQuery(Uri uri) {
    if (uri.query.isEmpty) {
      return '';
    }
    final pairs = <({String key, String value})>[];
    for (final part in uri.query.split('&')) {
      if (part.isEmpty) {
        continue;
      }
      final eqIdx = part.indexOf('=');
      final rawKey = eqIdx < 0 ? part : part.substring(0, eqIdx);
      final rawVal = eqIdx < 0 ? '' : part.substring(eqIdx + 1);
      final decodedKey = Uri.decodeQueryComponent(
        rawKey.replaceAll('+', '%20'),
      );
      final decodedVal = Uri.decodeQueryComponent(
        rawVal.replaceAll('+', '%20'),
      );
      pairs.add((
        key: awsUriEncode(decodedKey, encodeSlash: true),
        value: awsUriEncode(decodedVal, encodeSlash: true),
      ));
    }
    pairs.sort((a, b) {
      final kCmp = a.key.compareTo(b.key);
      return kCmp != 0 ? kCmp : a.value.compareTo(b.value);
    });
    return pairs.map((p) => '${p.key}=${p.value}').join('&');
  }

  /// RFC 3986 percent-encoding required by AWS SigV4 (unreserved: `A-Z a-z 0-9 - _ . ~`).
  static String awsUriEncode(String input, {required bool encodeSlash}) {
    final bytes = utf8.encode(input);
    final out = StringBuffer();
    for (final b in bytes) {
      final isUnreserved =
          (b >= 0x41 && b <= 0x5A) || // A-Z
          (b >= 0x61 && b <= 0x7A) || // a-z
          (b >= 0x30 && b <= 0x39) || // 0-9
          b == 0x2D || // -
          b == 0x5F || // _
          b == 0x2E || // .
          b == 0x7E || // ~
          (!encodeSlash && b == 0x2F); // /
      if (isUnreserved) {
        out.writeCharCode(b);
      } else {
        out.write('%');
        out.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    return out.toString();
  }

  static String _trimCollapseSpaces(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');

  static String _formatDateStamp(DateTime utc) {
    final y = utc.year.toString().padLeft(4, '0');
    final m = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    return '$y$m$d';
  }

  static String _formatAmzDate(DateTime utc) {
    final hh = utc.hour.toString().padLeft(2, '0');
    final mm = utc.minute.toString().padLeft(2, '0');
    final ss = utc.second.toString().padLeft(2, '0');
    return '${_formatDateStamp(utc)}T$hh$mm${ss}Z';
  }
}

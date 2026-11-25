import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../errors/blink_error.dart';
import '../models/blink_models.dart';
import '../utils/atomic_io.dart';

final RegExp _sha256HexPattern = RegExp(r'^[0-9a-f]{64}$');

/// Content-addressed attachment store (`blobs/<xx>/<yy>/<sha256>`) (`INV-07`, `INV-12`).
abstract interface class BlobStore {
  /// Streams SHA-256, writes `.blink-tmp` + `flush()` + size/hash verify + atomic rename to `blobs/<xx>/<yy>/<sha256>`.
  Future<MediaBlob> putBytes(
    Uint8List bytes, {
    required String mimeType,
    int? width,
    int? height,
    int? durationMs,
  });

  /// Streams [sourceFile] into SHA-256 + `.blink-tmp` + `flush()` + verify + atomic rename.
  Future<MediaBlob> putFile(
    File sourceFile, {
    required String mimeType,
    int? width,
    int? height,
    int? durationMs,
  });

  Future<MediaBlob?> getMetadata(String sha256);

  /// Validates `^[0-9a-f]{64}$` before resolving disk path (zero path traversal).
  Future<File?> resolveFile(String sha256);

  Future<Uint8List?> readBytes(String sha256);

  Future<List<MediaBlob>> listBlobs({int limit = 200, int offset = 0});

  /// Deletes ONLY `media_blobs` rows and owned files under `blobs/` referenced by
  /// zero remaining entries (active or trashed), sources, or drafts (`INV-12`).
  Future<int> gcUnreferencedBlobs();
}

/// Validates that [sha256] is a strict 64-char lowercase hex digest.
bool isValidBlobSha256(String sha256) => _sha256HexPattern.hasMatch(sha256);

/// SQLite + filesystem implementation of [BlobStore].
final class SqliteBlobStore implements BlobStore {
  SqliteBlobStore({
    required this._vaultDir,
    required this._dbProvider,
    required this._runWriteTx,
    required this._onMutated,
  });

  final Directory _vaultDir;
  final Database Function() _dbProvider;
  final T Function<T>(T Function(Database db) action) _runWriteTx;
  final void Function() _onMutated;

  @override
  Future<MediaBlob> putBytes(
    Uint8List bytes, {
    required String mimeType,
    int? width,
    int? height,
    int? durationMs,
  }) async {
    final normalizedMime = _requireMimeType(mimeType);
    final digest = crypto.sha256.convert(bytes).toString();
    final relPath = _storageRelPath(digest);
    final targetFile = _diskFileForRelPath(relPath);

    if (!await targetFile.exists()) {
      await _writeAndVerifyBytes(targetFile, bytes, expectedSha256: digest);
    }

    final blob = _upsertBlobMetadata(
      sha256: digest,
      mimeType: normalizedMime,
      byteSize: bytes.length,
      width: width,
      height: height,
      durationMs: durationMs,
      storageRelPath: relPath,
    );
    _onMutated();
    return blob;
  }

  @override
  Future<MediaBlob> putFile(
    File sourceFile, {
    required String mimeType,
    int? width,
    int? height,
    int? durationMs,
  }) async {
    final normalizedMime = _requireMimeType(mimeType);
    if (!await sourceFile.exists()) {
      throw BlinkException(
        code: BlinkErrorCode.notFound,
        message: 'Source file does not exist for blob import',
      );
    }

    final blobsRoot = Directory(p.join(_vaultDir.path, 'blobs'));
    await blobsRoot.create(recursive: true);
    final tempFile = siblingTempFile(File(p.join(blobsRoot.path, 'import')));

    RandomAccessFile? outRaf;
    var byteSize = 0;
    String digestHex;
    try {
      outRaf = await tempFile.open(mode: FileMode.writeOnly);
      final digestChunks = <crypto.Digest>[];
      final digestSink = _SingleDigestSink(digestChunks);
      final hashInput = crypto.sha256.startChunkedConversion(digestSink);

      await for (final chunk in sourceFile.openRead()) {
        final chunkBytes = chunk is Uint8List
            ? chunk
            : Uint8List.fromList(chunk);
        await outRaf.writeFrom(chunkBytes);
        hashInput.add(chunkBytes);
        byteSize += chunkBytes.length;
      }
      hashInput.close();
      await outRaf.flush();
      await outRaf.close();
      outRaf = null;

      digestHex = digestChunks.single.toString();

      // Re-verify written file length and SHA-256 before atomic move (`INV-07`).
      final actualLen = await tempFile.length();
      final actualDigest = await _sha256File(tempFile);
      if (actualLen != byteSize || actualDigest != digestHex) {
        throw BlinkException(
          code: BlinkErrorCode.ioError,
          message: 'Blob verification failed after flush',
        );
      }

      final relPath = _storageRelPath(digestHex);
      final targetFile = _diskFileForRelPath(relPath);
      if (await targetFile.exists()) {
        await tempFile.delete();
      } else {
        await targetFile.parent.create(recursive: true);
        await atomicRenameWithRetry(tempFile, targetFile);
      }

      final blob = _upsertBlobMetadata(
        sha256: digestHex,
        mimeType: normalizedMime,
        byteSize: byteSize,
        width: width,
        height: height,
        durationMs: durationMs,
        storageRelPath: relPath,
      );
      _onMutated();
      return blob;
    } catch (error) {
      if (outRaf != null) {
        try {
          await outRaf.close();
        } catch (_) {}
      }
      try {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {}
      if (error is BlinkException) {
        rethrow;
      }
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'Failed to import blob file: $error',
        retryable: true,
        cause: error,
      );
    }
  }

  @override
  Future<MediaBlob?> getMetadata(String sha256) async {
    _validateSha256OrThrow(sha256);
    final db = _dbProvider();
    final rows = db.select(
      'SELECT sha256, mime_type, byte_size, width, height, duration_ms, storage_rel_path, created_at '
      'FROM media_blobs WHERE sha256 = ? LIMIT 1',
      <Object?>[sha256],
    );
    if (rows.isEmpty) {
      return null;
    }
    return _rowToMediaBlob(rows.first);
  }

  @override
  Future<File?> resolveFile(String sha256) async {
    _validateSha256OrThrow(sha256);
    final meta = await getMetadata(sha256);
    if (meta == null) {
      return null;
    }
    final expectedRel = _storageRelPath(sha256);
    if (meta.storageRelPath != expectedRel) {
      throw BlinkException(
        code: BlinkErrorCode.ioError,
        message: 'Corrupt storage_rel_path for blob $sha256',
      );
    }
    final file = _diskFileForRelPath(expectedRel);
    if (!await file.exists()) {
      return null;
    }
    return file;
  }

  @override
  Future<Uint8List?> readBytes(String sha256) async {
    final file = await resolveFile(sha256);
    if (file == null) {
      return null;
    }
    return file.readAsBytes();
  }

  @override
  Future<List<MediaBlob>> listBlobs({int limit = 200, int offset = 0}) async {
    if (limit < 0 || offset < 0) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'limit and offset must be non-negative',
      );
    }
    final db = _dbProvider();
    final rows = db.select(
      'SELECT sha256, mime_type, byte_size, width, height, duration_ms, storage_rel_path, created_at '
      'FROM media_blobs ORDER BY created_at DESC, sha256 ASC LIMIT ? OFFSET ?',
      <Object?>[limit, offset],
    );
    return rows.map(_rowToMediaBlob).toList(growable: false);
  }

  @override
  Future<int> gcUnreferencedBlobs() async {
    final candidates = _runWriteTx<List<MediaBlob>>((db) {
      final referenced = <String>{};

      // Active AND trashed raw_entries protect their blobs until permanently purged (`INV-12`).
      for (final row in db.select(
        'SELECT audio_blob_sha256, image_blob_sha256s FROM raw_entries',
      )) {
        final audio = row['audio_blob_sha256'] as String?;
        if (audio != null && isValidBlobSha256(audio)) {
          referenced.add(audio);
        }
        _collectJsonShaList(row['image_blob_sha256s'] as String?, referenced);
      }

      for (final row in db.select(
        'SELECT file_blob_sha256, cover_blob_sha256 FROM raw_sources',
      )) {
        final fileSha = row['file_blob_sha256'] as String?;
        if (fileSha != null && isValidBlobSha256(fileSha)) {
          referenced.add(fileSha);
        }
        final coverSha = row['cover_blob_sha256'] as String?;
        if (coverSha != null && isValidBlobSha256(coverSha)) {
          referenced.add(coverSha);
        }
      }

      for (final row in db.select(
        'SELECT image_blob_sha256s FROM editor_drafts',
      )) {
        _collectJsonShaList(row['image_blob_sha256s'] as String?, referenced);
      }

      final allBlobs = db
          .select(
            'SELECT sha256, mime_type, byte_size, width, height, duration_ms, storage_rel_path, created_at '
            'FROM media_blobs',
          )
          .map(_rowToMediaBlob)
          .toList(growable: false);

      final unreferenced = <MediaBlob>[];
      for (final blob in allBlobs) {
        if (!referenced.contains(blob.sha256)) {
          unreferenced.add(blob);
          db.execute('DELETE FROM media_blobs WHERE sha256 = ?', <Object?>[
            blob.sha256,
          ]);
        }
      }
      return unreferenced;
    });

    var deletedCount = 0;
    for (final blob in candidates) {
      if (!isValidBlobSha256(blob.sha256)) {
        continue;
      }
      final expectedRel = _storageRelPath(blob.sha256);
      if (blob.storageRelPath != expectedRel) {
        continue;
      }
      final diskFile = _diskFileForRelPath(expectedRel);
      if (await diskFile.exists()) {
        try {
          await diskFile.delete();
        } catch (_) {
          // Best-effort file deletion after DB row removal.
        }
      }
      deletedCount += 1;
    }

    if (deletedCount > 0) {
      _onMutated();
    }
    return deletedCount;
  }

  Future<void> _writeAndVerifyBytes(
    File targetFile,
    Uint8List bytes, {
    required String expectedSha256,
  }) async {
    await targetFile.parent.create(recursive: true);
    final tempFile = siblingTempFile(targetFile);
    RandomAccessFile? raf;
    try {
      raf = await tempFile.open(mode: FileMode.writeOnly);
      await raf.writeFrom(bytes);
      await raf.flush();
      await raf.close();
      raf = null;

      final actualLen = await tempFile.length();
      final actualDigest = await _sha256File(tempFile);
      if (actualLen != bytes.length || actualDigest != expectedSha256) {
        throw BlinkException(
          code: BlinkErrorCode.ioError,
          message: 'Blob write verification failed for $expectedSha256',
        );
      }
      await atomicRenameWithRetry(tempFile, targetFile);
    } catch (error) {
      if (raf != null) {
        try {
          await raf.close();
        } catch (_) {}
      }
      try {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      } catch (_) {}
      rethrow;
    }
  }

  MediaBlob _upsertBlobMetadata({
    required String sha256,
    required String mimeType,
    required int byteSize,
    required int? width,
    required int? height,
    required int? durationMs,
    required String storageRelPath,
  }) {
    final nowUtc = DateTime.now().toUtc();
    return _runWriteTx<MediaBlob>((db) {
      final existing = db.select(
        'SELECT sha256, mime_type, byte_size, width, height, duration_ms, storage_rel_path, created_at '
        'FROM media_blobs WHERE sha256 = ? LIMIT 1',
        <Object?>[sha256],
      );
      if (existing.isNotEmpty) {
        return _rowToMediaBlob(existing.first);
      }
      db.execute(
        'INSERT INTO media_blobs '
        '(sha256, mime_type, byte_size, width, height, duration_ms, storage_rel_path, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        <Object?>[
          sha256,
          mimeType,
          byteSize,
          width,
          height,
          durationMs,
          storageRelPath,
          nowUtc.toIso8601String(),
        ],
      );
      return MediaBlob(
        sha256: sha256,
        mimeType: mimeType,
        byteSize: byteSize,
        width: width,
        height: height,
        durationMs: durationMs,
        storageRelPath: storageRelPath,
        createdAtUtc: nowUtc,
      );
    });
  }

  static String _requireMimeType(String mimeType) {
    final trimmed = mimeType.trim();
    if (trimmed.isEmpty || trimmed.contains('\n') || trimmed.contains('\r')) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Invalid MIME type for blob storage',
      );
    }
    return trimmed;
  }

  static void _validateSha256OrThrow(String sha256) {
    if (!isValidBlobSha256(sha256)) {
      throw BlinkException(
        code: BlinkErrorCode.invalidArgument,
        message: 'Invalid blob SHA-256 digest: expected 64 lowercase hex chars',
      );
    }
  }

  static String _storageRelPath(String sha256) =>
      'blobs/${sha256.substring(0, 2)}/${sha256.substring(2, 4)}/$sha256';

  File _diskFileForRelPath(String relPath) {
    final parts = relPath.split('/');
    return File(p.joinAll(<String>[_vaultDir.path, ...parts]));
  }

  static MediaBlob _rowToMediaBlob(Row row) => MediaBlob(
    sha256: row['sha256'] as String,
    mimeType: row['mime_type'] as String,
    byteSize: row['byte_size'] as int,
    width: row['width'] as int?,
    height: row['height'] as int?,
    durationMs: row['duration_ms'] as int?,
    storageRelPath: row['storage_rel_path'] as String,
    createdAtUtc: DateTime.parse(row['created_at'] as String).toUtc(),
  );

  static void _collectJsonShaList(String? rawJson, Set<String> out) {
    if (rawJson == null || rawJson.isEmpty) {
      return;
    }
    try {
      final decoded = jsonDecode(rawJson);
      if (decoded is List) {
        for (final item in decoded) {
          if (item is String && isValidBlobSha256(item)) {
            out.add(item);
          }
        }
      }
    } catch (_) {}
  }

  static Future<String> _sha256File(File file) async {
    final digestChunks = <crypto.Digest>[];
    final sink = _SingleDigestSink(digestChunks);
    final input = crypto.sha256.startChunkedConversion(sink);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return digestChunks.single.toString();
  }
}

final class _SingleDigestSink implements Sink<crypto.Digest> {
  _SingleDigestSink(this._out);

  final List<crypto.Digest> _out;

  @override
  void add(crypto.Digest data) => _out.add(data);

  @override
  void close() {}
}

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../errors/blink_error.dart';

final Random _tmpNonceRng = Random.secure();

/// Creates a unique sibling `.blink-tmp` path in the same directory as [targetFile].
File siblingTempFile(File targetFile) {
  final dir = targetFile.parent.path;
  final base = p.basename(targetFile.path);
  final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
  final nonce = _tmpNonceRng.nextInt(0xFFFF).toRadixString(16).padLeft(4, '0');
  return File(p.join(dir, '.$base.$micros.$nonce.blink-tmp'));
}

/// Atomically writes [bytes] to [targetFile] via sibling `.blink-tmp` -> `flush()` -> `rename()`
/// with bounded Windows file-lock retry (`INV-07`).
Future<void> writeBytesAtomically(File targetFile, Uint8List bytes) async {
  await targetFile.parent.create(recursive: true);
  final tempFile = siblingTempFile(targetFile);
  RandomAccessFile? raf;
  try {
    raf = await tempFile.open(mode: FileMode.writeOnly);
    await raf.writeFrom(bytes);
    await raf.flush();
    await raf.close();
    raf = null;
    await atomicRenameWithRetry(tempFile, targetFile);
  } catch (error) {
    if (raf != null) {
      try {
        await raf.close();
      } catch (_) {}
    }
    await _bestEffortDelete(tempFile);
    if (error is BlinkException) {
      rethrow;
    }
    throw BlinkException(
      code: BlinkErrorCode.ioError,
      message: 'Atomic write failed for ${p.basename(targetFile.path)}: $error',
      retryable: true,
      cause: error,
    );
  }
}

/// Atomically writes UTF-8 (no BOM) [content] to [targetFile] (`INV-07`).
Future<void> writeStringAtomically(File targetFile, String content) async {
  final bytes = Uint8List.fromList(utf8.encode(content));
  await writeBytesAtomically(targetFile, bytes);
}

/// Atomically renames [sourceFile] over [destFile] with bounded backoff retry for
/// transient Windows sharing/AV scanner locks (`INV-07`).
Future<void> atomicRenameWithRetry(
  File sourceFile,
  File destFile, {
  int maxAttempts = 6,
}) async {
  await destFile.parent.create(recursive: true);
  FileSystemException? lastError;
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      await sourceFile.rename(destFile.path);
      return;
    } on FileSystemException catch (error) {
      lastError = error;
      if (attempt + 1 >= maxAttempts) {
        break;
      }
      await Future<void>.delayed(Duration(milliseconds: 15 * (1 << attempt)));
    }
  }
  throw BlinkException(
    code: BlinkErrorCode.ioError,
    message:
        'Atomic rename failed for ${p.basename(destFile.path)}: $lastError',
    retryable: true,
    cause: lastError,
  );
}

/// Renames a corrupt file to `<filename>.corrupt-<utc>` to preserve evidence (`INV-07`).
Future<File> preserveCorruptFile(File corruptFile, {DateTime? nowUtc}) async {
  final stamp = formatCompactUtcStamp(nowUtc ?? DateTime.now().toUtc());
  final dir = corruptFile.parent.path;
  final base = p.basename(corruptFile.path);
  var candidate = File(p.join(dir, '$base.corrupt-$stamp'));
  var suffix = 1;
  while (await candidate.exists()) {
    candidate = File(p.join(dir, '$base.corrupt-$stamp-$suffix'));
    suffix += 1;
  }
  await atomicRenameWithRetry(corruptFile, candidate);
  return candidate;
}

/// Applies `0700` owner-only permissions on POSIX platforms (`mirror/markdown/private/`).
Future<void> applyOwnerOnlyDirPermissions(Directory dir) async {
  await dir.create(recursive: true);
  if (Platform.isLinux || Platform.isMacOS) {
    try {
      await Process.run('chmod', <String>['0700', dir.path]);
    } catch (_) {
      // Best-effort on constrained POSIX environments.
    }
  }
}

/// Formats UTC timestamp as `YYYYMMDDTHHMMSSZ` for filenames.
String formatCompactUtcStamp(DateTime utc) {
  final dt = utc.toUtc();
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  final ss = dt.second.toString().padLeft(2, '0');
  return '$y$m${d}T$hh$mm${ss}Z';
}

Future<void> _bestEffortDelete(File file) async {
  try {
    if (await file.exists()) {
      await file.delete();
    }
  } catch (_) {}
}

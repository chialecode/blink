import 'dart:convert';
import 'dart:io';

/// Result of loading a JSON object file with corrupt-file preservation.
class JsonObjectLoadResult {
  const JsonObjectLoadResult({
    required this.data,
    required this.exists,
    required this.wasCorrupt,
    this.preservedCorruptFile,
  });

  final Map<String, Object?> data;
  final bool exists;
  final bool wasCorrupt;
  final File? preservedCorruptFile;
}

/// Formats a UTC timestamp suitable for filenames: `YYYYMMDDTHHMMSSZ`.
String formatUtcFileTimestamp(DateTime utc) {
  final t = utc.toUtc();
  final year = t.year.toString().padLeft(4, '0');
  final month = t.month.toString().padLeft(2, '0');
  final day = t.day.toString().padLeft(2, '0');
  final hour = t.hour.toString().padLeft(2, '0');
  final minute = t.minute.toString().padLeft(2, '0');
  final second = t.second.toString().padLeft(2, '0');
  return '$year$month${day}T$hour$minute${second}Z';
}

/// Writes UTF-8 [content] to [target] using a same-directory `.blink-tmp`
/// file, explicit `flush()`, and atomic rename (`INV-07`).
void writeStringAtomicallySync(File target, String content) {
  target.parent.createSync(recursive: true);
  final tempFile = File('${target.path}.blink-tmp');
  final bytes = utf8.encode(content);
  final raf = tempFile.openSync(mode: FileMode.writeOnly);
  try {
    raf.writeFromSync(bytes);
    raf.flushSync();
  } finally {
    raf.closeSync();
  }
  tempFile.renameSync(target.path);
}

/// Preserves a corrupt file by renaming it to `<file>.corrupt-<utc>` in place
/// so the original evidence is never silently discarded (`INV-07`).
File preserveCorruptFileSync(File file, {DateTime Function()? nowUtc}) {
  final stamp = formatUtcFileTimestamp(
    (nowUtc ?? () => DateTime.now().toUtc())(),
  );
  var candidate = File('${file.path}.corrupt-$stamp');
  var counter = 1;
  while (candidate.existsSync()) {
    candidate = File('${file.path}.corrupt-$stamp-$counter');
    counter++;
  }
  return file.renameSync(candidate.path);
}

/// Reads a JSON object from [file]. If the file does not exist, returns an
/// empty map with `wasCorrupt: false`. If the file cannot be decoded as UTF-8
/// JSON object, renames it to `<file>.corrupt-<utc>` and returns an empty map
/// with `wasCorrupt: true`.
JsonObjectLoadResult readJsonObjectOrDefaultSync(
  File file, {
  DateTime Function()? nowUtc,
}) {
  if (!file.existsSync()) {
    return const JsonObjectLoadResult(
      data: <String, Object?>{},
      exists: false,
      wasCorrupt: false,
    );
  }

  try {
    final raw = file.readAsStringSync(encoding: utf8);
    final decoded = jsonDecode(raw);
    if (decoded is Map) {
      final typed = <String, Object?>{};
      for (final entry in decoded.entries) {
        if (entry.key is! String) {
          throw const FormatException('JSON object key is not a string');
        }
        typed[entry.key as String] = entry.value;
      }
      return JsonObjectLoadResult(data: typed, exists: true, wasCorrupt: false);
    }
  } on FormatException {
    // Handled below by preserving the corrupt file.
  } on FileSystemException {
    // Handled below if the file still exists and is unreadable/malformed UTF-8.
  }

  final preserved = file.existsSync()
      ? preserveCorruptFileSync(file, nowUtc: nowUtc)
      : null;
  return JsonObjectLoadResult(
    data: const <String, Object?>{},
    exists: false,
    wasCorrupt: true,
    preservedCorruptFile: preserved,
  );
}

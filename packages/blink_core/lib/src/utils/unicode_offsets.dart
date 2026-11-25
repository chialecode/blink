import 'package:characters/characters.dart';

/// Converts a 0-based Unicode scalar value (`.runes`) offset in [text] into the
/// corresponding UTF-16 code unit index used by Dart [String] and Flutter `TextSelection` (`INV-10`).
///
/// Out-of-range offsets are clamped to `[0, text.length]`.
int codePointToUtf16Index(String text, int codePointOffset) {
  if (codePointOffset <= 0 || text.isEmpty) {
    return 0;
  }
  var utf16Index = 0;
  var seenCodePoints = 0;
  for (final rune in text.runes) {
    if (seenCodePoints == codePointOffset) {
      return utf16Index;
    }
    utf16Index += rune > 0xFFFF ? 2 : 1;
    seenCodePoints += 1;
  }
  return text.length;
}

/// Converts a 0-based UTF-16 code unit index in [text] into the corresponding
/// Unicode scalar value (`.runes`) offset (`INV-10`).
///
/// If [utf16Offset] falls inside a UTF-16 surrogate pair, it snaps to the start of
/// that scalar value. Out-of-range offsets are clamped to `[0, text.runes.length]`.
int utf16ToCodePointIndex(String text, int utf16Offset) {
  if (utf16Offset <= 0 || text.isEmpty) {
    return 0;
  }
  if (utf16Offset >= text.length) {
    return text.runes.length;
  }
  var utf16Index = 0;
  var codePointIndex = 0;
  for (final rune in text.runes) {
    final unitWidth = rune > 0xFFFF ? 2 : 1;
    if (utf16Index >= utf16Offset || utf16Index + unitWidth > utf16Offset) {
      return codePointIndex;
    }
    utf16Index += unitWidth;
    codePointIndex += 1;
  }
  return codePointIndex;
}

/// Extracts the substring of [text] spanning Unicode scalar range `[startCodePoint, endCodePoint)`.
String sliceByCodePoints(String text, int startCodePoint, int endCodePoint) {
  if (endCodePoint <= startCodePoint || text.isEmpty) {
    return '';
  }
  final startUtf16 = codePointToUtf16Index(text, startCodePoint);
  final endUtf16 = codePointToUtf16Index(text, endCodePoint);
  return text.substring(startUtf16, endUtf16);
}

/// Counts user-perceived grapheme clusters in [text] via `package:characters`.
int graphemeLength(String text) => text.characters.length;

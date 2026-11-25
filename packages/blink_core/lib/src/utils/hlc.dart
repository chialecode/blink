/// Monotonic Hybrid Logical Clock (HLC) generator for causal OpLog ordering (`INV-05`).
final class HlcClock {
  HlcClock({required String nodeId})
    : _nodeTag = _normalizeNodeTag(nodeId),
      _lastWallMs = 0,
      _logicalCounter = 0;

  final String _nodeTag;
  int _lastWallMs;
  int _logicalCounter;

  /// Generates a strictly monotonic lexicographically sortable HLC timestamp string:
  /// `<YYYY-MM-DDTHH:MM:SS.mmmZ>-<4-hex-counter>-<node8>`.
  String next({DateTime? nowUtc}) {
    final physicalMs = (nowUtc ?? DateTime.now().toUtc())
        .toUtc()
        .millisecondsSinceEpoch;
    if (physicalMs > _lastWallMs) {
      _lastWallMs = physicalMs;
      _logicalCounter = 0;
    } else {
      _logicalCounter += 1;
      if (_logicalCounter > 0xFFFF) {
        _lastWallMs += 1;
        _logicalCounter = 0;
      }
    }
    final iso = _formatUtcMillis(_lastWallMs);
    final counterHex = _logicalCounter.toRadixString(16).padLeft(4, '0');
    return '$iso-$counterHex-$_nodeTag';
  }

  /// Advances the local clock to stay strictly ahead of a previously persisted [hlcTs].
  void observe(String hlcTs) {
    final parts = hlcTs.split('-');
    if (parts.length < 5) {
      return;
    }
    // ISO string contains two '-' characters in YYYY-MM-DD, so re-join first 3 parts.
    final isoPart = '${parts[0]}-${parts[1]}-${parts[2]}';
    final parsed = DateTime.tryParse(isoPart)?.toUtc();
    if (parsed == null) {
      return;
    }
    final parsedMs = parsed.millisecondsSinceEpoch;
    final parsedCounter = int.tryParse(parts[3], radix: 16) ?? 0;
    if (parsedMs > _lastWallMs) {
      _lastWallMs = parsedMs;
      _logicalCounter = parsedCounter;
    } else if (parsedMs == _lastWallMs && parsedCounter > _logicalCounter) {
      _logicalCounter = parsedCounter;
    }
  }

  static String _normalizeNodeTag(String nodeId) {
    final hexOnly = nodeId.toLowerCase().replaceAll(RegExp(r'[^0-9a-f]'), '');
    if (hexOnly.length >= 8) {
      return hexOnly.substring(0, 8);
    }
    return hexOnly.padRight(8, '0');
  }

  static String _formatUtcMillis(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    final ms = dt.millisecond.toString().padLeft(3, '0');
    return '$y-$m-${d}T$hh:$mm:$ss.${ms}Z';
  }
}

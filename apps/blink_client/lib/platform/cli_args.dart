import 'dart:io';

/// Desktop client startup mode determined by CLI flags.
enum LaunchMode { normal, background, quitForUpdate }

/// Parsed CLI flags and environment options for startup.
class LaunchOptions {
  const LaunchOptions({
    required this.mode,
    required this.quiet,
    this.unknownArgs = const <String>[],
  });

  final LaunchMode mode;
  final bool quiet;
  final List<String> unknownArgs;

  bool get isBackground => mode == LaunchMode.background;
  bool get isQuitForUpdate => mode == LaunchMode.quitForUpdate;
}

/// Parses command-line arguments and `BLINK_QUIET` without throwing on
/// unrecognized flags.
LaunchOptions parseLaunchOptions(
  List<String> args, {
  Map<String, String>? environment,
}) {
  var hasBackground = false;
  var hasQuitForUpdate = false;
  final unknown = <String>[];

  for (final raw in args) {
    final arg = raw.trim();
    if (arg.isEmpty) {
      continue;
    }
    switch (arg) {
      case '--background':
        hasBackground = true;
      case '--quit-for-update':
        hasQuitForUpdate = true;
      default:
        unknown.add(arg);
    }
  }

  final mode = hasQuitForUpdate
      ? LaunchMode.quitForUpdate
      : (hasBackground ? LaunchMode.background : LaunchMode.normal);

  final env = environment ?? Platform.environment;
  final rawQuiet = _readQuietFlag(env);
  final quiet = rawQuiet == '1' || rawQuiet == 'true';

  return LaunchOptions(
    mode: mode,
    quiet: quiet,
    unknownArgs: List<String>.unmodifiable(unknown),
  );
}

String _readQuietFlag(Map<String, String> env) {
  final exact = env['BLINK_QUIET'];
  if (exact != null) {
    return exact.trim().toLowerCase();
  }
  for (final entry in env.entries) {
    if (entry.key.toUpperCase() == 'BLINK_QUIET') {
      return entry.value.trim().toLowerCase();
    }
  }
  return '';
}

/// Compile-time channel, identity, version, and revision metadata injected via
/// `--dart-define`.
class BlinkBuildInfo {
  const BlinkBuildInfo({
    required this.channel,
    required this.identity,
    required this.version,
    required this.gitSha,
  });

  /// Constructs build info from `--dart-define` compile-time constants.
  factory BlinkBuildInfo.fromEnvironment() {
    const rawChannel = String.fromEnvironment(
      'BLINK_CHANNEL',
      defaultValue: 'blink-dev',
    );
    const rawIdentity = String.fromEnvironment(
      'BLINK_IDENTITY',
      defaultValue: '',
    );
    const rawVersion = String.fromEnvironment(
      'BLINK_VERSION',
      defaultValue: '0.1.0-dev.local',
    );
    const rawGitSha = String.fromEnvironment(
      'BLINK_GIT_SHA',
      defaultValue: 'unknown',
    );

    return BlinkBuildInfo.normalized(
      channel: rawChannel,
      identity: rawIdentity,
      version: rawVersion,
      gitSha: rawGitSha,
    );
  }

  /// Creates a normalized instance suitable for both runtime and unit tests.
  factory BlinkBuildInfo.normalized({
    String channel = 'blink-dev',
    String identity = '',
    String version = '0.1.0-dev.local',
    String gitSha = 'unknown',
  }) {
    final normalizedChannel = channel.trim().isEmpty
        ? 'blink-dev'
        : channel.trim().toLowerCase();
    final normalizedIdentity = identity.trim().toLowerCase();
    final normalizedVersion = version.trim().isEmpty
        ? '0.1.0-dev.local'
        : version.trim();
    final normalizedGitSha = gitSha.trim().isEmpty ? 'unknown' : gitSha.trim();

    return BlinkBuildInfo(
      channel: normalizedChannel,
      identity: normalizedIdentity,
      version: normalizedVersion,
      gitSha: normalizedGitSha,
    );
  }

  /// Release channel: `blink` or `blink-dev`.
  final String channel;

  /// Windows installation identity (`blink`, `blink-dev`, `blink-test`,
  /// `blink-dev-test`), or empty string for source (`flutter run`) builds.
  final String identity;

  /// Full build version string (e.g. `0.1.0-dev.202611221600` or `0.1.0`).
  final String version;

  /// Full or short git commit SHA injected at build time.
  final String gitSha;

  /// Source builds carry an empty installation identity and never claim a
  /// single-instance mutex or control pipe.
  bool get isSourceBuild => identity.isEmpty;

  /// True only for the formal production release channel `blink`.
  bool get isProductionChannel => channel == 'blink';

  /// True for the development channel (`blink-dev` or any non-`blink` channel).
  bool get isDevChannel => !isProductionChannel;

  /// Human-readable application title shown in the window and tray tooltip.
  String get productName {
    switch (identity) {
      case 'blink-dev-test':
        return 'BLINK Dev Test';
      case 'blink-test':
        return 'BLINK Test';
    }
    return isProductionChannel ? 'BLINK' : 'BLINK Dev';
  }

  /// Human-readable identity label displayed in the About section.
  String get displayIdentity => isSourceBuild ? '源码构建（无安装身份）' : identity;

  /// Short git commit hash (up to 7 characters) displayed in the About section.
  String get shortGitSha {
    if (gitSha.isEmpty || gitSha == 'unknown') {
      return 'unknown';
    }
    return gitSha.length > 7 ? gitSha.substring(0, 7) : gitSha;
  }

  /// Directory name under `%LOCALAPPDATA%` (or platform data root).
  String get pathSegment => isSourceBuild ? channel : identity;

  /// Single-instance Win32 mutex name, or null for source builds.
  String? get mutexName => isSourceBuild ? null : '$identity-instance';

  /// Single-instance Win32 named pipe path, or null for source builds.
  String? get controlPipeName =>
      isSourceBuild ? null : '\\\\.\\pipe\\$identity-control';

  /// Asset path of the channel-specific `.ico` icon for the system tray.
  String get trayIconAssetPath => isProductionChannel
      ? 'assets/icons/blink.ico'
      : 'assets/icons/blink-dev.ico';
}

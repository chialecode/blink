import 'package:meta/meta.dart';

/// Rendering and sanitization profile for BLINK HTML content.
enum SanitizeProfile {
  /// Surface 1: inline pure-Flutter native widget cards (`view_html`).
  surface1Native('surface1_native'),

  /// Surface 2: on-demand zero-JS offline CSP full-page view (`artifact_html`).
  surface2Sandbox('surface2_sandbox'),

  /// Unified document reading block (`html_sanitized` from web clip or EPUB).
  readingBlock('reading_block');

  const SanitizeProfile(this.wireValue);

  final String wireValue;
}

/// Origin / producer boundary that determines permitted `<blink-*>` tags.
enum HtmlProducer {
  /// Compiled from user-authored BFM v1 raw entries or annotations.
  userBfm('user_bfm'),

  /// Produced by external CLI/MCP AI or optional direct AI (`ai_*` layer).
  aiDerived('ai_derived'),

  /// Parsed from external untrusted web clips or EPUB XHTML chapters.
  externalContent('external_content');

  const HtmlProducer(this.wireValue);

  final String wireValue;
}

/// Privacy scope enforced when validating `<blink-ref>` targets.
enum PrivacyScope {
  /// Normal entries/sources only (`#private` targets are forbidden).
  normalOnly('normal_only'),

  /// Local scope explicitly authorized to reference `#private` records.
  localWithPrivate('local_with_private');

  const PrivacyScope(this.wireValue);

  final String wireValue;
}

/// Severity of a sanitizer diagnostic entry.
enum DiagnosticSeverity {
  /// Blocks AI write-time acceptance (`isValid == false`).
  error('error'),

  /// Advisory warning that does not reject write-time acceptance.
  warning('warning');

  const DiagnosticSeverity(this.wireValue);

  final String wireValue;
}

/// Structured machine-readable diagnostic codes for BLINK HTML/CSS sanitization.
enum DiagnosticCode {
  disallowedTag('E_DISALLOWED_TAG', DiagnosticSeverity.error),
  disallowedAttr('E_DISALLOWED_ATTR', DiagnosticSeverity.error),
  cssUrlBlocked('E_CSS_URL_BLOCKED', DiagnosticSeverity.error),
  rawColorLiteral('E_RAW_COLOR_LITERAL', DiagnosticSeverity.error),
  disallowedProducerTag('E_DISALLOWED_PRODUCER_TAG', DiagnosticSeverity.error),
  invalidBlinkAttr('E_INVALID_BLINK_ATTR', DiagnosticSeverity.error),
  brokenBlinkRef('E_BROKEN_BLINK_REF', DiagnosticSeverity.error),
  privacyScopeViolation('E_PRIVACY_SCOPE_VIOLATION', DiagnosticSeverity.error),
  surface1SvgText('W_SURFACE1_SVG_TEXT', DiagnosticSeverity.warning);

  const DiagnosticCode(this.wireCode, this.defaultSeverity);

  /// Stable wire code returned to CLI/MCP callers for self-repair.
  final String wireCode;

  /// Default severity associated with this diagnostic code.
  final DiagnosticSeverity defaultSeverity;
}

/// A single structured finding produced during HTML/CSS sanitization.
@immutable
class SanitizeDiagnostic {
  const SanitizeDiagnostic({
    required this.code,
    required this.message,
    DiagnosticSeverity? severity,
    this.tagName,
    this.attributeName,
    this.detail,
  }) : _explicitSeverity = severity;

  final DiagnosticCode code;
  final DiagnosticSeverity? _explicitSeverity;
  final String message;
  final String? tagName;
  final String? attributeName;
  final String? detail;

  /// Effective diagnostic severity (defaults to [DiagnosticCode.defaultSeverity]).
  DiagnosticSeverity get severity => _explicitSeverity ?? code.defaultSeverity;

  /// Wire code string (e.g. `E_CSS_URL_BLOCKED`, `W_SURFACE1_SVG_TEXT`).
  String get codeString => code.wireCode;

  Map<String, Object?> toJson() => <String, Object?>{
    'code': codeString,
    'severity': severity.wireValue,
    'message': message,
    if (tagName != null) 'tag': tagName,
    if (attributeName != null) 'attribute': attributeName,
    if (detail != null) 'detail': detail,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SanitizeDiagnostic &&
          code == other.code &&
          severity == other.severity &&
          message == other.message &&
          tagName == other.tagName &&
          attributeName == other.attributeName &&
          detail == other.detail;

  @override
  int get hashCode =>
      Object.hash(code, severity, message, tagName, attributeName, detail);

  @override
  String toString() => 'SanitizeDiagnostic($codeString: $message)';
}

/// Entity kind referenced by a `<blink-ref>` element.
enum BlinkRefKind {
  entry('entry'),
  annotation('annotation'),
  source('source'),
  titleQuery('title_query');

  const BlinkRefKind(this.wireValue);

  final String wireValue;

  static BlinkRefKind? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }
    for (final kind in BlinkRefKind.values) {
      if (kind.wireValue == raw) {
        return kind;
      }
    }
    return null;
  }
}

/// Parsed and schema-validated `<blink-ref>` target metadata.
@immutable
class BlinkRefTarget {
  const BlinkRefTarget({
    required this.kind,
    required this.label,
    this.id,
    this.anchor,
    this.dataBind,
  });

  final BlinkRefKind kind;
  final String? id;
  final String? anchor;
  final String? dataBind;
  final String label;

  /// Builds the Surface 2 zero-JS navigation URL (`blink-ref://<kind>/<id>`).
  String? toSurface2Href() {
    if (kind == BlinkRefKind.titleQuery || id == null || id!.isEmpty) {
      return null;
    }
    final base = 'blink-ref://${kind.wireValue}/$id';
    if (anchor == null || anchor!.isEmpty) {
      return base;
    }
    return '$base?anchor=${Uri.encodeQueryComponent(anchor!)}';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BlinkRefTarget &&
          kind == other.kind &&
          id == other.id &&
          anchor == other.anchor &&
          dataBind == other.dataBind &&
          label == other.label;

  @override
  int get hashCode => Object.hash(kind, id, anchor, dataBind, label);

  @override
  String toString() =>
      'BlinkRefTarget(kind: ${kind.wireValue}, id: $id, anchor: $anchor, label: $label)';
}

/// Outcome returned by a pluggable `<blink-ref>` database/scope validator.
enum BlinkRefValidationStatus {
  /// Target exists and is accessible within the active [PrivacyScope].
  valid,

  /// Target ID does not exist (triggers `E_BROKEN_BLINK_REF`).
  notFound,

  /// Target is `#private` while active scope is `normalOnly`
  /// (triggers `E_PRIVACY_SCOPE_VIOLATION`).
  privacyScopeViolation,
}

/// Pluggable callback used by `blink_core` at write time to verify `<blink-ref>`
/// target existence and `#private` scope isolation.
typedef BlinkRefValidator = BlinkRefValidationStatus Function(
  BlinkRefTarget target,
  PrivacyScope scope,
);

/// Configuration options for [BlinkHtmlSanitizer.sanitize].
@immutable
class SanitizeOptions {
  const SanitizeOptions({
    required this.profile,
    HtmlProducer? producer,
    this.privacyScope = PrivacyScope.normalOnly,
    this.refValidator,
    this.compileSurface2Refs = true,
  }) : producer =
           producer ??
           (profile == SanitizeProfile.readingBlock
               ? HtmlProducer.externalContent
               : HtmlProducer.aiDerived);

  final SanitizeProfile profile;
  final HtmlProducer producer;
  final PrivacyScope privacyScope;
  final BlinkRefValidator? refValidator;

  /// When `true` and [profile] is [SanitizeProfile.surface2Sandbox], valid
  /// `<blink-ref>` tags are compiled to `<a class="blink-ref" href="blink-ref://...">`.
  final bool compileSurface2Refs;
}

/// Deterministic output and structured diagnostics from HTML/CSS sanitization.
@immutable
class SanitizeResult {
  SanitizeResult({
    required this.html,
    List<SanitizeDiagnostic> diagnostics = const <SanitizeDiagnostic>[],
    List<BlinkRefTarget> extractedRefs = const <BlinkRefTarget>[],
  }) : diagnostics = List<SanitizeDiagnostic>.unmodifiable(diagnostics),
       extractedRefs = List<BlinkRefTarget>.unmodifiable(extractedRefs);

  /// Deterministically rebuilt sanitized HTML string.
  final String html;

  /// All structured error and warning diagnostics emitted during sanitization.
  final List<SanitizeDiagnostic> diagnostics;

  /// All schema- and validator-verified `<blink-ref>` targets found in the input.
  final List<BlinkRefTarget> extractedRefs;

  /// Whether at least one error-severity diagnostic was emitted.
  bool get hasErrors =>
      diagnostics.any((d) => d.severity == DiagnosticSeverity.error);

  /// Whether the input passed with zero error-severity diagnostics.
  bool get isValid => !hasErrors;

  /// Error-severity diagnostics only.
  List<SanitizeDiagnostic> get errors => diagnostics
      .where((d) => d.severity == DiagnosticSeverity.error)
      .toList(growable: false);

  /// Warning-severity diagnostics only.
  List<SanitizeDiagnostic> get warnings => diagnostics
      .where((d) => d.severity == DiagnosticSeverity.warning)
      .toList(growable: false);
}

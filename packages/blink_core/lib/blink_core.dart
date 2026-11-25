/// Pure Dart portable vault, SQLite WAL storage, BFM v1 engine, CJK FTS5 search,
/// content-addressed blobs, and open Markdown mirror exporter for BLINK.
library;

export 'package:blink_sanitizer/blink_sanitizer.dart'
    show
        BlinkRefKind,
        BlinkRefTarget,
        BlinkRefValidationStatus,
        BlinkRefValidator,
        DiagnosticCode,
        DiagnosticSeverity,
        HtmlProducer,
        PrivacyScope,
        SanitizeDiagnostic,
        SanitizeProfile,
        SanitizeResult;

export 'src/bfm/bfm_engine.dart'
    show
        BfmDocument,
        BfmEngine,
        BfmParsedLink,
        BfmTaskItem,
        BfmTimestamp,
        MirrorLinkResolver;
export 'src/errors/blink_error.dart'
    show BlinkDiagnostic, BlinkErrorCode, BlinkException;
export 'src/mirror/mirror_exporter.dart' show MirrorExporter, MirrorStatus;
export 'src/models/blink_models.dart'
    show
        BfmLinkRecord,
        BfmLinkTargetKind,
        BlinkChannel,
        CaptureOrigin,
        EditorDraft,
        EntryKind,
        MediaBlob,
        PrivacyLevel,
        RawEntry,
        RawTask,
        TaskStatus,
        VaultMetadata,
        VaultStats;
export 'src/repositories/external_ai_repository.dart' show ExternalAiRepository;
export 'src/repositories/raw_repository.dart'
    show EntryQuery, RawRepository, TaskQuery;
export 'src/search/fts_search_service.dart'
    show
        FtsSearchHit,
        FtsSearchService,
        buildSafeFtsMatchQuery,
        cjkFtsPretokenize;
export 'src/storage/blob_store.dart' show BlobStore, isValidBlobSha256;
export 'src/utils/unicode_offsets.dart'
    show
        codePointToUtf16Index,
        graphemeLength,
        sliceByCodePoints,
        utf16ToCodePointIndex;
export 'src/utils/uuid_v7.dart' show generateUuidV7, isValidUuidV7;
export 'src/vault/vault_config.dart' show VaultBackupResult, VaultConfig;
export 'src/vault/vault_manager.dart' show VaultManager;
export 'src/vault/vault_schema.dart'
    show currentVaultFormatVersion, currentVaultSchemaVersion;

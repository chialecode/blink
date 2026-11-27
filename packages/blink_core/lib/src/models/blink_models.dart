import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

const ListEquality<String> _stringListEquality = ListEquality<String>();

/// Build and vault isolation channel (`INV-06`).
enum BlinkChannel {
  blink('blink'),
  blinkDev('blink-dev');

  const BlinkChannel(this.wireValue);

  final String wireValue;

  static BlinkChannel? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }
    for (final value in BlinkChannel.values) {
      if (value.wireValue == raw) {
        return value;
      }
    }
    return null;
  }
}

/// Row-level privacy classification (`INV-03`).
enum PrivacyLevel {
  normal('normal'),
  private('private');

  const PrivacyLevel(this.wireValue);

  final String wireValue;

  static PrivacyLevel? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }
    for (final value in PrivacyLevel.values) {
      if (value.wireValue == raw) {
        return value;
      }
    }
    return null;
  }
}

/// Raw entry kind stored in `raw_entries`.
enum EntryKind {
  blink('blink'),
  diary('diary'),
  voiceNote('voice_note'),
  photoNote('photo_note');

  const EntryKind(this.wireValue);

  final String wireValue;

  static EntryKind? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }
    for (final value in EntryKind.values) {
      if (value.wireValue == raw) {
        return value;
      }
    }
    return null;
  }
}

/// Provenance of a user-authored raw entry.
enum CaptureOrigin {
  appUi('app_ui'),
  shareSheet('share_sheet'),
  cliCapture('cli_capture'),
  mcpCapture('mcp_capture'),
  chatPromoted('chat_promoted');

  const CaptureOrigin(this.wireValue);

  final String wireValue;

  static CaptureOrigin? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }
    for (final value in CaptureOrigin.values) {
      if (value.wireValue == raw) {
        return value;
      }
    }
    return null;
  }
}

/// Endogenous task status synchronized between `raw_tasks` and BFM checkboxes.
enum TaskStatus {
  open('open', ' '),
  done('done', 'x'),
  deferred('deferred', '>'),
  dropped('dropped', '-');

  const TaskStatus(this.wireValue, this.bfmMarker);

  final String wireValue;
  final String bfmMarker;

  static TaskStatus? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }
    for (final value in TaskStatus.values) {
      if (value.wireValue == raw) {
        return value;
      }
    }
    return null;
  }

  static TaskStatus? fromBfmMarker(String marker) {
    switch (marker) {
      case ' ':
        return TaskStatus.open;
      case 'x':
      case 'X':
        return TaskStatus.done;
      case '>':
        return TaskStatus.deferred;
      case '-':
        return TaskStatus.dropped;
      default:
        return null;
    }
  }
}

/// Target entity kind of a BFM v1 link or embed edge.
enum BfmLinkTargetKind {
  entry('entry'),
  annotation('annotation'),
  source('source'),
  ai('ai'),
  titleQuery('title_query');

  const BfmLinkTargetKind(this.wireValue);

  final String wireValue;

  static BfmLinkTargetKind? tryParse(String? raw) {
    if (raw == null) {
      return null;
    }
    for (final value in BfmLinkTargetKind.values) {
      if (value.wireValue == raw) {
        return value;
      }
    }
    return null;
  }
}

/// Metadata persisted in `<BLINK_VAULT_DIR>/vault.json`.
@immutable
final class VaultMetadata {
  const VaultMetadata({
    required this.formatVersion,
    required this.schemaVersion,
    required this.vaultId,
    required this.channel,
    required this.createdAtUtc,
  });

  final int formatVersion;
  final int schemaVersion;
  final String vaultId;
  final BlinkChannel channel;
  final DateTime createdAtUtc;

  Map<String, Object?> toJson() => <String, Object?>{
    'format_version': formatVersion,
    'schema_version': schemaVersion,
    'vault_id': vaultId,
    'channel': channel.wireValue,
    'created_at_utc': createdAtUtc.toUtc().toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VaultMetadata &&
          formatVersion == other.formatVersion &&
          schemaVersion == other.schemaVersion &&
          vaultId == other.vaultId &&
          channel == other.channel &&
          createdAtUtc.isAtSameMomentAs(other.createdAtUtc);

  @override
  int get hashCode => Object.hash(
    formatVersion,
    schemaVersion,
    vaultId,
    channel,
    createdAtUtc.toUtc(),
  );
}

/// Immutable raw entry record (`raw_entries`, `INV-01`).
@immutable
final class RawEntry {
  RawEntry({
    required this.id,
    required this.entryKind,
    required this.bodyMd,
    this.audioBlobSha256,
    List<String> imageBlobSha256s = const <String>[],
    this.sourceRefId,
    required this.captureOrigin,
    required this.privacyLevel,
    required this.revision,
    required this.hlcTs,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.deletedAtUtc,
  }) : imageBlobSha256s = List<String>.unmodifiable(imageBlobSha256s);

  final String id;
  final EntryKind entryKind;
  final String bodyMd;
  final String? audioBlobSha256;
  final List<String> imageBlobSha256s;
  final String? sourceRefId;
  final CaptureOrigin captureOrigin;
  final PrivacyLevel privacyLevel;
  final int revision;
  final String hlcTs;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
  final DateTime? deletedAtUtc;

  bool get isPrivate => privacyLevel == PrivacyLevel.private;
  bool get isDeleted => deletedAtUtc != null;

  RawEntry copyWith({
    EntryKind? entryKind,
    String? bodyMd,
    String? audioBlobSha256,
    List<String>? imageBlobSha256s,
    String? sourceRefId,
    CaptureOrigin? captureOrigin,
    PrivacyLevel? privacyLevel,
    int? revision,
    String? hlcTs,
    DateTime? createdAtUtc,
    DateTime? updatedAtUtc,
    DateTime? deletedAtUtc,
    bool clearDeletedAt = false,
  }) => RawEntry(
    id: id,
    entryKind: entryKind ?? this.entryKind,
    bodyMd: bodyMd ?? this.bodyMd,
    audioBlobSha256: audioBlobSha256 ?? this.audioBlobSha256,
    imageBlobSha256s: imageBlobSha256s ?? this.imageBlobSha256s,
    sourceRefId: sourceRefId ?? this.sourceRefId,
    captureOrigin: captureOrigin ?? this.captureOrigin,
    privacyLevel: privacyLevel ?? this.privacyLevel,
    revision: revision ?? this.revision,
    hlcTs: hlcTs ?? this.hlcTs,
    createdAtUtc: createdAtUtc ?? this.createdAtUtc,
    updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
    deletedAtUtc: clearDeletedAt ? null : (deletedAtUtc ?? this.deletedAtUtc),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RawEntry &&
          id == other.id &&
          entryKind == other.entryKind &&
          bodyMd == other.bodyMd &&
          audioBlobSha256 == other.audioBlobSha256 &&
          _stringListEquality.equals(
            imageBlobSha256s,
            other.imageBlobSha256s,
          ) &&
          sourceRefId == other.sourceRefId &&
          captureOrigin == other.captureOrigin &&
          privacyLevel == other.privacyLevel &&
          revision == other.revision &&
          hlcTs == other.hlcTs &&
          createdAtUtc.isAtSameMomentAs(other.createdAtUtc) &&
          updatedAtUtc.isAtSameMomentAs(other.updatedAtUtc) &&
          ((deletedAtUtc == null && other.deletedAtUtc == null) ||
              (deletedAtUtc != null &&
                  other.deletedAtUtc != null &&
                  deletedAtUtc!.isAtSameMomentAs(other.deletedAtUtc!)));

  @override
  int get hashCode => Object.hash(
    id,
    entryKind,
    bodyMd,
    audioBlobSha256,
    _stringListEquality.hash(imageBlobSha256s),
    sourceRefId,
    captureOrigin,
    privacyLevel,
    revision,
    hlcTs,
    createdAtUtc.toUtc(),
    updatedAtUtc.toUtc(),
    deletedAtUtc?.toUtc(),
  );
}

/// Immutable endogenous task record (`raw_tasks`).
@immutable
final class RawTask {
  const RawTask({
    required this.id,
    required this.title,
    required this.status,
    this.originEntryId,
    this.originAnnotationId,
    this.focusDate,
    this.completedAtUtc,
    required this.privacyLevel,
    required this.revision,
    required this.hlcTs,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.deletedAtUtc,
  });

  final String id;
  final String title;
  final TaskStatus status;
  final String? originEntryId;
  final String? originAnnotationId;
  final String? focusDate;
  final DateTime? completedAtUtc;
  final PrivacyLevel privacyLevel;
  final int revision;
  final String hlcTs;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
  final DateTime? deletedAtUtc;

  bool get isPrivate => privacyLevel == PrivacyLevel.private;
  bool get isDeleted => deletedAtUtc != null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RawTask &&
          id == other.id &&
          title == other.title &&
          status == other.status &&
          originEntryId == other.originEntryId &&
          originAnnotationId == other.originAnnotationId &&
          focusDate == other.focusDate &&
          ((completedAtUtc == null && other.completedAtUtc == null) ||
              (completedAtUtc != null &&
                  other.completedAtUtc != null &&
                  completedAtUtc!.isAtSameMomentAs(other.completedAtUtc!))) &&
          privacyLevel == other.privacyLevel &&
          revision == other.revision &&
          hlcTs == other.hlcTs &&
          createdAtUtc.isAtSameMomentAs(other.createdAtUtc) &&
          updatedAtUtc.isAtSameMomentAs(other.updatedAtUtc) &&
          ((deletedAtUtc == null && other.deletedAtUtc == null) ||
              (deletedAtUtc != null &&
                  other.deletedAtUtc != null &&
                  deletedAtUtc!.isAtSameMomentAs(other.deletedAtUtc!)));

  @override
  int get hashCode => Object.hash(
    id,
    title,
    status,
    originEntryId,
    originAnnotationId,
    focusDate,
    completedAtUtc?.toUtc(),
    privacyLevel,
    revision,
    hlcTs,
    createdAtUtc.toUtc(),
    updatedAtUtc.toUtc(),
    deletedAtUtc?.toUtc(),
  );
}

/// Content-addressed attachment record (`media_blobs`).
@immutable
final class MediaBlob {
  const MediaBlob({
    required this.sha256,
    required this.mimeType,
    required this.byteSize,
    this.width,
    this.height,
    this.durationMs,
    required this.storageRelPath,
    required this.createdAtUtc,
  });

  final String sha256;
  final String mimeType;
  final int byteSize;
  final int? width;
  final int? height;
  final int? durationMs;
  final String storageRelPath;
  final DateTime createdAtUtc;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MediaBlob &&
          sha256 == other.sha256 &&
          mimeType == other.mimeType &&
          byteSize == other.byteSize &&
          width == other.width &&
          height == other.height &&
          durationMs == other.durationMs &&
          storageRelPath == other.storageRelPath &&
          createdAtUtc.isAtSameMomentAs(other.createdAtUtc);

  @override
  int get hashCode => Object.hash(
    sha256,
    mimeType,
    byteSize,
    width,
    height,
    durationMs,
    storageRelPath,
    createdAtUtc.toUtc(),
  );
}

/// Structured BFM v1 link/embed edge persisted in `ai_bfm_links`.
@immutable
final class BfmLinkRecord {
  const BfmLinkRecord({
    required this.id,
    required this.srcType,
    required this.srcId,
    required this.targetKind,
    this.targetId,
    this.anchor,
    required this.privacyLevel,
  });

  final String id;
  final String srcType;
  final String srcId;
  final BfmLinkTargetKind targetKind;
  final String? targetId;
  final String? anchor;
  final PrivacyLevel privacyLevel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BfmLinkRecord &&
          id == other.id &&
          srcType == other.srcType &&
          srcId == other.srcId &&
          targetKind == other.targetKind &&
          targetId == other.targetId &&
          anchor == other.anchor &&
          privacyLevel == other.privacyLevel;

  @override
  int get hashCode => Object.hash(
    id,
    srcType,
    srcId,
    targetKind,
    targetId,
    anchor,
    privacyLevel,
  );
}

/// Crash-recovery editor draft persisted in local SQLite WAL (`editor_drafts`).
@immutable
final class EditorDraft {
  EditorDraft({
    required this.draftKey,
    required this.bodyMd,
    required this.entryKind,
    required this.privacyLocked,
    List<String> imageBlobSha256s = const <String>[],
    required this.updatedAtUtc,
  }) : imageBlobSha256s = List<String>.unmodifiable(imageBlobSha256s);

  final String draftKey;
  final String bodyMd;
  final EntryKind entryKind;
  final bool privacyLocked;
  final List<String> imageBlobSha256s;
  final DateTime updatedAtUtc;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EditorDraft &&
          draftKey == other.draftKey &&
          bodyMd == other.bodyMd &&
          entryKind == other.entryKind &&
          privacyLocked == other.privacyLocked &&
          _stringListEquality.equals(
            imageBlobSha256s,
            other.imageBlobSha256s,
          ) &&
          updatedAtUtc.isAtSameMomentAs(other.updatedAtUtc);

  @override
  int get hashCode => Object.hash(
    draftKey,
    bodyMd,
    entryKind,
    privacyLocked,
    _stringListEquality.hash(imageBlobSha256s),
    updatedAtUtc.toUtc(),
  );
}

/// Snapshot summary of vault counts and replication/mirror watermarks.
@immutable
final class VaultStats {
  const VaultStats({
    required this.activeEntries,
    required this.privateEntries,
    required this.trashedEntries,
    required this.openTasks,
    required this.totalBlobs,
    required this.totalBlobBytes,
    required this.latestSeqId,
    required this.mirrorWatermarkSeq,
    this.pendingOutboxCount = 0,
    this.openConflictCount = 0,
  });

  final int activeEntries;
  final int privateEntries;
  final int trashedEntries;
  final int openTasks;
  final int totalBlobs;
  final int totalBlobBytes;
  final int latestSeqId;
  final int mirrorWatermarkSeq;
  final int pendingOutboxCount;
  final int openConflictCount;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VaultStats &&
          activeEntries == other.activeEntries &&
          privateEntries == other.privateEntries &&
          trashedEntries == other.trashedEntries &&
          openTasks == other.openTasks &&
          totalBlobs == other.totalBlobs &&
          totalBlobBytes == other.totalBlobBytes &&
          latestSeqId == other.latestSeqId &&
          mirrorWatermarkSeq == other.mirrorWatermarkSeq &&
          pendingOutboxCount == other.pendingOutboxCount &&
          openConflictCount == other.openConflictCount;

  @override
  int get hashCode => Object.hash(
    activeEntries,
    privateEntries,
    trashedEntries,
    openTasks,
    totalBlobs,
    totalBlobBytes,
    latestSeqId,
    mirrorWatermarkSeq,
    pendingOutboxCount,
    openConflictCount,
  );
}

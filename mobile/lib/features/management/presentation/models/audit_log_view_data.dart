import 'package:flutter/foundation.dart';

import 'report_audit_json_parsers.dart';

/// Presentation data for a single recorded field-level modification.
@immutable
class AuditFieldChangeViewData {
  final String field;
  final String fieldLabel;
  final String beforeDisplay;
  final String afterDisplay;
  final bool captured;

  const AuditFieldChangeViewData({
    required this.field,
    required this.fieldLabel,
    required this.beforeDisplay,
    required this.afterDisplay,
    this.captured = true,
  });

  String get safeFieldLabel =>
      fieldLabel.trim().isNotEmpty ? fieldLabel : field;

  String get safeBeforeDisplay =>
      beforeDisplay.trim().isNotEmpty ? beforeDisplay : 'Not recorded';

  String get safeAfterDisplay =>
      afterDisplay.trim().isNotEmpty ? afterDisplay : 'Not recorded';

  factory AuditFieldChangeViewData.fromJson(Map<String, dynamic> json) {
    final field = TypedJsonReader.readRequiredString(json, 'field');
    final fieldLabel =
        TypedJsonReader.readOptionalString(json, 'field_label') ?? field;
    final beforeDisplay =
        TypedJsonReader.readOptionalString(json, 'before_display') ?? '';
    final afterDisplay =
        TypedJsonReader.readOptionalString(json, 'after_display') ?? '';
    final captured = TypedJsonReader.readOptionalBool(json, 'captured') ?? true;
    return AuditFieldChangeViewData(
      field: field,
      fieldLabel: fieldLabel,
      beforeDisplay: beforeDisplay,
      afterDisplay: afterDisplay,
      captured: captured,
    );
  }
}

/// Presentation data for an immutable append-only audit event.
@immutable
class AuditLogEntryViewData {
  final int id;
  final DateTime? occurredAt;
  final String actorLabelSnapshot;
  final int? actorId;
  final String action;
  final String actionLabel;
  final String entityType;
  final String entityLabel;
  final String entityId;
  final String? recordSummary;
  final String? reason;
  final List<AuditFieldChangeViewData> changes;
  final String detailKind; // 'creation', 'changes', 'snapshot'
  final String? snapshotNotice;

  const AuditLogEntryViewData({
    required this.id,
    this.occurredAt,
    required this.actorLabelSnapshot,
    this.actorId,
    required this.action,
    required this.actionLabel,
    required this.entityType,
    required this.entityLabel,
    required this.entityId,
    this.recordSummary,
    this.reason,
    this.changes = const [],
    this.detailKind = 'snapshot',
    this.snapshotNotice,
  });

  String get safeActorLabel {
    if (actorLabelSnapshot.trim().isNotEmpty) return actorLabelSnapshot;
    if (actorId != null && actorId! > 0) return 'User #$actorId';
    return 'System';
  }

  String get safeActionLabel =>
      actionLabel.trim().isNotEmpty ? actionLabel : action;

  String get safeEntityLabel =>
      entityLabel.trim().isNotEmpty ? entityLabel : entityType;

  String get safeRecordSummary {
    if (recordSummary != null && recordSummary!.trim().isNotEmpty) {
      return recordSummary!;
    }
    if (entityId.trim().isNotEmpty) {
      return '$safeEntityLabel #$entityId';
    }
    return 'Record #$id';
  }

  bool get hasChanges => changes.isNotEmpty;
  bool get hasReason => reason != null && reason!.trim().isNotEmpty;

  factory AuditLogEntryViewData.fromJson(Map<String, dynamic> json) {
    final id = TypedJsonReader.readRequiredInt(json, 'id', minValue: 1);
    final occurredAt = TypedJsonReader.readRequiredDateTime(
      json,
      'occurred_at',
    );
    final action = TypedJsonReader.readRequiredString(
      json,
      'action',
      allowEmpty: false,
    );

    final rawChanges = TypedJsonReader.readOptionalList(json, 'changes');
    final changes = rawChanges
        .map(
          (c) => AuditFieldChangeViewData.fromJson(
            TypedJsonReader.readMap(c, 'audit change'),
          ),
        )
        .toList();

    return AuditLogEntryViewData(
      id: id,
      occurredAt: occurredAt,
      actorLabelSnapshot:
          TypedJsonReader.readOptionalString(json, 'actor_label_snapshot') ??
          '',
      actorId: TypedJsonReader.readOptionalInt(json, 'actor_id', minValue: 1),
      action: action,
      actionLabel:
          TypedJsonReader.readOptionalString(json, 'action_label') ?? action,
      entityType:
          TypedJsonReader.readOptionalString(json, 'entity_type') ?? 'other',
      entityLabel:
          TypedJsonReader.readOptionalString(json, 'entity_label') ?? 'Record',
      entityId: TypedJsonReader.readOptionalString(json, 'entity_id') ?? '',
      recordSummary: TypedJsonReader.readOptionalString(json, 'record_summary'),
      reason: TypedJsonReader.readOptionalString(json, 'reason'),
      changes: changes,
      detailKind:
          TypedJsonReader.readOptionalString(json, 'detail_kind') ?? 'snapshot',
      snapshotNotice: TypedJsonReader.readOptionalString(
        json,
        'snapshot_notice',
      ),
    );
  }
}

/// Distinct actor option for audit filter dropdowns.
@immutable
class AuditFilterActorOption {
  final int id;
  final String username;
  final String displayName;

  const AuditFilterActorOption({
    required this.id,
    required this.username,
    required this.displayName,
  });

  String get label {
    final cleanDisplay = displayName.trim();
    final cleanUsername = username.trim();
    if (cleanDisplay.isNotEmpty &&
        cleanUsername.isNotEmpty &&
        cleanDisplay != cleanUsername) {
      return '$cleanDisplay ($cleanUsername)';
    }
    if (cleanDisplay.isNotEmpty) {
      return cleanDisplay;
    }
    return cleanUsername;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuditFilterActorOption &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Target record type option for audit filter dropdowns.
@immutable
class AuditFilterEntityOption {
  final String value;
  final String label;

  const AuditFilterEntityOption({required this.value, required this.label});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuditFilterEntityOption &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;
}

/// Scoped filter choices for audit log queries.
@immutable
class AuditLogFilterOptionsViewData {
  final List<AuditFilterActorOption> actors;
  final List<AuditFilterEntityOption> entityTypes;

  const AuditLogFilterOptionsViewData({
    this.actors = const [],
    this.entityTypes = const [],
  });

  factory AuditLogFilterOptionsViewData.fromJson(Map<String, dynamic> json) {
    final rawActors = TypedJsonReader.readOptionalList(json, 'actors');
    final actors = rawActors.map((a) {
      final map = TypedJsonReader.readMap(a, 'actor option');
      return AuditFilterActorOption(
        id: TypedJsonReader.readRequiredInt(map, 'id', minValue: 1),
        username: TypedJsonReader.readOptionalString(map, 'username') ?? '',
        displayName:
            TypedJsonReader.readOptionalString(map, 'display_name') ?? '',
      );
    }).toList();

    final rawEntities = TypedJsonReader.readOptionalList(json, 'entity_types');
    final entityTypes = rawEntities.map((e) {
      final map = TypedJsonReader.readMap(e, 'entity_type option');
      return AuditFilterEntityOption(
        value: TypedJsonReader.readRequiredString(map, 'value'),
        label: TypedJsonReader.readRequiredString(map, 'label'),
      );
    }).toList();

    return AuditLogFilterOptionsViewData(
      actors: actors,
      entityTypes: entityTypes,
    );
  }
}

/// Filter query parameters for the audit log.
/// Strictly matches confirmed Django backend parameters (actor, action,
/// start_date, end_date, target_type).
@immutable
class AuditLogFilterQuery {
  final int? actorId;
  final String? action;
  final DateTime? startDate;
  final DateTime? endDate;
  final String? targetType;
  final int page;
  final int pageSize;

  const AuditLogFilterQuery({
    this.actorId,
    this.action,
    this.startDate,
    this.endDate,
    this.targetType,
    this.page = 1,
    this.pageSize = 20,
  });

  AuditLogFilterQuery copyWith({
    int? actorId,
    String? action,
    DateTime? startDate,
    DateTime? endDate,
    String? targetType,
    int? page,
    int? pageSize,
    bool clearActor = false,
    bool clearAction = false,
    bool clearStartDate = false,
    bool clearEndDate = false,
    bool clearTargetType = false,
  }) {
    return AuditLogFilterQuery(
      actorId: clearActor ? null : (actorId ?? this.actorId),
      action: clearAction ? null : (action ?? this.action),
      startDate: clearStartDate ? null : (startDate ?? this.startDate),
      endDate: clearEndDate ? null : (endDate ?? this.endDate),
      targetType: clearTargetType ? null : (targetType ?? this.targetType),
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }

  bool get hasActiveFilters =>
      actorId != null ||
      (action != null && action!.trim().isNotEmpty) ||
      startDate != null ||
      endDate != null ||
      (targetType != null && targetType!.isNotEmpty);

  int get activeFilterCount {
    var count = 0;
    if (actorId != null) count++;
    if (action != null && action!.trim().isNotEmpty) count++;
    if (startDate != null) count++;
    if (endDate != null) count++;
    if (targetType != null && targetType!.isNotEmpty) count++;
    return count;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AuditLogFilterQuery &&
          runtimeType == other.runtimeType &&
          actorId == other.actorId &&
          action == other.action &&
          startDate == other.startDate &&
          endDate == other.endDate &&
          targetType == other.targetType &&
          page == other.page &&
          pageSize == other.pageSize;

  @override
  int get hashCode => Object.hash(
    actorId,
    action,
    startDate,
    endDate,
    targetType,
    page,
    pageSize,
  );
}

/// Paginated audit log result page.
@immutable
class AuditLogPageViewData {
  final List<AuditLogEntryViewData> items;
  final int count;
  final bool hasMore;
  final int page;
  final int pageSize;
  final int? resultLimit;

  const AuditLogPageViewData({
    required this.items,
    required this.count,
    required this.hasMore,
    required this.page,
    this.pageSize = 20,
    this.resultLimit,
  });

  factory AuditLogPageViewData.fromJson(
    Map<String, dynamic> json, {
    required int page,
    int pageSize = 20,
    int? resultLimit,
  }) {
    final count =
        TypedJsonReader.readOptionalInt(json, 'count', minValue: 0) ?? 0;
    final next = json['next'];
    final rawResults = TypedJsonReader.readOptionalList(json, 'results');
    final items = rawResults
        .map(
          (r) => AuditLogEntryViewData.fromJson(
            TypedJsonReader.readMap(r, 'audit result'),
          ),
        )
        .toList();
    return AuditLogPageViewData(
      items: items,
      count: count,
      hasMore: next != null,
      page: page,
      pageSize: pageSize,
      resultLimit: resultLimit,
    );
  }

  int get totalPages => (count <= 0) ? 1 : ((count - 1) ~/ pageSize) + 1;
}

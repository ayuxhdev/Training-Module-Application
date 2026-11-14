import 'package:flutter/foundation.dart';

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
    final field = (json['field'] as String?)?.trim() ?? '';
    final fieldLabel = (json['field_label'] as String?)?.trim() ?? field;
    final beforeDisplay = (json['before_display'] as String?)?.trim() ?? '';
    final afterDisplay = (json['after_display'] as String?)?.trim() ?? '';
    final captured = json['captured'] as bool? ?? true;
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
    final id = json['id'];
    if (id is! int || id <= 0) {
      throw const FormatException('Invalid audit log entry id.');
    }
    final rawChanges = json['changes'] as List<dynamic>? ?? const [];
    final changes = rawChanges
        .map((c) =>
            AuditFieldChangeViewData.fromJson(c as Map<String, dynamic>))
        .toList();

    return AuditLogEntryViewData(
      id: id,
      occurredAt: json['occurred_at'] != null
          ? DateTime.tryParse(json['occurred_at'] as String)
          : null,
      actorLabelSnapshot:
          (json['actor_label_snapshot'] as String?)?.trim() ?? '',
      actorId: json['actor_id'] as int?,
      action: (json['action'] as String?)?.trim() ?? 'other',
      actionLabel:
          (json['action_label'] as String?)?.trim() ?? 'Other recorded action',
      entityType: (json['entity_type'] as String?)?.trim() ?? 'other',
      entityLabel: (json['entity_label'] as String?)?.trim() ?? 'Record',
      entityId: (json['entity_id'] as String?)?.trim() ?? '',
      recordSummary: json['record_summary'] as String?,
      reason: json['reason'] as String?,
      changes: changes,
      detailKind: (json['detail_kind'] as String?)?.trim() ?? 'snapshot',
      snapshotNotice: json['snapshot_notice'] as String?,
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

  String get label =>
      displayName.isNotEmpty ? '$displayName ($username)' : username;

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

  const AuditFilterEntityOption({
    required this.value,
    required this.label,
  });

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
    final rawActors = json['actors'] as List<dynamic>? ?? const [];
    final actors = rawActors
        .map((a) {
          final map = a as Map<String, dynamic>;
          return AuditFilterActorOption(
            id: map['id'] as int? ?? 0,
            username: (map['username'] as String?)?.trim() ?? '',
            displayName: (map['display_name'] as String?)?.trim() ?? '',
          );
        })
        .where((a) => a.id > 0)
        .toList();

    final rawEntities = json['entity_types'] as List<dynamic>? ?? const [];
    final entityTypes = rawEntities
        .map((e) {
          final map = e as Map<String, dynamic>;
          return AuditFilterEntityOption(
            value: (map['value'] as String?)?.trim() ?? '',
            label: (map['label'] as String?)?.trim() ?? '',
          );
        })
        .where((e) => e.value.isNotEmpty)
        .toList();

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
    final count = json['count'] as int? ?? 0;
    final next = json['next'];
    final rawResults = json['results'] as List<dynamic>? ?? const [];
    final items = rawResults
        .map((r) =>
            AuditLogEntryViewData.fromJson(r as Map<String, dynamic>))
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

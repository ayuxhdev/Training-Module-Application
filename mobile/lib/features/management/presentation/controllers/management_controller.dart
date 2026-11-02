import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
import 'package:training_app/features/management/data/services/video_file_picker.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';

bool canViewManagementDashboard(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('company_dashboard') || identity.canViewTeam;

String? managementAccount(AuthState auth) {
  if (auth is! AuthAuthenticated) return null;
  final identity = auth.identity;
  final capabilities = identity.capabilities.toList()..sort();
  return '${identity.userId}:${identity.username}:${identity.personalAccount}:${capabilities.join(',')}';
}

bool canCreateOrganizationReference(
  AuthenticatedIdentity identity,
  ReferenceKind kind,
) => identity.capabilities.contains(kind.addPermission);

bool canEditOrganizationReference(
  AuthenticatedIdentity identity,
  ReferenceKind kind,
) => identity.capabilities.contains(kind.changePermission);

bool canEditEmployee(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('organization.change_employee');

bool canCreateEmployee(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('organization.add_employee');

bool canAssignTraining(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('training.add_trainingassignment') ||
    identity.capabilities.contains('team_assignment');

bool canManageTraining(AuthenticatedIdentity identity) =>
    identity.canManageTraining ||
    canManageAssessments(identity) ||
    canManageQuestionBank(identity);

bool canViewTraining(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('training.view_training');

bool canCreateTraining(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('training.add_training');

bool canEditTraining(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('training.change_training');

bool canViewVersions(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('training.view_trainingversion');

bool canCreateVersions(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('training.add_trainingversion');

bool canEditVersions(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('training.change_trainingversion');

bool canManageVersions(AuthenticatedIdentity identity) =>
    canViewVersions(identity) ||
    canCreateVersions(identity) ||
    canEditVersions(identity);

bool canViewModules(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('training.view_module');

bool canCreateModules(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('training.add_module');

bool canEditModules(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('training.change_module');

bool canViewLessons(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('training.view_lesson');

bool canCreateLessons(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('training.add_lesson');

bool canEditLessons(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('training.change_lesson');

bool canAccessLessonEditForm(AuthenticatedIdentity identity) =>
    canViewLessons(identity) && canEditLessons(identity);

bool canViewAssessments(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('assessments.view_assessment');

bool canCreateAssessments(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('assessments.add_assessment');

bool canEditAssessments(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('assessments.change_assessment');

bool canAccessAssessmentEditForm(AuthenticatedIdentity identity) =>
    canViewAssessments(identity) && canEditAssessments(identity);

bool canViewAssessmentQuestions(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('assessments.view_assessmentquestion');

bool canCreateAssessmentQuestions(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('assessments.add_assessmentquestion');

bool canEditAssessmentQuestions(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('assessments.change_assessmentquestion');

bool canAccessAssessmentQuestionEditForm(AuthenticatedIdentity identity) =>
    canViewAssessmentQuestions(identity) &&
    canEditAssessmentQuestions(identity);

bool canViewQuestions(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('assessments.view_question');

bool canCreateQuestions(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('assessments.add_question');

bool canEditQuestions(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('assessments.change_question');

bool canAccessQuestionEditForm(AuthenticatedIdentity identity) =>
    canViewQuestions(identity) && canEditQuestions(identity);

bool canViewQuestionRevisions(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('assessments.view_questionrevision');

bool canCreateQuestionRevisions(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('assessments.add_questionrevision');

bool canEditQuestionRevisions(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('assessments.change_questionrevision');

bool canAccessQuestionRevisionEditForm(AuthenticatedIdentity identity) =>
    canViewQuestionRevisions(identity) && canEditQuestionRevisions(identity);

bool canManageAssessments(AuthenticatedIdentity identity) =>
    canViewAssessments(identity) ||
    canCreateAssessments(identity) ||
    canEditAssessments(identity);

bool canManageQuestionBank(AuthenticatedIdentity identity) =>
    canViewQuestions(identity) ||
    canCreateQuestions(identity) ||
    canEditQuestions(identity) ||
    canViewQuestionRevisions(identity) ||
    canCreateQuestionRevisions(identity) ||
    canEditQuestionRevisions(identity);

bool hasCompanyAssignmentAuthority(AuthenticatedIdentity identity) =>
    identity.capabilities.contains('training.add_trainingassignment');

bool canViewEmployeeAssignments(
  AuthenticatedIdentity identity, {
  bool isCurrentEmployee = false,
}) {
  if (isCurrentEmployee && !hasCompanyAssignmentAuthority(identity)) {
    return false;
  }
  return hasCompanyAssignmentAuthority(identity) ||
      identity.capabilities.contains('team_assignment') ||
      identity.capabilities.contains('assignment_report') ||
      identity.canViewTeam;
}

bool canAssignTrainingToEmployee({
  required AuthenticatedIdentity identity,
  required DirectoryEmployee employee,
}) {
  if (!employee.isActive) return false;
  if (identity.capabilities.contains('training.add_trainingassignment')) {
    return true;
  }
  if (identity.capabilities.contains('team_assignment')) {
    if (identity.employee != null &&
        identity.employee!.employeeCode == employee.employeeCode) {
      return false;
    }
    return true;
  }
  return false;
}

class EmployeeProfileMutationController {
  final ManagementRepository repository;
  final AuthState Function() readAuth;

  const EmployeeProfileMutationController({
    required this.repository,
    required this.readAuth,
  });

  Future<DirectoryEmployee> save({
    required DirectoryEmployee original,
    required String displayName,
    required int departmentId,
    required int jobRoleId,
    required String dateJoined,
    required bool updateReportingManager,
    int? reportingManagerId,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canEditEmployee(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot edit employee profiles.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final saved = await repository.updateEmployeeProfile(
      original,
      displayName: displayName,
      departmentId: departmentId,
      jobRoleId: jobRoleId,
      dateJoined: dateJoined,
      updateReportingManager: updateReportingManager,
      reportingManagerId: reportingManagerId,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canEditEmployee(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before the save completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return saved;
  }
}

class EmployeeCreationMutationController {
  final ManagementRepository repository;
  final AuthState Function() readAuth;

  const EmployeeCreationMutationController({
    required this.repository,
    required this.readAuth,
  });

  Future<DirectoryEmployee> create({
    required String employeeCode,
    required String displayName,
    required int departmentId,
    required int jobRoleId,
    required String dateJoined,
    int? reportingManagerId,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canCreateEmployee(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot create employees.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final created = await repository.createEmployee(
      employeeCode: employeeCode,
      displayName: displayName,
      departmentId: departmentId,
      jobRoleId: jobRoleId,
      dateJoined: dateJoined,
      reportingManagerId: reportingManagerId,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canCreateEmployee(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before creation completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return created;
  }
}

class EmployeeDeactivationMutationController {
  final ManagementRepository repository;
  final AuthState Function() readAuth;

  const EmployeeDeactivationMutationController({
    required this.repository,
    required this.readAuth,
  });

  Future<DirectoryEmployee> deactivate({
    required DirectoryEmployee employee,
    required String reason,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canEditEmployee(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot deactivate employees.',
        statusCode: 403,
      );
    }
    if (!employee.isActive) {
      throw ApiError(
        message: 'This employee is already inactive.',
        statusCode: 409,
      );
    }
    final currentEmployeeCode = initialAuth.identity.employee?.employeeCode
        .trim();
    if (currentEmployeeCode != null &&
        currentEmployeeCode.isNotEmpty &&
        currentEmployeeCode == employee.employeeCode) {
      throw ApiError(
        message: 'You cannot deactivate your own employee record.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final deactivated = await repository.deactivateEmployee(
      employee.id,
      reason: reason,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canEditEmployee(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before deactivation completed. Reopen the employee to continue.',
        statusCode: 403,
      );
    }
    return deactivated;
  }
}

final employeeDeactivationMutationProvider =
    Provider<EmployeeDeactivationMutationController>(
      (ref) => EmployeeDeactivationMutationController(
        repository: ref.watch(managementRepositoryProvider),
        readAuth: () => ref.read(authControllerProvider),
      ),
    );

final employeeCreationMutationProvider =
    Provider<EmployeeCreationMutationController>(
      (ref) => EmployeeCreationMutationController(
        repository: ref.watch(managementRepositoryProvider),
        readAuth: () => ref.read(authControllerProvider),
      ),
    );

final employeeProfileMutationProvider =
    Provider<EmployeeProfileMutationController>(
      (ref) => EmployeeProfileMutationController(
        repository: ref.watch(managementRepositoryProvider),
        readAuth: () => ref.read(authControllerProvider),
      ),
    );

class OrganizationReferenceMutationController {
  final ManagementRepository repository;
  final AuthState Function() readAuth;

  const OrganizationReferenceMutationController({
    required this.repository,
    required this.readAuth,
  });

  Future<OrganizationReference> save({
    required ReferenceKind kind,
    int? id,
    OrganizationReference? original,
    required String code,
    required String name,
    required String description,
    required bool isActive,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !(id == null
            ? canCreateOrganizationReference(initialAuth.identity, kind)
            : canEditOrganizationReference(initialAuth.identity, kind))) {
      throw ApiError(
        message: 'This account cannot save this ${kind.singular}.',
        statusCode: 403,
      );
    }
    if (id != null && (original == null || original.id != id)) {
      throw ArgumentError.value(original, 'original');
    }
    final account = managementAccount(initialAuth);
    final saved = await repository.saveReference(
      kind,
      id: id,
      original: original,
      code: code,
      name: name,
      description: description,
      isActive: isActive,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !(id == null
            ? canCreateOrganizationReference(currentAuth.identity, kind)
            : canEditOrganizationReference(currentAuth.identity, kind))) {
      throw ApiError(
        message: 'The account changed before the save completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return saved;
  }
}

final organizationReferenceMutationProvider =
    Provider<OrganizationReferenceMutationController>(
      (ref) => OrganizationReferenceMutationController(
        repository: ref.watch(managementRepositoryProvider),
        readAuth: () => ref.read(authControllerProvider),
      ),
    );

class TrainingAssignmentMutationController {
  final ManagementRepository repository;
  final AuthState Function() readAuth;

  const TrainingAssignmentMutationController({
    required this.repository,
    required this.readAuth,
  });

  Future<CreatedAssignment> assign({
    required int employeeId,
    String? employeeCode,
    required int trainingVersionId,
    String? dueDate,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canAssignTraining(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot assign training.',
        statusCode: 403,
      );
    }
    if (!initialAuth.identity.capabilities.contains(
          'training.add_trainingassignment',
        ) &&
        initialAuth.identity.employee != null &&
        employeeCode != null &&
        initialAuth.identity.employee!.employeeCode == employeeCode) {
      throw ApiError(
        message: 'Managers cannot assign training to themselves.',
        statusCode: 400,
      );
    }
    final account = managementAccount(initialAuth);
    final created = await repository.assignTraining(
      employeeId: employeeId,
      trainingVersionId: trainingVersionId,
      dueDate: dueDate,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canAssignTraining(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before the assignment completed.',
        statusCode: 403,
      );
    }
    return created;
  }
}

final trainingAssignmentMutationProvider =
    Provider<TrainingAssignmentMutationController>(
      (ref) => TrainingAssignmentMutationController(
        repository: ref.watch(managementRepositoryProvider),
        readAuth: () => ref.read(authControllerProvider),
      ),
    );

class TrainingCourseMutationController {
  final ManagementRepository repository;
  final AuthState Function() readAuth;

  const TrainingCourseMutationController({
    required this.repository,
    required this.readAuth,
  });

  Future<ManagedTraining> create({
    required String code,
    required String catalogTitle,
    String description = '',
    bool isActive = true,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canCreateTraining(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot create training courses.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final created = await repository.createTraining(
      code: code,
      catalogTitle: catalogTitle,
      description: description,
      isActive: isActive,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canCreateTraining(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before course creation completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return created;
  }

  Future<ManagedTraining> update(
    int id, {
    String? code,
    String? catalogTitle,
    String? description,
    bool? isActive,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canEditTraining(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot edit training courses.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final updated = await repository.updateTraining(
      id,
      code: code,
      catalogTitle: catalogTitle,
      description: description,
      isActive: isActive,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canEditTraining(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before course update completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return updated;
  }
}

final trainingCourseMutationProvider =
    Provider<TrainingCourseMutationController>(
      (ref) => TrainingCourseMutationController(
        repository: ref.watch(managementRepositoryProvider),
        readAuth: () => ref.read(authControllerProvider),
      ),
    );

class DraftVersionMutationController {
  final ManagementRepository repository;
  final AuthState Function() readAuth;

  const DraftVersionMutationController({
    required this.repository,
    required this.readAuth,
  });

  Future<ManagedVersionDetail> create({
    required int trainingId,
    required String title,
    String description = '',
    String learningObjectives = '',
    String changeSummary = '',
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canCreateVersions(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot create draft training versions.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final created = await repository.createDraftVersion(
      trainingId,
      title: title,
      description: description,
      learningObjectives: learningObjectives,
      changeSummary: changeSummary,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canCreateVersions(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before version creation completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return created;
  }
}

final draftVersionMutationProvider = Provider<DraftVersionMutationController>(
  (ref) => DraftVersionMutationController(
    repository: ref.watch(managementRepositoryProvider),
    readAuth: () => ref.read(authControllerProvider),
  ),
);

class ModuleMutationController {
  final ManagementRepository repository;
  final AuthState Function() readAuth;

  const ModuleMutationController({
    required this.repository,
    required this.readAuth,
  });

  Future<ManagedModuleDetail> create({
    required int versionId,
    required String title,
    String description = '',
    required int position,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canCreateModules(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot create modules.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final created = await repository.createModule(
      versionId,
      title: title,
      description: description,
      position: position,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canCreateModules(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before module creation completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return created;
  }

  Future<ManagedModuleDetail> update({
    required int versionId,
    required int moduleId,
    String? title,
    String? description,
    int? position,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canEditModules(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot edit modules.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final updated = await repository.updateModule(
      versionId,
      moduleId,
      title: title,
      description: description,
      position: position,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canEditModules(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before module update completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return updated;
  }
}

final moduleMutationProvider = Provider<ModuleMutationController>(
  (ref) => ModuleMutationController(
    repository: ref.watch(managementRepositoryProvider),
    readAuth: () => ref.read(authControllerProvider),
  ),
);

class TextLessonMutationController {
  final ManagementRepository repository;
  final AuthState Function() readAuth;

  const TextLessonMutationController({
    required this.repository,
    required this.readAuth,
  });

  Future<ManagedTextLessonDetail> create({
    required int versionId,
    required int moduleId,
    required String title,
    required String body,
    required int position,
    bool isRequired = true,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canCreateLessons(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot create lessons.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final created = await repository.createTextLesson(
      versionId,
      moduleId,
      title: title,
      body: body,
      position: position,
      isRequired: isRequired,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canCreateLessons(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before lesson creation completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return created;
  }

  Future<ManagedTextLessonDetail> update({
    required int versionId,
    required int moduleId,
    required int lessonId,
    String? title,
    String? body,
    int? position,
    bool? isRequired,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canEditLessons(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot edit lessons.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final updated = await repository.updateTextLesson(
      versionId,
      moduleId,
      lessonId,
      title: title,
      body: body,
      position: position,
      isRequired: isRequired,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canEditLessons(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before lesson update completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return updated;
  }
}

final textLessonMutationProvider = Provider<TextLessonMutationController>(
  (ref) => TextLessonMutationController(
    repository: ref.watch(managementRepositoryProvider),
    readAuth: () => ref.read(authControllerProvider),
  ),
);

class VideoLessonMutationController {
  final ManagementRepository repository;
  final AuthState Function() readAuth;

  VideoLessonMutationController({
    required this.repository,
    required this.readAuth,
  });

  Future<ManagedVideoLessonDetail> create({
    required int versionId,
    required int moduleId,
    required String title,
    required int position,
    required SelectedVideoFile videoFile,
    bool isRequired = true,
    double? minimumWatchPercent,
    ProgressCallback? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canCreateLessons(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot create lessons.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final created = await repository.createVideoLesson(
      versionId,
      moduleId,
      title: title,
      position: position,
      videoFile: videoFile,
      isRequired: isRequired,
      minimumWatchPercent: minimumWatchPercent,
      onSendProgress: onSendProgress,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canCreateLessons(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before lesson creation completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return created;
  }

  Future<ManagedVideoLessonDetail> update({
    required int versionId,
    required int moduleId,
    required int lessonId,
    String? title,
    int? position,
    bool? isRequired,
    double? minimumWatchPercent,
    SelectedVideoFile? videoFile,
    ProgressCallback? onSendProgress,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canEditLessons(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot edit lessons.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final updated = await repository.updateVideoLesson(
      versionId,
      moduleId,
      lessonId,
      title: title,
      position: position,
      isRequired: isRequired,
      minimumWatchPercent: minimumWatchPercent,
      videoFile: videoFile,
      onSendProgress: onSendProgress,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canEditLessons(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before lesson update completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return updated;
  }
}

final videoLessonMutationProvider = Provider<VideoLessonMutationController>(
  (ref) => VideoLessonMutationController(
    repository: ref.watch(managementRepositoryProvider),
    readAuth: () => ref.read(authControllerProvider),
  ),
);

class AssessmentMutationController {
  final ManagementRepository repository;
  final AuthState Function() readAuth;

  AssessmentMutationController({
    required this.repository,
    required this.readAuth,
  });

  Future<ManagedAssessment> create({
    required int versionId,
    required String kind,
    required String title,
    int? moduleId,
    int? sequence,
    double? passPercentage,
    int? maxAttempts,
    int? timeLimitMinutes,
    bool? isRequired,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canCreateAssessments(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot create assessments.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final created = await repository.createAssessment(
      versionId,
      kind: kind,
      title: title,
      moduleId: moduleId,
      sequence: sequence,
      passPercentage: passPercentage,
      maxAttempts: maxAttempts,
      timeLimitMinutes: timeLimitMinutes,
      isRequired: isRequired,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canCreateAssessments(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before assessment creation completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return created;
  }

  Future<ManagedAssessment> update({
    required int versionId,
    required int assessmentId,
    String? kind,
    String? title,
    int? moduleId,
    bool clearModuleId = false,
    int? sequence,
    double? passPercentage,
    int? maxAttempts,
    int? timeLimitMinutes,
    bool clearTimeLimit = false,
    bool? isRequired,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canEditAssessments(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot edit assessments.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final updated = await repository.updateAssessment(
      versionId,
      assessmentId,
      kind: kind,
      title: title,
      moduleId: moduleId,
      clearModuleId: clearModuleId,
      sequence: sequence,
      passPercentage: passPercentage,
      maxAttempts: maxAttempts,
      timeLimitMinutes: timeLimitMinutes,
      clearTimeLimit: clearTimeLimit,
      isRequired: isRequired,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canEditAssessments(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before assessment update completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return updated;
  }
}

final assessmentMutationProvider = Provider<AssessmentMutationController>(
  (ref) => AssessmentMutationController(
    repository: ref.watch(managementRepositoryProvider),
    readAuth: () => ref.read(authControllerProvider),
  ),
);

class AssessmentQuestionMutationController {
  final ManagementRepository repository;
  final AuthState Function() readAuth;

  AssessmentQuestionMutationController({
    required this.repository,
    required this.readAuth,
  });

  Future<ManagedAssessmentQuestion> create({
    required int versionId,
    required int assessmentId,
    required int questionRevisionId,
    required int position,
    double? points,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canCreateAssessmentQuestions(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot attach assessment questions.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final created = await repository.createAssessmentQuestion(
      versionId,
      assessmentId,
      questionRevisionId: questionRevisionId,
      position: position,
      points: points,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canCreateAssessmentQuestions(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before assessment question creation completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return created;
  }

  Future<ManagedAssessmentQuestion> update({
    required int versionId,
    required int assessmentId,
    required int itemId,
    int? questionRevisionId,
    int? position,
    double? points,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canEditAssessmentQuestions(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot edit assessment questions.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final updated = await repository.updateAssessmentQuestion(
      versionId,
      assessmentId,
      itemId,
      questionRevisionId: questionRevisionId,
      position: position,
      points: points,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canEditAssessmentQuestions(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before assessment question update completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return updated;
  }
}

final assessmentQuestionMutationProvider =
    Provider<AssessmentQuestionMutationController>(
      (ref) => AssessmentQuestionMutationController(
        repository: ref.watch(managementRepositoryProvider),
        readAuth: () => ref.read(authControllerProvider),
      ),
    );

class QuestionMutationController {
  final ManagementRepository repository;
  final AuthState Function() readAuth;

  QuestionMutationController({
    required this.repository,
    required this.readAuth,
  });

  Future<ManagedQuestion> create({
    required String code,
    String? topic,
    bool? isActive,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canCreateQuestions(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot create questions.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final created = await repository.createQuestion(
      code: code,
      topic: topic,
      isActive: isActive,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canCreateQuestions(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before question creation completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return created;
  }

  Future<ManagedQuestion> update({
    required int questionId,
    String? code,
    String? topic,
    bool? isActive,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canEditQuestions(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot edit questions.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final updated = await repository.updateQuestion(
      questionId,
      code: code,
      topic: topic,
      isActive: isActive,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canEditQuestions(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before question update completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return updated;
  }
}

final questionMutationProvider = Provider<QuestionMutationController>(
  (ref) => QuestionMutationController(
    repository: ref.watch(managementRepositoryProvider),
    readAuth: () => ref.read(authControllerProvider),
  ),
);

class QuestionRevisionMutationController {
  final ManagementRepository repository;
  final AuthState Function() readAuth;

  QuestionRevisionMutationController({
    required this.repository,
    required this.readAuth,
  });

  Future<ManagedQuestionRevisionSummary> create({
    required int questionId,
    required String prompt,
    String? questionType,
    String? explanation,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canCreateQuestionRevisions(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot create question revisions.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final created = await repository.createQuestionRevision(
      questionId,
      prompt: prompt,
      questionType: questionType,
      explanation: explanation,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canCreateQuestionRevisions(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before revision creation completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return created;
  }

  Future<ManagedQuestionRevisionDetail> update({
    required int questionId,
    required int revisionId,
    String? questionType,
    String? prompt,
    String? explanation,
    List<Map<String, dynamic>>? options,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canEditQuestionRevisions(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot edit question revisions.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final updated = await repository.updateQuestionRevision(
      questionId,
      revisionId,
      questionType: questionType,
      prompt: prompt,
      explanation: explanation,
      options: options,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canEditQuestionRevisions(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before revision update completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return updated;
  }

  Future<ManagedQuestionRevisionDetail> freeze({
    required int questionId,
    required int revisionId,
    CancelToken? cancelToken,
  }) async {
    final initialAuth = readAuth();
    if (initialAuth is! AuthAuthenticated ||
        !canEditQuestionRevisions(initialAuth.identity)) {
      throw ApiError(
        message: 'This account cannot freeze question revisions.',
        statusCode: 403,
      );
    }
    final account = managementAccount(initialAuth);
    final frozen = await repository.freezeQuestionRevision(
      questionId,
      revisionId,
      cancelToken: cancelToken,
    );
    final currentAuth = readAuth();
    if (managementAccount(currentAuth) != account ||
        currentAuth is! AuthAuthenticated ||
        !canEditQuestionRevisions(currentAuth.identity)) {
      throw ApiError(
        message: 'The account changed before revision freeze completed. Reopen the form to continue.',
        statusCode: 403,
      );
    }
    return frozen;
  }
}

final questionRevisionMutationProvider =
    Provider<QuestionRevisionMutationController>(
      (ref) => QuestionRevisionMutationController(
        repository: ref.watch(managementRepositoryProvider),
        readAuth: () => ref.read(authControllerProvider),
      ),
    );

CancelToken _request(Ref ref, bool Function(AuthenticatedIdentity) allowed) {
  final account = ref.watch(authControllerProvider.select(managementAccount));
  final auth = ref.read(authControllerProvider);
  if (account == null ||
      auth is! AuthAuthenticated ||
      !allowed(auth.identity)) {
    throw ApiError(
      message: 'This account cannot access this page.',
      statusCode: 403,
    );
  }
  final request = CancelToken();
  ref.onDispose(request.cancel);
  return request;
}

final managementDashboardProvider =
    FutureProvider.autoDispose<ManagementDashboard>((ref) {
      final request = _request(ref, canViewManagementDashboard);
      return ref
          .watch(managementRepositoryProvider)
          .dashboard(cancelToken: request);
    }, retry: (_, _) => null);

typedef EmployeeDirectoryRequest = ({
  int page,
  String? search,
  int? departmentId,
  int? jobRoleId,
  bool? isActive,
});

final employeeDirectoryProvider = FutureProvider.autoDispose
    .family<ManagementPage<DirectoryEmployee>, EmployeeDirectoryRequest>((
      ref,
      request,
    ) {
      final cancelToken = _request(
        ref,
        (identity) =>
            identity.capabilities.contains('organization.view_employee'),
      );
      final repository = ref.watch(managementRepositoryProvider);
      if (request.search == null &&
          request.departmentId == null &&
          request.jobRoleId == null &&
          request.isActive == null) {
        return repository.employees(
          page: request.page,
          cancelToken: cancelToken,
        );
      }
      return repository.employees(
        page: request.page,
        search: request.search,
        departmentId: request.departmentId,
        jobRoleId: request.jobRoleId,
        isActive: request.isActive,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);
final directoryEmployeeProvider = FutureProvider.autoDispose
    .family<DirectoryEmployee, int>((ref, id) {
      final request = _request(
        ref,
        (identity) =>
            identity.capabilities.contains('organization.view_employee'),
      );
      return ref
          .watch(managementRepositoryProvider)
          .employee(id, cancelToken: request);
    }, retry: (_, _) => null);

final employeeEditChoicesProvider = FutureProvider.autoDispose
    .family<EmployeeEditChoices, int>((ref, employeeId) {
      if (employeeId <= 0) throw ArgumentError.value(employeeId, 'employeeId');
      final request = _request(
        ref,
        (identity) =>
            identity.capabilities.contains('organization.view_employee'),
      );
      return ref
          .watch(managementRepositoryProvider)
          .employeeEditChoices(employeeId: employeeId, cancelToken: request);
    }, retry: (_, _) => null);

final employeeCreationChoicesProvider =
    FutureProvider.autoDispose<EmployeeEditChoices>((ref) {
      final request = _request(ref, canCreateEmployee);
      final auth = ref.read(authControllerProvider) as AuthAuthenticated;
      return ref
          .watch(managementRepositoryProvider)
          .employeeCreationChoices(
            includeReportingManagers: auth.identity.capabilities.contains(
              'organization.view_employee',
            ),
            cancelToken: request,
          );
    }, retry: (_, _) => null);

typedef ReferencePageRequest = ({ReferenceKind kind, int page});

final organizationReferencesProvider = FutureProvider.autoDispose
    .family<ManagementPage<OrganizationReference>, ReferencePageRequest>((
      ref,
      target,
    ) {
      final request = _request(
        ref,
        (identity) => identity.capabilities.contains(target.kind.permission),
      );
      return ref
          .watch(managementRepositoryProvider)
          .references(target.kind, page: target.page, cancelToken: request);
    }, retry: (_, _) => null);

final organizationReferenceChoicesProvider = FutureProvider.autoDispose
    .family<List<OrganizationReference>, ReferenceKind>((ref, kind) {
      final request = _request(
        ref,
        (identity) => identity.capabilities.contains(kind.permission),
      );
      return ref
          .watch(managementRepositoryProvider)
          .allReferences(kind, cancelToken: request);
    }, retry: (_, _) => null);

typedef AssignableVersionsRequest = ({int page, String? search});

final assignableTrainingVersionsProvider = FutureProvider.autoDispose
    .family<
      ManagementPage<AssignableTrainingVersion>,
      AssignableVersionsRequest
    >((ref, request) {
      final cancelToken = _request(ref, canAssignTraining);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.assignableTrainingVersions(
        page: request.page,
        search: request.search,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

typedef EmployeeAssignmentsRequest = ({int employeeId, int page});

final employeeAssignmentsProvider = FutureProvider.autoDispose
    .family<
      ManagementPage<EmployeeAssignmentSummary>,
      EmployeeAssignmentsRequest
    >((ref, request) {
      final cancelToken = _request(ref, canViewEmployeeAssignments);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.employeeAssignments(
        request.employeeId,
        page: request.page,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

typedef TrainingCatalogRequest = ({int page, String? search});

final managedTrainingsProvider = FutureProvider.autoDispose
    .family<ManagementPage<ManagedTraining>, TrainingCatalogRequest>((
      ref,
      request,
    ) {
      final cancelToken = _request(ref, canViewTraining);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.trainings(
        page: request.page,
        search: request.search,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

final managedTrainingDetailProvider = FutureProvider.autoDispose
    .family<ManagedTraining, int>((ref, id) {
      if (id <= 0) throw ArgumentError.value(id, 'id');
      final cancelToken = _request(ref, canViewTraining);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.training(id, cancelToken: cancelToken);
    }, retry: (_, _) => null);

typedef TrainingVersionsRequest = ({int trainingId, int page});

final managedTrainingVersionsProvider = FutureProvider.autoDispose
    .family<
      ManagementPage<ManagedTrainingVersionItem>,
      TrainingVersionsRequest
    >((ref, request) {
      if (request.trainingId <= 0) {
        throw ArgumentError.value(request.trainingId, 'trainingId');
      }
      final cancelToken = _request(ref, canViewVersions);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.trainingVersions(
        request.trainingId,
        page: request.page,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

final managedVersionDetailProvider = FutureProvider.autoDispose
    .family<ManagedVersionDetail, int>((ref, id) {
      if (id <= 0) throw ArgumentError.value(id, 'id');
      final cancelToken = _request(ref, canViewVersions);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.versionDetail(id, cancelToken: cancelToken);
    }, retry: (_, _) => null);

final allTrainingVersionsProvider = FutureProvider.autoDispose
    .family<ManagementPage<ManagedTrainingVersionItem>, int>((ref, page) {
      if (page <= 0) throw ArgumentError.value(page, 'page');
      final cancelToken = _request(ref, canViewVersions);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.allTrainingVersions(
        page: page,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

typedef ManagedModuleDetailKey = ({int versionId, int moduleId});

final managedModuleDetailProvider = FutureProvider.autoDispose
    .family<ManagedModuleDetail, ManagedModuleDetailKey>((ref, key) {
      if (key.versionId <= 0) {
        throw ArgumentError.value(key.versionId, 'versionId');
      }
      if (key.moduleId <= 0) {
        throw ArgumentError.value(key.moduleId, 'moduleId');
      }
      final cancelToken = _request(ref, canViewModules);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.moduleDetail(
        key.versionId,
        key.moduleId,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

typedef ManagedTextLessonDetailKey = ({
  int versionId,
  int moduleId,
  int lessonId,
});

final managedTextLessonDetailProvider = FutureProvider.autoDispose
    .family<ManagedTextLessonDetail, ManagedTextLessonDetailKey>((ref, key) {
      if (key.versionId <= 0) {
        throw ArgumentError.value(key.versionId, 'versionId');
      }
      if (key.moduleId <= 0) {
        throw ArgumentError.value(key.moduleId, 'moduleId');
      }
      if (key.lessonId <= 0) {
        throw ArgumentError.value(key.lessonId, 'lessonId');
      }
      final cancelToken = _request(ref, canViewLessons);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.textLessonDetail(
        key.versionId,
        key.moduleId,
        key.lessonId,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

typedef ManagedVideoLessonDetailKey = ({
  int versionId,
  int moduleId,
  int lessonId,
});

final managedVideoLessonDetailProvider = FutureProvider.autoDispose
    .family<ManagedVideoLessonDetail, ManagedVideoLessonDetailKey>((ref, key) {
      if (key.versionId <= 0) {
        throw ArgumentError.value(key.versionId, 'versionId');
      }
      if (key.moduleId <= 0) {
        throw ArgumentError.value(key.moduleId, 'moduleId');
      }
      if (key.lessonId <= 0) {
        throw ArgumentError.value(key.lessonId, 'lessonId');
      }
      final cancelToken = _request(ref, canViewLessons);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.videoLessonDetail(
        key.versionId,
        key.moduleId,
        key.lessonId,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

typedef ManagedVersionAssessmentsQuery = ({int versionId, int page});

final managedVersionAssessmentsProvider = FutureProvider.autoDispose
    .family<ManagementPage<ManagedAssessment>, ManagedVersionAssessmentsQuery>((
      ref,
      query,
    ) {
      if (query.versionId <= 0) {
        throw ArgumentError.value(query.versionId, 'versionId');
      }
      if (query.page <= 0) {
        throw ArgumentError.value(query.page, 'page');
      }
      final cancelToken = _request(ref, canViewAssessments);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.assessments(
        query.versionId,
        page: query.page,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

typedef ManagedAssessmentKey = ({int versionId, int assessmentId});

final managedAssessmentDetailProvider = FutureProvider.autoDispose
    .family<ManagedAssessment, ManagedAssessmentKey>((ref, key) {
      if (key.versionId <= 0) {
        throw ArgumentError.value(key.versionId, 'versionId');
      }
      if (key.assessmentId <= 0) {
        throw ArgumentError.value(key.assessmentId, 'assessmentId');
      }
      final cancelToken = _request(ref, canViewAssessments);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.assessmentDetail(
        key.versionId,
        key.assessmentId,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

typedef ManagedAssessmentQuestionsQuery = ({
  int versionId,
  int assessmentId,
  int page,
});

final managedAssessmentQuestionsProvider = FutureProvider.autoDispose
    .family<
      ManagementPage<ManagedAssessmentQuestion>,
      ManagedAssessmentQuestionsQuery
    >((ref, query) {
      if (query.versionId <= 0) {
        throw ArgumentError.value(query.versionId, 'versionId');
      }
      if (query.assessmentId <= 0) {
        throw ArgumentError.value(query.assessmentId, 'assessmentId');
      }
      if (query.page <= 0) {
        throw ArgumentError.value(query.page, 'page');
      }
      final cancelToken = _request(ref, canViewAssessmentQuestions);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.assessmentQuestions(
        query.versionId,
        query.assessmentId,
        page: query.page,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

typedef ManagedAssessmentQuestionDetailKey = ({
  int versionId,
  int assessmentId,
  int itemId,
});

final managedAssessmentQuestionDetailProvider = FutureProvider.autoDispose
    .family<ManagedAssessmentQuestion, ManagedAssessmentQuestionDetailKey>((
      ref,
      key,
    ) {
      if (key.versionId <= 0) {
        throw ArgumentError.value(key.versionId, 'versionId');
      }
      if (key.assessmentId <= 0) {
        throw ArgumentError.value(key.assessmentId, 'assessmentId');
      }
      if (key.itemId <= 0) {
        throw ArgumentError.value(key.itemId, 'itemId');
      }
      final cancelToken = _request(ref, canViewAssessmentQuestions);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.assessmentQuestionDetail(
        key.versionId,
        key.assessmentId,
        key.itemId,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

typedef QuestionQuery = ({int page, String? search, bool? isActive});

final managedQuestionsProvider = FutureProvider.autoDispose
    .family<ManagementPage<ManagedQuestion>, QuestionQuery>((ref, query) {
      if (query.page <= 0) {
        throw ArgumentError.value(query.page, 'page');
      }
      final cancelToken = _request(ref, canViewQuestions);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.questions(
        page: query.page,
        search: query.search,
        isActive: query.isActive,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

final managedQuestionDetailProvider = FutureProvider.autoDispose
    .family<ManagedQuestion, int>((ref, questionId) {
      if (questionId <= 0) {
        throw ArgumentError.value(questionId, 'questionId');
      }
      final cancelToken = _request(ref, canViewQuestions);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.questionDetail(questionId, cancelToken: cancelToken);
    }, retry: (_, _) => null);

typedef QuestionRevisionsQuery = ({int questionId, int page});

final managedQuestionRevisionsProvider = FutureProvider.autoDispose
    .family<
      ManagementPage<ManagedQuestionRevisionSummary>,
      QuestionRevisionsQuery
    >((ref, query) {
      if (query.questionId <= 0) {
        throw ArgumentError.value(query.questionId, 'questionId');
      }
      if (query.page <= 0) {
        throw ArgumentError.value(query.page, 'page');
      }
      final cancelToken = _request(ref, canViewQuestionRevisions);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.questionRevisions(
        query.questionId,
        page: query.page,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

typedef ManagedRevisionKey = ({int questionId, int revisionId});

final managedQuestionRevisionDetailProvider = FutureProvider.autoDispose
    .family<ManagedQuestionRevisionDetail, ManagedRevisionKey>((ref, key) {
      if (key.questionId <= 0) {
        throw ArgumentError.value(key.questionId, 'questionId');
      }
      if (key.revisionId <= 0) {
        throw ArgumentError.value(key.revisionId, 'revisionId');
      }
      final cancelToken = _request(ref, canViewQuestionRevisions);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.questionRevisionDetail(
        key.questionId,
        key.revisionId,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

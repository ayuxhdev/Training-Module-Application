import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/data/repositories/management_repository.dart';
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
    .family<ManagementPage<AssignableTrainingVersion>, AssignableVersionsRequest>((
      ref,
      request,
    ) {
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
    .family<ManagementPage<EmployeeAssignmentSummary>, EmployeeAssignmentsRequest>((
      ref,
      request,
    ) {
      final cancelToken = _request(ref, canViewEmployeeAssignments);
      final repository = ref.watch(managementRepositoryProvider);
      return repository.employeeAssignments(
        request.employeeId,
        page: request.page,
        cancelToken: cancelToken,
      );
    }, retry: (_, _) => null);

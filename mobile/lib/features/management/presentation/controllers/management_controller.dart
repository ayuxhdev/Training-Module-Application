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

final employeeDirectoryProvider = FutureProvider.autoDispose
    .family<ManagementPage<DirectoryEmployee>, int>((ref, page) {
      final request = _request(
        ref,
        (identity) =>
            identity.capabilities.contains('organization.view_employee'),
      );
      return ref
          .watch(managementRepositoryProvider)
          .employees(page: page, cancelToken: request);
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

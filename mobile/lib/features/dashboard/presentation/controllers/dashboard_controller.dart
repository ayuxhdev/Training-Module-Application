import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/data/repositories/dashboard_repository.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';

final dashboardDataProvider = FutureProvider.autoDispose<DashboardData>((
  ref,
) async {
  final username = ref.watch(
    authControllerProvider.select(
      (state) => state is AuthAuthenticated ? state.employee.username : null,
    ),
  );
  if (username == null) {
    throw ApiError(message: 'Sign in to view your dashboard.', statusCode: 401);
  }
  final repository = ref.watch(dashboardRepositoryProvider);
  return repository.getDashboardData();
}, retry: (_, _) => null);

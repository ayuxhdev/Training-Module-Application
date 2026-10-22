import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/dashboard/data/repositories/dashboard_repository.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';

final dashboardDataProvider = FutureProvider.autoDispose<DashboardData>((
  ref,
) async {
  final account = ref.watch(
    authControllerProvider.select(
      (state) => state is AuthAuthenticated
          ? state.personalAccount
          : null,
    ),
  );
  if (account == null) {
    throw ApiError(message: 'Sign in to view your dashboard.', statusCode: 401);
  }
  final requests = CancelToken();
  ref.onDispose(requests.cancel);
  final repository = ref.watch(dashboardRepositoryProvider);
  return repository.getDashboardData(cancelToken: requests);
}, retry: (_, _) => null);

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/features/dashboard/data/repositories/dashboard_repository.dart';
import 'package:training_app/features/dashboard/domain/models/dashboard_data.dart';

final dashboardDataProvider = FutureProvider.autoDispose<DashboardData>((ref) async {
  final repository = ref.watch(dashboardRepositoryProvider);
  return repository.getDashboardData();
});


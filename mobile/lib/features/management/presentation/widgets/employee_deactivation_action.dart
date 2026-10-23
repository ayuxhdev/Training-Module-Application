import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';
import 'package:training_app/features/management/presentation/controllers/management_controller.dart';
import 'package:training_app/features/management/presentation/widgets/employee_deactivation_dialog.dart';

class EmployeeDeactivationAction extends ConsumerStatefulWidget {
  final DirectoryEmployee employee;

  const EmployeeDeactivationAction({super.key, required this.employee});

  @override
  ConsumerState<EmployeeDeactivationAction> createState() =>
      _EmployeeDeactivationActionState();
}

class _EmployeeDeactivationActionState
    extends ConsumerState<EmployeeDeactivationAction> {
  late final String? _account;
  CancelToken? _activeRequest;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    _account = managementAccount(ref.read(authControllerProvider));
  }

  @override
  void dispose() {
    _activeRequest?.cancel('Employee deactivation action disposed');
    super.dispose();
  }

  Future<void> _deactivate() async {
    if (_isSubmitting) return;
    final reason = await showDialog<String>(
      context: context,
      builder: (_) => const EmployeeDeactivationDialog(),
    );
    if (reason == null || !mounted) return;
    final auth = ref.read(authControllerProvider);
    if (managementAccount(auth) != _account ||
        auth is! AuthAuthenticated ||
        !canEditEmployee(auth.identity)) {
      _showMessage(
        'Your account or permissions changed. Reopen this employee.',
      );
      return;
    }

    final request = CancelToken();
    _activeRequest = request;
    setState(() => _isSubmitting = true);
    try {
      await ref
          .read(employeeDeactivationMutationProvider)
          .deactivate(
            employee: widget.employee,
            reason: reason,
            cancelToken: request,
          );
      if (!mounted ||
          request.isCancelled ||
          managementAccount(ref.read(authControllerProvider)) != _account) {
        return;
      }
      ref.invalidate(directoryEmployeeProvider(widget.employee.id));
      ref.invalidate(employeeDirectoryProvider);
      ref.invalidate(managementDashboardProvider);
      _showMessage(
        'Employee deactivated. Any linked login is disabled; historical training records are preserved.',
      );
    } catch (error) {
      if (!mounted ||
          request.isCancelled ||
          managementAccount(ref.read(authControllerProvider)) != _account) {
        return;
      }
      final apiError = error is ApiError ? error : ApiError.unexpected();
      if (apiError.statusCode == 401) {
        await ref.read(authControllerProvider.notifier).logout();
        return;
      }
      if (apiError.statusCode == 409 && apiError.code == 'employee_inactive') {
        ref.invalidate(directoryEmployeeProvider(widget.employee.id));
        ref.invalidate(employeeDirectoryProvider);
      }
      _showMessage(
        apiError.statusCode == 403
            ? 'You are not authorized to deactivate this employee.'
            : apiError.message,
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSubmitting = false;
          if (identical(_activeRequest, request)) _activeRequest = null;
        });
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AuthState>(authControllerProvider, (_, next) {
      if (managementAccount(next) != _account) {
        _activeRequest?.cancel('Account changed');
        setState(() {});
      }
    });
    return IconButton(
      tooltip: _isSubmitting ? 'Deactivating employee' : 'Deactivate employee',
      onPressed: _isSubmitting ? null : _deactivate,
      icon: _isSubmitting
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              Icons.person_off_outlined,
              color: Theme.of(context).colorScheme.error,
            ),
    );
  }
}

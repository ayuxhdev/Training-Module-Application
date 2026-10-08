import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:training_app/core/presentation/components/custom_card.dart';
import 'package:training_app/core/presentation/components/secondary_button.dart';
import 'package:training_app/core/presentation/components/status_badge.dart';
import 'package:training_app/core/theme/app_spacing.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);

    if (authState is! AuthAuthenticated) {
      return const SizedBox.shrink(); // AppShell handles loading/error
    }

    final employee = authState.employee;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Center(
            child: CircleAvatar(
              radius: 48,
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(
                Icons.person,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Center(
            child: StatusBadge(
              text: employee.isActive ? 'Active' : 'Inactive',
              status: employee.isActive ? BadgeStatus.success : BadgeStatus.error,
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          CustomCard(
            child: Column(
              children: [
                _ProfileItem(label: 'Name', value: employee.displayName),
                const Divider(),
                _ProfileItem(label: 'Employee Code', value: employee.employeeCode),
                const Divider(),
                _ProfileItem(label: 'Department', value: employee.department),
                const Divider(),
                _ProfileItem(label: 'Job Role', value: employee.jobRole),
                const Divider(),
                _ProfileItem(label: 'Username', value: employee.username),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          SecondaryButton(
            text: 'Logout',
            onPressed: () {
              ref.read(authControllerProvider.notifier).logout();
            },
          ),
        ],
      ),
    );
  }
}

class _ProfileItem extends StatelessWidget {
  final String label;
  final String value;

  const _ProfileItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

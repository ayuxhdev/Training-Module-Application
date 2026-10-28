import 'package:training_app/features/auth/domain/models/employee.dart';

/// Server-issued navigation hints. Every API operation still checks authorization.
class AuthenticatedIdentity {
  final int? userId;
  final String username;
  final String displayName;
  final Employee? employee;
  final Set<String> capabilities;

  AuthenticatedIdentity({
    this.userId,
    required this.username,
    required this.displayName,
    this.employee,
    Set<String> capabilities = const {},
  }) : capabilities = Set.unmodifiable(capabilities);

  factory AuthenticatedIdentity.fromEmployee(Employee employee) =>
      AuthenticatedIdentity(
        username: employee.username,
        displayName: employee.displayName,
        employee: employee,
        capabilities: {if (employee.isActive) 'personal_learning'},
      );

  factory AuthenticatedIdentity.fromJson(Map<String, dynamic> json) {
    // Existing servers return the flat Employee contract. New servers explicitly
    // return nullable Employee context and capabilities; never infer grants there.
    if (!json.containsKey('employee')) {
      return AuthenticatedIdentity.fromEmployee(Employee.fromJson(json));
    }
    final user = json['user'] as Map<String, dynamic>;
    final context = json['employee'] as Map<String, dynamic>?;
    return AuthenticatedIdentity(
      userId: user['id'] as int,
      username: user['username'] as String,
      displayName: user['display_name'] as String,
      employee: context == null ? null : Employee.fromJson(context),
      capabilities: (json['capabilities'] as List<dynamic>)
          .cast<String>()
          .toSet(),
    );
  }

  bool get canLearn =>
      employee?.isActive == true && capabilities.contains('personal_learning');
  bool get canManage => capabilities.contains('management_workspace');
  bool get canViewTeam => capabilities.contains('team_workspace');
  bool get canManageTraining =>
      capabilities.contains('training.view_training') ||
      capabilities.contains('training.add_training') ||
      capabilities.contains('training.change_training') ||
      capabilities.contains('training.view_trainingversion') ||
      capabilities.contains('training.add_trainingversion') ||
      capabilities.contains('training.change_trainingversion') ||
      capabilities.contains('training.view_module') ||
      capabilities.contains('training.add_module') ||
      capabilities.contains('training.change_module') ||
      capabilities.contains('training.view_lesson') ||
      capabilities.contains('training.add_lesson') ||
      capabilities.contains('training.change_lesson');

  String get homePath => canLearn
      ? '/dashboard'
      : canManage || canViewTeam || canManageTraining
      ? '/workspace'
      : '/profile';
  String? get personalAccount =>
      canLearn ? '$username:${employee!.employeeCode}' : null;
}

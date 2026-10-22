import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';

sealed class AuthState {}

class AuthInitial extends AuthState {}

class AuthLoading extends AuthState {}

class AuthUnauthenticated extends AuthState {}

class AuthAuthenticated extends AuthState {
  final AuthenticatedIdentity identity;
  AuthAuthenticated(Employee employee)
    : identity = AuthenticatedIdentity.fromEmployee(employee);
  AuthAuthenticated.identity(this.identity);

  Employee? get employee => identity.employee;
  bool get canLearn => identity.canLearn;
  String? get personalAccount => identity.personalAccount;
}

class AuthError extends AuthState {
  final ApiError error;
  AuthError(this.error);
}

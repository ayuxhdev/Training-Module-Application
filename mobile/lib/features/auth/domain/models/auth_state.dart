import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';

sealed class AuthState {}

class AuthInitial extends AuthState {}

class AuthLoading extends AuthState {}

class AuthUnauthenticated extends AuthState {}

class AuthAuthenticated extends AuthState {
  final Employee employee;
  AuthAuthenticated(this.employee);
}

class AuthError extends AuthState {
  final ApiError error;
  AuthError(this.error);
}


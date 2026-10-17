import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/auth/presentation/screens/login_screen.dart';
import 'package:training_app/core/presentation/screens/app_shell.dart';
import 'package:training_app/features/dashboard/presentation/screens/dashboard_screen.dart';
import 'package:training_app/features/learning/presentation/screens/learning_screen.dart';
import 'package:training_app/features/learning/presentation/screens/assignment_detail_screen.dart';
import 'package:training_app/features/learning/presentation/screens/module_list_screen.dart';
import 'package:training_app/features/learning/presentation/screens/lesson_list_screen.dart';
import 'package:training_app/features/learning/presentation/screens/text_lesson_screen.dart';
import 'package:training_app/features/learning/presentation/screens/video_lesson_screen.dart';
import 'package:training_app/features/profile/presentation/screens/profile_screen.dart';
import 'package:training_app/core/presentation/components/error_view.dart';
import 'package:training_app/features/assessments/presentation/screens/assessment_overview_screen.dart';
import 'package:training_app/features/assessments/presentation/screens/assessment_attempt_screen.dart';
import 'package:training_app/features/certificates/presentation/screens/certificate_list_screen.dart';
import 'package:training_app/features/certificates/presentation/screens/certificate_detail_screen.dart';
import 'package:training_app/features/notifications/presentation/screens/notification_center_screen.dart';

// Create a Listenable to trigger router redirects on auth state changes
class RouterNotifier extends ChangeNotifier {
  final Ref _ref;

  RouterNotifier(this._ref) {
    _ref.listen<AuthState>(authControllerProvider, (_, _) {
      notifyListeners();
    });
  }
}

final appRouterProvider = Provider<GoRouter>((ref) {
  final notifier = RouterNotifier(ref);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: notifier,
    redirect: (context, state) {
      final authState = ref.read(authControllerProvider);
      final isLoggingIn = state.matchedLocation == '/login';

      if (authState is AuthInitial || authState is AuthLoading) {
        return null;
      }

      if (authState is AuthUnauthenticated) {
        return isLoggingIn ? null : '/login';
      }

      if (authState is AuthAuthenticated) {
        if (isLoggingIn || state.matchedLocation == '/') {
          return '/dashboard';
        }
        return null;
      }

      if (authState is AuthError) {
        return null; // Do not force logout redirect on transient errors
      }

      return null;
    },
    routes: [
      // Protected playback sits outside the shell so fullscreen has no tab bar.
      GoRoute(
        path: '/learning/assignments/:id/modules/:moduleId/lessons/:lessonId/video',
        builder: (context, state) {
          final id = int.tryParse(state.pathParameters['id'] ?? '');
          final moduleId = int.tryParse(state.pathParameters['moduleId'] ?? '');
          final lessonId = int.tryParse(state.pathParameters['lessonId'] ?? '');
          if (id == null ||
              moduleId == null ||
              lessonId == null ||
              id <= 0 ||
              moduleId <= 0 ||
              lessonId <= 0) {
            return const Scaffold(body: ErrorView(message: 'Invalid ID'));
          }
          return VideoLessonScreen(
            assignmentId: id,
            moduleId: moduleId,
            lessonId: lessonId,
          );
        },
      ),
      GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
      GoRoute(
        path: '/',
        builder: (context, state) =>
            AppShell(location: state.uri.path, child: const SizedBox.shrink()),
      ),
      ShellRoute(
        builder: (context, state, child) =>
            AppShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/dashboard',
            builder: (context, state) => const DashboardScreen(),
          ),
          GoRoute(
            path: '/notifications',
            builder: (context, state) => const NotificationCenterScreen(),
          ),
          GoRoute(
            path: '/learning/assignments/:id/assessments',
            builder: (context, state) {
              final id = int.tryParse(state.pathParameters['id'] ?? '');
              final module = state.uri.queryParameters['module'];
              final moduleId = module == null ? null : int.tryParse(module);
              if (id == null ||
                  id <= 0 ||
                  (module != null && (moduleId == null || moduleId <= 0))) {
                return const Scaffold(body: ErrorView(message: 'Invalid ID'));
              }
              return AssessmentOverviewScreen(
                assignmentId: id,
                moduleId: moduleId,
              );
            },
            routes: [
              GoRoute(
                path: ':assessmentId/attempt',
                builder: _assessmentAttempt,
              ),
              GoRoute(
                path: ':assessmentId/attempts/:attemptId',
                builder: _assessmentAttempt,
              ),
            ],
          ),
          GoRoute(
            path: '/learning',
            builder: (context, state) => const LearningScreen(),
            routes: [
              GoRoute(
                path: 'assignments/:id',
                builder: (context, state) {
                  final idString = state.pathParameters['id'];
                  final id = int.tryParse(idString ?? '');
                  if (id == null) {
                    return const Scaffold(
                      body: ErrorView(message: 'Invalid assignment ID'),
                    );
                  }
                  return AssignmentDetailScreen(assignmentId: id);
                },
                routes: [
                  GoRoute(
                    path: 'modules',
                    builder: (context, state) {
                      final idString = state.pathParameters['id'];
                      final id = int.tryParse(idString ?? '');
                      if (id == null) {
                        return const Scaffold(
                          body: ErrorView(message: 'Invalid assignment ID'),
                        );
                      }
                      return ModuleListScreen(assignmentId: id);
                    },
                    routes: [
                      GoRoute(
                        path: ':moduleId/lessons',
                        builder: (context, state) {
                          final idString = state.pathParameters['id'];
                          final moduleIdString =
                              state.pathParameters['moduleId'];
                          final id = int.tryParse(idString ?? '');
                          final moduleId = int.tryParse(moduleIdString ?? '');
                          if (id == null || moduleId == null) {
                            return const Scaffold(
                              body: ErrorView(message: 'Invalid ID'),
                            );
                          }
                          return LessonListScreen(
                            assignmentId: id,
                            moduleId: moduleId,
                          );
                        },
                        routes: [
                          GoRoute(
                            path: ':lessonId/text',
                            builder: (context, state) {
                              final idString = state.pathParameters['id'];
                              final lessonIdString =
                                  state.pathParameters['lessonId'];
                              final id = int.tryParse(idString ?? '');
                              final lessonId = int.tryParse(
                                lessonIdString ?? '',
                              );
                              if (id == null || lessonId == null) {
                                return const Scaffold(
                                  body: ErrorView(message: 'Invalid ID'),
                                );
                              }
                              return TextLessonScreen(
                                assignmentId: id,
                                lessonId: lessonId,
                              );
                            },
                          ),
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          GoRoute(
            path: '/profile',
            builder: (context, state) => const ProfileScreen(),
            routes: [
              GoRoute(
                path: 'certificates',
                builder: (context, state) => const CertificateListScreen(),
                routes: [
                  GoRoute(
                    path: ':certificateId',
                    builder: (context, state) {
                      final id = int.tryParse(
                        state.pathParameters['certificateId'] ?? '',
                      );
                      if (id == null || id <= 0) {
                        return const Scaffold(
                          body: ErrorView(message: 'Invalid ID'),
                        );
                      }
                      return CertificateDetailScreen(
                        key: ValueKey(id),
                        certificateId: id,
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
});

Widget _assessmentAttempt(BuildContext context, GoRouterState state) {
  final assignmentId = int.tryParse(state.pathParameters['id'] ?? '');
  final assessmentId = int.tryParse(state.pathParameters['assessmentId'] ?? '');
  final rawAttempt = state.pathParameters['attemptId'];
  final attemptId = rawAttempt == null ? null : int.tryParse(rawAttempt);
  if (assignmentId == null ||
      assignmentId <= 0 ||
      assessmentId == null ||
      assessmentId <= 0 ||
      (rawAttempt != null && (attemptId == null || attemptId <= 0))) {
    return const Scaffold(body: ErrorView(message: 'Invalid ID'));
  }
  return AssessmentAttemptScreen(
    key: ValueKey((assignmentId, assessmentId, attemptId)),
    target: (assignmentId: assignmentId, assessmentId: assessmentId),
    attemptId: attemptId,
  );
}

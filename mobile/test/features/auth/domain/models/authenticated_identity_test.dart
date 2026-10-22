import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';

Map<String, dynamic> identityJson({
  bool employee = true,
  List<String>? capabilities,
}) => {
  'user': {'id': 7, 'username': 'qa', 'display_name': 'QA account'},
  'employee': employee
      ? {
          'username': 'qa',
          'employee_code': 'QA7',
          'display_name': 'QA employee',
          'department': 'QA',
          'job_role': 'Manager',
          'is_active': true,
        }
      : null,
  'capabilities': capabilities ?? ['personal_learning'],
};

void main() {
  test(
    'employee context and server capabilities parse independently of job role',
    () {
      final identity = AuthenticatedIdentity.fromJson(identityJson());
      expect(identity.userId, 7);
      expect(identity.employee!.employeeCode, 'QA7');
      expect(identity.canLearn, isTrue);
      expect(identity.canManage, isFalse);
      expect(identity.canViewTeam, isFalse);
      expect(identity.homePath, '/dashboard');
    },
  );

  test(
    'management-only identity has no personal context or fabricated grants',
    () {
      final identity = AuthenticatedIdentity.fromJson(
        identityJson(
          employee: false,
          capabilities: ['management_workspace', 'training.view_training'],
        ),
      );
      expect(identity.employee, isNull);
      expect(identity.canManage, isTrue);
      expect(identity.canLearn, isFalse);
      expect(identity.personalAccount, isNull);
      expect(identity.homePath, '/workspace');
    },
  );

  test('combined capabilities are supported and immutable', () {
    final identity = AuthenticatedIdentity.fromJson(
      identityJson(
        capabilities: [
          'personal_learning',
          'team_workspace',
          'management_workspace',
        ],
      ),
    );
    expect(
      identity.canLearn && identity.canManage && identity.canViewTeam,
      isTrue,
    );
    expect(() => identity.capabilities.add('another'), throwsUnsupportedError);
  });

  test('personal access requires both an active employee and an explicit capability', () {
    expect(
      AuthenticatedIdentity.fromJson(identityJson(capabilities: [])).canLearn,
      isFalse,
    );
    expect(
      AuthenticatedIdentity.fromJson(identityJson(employee: false)).canLearn,
      isFalse,
    );
    final json = identityJson();
    (json['employee'] as Map<String, dynamic>)['is_active'] = false;
    expect(AuthenticatedIdentity.fromJson(json).canLearn, isFalse);
  });

  test(
    'legacy flat Employee contract remains supported without management grants',
    () {
      final json = identityJson()['employee'] as Map<String, dynamic>;
      final identity = AuthenticatedIdentity.fromJson(json);
      expect(identity.personalAccount, 'qa:QA7');
      expect(identity.canManage || identity.canViewTeam, isFalse);
    },
  );

  test(
    'malformed new identity fails rather than falling back to inferred grants',
    () {
      final json = identityJson()..remove('capabilities');
      expect(
        () => AuthenticatedIdentity.fromJson(json),
        throwsA(isA<TypeError>()),
      );
    },
  );
}

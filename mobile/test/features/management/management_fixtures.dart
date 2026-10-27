import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/authenticated_identity.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/management/domain/models/management_models.dart';

class ManagementTestAuth extends AuthController {
  final AuthenticatedIdentity identity;
  bool loggedOut = false;
  ManagementTestAuth(this.identity);
  @override
  AuthState build() => AuthAuthenticated.identity(identity);
  void setAuth(AuthState auth) => state = auth;
  @override
  Future<void> logout() async {
    loggedOut = true;
    state = AuthUnauthenticated();
  }
}

AuthenticatedIdentity managementIdentity({
  bool team = false,
  String username = 'admin',
  Set<String>? capabilities,
  bool writeReferences = false,
}) => AuthenticatedIdentity(
  userId: team ? 2 : 1,
  username: username,
  displayName: username,
  employee: team
      ? Employee(
          username: username,
          employeeCode: 'MGR',
          displayName: username,
          department: 'Operations',
          jobRole: 'Operator',
          isActive: true,
        )
      : null,
  capabilities:
      capabilities ??
      {
        if (team) ...{
          'personal_learning',
          'team_workspace',
        } else ...{
          'management_workspace',
          'company_dashboard',
        },
        'organization.view_employee',
        'organization.view_department',
        'organization.view_jobrole',
        if (writeReferences) ...{
          'organization.add_department',
          'organization.change_department',
          'organization.add_jobrole',
          'organization.change_jobrole',
        },
      },
);

Map<String, dynamic> referenceJson([int id = 1]) => {
  'id': id,
  'code': 'REF$id',
  'name': 'Operations $id',
  'description': 'Organization reference',
  'is_active': true,
};

Map<String, dynamic> employeeJson([int id = 1, String? name]) => {
  'id': id,
  'employee_code': 'EMP$id',
  'display_name': name ?? 'Employee $id',
  'department': {'id': 1, 'code': 'OPS', 'name': 'Operations'},
  'job_role': {'id': 1, 'code': 'OP', 'name': 'Operator'},
  'reporting_manager': 'Team Manager',
  'is_active': true,
  'date_joined': '2020-01-02',
  'login_status': 'ACTIVE',
};

Map<String, dynamic> employeeDetailJson([int id = 1, String? name]) =>
    employeeJson(id, name)..['reporting_manager_id'] = 9;

EmployeeEditChoices employeeEditChoicesFixture({int employeeId = 1}) =>
    EmployeeEditChoices(
      departments: [
        OrganizationReference(id: 1, code: 'OPS', name: 'Operations'),
        const OrganizationReference(
          id: 2,
          code: 'ARCHIVE',
          name: 'Archived Department',
          isActive: false,
        ),
      ],
      jobRoles: [
        const OrganizationReference(id: 1, code: 'OP', name: 'Operator'),
        const OrganizationReference(
          id: 2,
          code: 'LEAD',
          name: 'Lead',
          isActive: false,
        ),
      ],
      reportingManagers: [
        for (final id in [1, 2, 3])
          if (id != employeeId)
            DirectoryEmployee.fromJson(
              employeeJson(id, id == 2 ? 'Manager Two' : 'Employee $id'),
            ),
      ],
    );

Map<String, dynamic> pageJson(
  List<Map<String, dynamic>> items, {
  int? count,
  String? next,
}) => {
  'count': count ?? items.length,
  'next': next,
  'previous': null,
  'results': items,
};

Map<String, dynamic> managementDashboardJson({bool team = false}) => {
  'scope': team ? 'team' : 'company',
  'metrics': {
    'total': 3,
    'assigned': 1,
    'in_progress': 1,
    'completed': 1,
    'cancelled': 0,
    'overdue': 1,
    'eligible': 3,
    'completion_percent': 33.3,
  },
  'summary': team
      ? {'employees_in_scope': 3, 'certificates_issued': 1}
      : {
          'active_employee_count': 4,
          'department_count': 2,
          'published_training_count': 1,
          'certificates_issued': 1,
        },
  'recent_failures': [
    {
      'assessment_title': 'Safety quiz',
      'employee_name': 'Employee 1',
      'score_points': '0.00',
      'maximum_points': '2.00',
      'submitted_at': '2026-10-20T23:00:00Z',
    },
  ],
  'incomplete_employees': team
      ? [
          {
            'employee_id': 1,
            'employee_name': 'Employee 1',
            'incomplete_assignment_count': 2,
            'overdue_assignment_count': 1,
          },
        ]
      : [],
};

ManagementDashboard dashboardFixture({bool team = false}) =>
    ManagementDashboard.fromJson(managementDashboardJson(team: team));
ManagementPage<DirectoryEmployee> employeePage({
  int id = 1,
  String? name,
  bool more = false,
}) => ManagementPage.fromJson(
  pageJson(
    [employeeJson(id, name)],
    count: more ? 2 : 1,
    next: more ? 'https://example.invalid/next' : null,
  ),
  DirectoryEmployee.fromJson,
);

Map<String, dynamic> assignableVersionJson(
  int id, {
  int trainingId = 1,
  String code = 'SAFE',
  String trainingTitle = 'Workplace safety',
  String? title,
  int versionNumber = 1,
  String? publishedAt = '2026-10-27T10:00:00Z',
}) => {
  'id': id,
  'training_id': trainingId,
  'training_code': code,
  'training_title': trainingTitle,
  'title': title ?? '$trainingTitle v$versionNumber',
  'version_number': versionNumber,
  'published_at': publishedAt,
};

Map<String, dynamic> createdAssignmentJson({
  int id = 1,
  int employeeId = 1,
  int trainingVersionId = 1,
  String? dueDate,
  String status = 'ASSIGNED',
  String source = 'MANUAL',
}) => {
  'id': id,
  'employee_id': employeeId,
  'training_version_id': trainingVersionId,
  'status': status,
  'source': source,
  'assigned_by_id': 1,
  'department_at_assignment_id': 1,
  'job_role_at_assignment_id': 1,
  'assigned_at': '2026-10-27T12:00:00Z',
  'due_at': dueDate != null ? '${dueDate}T23:59:59Z' : null,
};

ManagementPage<AssignableTrainingVersion> assignableVersionPage({
  int id = 1,
  String trainingTitle = 'Workplace safety',
  bool more = false,
}) => ManagementPage.fromJson(
  pageJson(
    [assignableVersionJson(id, trainingTitle: trainingTitle)],
    count: more ? 2 : 1,
    next: more ? 'https://example.invalid/next' : null,
  ),
  AssignableTrainingVersion.fromJson,
);

class Employee {
  final String username;
  final String employeeCode;
  final String displayName;
  final String department;
  final String jobRole;
  final bool isActive;

  Employee({
    required this.username,
    required this.employeeCode,
    required this.displayName,
    required this.department,
    required this.jobRole,
    required this.isActive,
  });

  factory Employee.fromJson(Map<String, dynamic> json) {
    return Employee(
      username: json['username'] as String? ?? '',
      employeeCode: json['employee_code'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      department: json['department'] as String? ?? '',
      jobRole: json['job_role'] as String? ?? '',
      isActive: json['is_active'] as bool? ?? false,
    );
  }
}


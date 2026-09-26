from datetime import timedelta

from django.conf import settings
from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import Client
from django.utils import timezone

from certifications.services import issue_completed_assignment_certificate
from config.model_test_utils import CurriculumTestCase
from organization.models import Department, Employee, JobRole
from training.models import Training, TrainingAssignment

from .queries import assignment_metrics, overdue_assignments


class ReportingTests(CurriculumTestCase):
	def client_for(self, user):
		client = Client()
		client.force_login(user)
		return client

	def group_user(self, username, group_name):
		user = get_user_model().objects.create_user(username=username)
		Group.objects.get(name=group_name).user_set.add(user)
		return user

	def make_employee(self, code, name, user=None, manager=None, department=None, job_role=None):
		return Employee.objects.create(
			employee_code=code,
			display_name=name,
			user=user,
			department=department or self.department,
			job_role=job_role or self.role,
			reporting_manager=manager,
			date_joined=timezone.localdate(),
		)

	def make_assignment(self, employee, status=TrainingAssignment.Status.ASSIGNED, due_at=None):
		assigned_at = timezone.now() - timedelta(days=2)
		values = {
			"employee": employee,
			"training_version": self.version,
			"status": status,
			"department_at_assignment": employee.department,
			"job_role_at_assignment": employee.job_role,
			"assigned_by": self.user,
			"assigned_at": assigned_at,
			"due_at": due_at,
		}
		if status == TrainingAssignment.Status.IN_PROGRESS:
			values["started_at"] = assigned_at
		if status == TrainingAssignment.Status.CANCELLED:
			values.update(cancelled_at=timezone.now(), cancellation_reason="Cancelled")
		return TrainingAssignment.objects.create(**values)

	def test_administrator_and_coordinator_see_company_metrics(self):
		self.finish_attempt(self.quiz, correct=False)
		self.assignment.due_at = self.now + timedelta(minutes=1)
		self.assignment.save()
		self.complete_assignment()
		certificate = issue_completed_assignment_certificate(self.assignment.pk)

		assigned_employee = self.make_employee("GN-101", "Assigned employee")
		self.make_assignment(assigned_employee, due_at=timezone.now() - timedelta(days=1))
		cancelled_employee = self.make_employee("GN-102", "Cancelled employee")
		self.make_assignment(
			cancelled_employee,
			status=TrainingAssignment.Status.CANCELLED,
			due_at=timezone.now() - timedelta(days=1),
		)

		for group_name in ("Administrator", "Training Coordinator"):
			with self.subTest(group=group_name):
				response = self.client_for(self.group_user(f"dashboard-{group_name}", group_name)).get("/")
				self.assertEqual(response.status_code, 200)
				self.assertEqual(response.context["role"], "company")
				self.assertEqual(response.context["active_employee_count"], 3)
				self.assertEqual(response.context["department_count"], 1)
				self.assertEqual(response.context["published_training_count"], 1)
				self.assertEqual(response.context["certificates_issued"], 1)
				metrics = response.context["metrics"]
				self.assertEqual((metrics["total"], metrics["assigned"], metrics["completed"], metrics["cancelled"]), (3, 1, 1, 1))
				self.assertEqual(metrics["eligible"], 2)
				self.assertEqual(metrics["overdue"], 1)
				self.assertEqual(metrics["completion_percent"], 50.0)
				self.assertTrue(response.context["recent_attempts"])

		coordinator = self.group_user("report-certificate-coordinator", "Training Coordinator")
		coordinator_client = self.client_for(coordinator)
		self.assertContains(coordinator_client.get("/reports/assignments/"), "Issued")
		self.assertEqual(coordinator_client.post(
			f"/certificates/{certificate.pk}/revoke/", {"reason": "Issued in error"},
		).status_code, 302)
		self.assertContains(coordinator_client.get("/reports/assignments/"), "Revoked")

	def test_manager_scope_is_recursive_and_filters_never_expand_it(self):
		manager_user = self.group_user("report-manager", "Manager")
		manager = self.make_employee("GN-201", "Manager", user=manager_user)
		child = self.make_employee("GN-202", "Direct report", manager=manager)
		grandchild = self.make_employee("GN-203", "Second-level report", manager=child)
		self.make_assignment(child, due_at=timezone.now() - timedelta(days=1))
		grandchild_assignment = self.make_assignment(
			grandchild,
			status=TrainingAssignment.Status.IN_PROGRESS,
			due_at=timezone.now() + timedelta(days=1),
		)
		outsider_department = Department.objects.create(code="OUT", name="Outside department")
		outsider_role = JobRole.objects.create(code="OUT", name="Outside role")
		outsider = self.make_employee(
			"GN-204", "Outside employee", department=outsider_department, job_role=outsider_role,
		)
		self.make_assignment(outsider, due_at=timezone.now() + timedelta(days=1))
		outsider_training = Training.objects.create(code="OUTSIDE", catalog_title="Outside training", created_by=self.user)
		outsider_version = self.new_version()

		current_assignment = self.assignment
		self.assignment = grandchild_assignment
		try:
			self.finish_attempt(self.quiz, correct=False)
			self.complete_assignment()
		finally:
			self.assignment = current_assignment
		self.finish_attempt(self.quiz, correct=False)

		client = self.client_for(manager_user)
		response = client.get("/")
		self.assertEqual(response.status_code, 200)
		self.assertEqual(response.context["role"], "manager")
		self.assertEqual(response.context["employees_in_scope"], 3)
		self.assertEqual(response.context["metrics"]["total"], 2)
		self.assertEqual(response.context["metrics"]["assigned"], 1)
		self.assertEqual(response.context["metrics"]["completed"], 1)
		self.assertEqual(response.context["metrics"]["overdue"], 1)
		self.assertEqual(response.context["metrics"]["completion_percent"], 50.0)
		self.assertEqual(
			{employee.display_name for employee in response.context["incomplete_employees"]},
			{child.display_name},
		)
		self.assertTrue(all(
			attempt.assignment_id != current_assignment.pk
			for attempt in response.context["recent_attempts"]
		))
		self.assertNotContains(response, outsider.display_name)

		report = client.get(f"/reports/assignments/?training={self.training.pk}")
		self.assertEqual(report.status_code, 200)
		self.assertContains(report, child.display_name)
		self.assertContains(report, grandchild.display_name)
		self.assertNotContains(report, outsider.display_name)
		self.assertEqual(len(report.context["assignments"]), 2)
		version_report = client.get(f"/reports/assignments/?training_version={self.version.pk}")
		self.assertEqual(version_report.status_code, 200)
		self.assertEqual(len(version_report.context["assignments"]), 2)
		overdue_report = client.get("/reports/assignments/?overdue_only=on")
		self.assertEqual(overdue_report.status_code, 200)
		self.assertEqual(len(overdue_report.context["assignments"]), 1)
		self.assertEqual(overdue_report.context["assignments"][0].employee_id, child.pk)
		for parameter, value in (
			("department", outsider_department.pk),
			("job_role", outsider_role.pk),
			("training", outsider_training.pk),
			("training_version", outsider_version.pk),
			("status", "NOT_A_STATUS"),
		):
			with self.subTest(parameter=parameter):
				filtered = client.get(f"/reports/assignments/?{parameter}={value}")
				self.assertEqual(filtered.status_code, 400)
				self.assertNotIn(outsider.display_name, filtered.content.decode())

	def test_employee_dashboard_and_assessment_results_are_self_only(self):
		Group.objects.get(name="Employee").user_set.add(self.employee_user)
		self.finish_attempt(self.quiz, correct=False)
		outsider_user = get_user_model().objects.create_user(username="other-report-user")
		outsider = self.make_employee("GN-301", "Other employee", user=outsider_user)
		outsider_assignment = self.make_assignment(outsider, status=TrainingAssignment.Status.IN_PROGRESS)
		current_assignment = self.assignment
		self.assignment = outsider_assignment
		try:
			self.finish_attempt(self.quiz, correct=False)
		finally:
			self.assignment = current_assignment
		self.complete_assignment()
		issue_completed_assignment_certificate(self.assignment.pk)

		client = self.client_for(self.employee_user)
		response = client.get("/")
		self.assertEqual(response.status_code, 200)
		self.assertEqual(response.context["role"], "employee")
		self.assertEqual(response.context["metrics"]["completed"], 1)
		self.assertEqual(response.context["certificates"].count(), 1)
		self.assertTrue(response.context["recent_attempts"])
		self.assertTrue(all(
			attempt.assignment_id == self.assignment.pk
			for attempt in response.context["recent_attempts"]
		))
		self.assertNotContains(response, outsider.display_name)
		self.assertEqual(client.get("/reports/assignments/").status_code, 403)

	def test_overdue_definition_excludes_completed_and_cancelled_and_zero_is_safe(self):
		self.assignment.due_at = self.now + timedelta(minutes=1)
		self.assignment.save()
		self.complete_assignment()
		assigned_employee = self.make_employee("GN-401", "Overdue employee")
		overdue_assignment = self.make_assignment(
			assigned_employee,
			due_at=timezone.now() - timedelta(days=1),
		)
		cancelled_employee = self.make_employee("GN-402", "Cancelled employee")
		cancelled_assignment = self.make_assignment(
			cancelled_employee,
			status=TrainingAssignment.Status.CANCELLED,
			due_at=timezone.now() - timedelta(days=1),
		)
		queryset = TrainingAssignment.objects.filter(
			pk__in=(self.assignment.pk, overdue_assignment.pk, cancelled_assignment.pk),
		)
		self.assertEqual(list(overdue_assignments(queryset).values_list("pk", flat=True)), [overdue_assignment.pk])
		metrics = assignment_metrics(queryset)
		self.assertEqual(metrics["overdue"], 1)
		self.assertEqual(metrics["eligible"], 2)
		self.assertEqual(metrics["completion_percent"], 50.0)
		zero_metrics = assignment_metrics(TrainingAssignment.objects.none())
		self.assertEqual(zero_metrics["eligible"], 0)
		self.assertEqual(zero_metrics["completion_percent"], 0)

	def test_root_redirects_anonymous_users_and_unlinked_roles_get_safe_landing(self):
		self.assertEqual(self.client_for(self.user).get("/").status_code, 200)
		self.assertEqual(settings.LOGIN_REDIRECT_URL, "/")
		anonymous = Client().get("/")
		self.assertEqual(anonymous.status_code, 302)
		self.assertIn("/accounts/login/", anonymous.url)

		unlinked_employee = self.group_user("unlinked-employee", "Employee")
		response = self.client_for(unlinked_employee).get("/")
		self.assertEqual(response.status_code, 200)
		self.assertEqual(response.context["role"], "unavailable")
		self.assertEqual(self.client_for(unlinked_employee).get("/reports/assignments/").status_code, 403)
		for group_name in ("Trainer", "Supervisor"):
			other_role_user = self.group_user(f"unsupported-{group_name}", group_name)
			other_role_response = self.client_for(other_role_user).get("/")
			self.assertEqual(other_role_response.context["role"], "unavailable")

		inactive_user = self.group_user("inactive-employee", "Employee")
		inactive_employee = self.make_employee("GN-501", "Inactive employee", user=inactive_user)
		inactive_employee.is_active = False
		inactive_employee.deactivation_reason = "Left"
		inactive_employee.save()
		inactive_response = self.client_for(inactive_user).get("/")
		self.assertEqual(inactive_response.status_code, 302)

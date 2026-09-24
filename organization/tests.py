from django.contrib.auth import get_user_model
from django.core.exceptions import ValidationError
from django.db.models.deletion import ProtectedError

from config.model_test_utils import CurriculumTestCase
from .models import Employee, JobRole


class EmployeeTests(CurriculumTestCase):
    def test_builtin_user_model_retained(self):
        self.assertEqual(get_user_model()._meta.label, "auth.User")

    def test_deactivation_disables_login_and_preserves_assignment(self):
        self.employee.is_active = False
        self.employee.deactivation_reason = "Employment ended"
        self.employee.save()
        self.employee_user.refresh_from_db()
        self.assertFalse(self.employee_user.is_active)
        self.assertIsNotNone(self.employee.deactivated_at)
        self.assertEqual(self.employee.training_assignments.count(), 1)

    def test_deactivation_requires_reason(self):
        self.employee.is_active = False
        with self.assertRaises(ValidationError):
            self.employee.save()
        self.employee_user.refresh_from_db()
        self.assertTrue(self.employee_user.is_active)

    def test_employee_and_user_deletion_protected(self):
        with self.assertRaises(ValidationError):
            self.employee.delete()
        with self.assertRaises(ValidationError):
            Employee.objects.filter(pk=self.employee.pk).delete()
        with self.assertRaises(ProtectedError):
            self.employee_user.delete()

    def test_self_reporting_and_longer_cycles_rejected(self):
        manager = Employee.objects.create(employee_code="GN-002", display_name="Manager", department=self.department,
                                         job_role=self.role, date_joined=self.now.date())
        self.employee.reporting_manager = self.employee
        with self.assertRaises(ValidationError):
            self.employee.save()
        self.employee.reporting_manager = manager
        self.employee.save()
        manager.reporting_manager = self.employee
        with self.assertRaises(ValidationError):
            manager.save()

    def test_assignment_role_snapshot_survives_transfer(self):
        self.employee.job_role = JobRole.objects.create(code="QC", name="Quality inspector")
        self.employee.save()
        self.assignment.refresh_from_db()
        self.assertEqual(self.assignment.job_role_at_assignment, self.role)

    def test_employee_code_cannot_be_reused_by_renaming(self):
        self.employee.employee_code = "CHANGED"
        with self.assertRaises(ValidationError):
            self.employee.save()

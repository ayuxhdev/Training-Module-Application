"""CSV contract regressions. Database tests require approved disposable MySQL.

Authored for the final validation phase; never run the DatabaseTests against
shared development, preserved-test or isolated physical-QA databases.
"""

import csv
import io
from datetime import datetime, timedelta, timezone as datetime_timezone
from types import SimpleNamespace
from unittest.mock import Mock, patch
from urllib.parse import urlencode

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.test import SimpleTestCase
from django.urls import resolve, reverse
from django.utils import timezone
from rest_framework.test import APIClient, APIRequestFactory, force_authenticate
from rest_framework_simplejwt.tokens import RefreshToken

from audit.models import AuditLog
from certifications.models import Certificate
from certifications.services import issue_completed_assignment_certificate
from config.model_test_utils import CurriculumTestCase
from organization.models import Department, Employee
from reports.views import ASSIGNMENT_REPORT_CSV_HEADERS
from training.models import LessonProgress, TrainingAssignment, VideoWatchSession

from . import assignment_report_views as views
from .assignment_report_csv import (
    ASSIGNMENT_REPORT_EXPORT_MAX_ROWS,
    AssignmentReportExportTooLarge,
    assignment_report_csv_response,
)
from .assignment_report_queries import assignment_report_queryset


EXPORT_URL = "/api/v1/management/reports/assignments/export/"
LIST_URL = "/api/v1/management/reports/assignments/"


def csv_rows(response):
    content = b"".join(response.streaming_content).decode("utf-8")
    return list(csv.reader(io.StringIO(content)))


def assignment_row(**overrides):
    values = dict(
        employee=SimpleNamespace(display_name="Learner"),
        department_at_assignment=SimpleNamespace(name="Historical department"),
        job_role_at_assignment=SimpleNamespace(name="Historical role"),
        training_version=SimpleNamespace(
            title="Pinned title", version_number=2,
            training=SimpleNamespace(catalog_title="Safety"),
        ),
        assigned_at=datetime(2026, 11, 16, tzinfo=datetime_timezone.utc),
        due_at=None, completed_at=None, is_overdue=False,
        get_status_display=lambda: "Assigned", certificate=None,
    )
    values.update(overrides)
    return SimpleNamespace(**values)


def fake_queryset(count=1, rows=None):
    queryset = Mock()
    queryset.values_list.return_value = range(count)
    queryset.filter.return_value.iterator.return_value = iter(
        [assignment_row()] if rows is None else rows
    )
    return queryset


class AssignmentReportExportBoundaryTests(SimpleTestCase):
    databases = set()

    def user(self, *, active=True, employee_active=True, report_access=True):
        user = Mock(is_authenticated=True, is_active=active, is_superuser=False)
        user.employee = SimpleNamespace(is_active=employee_active)
        user.has_perm.side_effect = lambda name: (
            report_access and name == "training.add_trainingassignment"
        )
        user.groups.filter.return_value.exists.return_value = False
        return user

    def request(self, query="", *, user=None, method="get"):
        request = getattr(APIRequestFactory(), method)(EXPORT_URL + query)
        if user is not None:
            force_authenticate(request, user=user)
        return views.AssignmentReportExportView.as_view()(request)

    def test_export_route_and_existing_report_routes_are_distinct(self):
        self.assertEqual(reverse("api:v1:management-assignment-report-export"), EXPORT_URL)
        self.assertIs(resolve(EXPORT_URL).func.view_class, views.AssignmentReportExportView)
        self.assertIs(resolve(LIST_URL).func.view_class, views.AssignmentReportView)
        self.assertIs(
            resolve(LIST_URL + "filters/").func.view_class,
            views.AssignmentReportFiltersView,
        )

    def test_authentication_and_active_account_gates_precede_query_access(self):
        with patch.object(views, "assignment_report_queryset") as query:
            cases = (
                (None, 401),
                (self.user(active=False), 403),
                (self.user(employee_active=False), 403),
                (self.user(report_access=False), 403),
            )
            for user, status in cases:
                with self.subTest(status=status, user=user):
                    response = self.request(user=user)
                    self.assertEqual(response.status_code, status)
                    self.assertEqual(response["Cache-Control"], "private, no-store")
                    self.assertNotIn("Content-Disposition", response)
            query.assert_not_called()

    def test_mutation_methods_are_not_allowed(self):
        with patch.object(views, "assignment_report_queryset") as query:
            for method in ("post", "put", "patch", "delete"):
                self.assertEqual(
                    self.request(user=self.user(), method=method).status_code, 405,
                )
            query.assert_not_called()

    def test_malformed_known_filters_fail_before_queryset_access(self):
        with patch.object(views, "assignment_report_queryset") as query:
            for parameters in (
                {"status": "OVERDUE"}, {"department": "x"}, {"job_role": 0},
                {"training": -1}, {"training_version": "bad"},
                {"overdue_only": "maybe"},
            ):
                with self.subTest(parameters=parameters):
                    response = self.request("?" + urlencode(parameters), user=self.user())
                    self.assertEqual(response.status_code, 400)
                    self.assertEqual(response.data["error"]["code"], "validation_error")
                    self.assertNotIn("Content-Disposition", response)
            query.assert_not_called()

    def test_omitted_and_explicit_boolean_filters_match_existing_api(self):
        for query, expected in (("", {}), ("?overdue_only=false", {"overdue_only": False}),
                                ("?overdue_only=true", {"overdue_only": True})):
            with self.subTest(query=query):
                user = self.user()
                with patch.object(views, "assignment_report_queryset", return_value=fake_queryset()) as scoped:
                    response = self.request(query, user=user)
                    self.assertEqual(response.status_code, 200)
                    scoped.assert_called_once_with(user, expected)
                    response.close()

    def test_success_headers_and_nullable_csv_values(self):
        response = assignment_report_csv_response(fake_queryset())
        self.assertEqual(response["Content-Type"], "text/csv; charset=utf-8")
        self.assertRegex(
            response["Content-Disposition"],
            r'^attachment; filename="assignment-report-\d{4}-\d{2}-\d{2}\.csv"$',
        )
        self.assertEqual(response["Cache-Control"], "private, no-store")
        self.assertEqual(response["X-Content-Type-Options"], "nosniff")
        rows = csv_rows(response)
        self.assertEqual(rows[0], list(ASSIGNMENT_REPORT_CSV_HEADERS))
        self.assertEqual(rows[1][0:4], ["Learner", "Historical department", "Historical role", "Safety"])
        self.assertIn("Pinned title", rows[1][4])
        self.assertIn("Version 2", rows[1][4])
        self.assertEqual(rows[1][5:], ["2026-11-16T00:00:00+00:00", "", "Assigned", "No", "", "Not issued"])
        self.assertEqual(len(rows[1]), 11)

    def test_formula_injection_unicode_and_csv_escaping_use_website_writer(self):
        for value in ("=1+1", "+1", "-1", "@SUM(1,1)", " \t=1", "\x00@SUM(1,1)", "\u200b+1"):
            with self.subTest(value=value):
                row = assignment_row(
                    employee=SimpleNamespace(display_name=value),
                    department_at_assignment=SimpleNamespace(name='North, "Wing"\n\u90e8\u9580'),
                    job_role_at_assignment=SimpleNamespace(name="Op\u00e9rateur"),
                )
                result = csv_rows(assignment_report_csv_response(fake_queryset(rows=[row])))
                self.assertEqual(result[1][0], "'" + value)
                self.assertEqual(result[1][1], 'North, "Wing"\n\u90e8\u9580')
                self.assertEqual(result[1][2], "Op\u00e9rateur")

    def test_empty_result_is_header_only(self):
        self.assertEqual(
            csv_rows(assignment_report_csv_response(fake_queryset(0, []))),
            [list(ASSIGNMENT_REPORT_CSV_HEADERS)],
        )

    def test_certificate_column_is_status_only(self):
        for certificate, expected in (
            (None, "Not issued"),
            (SimpleNamespace(revoked_at=None), "Issued"),
            (SimpleNamespace(revoked_at=datetime.now(datetime_timezone.utc)), "Revoked"),
        ):
            rows = csv_rows(assignment_report_csv_response(fake_queryset(
                rows=[assignment_row(certificate=certificate)],
            )))
            self.assertEqual(rows[1][-1], expected)
            self.assertEqual(len(rows[1]), 11)

    def test_exact_limit_is_allowed_and_id_probe_is_bounded(self):
        self.assertEqual(ASSIGNMENT_REPORT_EXPORT_MAX_ROWS, 10000)
        queryset = fake_queryset(10000)
        response = assignment_report_csv_response(queryset)
        self.assertEqual(response.status_code, 200)
        queryset.values_list.assert_called_once_with("pk", flat=True)
        queryset.filter.assert_called_once_with(pk__in=list(range(10000)))
        response.close()

    def test_oversize_raises_before_writer_or_row_query(self):
        queryset = fake_queryset(10001)
        with patch("api.v1.assignment_report_csv._assignment_report_csv_stream") as writer:
            with self.assertRaises(AssignmentReportExportTooLarge):
                assignment_report_csv_response(queryset)
            writer.assert_not_called()
        queryset.filter.assert_not_called()

    def test_http_413_is_json_error_without_csv_or_partial_output(self):
        with patch.object(views, "assignment_report_queryset", return_value=fake_queryset(10001)):
            response = self.request(user=self.user())
        self.assertEqual(response.status_code, 413)
        self.assertEqual(response.data["error"]["code"], "export_too_large")
        self.assertIn("Narrow", response.data["error"]["message"])
        self.assertFalse(getattr(response, "streaming", False))
        self.assertNotIn("Content-Disposition", response)
        self.assertEqual(response["Cache-Control"], "private, no-store")


class AssignmentReportExportDatabaseTests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        cls.user.groups.add(Group.objects.get(name="Training Coordinator"))
        cls.admin = get_user_model().objects.create_user(username="csv-api-admin")
        cls.admin.groups.add(Group.objects.get(name="Administrator"))
        cls.manager = get_user_model().objects.create_user(username="csv-api-manager")
        cls.manager.groups.add(Group.objects.get(name="Manager"))
        cls.manager_employee = cls.learner("MGR", user=cls.manager)
        cls.child = cls.learner("CHILD", reporting_manager=cls.manager_employee)
        cls.descendant = cls.learner("NESTED", reporting_manager=cls.child)
        cls.other_department = Department.objects.create(code="CSV-OTHER", name="Other department")
        cls.outsider = cls.learner("OUTSIDE", department=cls.other_department)
        cls.child_assignment = cls.assign(cls.child)
        cls.descendant_assignment = cls.assign(
            cls.descendant,
            assigned_at=cls.now - timedelta(days=2),
            due_at=cls.now - timedelta(days=1),
        )
        cls.outside_assignment = cls.assign(cls.outsider)

    @classmethod
    def learner(cls, suffix, **overrides):
        values = dict(
            employee_code=f"CSV-{suffix}", display_name=f"CSV Learner {suffix}",
            department=cls.department, job_role=cls.role, date_joined=cls.now.date(),
        )
        values.update(overrides)
        return Employee.objects.create(**values)

    @classmethod
    def assign(cls, employee, **overrides):
        values = dict(
            employee=employee, training_version=cls.version,
            status=TrainingAssignment.Status.ASSIGNED, assigned_at=cls.now,
            assigned_by=cls.user, department_at_assignment=employee.department,
            job_role_at_assignment=employee.job_role,
        )
        values.update(overrides)
        return TrainingAssignment.objects.create(**values)

    def get(self, user, query=""):
        token = str(RefreshToken.for_user(user).access_token)
        return APIClient(HTTP_AUTHORIZATION=f"Bearer {token}").get(EXPORT_URL + query)

    def test_admin_and_coordinator_export_all_scoped_rows(self):
        for user in (self.admin, self.user):
            with self.subTest(user=user.username):
                response = self.get(user)
                self.assertEqual(response.status_code, 200)
                names = {row[0] for row in csv_rows(response)[1:]}
                self.assertEqual(names, {
                    self.employee.display_name, self.child.display_name,
                    self.descendant.display_name, self.outsider.display_name,
                })

    def test_manager_hierarchy_and_forged_scope_parameters(self):
        for query in ("", f"?employee={self.outsider.pk}&manager={self.admin.pk}"):
            with self.subTest(query=query):
                response = self.get(self.manager, query)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(
                    {row[0] for row in csv_rows(response)[1:]},
                    {self.child.display_name, self.descendant.display_name},
                )
        empty = self.get(self.manager, f"?department={self.other_department.pk}")
        self.assertEqual(empty.status_code, 200)
        self.assertEqual(csv_rows(empty), [list(ASSIGNMENT_REPORT_CSV_HEADERS)])

    def test_combined_filters_match_paginated_report_semantics(self):
        query = "?" + urlencode({
            "status": "ASSIGNED", "department": self.department.pk,
            "job_role": self.role.pk, "training": self.training.pk,
            "training_version": self.version.pk, "overdue_only": "true",
        })
        rows = csv_rows(self.get(self.manager, query))
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[1][0], self.descendant.display_name)
        self.assertEqual(rows[1][8], "Yes")
        client = APIClient()
        client.force_authenticate(self.manager)
        listed = client.get(LIST_URL + query)
        self.assertEqual(listed.status_code, 200)
        self.assertEqual(listed.json()["count"], 1)
        self.assertEqual(listed.json()["results"][0]["id"], self.descendant_assignment.pk)

    def test_nonexistent_filters_return_no_rows_and_invalid_filters_return_400(self):
        for field in ("department", "job_role", "training", "training_version"):
            with self.subTest(field=field):
                response = self.get(self.manager, f"?{field}=2147483647")
                self.assertEqual(response.status_code, 200)
                self.assertEqual(csv_rows(response), [list(ASSIGNMENT_REPORT_CSV_HEADERS)])
        response = self.get(self.user, "?status=INVALID")
        self.assertEqual(response.status_code, 400)
        self.assertEqual(response.json()["error"]["code"], "validation_error")

    def test_export_ignores_page_parameters_and_keeps_stable_order(self):
        for number in range(21):
            self.assign(self.learner(f"PAGE-{number:03}"))
        response = self.get(self.user, "?status=ASSIGNED&page=2&page_size=1")
        rows = csv_rows(response)
        expected = list(assignment_report_queryset(self.user, {"status": "ASSIGNED"})
                        .values_list("employee__display_name", flat=True))
        self.assertEqual([row[0] for row in rows[1:]], expected)
        self.assertGreater(len(expected), 20)
        client = APIClient()
        client.force_authenticate(self.user)
        listed = client.get(LIST_URL + "?status=ASSIGNED&page_size=1")
        self.assertEqual(set(listed.json()), {"count", "next", "previous", "results"})
        self.assertEqual(len(listed.json()["results"]), 1)
        self.assertEqual(listed.json()["count"], len(expected))

    def test_employee_anonymous_and_inactive_accounts_are_denied(self):
        self.assertEqual(APIClient().get(EXPORT_URL).status_code, 401)
        self.assertEqual(self.get(self.employee_user).status_code, 403)
        self.manager.is_active = False
        self.manager.save(update_fields=["is_active"])
        self.assertEqual(self.get(self.manager).status_code, 401)

    def test_inactive_linked_employee_is_denied_with_active_user(self):
        self.manager_employee.is_active = False
        self.manager_employee.deactivated_at = timezone.now()
        self.manager_employee.deactivation_reason = "Disposable export fixture"
        self.manager_employee.save()
        # Employee deactivation also disables its User. Reactivate only the
        # User so this independently exercises the linked-Employee gate.
        self.manager.is_active = True
        self.manager.save(update_fields=["is_active"])
        self.manager.refresh_from_db()
        self.assertTrue(self.manager.is_active)
        self.assertEqual(self.get(self.manager).status_code, 403)

    def test_database_limit_boundary_rejects_whole_export_before_streaming(self):
        # Scale down only the limit, retaining real SQL selection and API errors.
        with patch("api.v1.assignment_report_csv.ASSIGNMENT_REPORT_EXPORT_MAX_ROWS", 3):
            allowed = self.get(self.user, "?status=ASSIGNED")
            self.assertEqual(allowed.status_code, 200)
            self.assertEqual(len(csv_rows(allowed)), 4)
            rejected = self.get(self.user)
            self.assertEqual(rejected.status_code, 413)
            self.assertEqual(rejected.json()["error"]["code"], "export_too_large")
            self.assertFalse(getattr(rejected, "streaming", False))
            self.assertNotIn("Content-Disposition", rejected)

    def test_joined_stream_has_no_per_assignment_queries(self):
        queryset = assignment_report_queryset(self.user, {})
        with self.assertNumQueries(2):
            rows = csv_rows(assignment_report_csv_response(queryset))
        self.assertEqual(len(rows), 5)

    def test_read_only_export_preserves_assignment_progress_certificate_and_audit(self):
        self.complete_assignment()
        certificate = issue_completed_assignment_certificate(self.assignment.pk, actor=self.user)
        self.assertIsNotNone(certificate)
        models = (TrainingAssignment, LessonProgress, VideoWatchSession, Certificate, AuditLog)
        before = {model: list(model.objects.order_by("pk").values()) for model in models}
        response = self.get(self.user, "?status=COMPLETED")
        rows = csv_rows(response)
        self.assertEqual(rows[1][-1], "Issued")
        self.assertNotIn(certificate.certificate_number, str(rows))
        for model in models:
            self.assertEqual(list(model.objects.order_by("pk").values()), before[model])

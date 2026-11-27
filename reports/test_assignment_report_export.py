import csv
import io
from datetime import datetime, timezone as datetime_timezone
from types import SimpleNamespace
from unittest.mock import MagicMock, Mock, patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.http import HttpResponse
from django.test import RequestFactory, SimpleTestCase
from django.urls import reverse
from django.utils import timezone

from config.model_test_utils import CurriculumTestCase
from organization.models import Department, Employee, JobRole
from training.models import TrainingAssignment

from .views import (
    ASSIGNMENT_REPORT_CSV_HEADERS,
    ASSIGNMENT_REPORT_EXPORT_CHUNK_SIZE,
    ASSIGNMENT_REPORT_EXPORT_MAX_ROWS,
    _assignment_report_csv_stream,
    _bounded_assignment_export,
    _safe_csv_cell,
    assignment_report_export,
)


class CsvSafetyTests(SimpleTestCase):
    def assignment(self, display_name="Employee"):
        return SimpleNamespace(
            employee=SimpleNamespace(display_name=display_name),
            department_at_assignment=SimpleNamespace(name="Operations, North\nWing"),
            job_role_at_assignment=SimpleNamespace(name='Role "A"'),
            training_version=SimpleNamespace(
                training=SimpleNamespace(catalog_title="+Unsafe training"),
                title="Safety",
                version_number=2,
            ),
            assigned_at=datetime(2026, 1, 2, tzinfo=datetime_timezone.utc),
            due_at=None,
            status="ASSIGNED",
            get_status_display=lambda: "Assigned",
            is_overdue=False,
            completed_at=None,
            certificate=None,
        )

    def test_formula_prefixes_and_leading_controls_are_defanged(self):
        malicious_values = (
            "=1+1",
            "+SUM(1,1)",
            "-1+2",
            "@SUM(1,1)",
            " \t=1+1",
            "\u00a0+1",
            "\x00@SUM(1,1)",
        )
        for value in malicious_values:
            with self.subTest(value=value):
                self.assertEqual(_safe_csv_cell(value), "'" + value)

        self.assertEqual(_safe_csv_cell("Ordinary value"), "Ordinary value")
        self.assertEqual(_safe_csv_cell(None), "")

    def test_csv_escaping_preserves_commas_quotes_and_newlines(self):
        assignment = self.assignment(display_name="\t=1+1")

        class SingleAssignment:
            def iterator(self, chunk_size):
                return iter((assignment,))

        content = "".join(_assignment_report_csv_stream(SingleAssignment()))
        rows = list(csv.reader(io.StringIO(content)))

        self.assertEqual(rows[0], list(ASSIGNMENT_REPORT_CSV_HEADERS))
        self.assertEqual(rows[1][0], "'\t=1+1")
        self.assertEqual(rows[1][1], "Operations, North\nWing")
        self.assertEqual(rows[1][2], 'Role "A"')
        self.assertEqual(rows[1][3], "'+Unsafe training")
        self.assertEqual(rows[1][5], "2026-01-02T00:00:00+00:00")
        self.assertEqual(rows[1][6], "")
        self.assertEqual(rows[1][10], "Not issued")

    def test_streaming_export_iterates_in_chunks_for_large_results(self):
        class LazyAssignments:
            def __init__(self, factory):
                self.factory = factory
                self.chunk_size = None

            def iterator(self, chunk_size):
                self.chunk_size = chunk_size
                return (
                    self.factory(number)
                    for number in range(2500)
                )

        assignments = LazyAssignments(lambda number: self.assignment(f"Employee {number}"))
        chunks = _assignment_report_csv_stream(assignments)
        self.assertTrue(next(chunks).startswith("Employee,Department,"))
        row_count = 1 + sum(1 for _ in chunks)

        self.assertEqual(assignments.chunk_size, ASSIGNMENT_REPORT_EXPORT_CHUNK_SIZE)
        self.assertEqual(row_count, 2501)

    def test_export_row_limit_rejects_oversized_results_without_partial_slice(self):
        for count in (0, ASSIGNMENT_REPORT_EXPORT_MAX_ROWS,
                      ASSIGNMENT_REPORT_EXPORT_MAX_ROWS + 1):
            with self.subTest(count=count):
                assignments = Mock()
                probe = MagicMock()
                probe.__getitem__.return_value = range(count)
                assignments.values_list.return_value = probe
                selected = _bounded_assignment_export(assignments)
                assignments.values_list.assert_called_once_with("pk", flat=True)
                probe.__getitem__.assert_called_once_with(
                    slice(None, ASSIGNMENT_REPORT_EXPORT_MAX_ROWS + 1),
                )
                assignments.count.assert_not_called()
                if count > ASSIGNMENT_REPORT_EXPORT_MAX_ROWS:
                    self.assertIsNone(selected)
                    assignments.filter.assert_not_called()
                else:
                    self.assertIs(selected, assignments.filter.return_value)
                    assignments.filter.assert_called_once_with(pk__in=list(range(count)))

    def test_exact_10000_rows_stream_successfully(self):
        assignments = Mock()
        assignments.values_list.return_value = list(range(1, 10001))
        selected = assignments.filter.return_value
        selected.iterator.side_effect = lambda **kwargs: (
            self.assignment(f"Employee {number}") for number in range(1, 10001)
        )
        request = RequestFactory().get("/reports/assignments/export/")
        request.user = SimpleNamespace(is_authenticated=True)
        with patch(
            "reports.views._filtered_assignment_report",
            return_value=("company", object(), assignments, True),
        ):
            response = assignment_report_export(request)
        self.assertEqual(response.status_code, 200)
        exported = csv.reader(io.StringIO(
            b"".join(response.streaming_content).decode("utf-8"),
        ))
        self.assertEqual(next(exported), list(ASSIGNMENT_REPORT_CSV_HEADERS))
        self.assertEqual(sum(1 for _ in exported), 10000)
        assignments.filter.assert_called_once_with(pk__in=list(range(1, 10001)))
        selected.iterator.assert_called_once_with(
            chunk_size=ASSIGNMENT_REPORT_EXPORT_CHUNK_SIZE,
        )

    def test_10001_rows_return_413_before_csv_response_or_iteration(self):
        assignments = Mock()
        assignments.values_list.return_value = list(range(1, 10002))
        request = RequestFactory().get("/reports/assignments/export/")
        request.user = SimpleNamespace(is_authenticated=True)
        with (
            patch(
                "reports.views._filtered_assignment_report",
                return_value=("company", object(), assignments, True),
            ),
            patch("reports.views._assignment_report_context", return_value={}),
            patch("reports.views.render", return_value=HttpResponse(status=413)),
            patch("reports.views.StreamingHttpResponse") as streaming,
        ):
            response = assignment_report_export(request)
        self.assertEqual(response.status_code, 413)
        self.assertNotIn("Content-Disposition", response)
        assignments.filter.assert_not_called()
        assignments.iterator.assert_not_called()
        streaming.assert_not_called()

    def test_mysql_compiles_10000_ids_with_scope_without_a_connection(self):
        from django.db.backends.mysql.base import DatabaseWrapper

        mysql = DatabaseWrapper(
            {"ENGINE": "django.db.backends.mysql", "NAME": "compiler_only"},
            alias="compiler_only",
        )
        assignments = TrainingAssignment.objects.filter(
            employee_id=123, status=TrainingAssignment.Status.ASSIGNED,
        ).select_related(
            "employee", "training_version__training", "department_at_assignment",
            "job_role_at_assignment", "certificate",
        ).order_by("-assigned_at", "pk").filter(pk__in=range(1, 10001))
        with patch.object(
            mysql, "connect", side_effect=AssertionError("No database access"),
        ) as connect:
            sql, parameters = assignments.query.get_compiler(connection=mysql).as_sql()
        connect.assert_not_called()
        self.assertEqual(len(parameters), 10002)
        self.assertEqual(parameters[:2], (123, TrainingAssignment.Status.ASSIGNED))
        self.assertEqual(parameters[2:], tuple(range(1, 10001)))
        self.assertIn("`training_trainingassignment`.`employee_id` = %s", sql)
        self.assertIn("`training_trainingassignment`.`id` IN (", sql)
        self.assertIsNone(mysql.features.max_query_params)
        self.assertIsNone(mysql.ops.max_in_list_size())

    def test_deleted_selected_row_is_not_replaced_by_a_new_matching_row(self):
        rows = {1: self.assignment("Deleted"), 2: self.assignment("Retained")}
        assignments = Mock()
        assignments.values_list.return_value = [1, 2]
        selected = assignments.filter.return_value
        selected.iterator.side_effect = lambda **kwargs: (
            rows[pk] for pk in (1, 2) if pk in rows
        )
        request = RequestFactory().get("/reports/assignments/export/")
        request.user = SimpleNamespace(is_authenticated=True)
        with patch(
            "reports.views._filtered_assignment_report",
            return_value=("manager", object(), assignments, True),
        ):
            response = assignment_report_export(request)
        del rows[1]
        rows[3] = self.assignment("Later insertion")
        exported = list(csv.reader(io.StringIO(
            b"".join(response.streaming_content).decode("utf-8"),
        )))
        self.assertEqual([row[0] for row in exported[1:]], ["Retained"])
        assignments.filter.assert_called_once_with(pk__in=[1, 2])

    def test_deferred_stream_keeps_authorized_selection_despite_new_rows(self):
        rows = {1: self.assignment("Selected"), 99: self.assignment("Foreign")}
        authorized_ids = {1}
        events = []

        class ScopedAssignments:
            def __init__(self, selected=None, row_slice=None):
                self.selected = selected
                self.row_slice = row_slice

            def matching_ids(self):
                ids = sorted(authorized_ids & rows.keys(), reverse=True)
                if self.selected is not None:
                    ids = [pk for pk in ids if pk in self.selected]
                return ids[self.row_slice] if self.row_slice is not None else ids

            def count(self):
                return len(self.matching_ids())

            def __getitem__(self, row_slice):
                return ScopedAssignments(self.selected, row_slice)

            def values_list(self, field, *, flat):
                events.append(("ids", field, flat))
                return self.matching_ids()

            def filter(self, *, pk__in):
                events.append(("filter", tuple(pk__in)))
                return ScopedAssignments(set(pk__in))

            def iterator(self, chunk_size):
                events.append(("iterator", chunk_size))
                return (rows[pk] for pk in self.matching_ids())

        request = RequestFactory().get("/reports/assignments/export/")
        request.user = SimpleNamespace(is_authenticated=True)
        with (
            patch("reports.views.ASSIGNMENT_REPORT_EXPORT_MAX_ROWS", 2),
            patch(
                "reports.views._filtered_assignment_report",
                return_value=("manager", object(), ScopedAssignments(), True),
            ),
        ):
            response = assignment_report_export(request)
            self.assertEqual(response.status_code, 200)
            self.assertTrue(response.streaming)
            self.assertFalse(any(event[0] == "iterator" for event in events))
            # These arrive after response construction, before deferred iteration.
            rows.update({2: self.assignment("New 2"), 3: self.assignment("New 3")})
            authorized_ids.update({2, 3})
            exported = list(csv.reader(io.StringIO(
                b"".join(response.streaming_content).decode("utf-8"),
            )))
        self.assertEqual(len(exported), 2)
        self.assertEqual(exported[1][0], "Selected")
        self.assertNotIn("Foreign", {row[0] for row in exported[1:]})
        self.assertEqual(events, [
            ("ids", "pk", True), ("filter", (1,)),
            ("iterator", ASSIGNMENT_REPORT_EXPORT_CHUNK_SIZE),
        ])

    def test_oversized_export_returns_error_without_a_partial_file(self):
        request = RequestFactory().get("/reports/assignments/export/")
        request.user = SimpleNamespace(is_authenticated=True)
        context = {"export_limit_exceeded": True}
        with (
            patch(
                "reports.views._filtered_assignment_report",
                return_value=("company", object(), object(), True),
            ),
            patch("reports.views._bounded_assignment_export", return_value=None),
            patch("reports.views._assignment_report_context", return_value=context),
            patch("reports.views.render", return_value=HttpResponse(status=413)) as render,
        ):
            response = assignment_report_export(request)

        self.assertEqual(response.status_code, 413)
        self.assertEqual(render.call_args.kwargs["status"], 413)
        self.assertTrue(context["export_limit_exceeded"])


class AssignmentReportExportTests(CurriculumTestCase):
    def setUp(self):
        self.coordinator = get_user_model().objects.create_user(
            username="assignment-export-coordinator",
            password="test-password",
        )
        Group.objects.get(name="Training Coordinator").user_set.add(self.coordinator)
        self.client.force_login(self.coordinator)
        self.export_url = reverse("reports:assignment-report-export")

    def create_assignment(self, employee, *, status=TrainingAssignment.Status.ASSIGNED):
        assigned_at = timezone.now()
        return TrainingAssignment.objects.create(
            employee=employee,
            training_version=self.version,
            status=status,
            department_at_assignment=employee.department,
            job_role_at_assignment=employee.job_role,
            assigned_by=self.user,
            assigned_at=assigned_at,
            started_at=assigned_at if status == TrainingAssignment.Status.IN_PROGRESS else None,
        )

    def csv_rows(self, response):
        content = b"".join(response.streaming_content).decode("utf-8")
        return list(csv.reader(io.StringIO(content)))

    def test_authorized_export_has_safe_filename_headers_and_report_values(self):
        response = self.client.get(self.export_url)

        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.streaming)
        self.assertEqual(response["Content-Type"], "text/csv; charset=utf-8")
        self.assertEqual(response["Cache-Control"], "private, no-store")
        self.assertEqual(response["X-Content-Type-Options"], "nosniff")
        self.assertRegex(
            response["Content-Disposition"],
            r'^attachment; filename="assignment-report-\d{4}-\d{2}-\d{2}\.csv"$',
        )
        rows = self.csv_rows(response)
        self.assertEqual(rows[0], list(ASSIGNMENT_REPORT_CSV_HEADERS))
        self.assertEqual(len(rows), 2)
        self.assertEqual(
            rows[1],
            [
                self.employee.display_name,
                self.department.name,
                self.role.name,
                self.training.catalog_title,
                f"{self.version.title} · Version {self.version.version_number}",
                self.assignment.assigned_at.isoformat(),
                "",
                self.assignment.get_status_display(),
                "No",
                "",
                "Not issued",
            ],
        )

    def test_active_filters_are_shared_with_report_and_export_empty_results_work(self):
        assigned_employee = Employee.objects.create(
            employee_code="EXPORT-001",
            display_name="Export target",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
        )
        self.create_assignment(assigned_employee)
        query = f"?status={TrainingAssignment.Status.ASSIGNED}"

        report = self.client.get(reverse("reports:assignment-report") + query)
        self.assertEqual(report.status_code, 200)
        self.assertEqual(report.context["paginator"].count, 1)
        self.assertContains(
            report,
            f'href="{self.export_url}?status={TrainingAssignment.Status.ASSIGNED}"',
        )
        exported = self.csv_rows(self.client.get(self.export_url + query))
        self.assertEqual(len(exported), 2)
        self.assertEqual(exported[1][0], assigned_employee.display_name)
        self.assertNotEqual(exported[1][0], self.employee.display_name)

        empty = self.client.get(
            self.export_url + f"?status={TrainingAssignment.Status.COMPLETED}",
        )
        self.assertEqual(empty.status_code, 200)
        self.assertEqual(self.csv_rows(empty), [list(ASSIGNMENT_REPORT_CSV_HEADERS)])

    def test_manager_export_is_limited_to_recursive_reporting_hierarchy(self):
        manager_user = get_user_model().objects.create_user(
            username="assignment-export-manager",
        )
        Group.objects.get(name="Manager").user_set.add(manager_user)
        manager = Employee.objects.create(
            employee_code="EXPORT-MGR",
            display_name="Export Manager",
            user=manager_user,
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
        )
        child = Employee.objects.create(
            employee_code="EXPORT-CHILD",
            display_name="Scoped Learner",
            reporting_manager=manager,
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
        )
        grandchild = Employee.objects.create(
            employee_code="EXPORT-GRANDCHILD",
            display_name="Nested Learner",
            reporting_manager=child,
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
        )
        outsider = Employee.objects.create(
            employee_code="EXPORT-OUTSIDE",
            display_name="Out of scope",
            department=Department.objects.create(code="EXPORT-OUT", name="Outside department"),
            job_role=JobRole.objects.create(code="EXPORT-OUT", name="Outside role"),
            date_joined=self.now.date(),
        )
        self.create_assignment(child)
        self.create_assignment(grandchild)
        self.create_assignment(outsider)

        self.client.force_login(manager_user)
        rows = self.csv_rows(self.client.get(self.export_url))
        names = {row[0] for row in rows[1:]}
        self.assertEqual(names, {child.display_name, grandchild.display_name})
        self.assertNotIn(outsider.display_name, names)

        out_of_scope_filter = self.client.get(
            self.export_url + f"?department={outsider.department_id}",
        )
        self.assertEqual(out_of_scope_filter.status_code, 400)
        self.assertNotIn("attachment", out_of_scope_filter.get("Content-Disposition", ""))
        self.assertNotContains(out_of_scope_filter, outsider.display_name, status_code=400)

    def test_deferred_manager_export_keeps_selected_ids_and_excludes_later_rows(self):
        manager_user = get_user_model().objects.create_user(
            username="deferred-export-manager",
        )
        Group.objects.get(name="Manager").user_set.add(manager_user)
        manager = Employee.objects.create(
            employee_code="DEFERRED-MGR",
            display_name="Deferred Export Manager",
            user=manager_user,
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
        )
        self.employee.reporting_manager = manager
        self.employee.save()
        child = Employee.objects.create(
            employee_code="DEFERRED-CHILD",
            display_name="Later Scoped Learner",
            reporting_manager=manager,
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
        )
        outsider = Employee.objects.create(
            employee_code="DEFERRED-OUTSIDE",
            display_name="Later Foreign Learner",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
        )
        self.client.force_login(manager_user)
        with patch("reports.views.ASSIGNMENT_REPORT_EXPORT_MAX_ROWS", 1):
            response = self.client.get(self.export_url)
            self.assertEqual(response.status_code, 200)
            self.assertTrue(response.streaming)
            # Both employees existed when the authorized hierarchy was resolved.
            self.create_assignment(child)
            self.create_assignment(outsider)
            rows = self.csv_rows(response)

        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[1][0], self.employee.display_name)
        self.assertNotIn(child.display_name, {row[0] for row in rows[1:]})
        self.assertNotIn(outsider.display_name, {row[0] for row in rows[1:]})

    def test_oversized_database_selection_returns_413_before_streaming(self):
        employee = Employee.objects.create(
            employee_code="EXPORT-LIMIT",
            display_name="Beyond Export Limit",
            department=self.department,
            job_role=self.role,
            date_joined=self.now.date(),
        )
        self.create_assignment(employee)
        with patch("reports.views.ASSIGNMENT_REPORT_EXPORT_MAX_ROWS", 1):
            response = self.client.get(self.export_url)

        self.assertEqual(response.status_code, 413)
        self.assertFalse(response.streaming)
        self.assertNotIn("Content-Disposition", response)

    def test_unauthorized_and_invalid_filter_requests_do_not_export_data(self):
        employee_user = self.employee_user
        Group.objects.get(name="Employee").user_set.add(employee_user)
        self.client.force_login(employee_user)
        self.assertEqual(self.client.get(self.export_url).status_code, 403)

        self.client.force_login(self.coordinator)
        self.assertEqual(self.client.post(self.export_url).status_code, 405)
        invalid = self.client.get(self.export_url + "?status=NOT_A_STATUS")
        self.assertEqual(invalid.status_code, 400)
        self.assertNotIn("attachment", invalid.get("Content-Disposition", ""))
        self.assertContains(invalid, "Please review the filters", status_code=400)

        anonymous = self.client_class().get(self.export_url)
        self.assertEqual(anonymous.status_code, 302)

    def test_export_contains_every_filtered_row_beyond_visible_page_size(self):
        for number in range(51):
            employee = Employee.objects.create(
                employee_code=f"EXPORT-PAGE-{number:03}",
                display_name=f"Export page employee {number:03}",
                department=self.department,
                job_role=self.role,
                date_joined=self.now.date(),
            )
            self.create_assignment(employee)

        response = self.client.get(
            self.export_url + f"?status={TrainingAssignment.Status.ASSIGNED}",
        )
        self.assertTrue(response.streaming)
        rows = self.csv_rows(response)
        self.assertEqual(len(rows), 52)


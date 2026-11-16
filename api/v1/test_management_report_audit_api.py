"""Database-free boundary/presentation tests; real SQL coverage is owned separately."""

from datetime import datetime, timezone
from decimal import Decimal
from types import SimpleNamespace
from unittest.mock import Mock, patch

from django.contrib.auth.models import AnonymousUser
from django.http import Http404
from django.test import SimpleTestCase
from django.urls import resolve, reverse
from rest_framework.test import APIRequestFactory, force_authenticate

from training.models import TrainingAssignment
from training.models import Lesson
from assessments.models import Assessment
from audit.services import audit_snapshot

from . import assignment_report_queries as report_queries
from . import assignment_report_views as report_views
from . import management_audit_views as audit_views
from .assignment_report_serializers import AssignmentReportQuerySerializer, AssignmentReportSerializer
from .management_audit_serializers import AuditLogQuerySerializer, AuditLogSerializer, safe_snapshot


def account(*permissions, active=True, employee_active=True):
    user = Mock(is_authenticated=True, is_active=active, is_superuser=False)
    user.has_perm.side_effect = lambda permission: permission in permissions
    user.employee = SimpleNamespace(is_active=employee_active)
    user.groups.filter.return_value.exists.return_value = False
    return user


def event(**overrides):
    values = dict(
        id=1, occurred_at=datetime(2026, 11, 14, tzinfo=timezone.utc), actor_id=None, actor=None,
        actor_label_snapshot="PRIVATE RECORDED ACTOR", action="training.trainingversion.published",
        entity_type="training.trainingversion", entity_id="42", reason="PRIVATE FREE TEXT",
        before_data={"status": "DRAFT"}, after_data={"status": "PUBLISHED"},
    )
    values.update(overrides)
    return SimpleNamespace(**values)


class ManagementReportAuditBoundaryTests(SimpleTestCase):
    databases = set()

    def request(self, view, *, user=None, path="/", method="get", **kwargs):
        request = getattr(APIRequestFactory(), method)(path, {}, format="json")
        if user is not None:
            force_authenticate(request, user=user)
        return view.as_view()(request, **kwargs)

    def test_routes_preserve_certificate_routes_and_put_filters_before_detail(self):
        for path, view in (
            ("management/reports/assignments/", report_views.AssignmentReportView),
            ("management/reports/assignments/filters/", report_views.AssignmentReportFiltersView),
            ("management/audit-logs/", audit_views.AuditLogListView),
            ("management/audit-logs/filters/", audit_views.AuditLogFiltersView),
            ("management/audit-logs/42/", audit_views.AuditLogDetailView),
        ):
            self.assertIs(resolve("/api/v1/" + path).func.view_class, view)
        self.assertEqual(reverse("api:v1:management-certificate-detail", kwargs={"pk": 42}),
                         "/api/v1/management/certificates/42/")

    def test_anonymous_and_inactive_accounts_are_denied_before_queryset_access(self):
        for view in (report_views.AssignmentReportView, audit_views.AuditLogListView,
                     audit_views.AuditLogDetailView, audit_views.AuditLogFiltersView):
            with self.subTest(view=view):
                self.assertEqual(self.request(view).status_code, 401)
                user = account("audit.view_auditlog", "training.add_trainingassignment", active=False)
                self.assertEqual(self.request(view, user=user).status_code, 403)
                user = account("audit.view_auditlog", "training.add_trainingassignment", employee_active=False)
                self.assertEqual(self.request(view, user=user).status_code, 403)

    def test_employee_denied_report_and_audit_without_effective_authority(self):
        for view in (report_views.AssignmentReportView, report_views.AssignmentReportFiltersView,
                     audit_views.AuditLogListView, audit_views.AuditLogDetailView,
                     audit_views.AuditLogFiltersView):
            self.assertEqual(self.request(view, user=account()).status_code, 403)

    def test_company_authority_uses_website_gate_without_role_name_requirement(self):
        user = account("training.add_trainingassignment")
        self.assertTrue(report_views.HasAssignmentReportAccess().has_permission(SimpleNamespace(user=user), None))
        user.has_perm.assert_any_call("training.add_trainingassignment")

    def test_report_manager_gate_requires_active_employee_and_reuses_website_policy(self):
        user = account()
        user.groups.filter.return_value.exists.return_value = True
        with patch("reports.queries.Employee.objects.filter") as employees:
            employees.return_value.exists.return_value = True
            self.assertTrue(report_views.HasAssignmentReportAccess().has_permission(SimpleNamespace(user=user), None))
            employees.assert_called_once_with(user=user, is_active=True)
            employees.return_value.exists.return_value = False
            self.assertFalse(report_views.HasAssignmentReportAccess().has_permission(SimpleNamespace(user=user), None))

    def test_list_pagination_is_bounded_and_empty_results_are_standard(self):
        user = account("audit.view_auditlog")
        for count, query, expected in ((0, "", 0), (105, "", 20), (105, "?page_size=1000", 100),
                                       (105, "?page_size=1000&page=2", 5)):
            with self.subTest(count=count, query=query):
                with patch.object(audit_views.AuditLogListView, "get_queryset", return_value=[event(id=i) for i in range(count)]):
                    response = self.request(audit_views.AuditLogListView, user=user, path="/api/v1/management/audit-logs/" + query)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(set(response.data), {"count", "next", "previous", "results"})
                self.assertEqual(response.data["count"], count)
                self.assertEqual(len(response.data["results"]), expected)

    def test_audit_detail_permission_is_checked_before_unknown_id_lookup(self):
        with patch.object(audit_views.AuditLogDetailView, "get_object", side_effect=Http404) as lookup:
            self.assertEqual(self.request(audit_views.AuditLogDetailView, user=account(), pk=999).status_code, 403)
            lookup.assert_not_called()
            self.assertEqual(self.request(audit_views.AuditLogDetailView, user=account("audit.view_auditlog"), pk=999).status_code, 404)

    def test_all_report_and_audit_routes_are_read_only(self):
        user = account("training.add_trainingassignment", "audit.view_auditlog")
        for view in (report_views.AssignmentReportView, report_views.AssignmentReportFiltersView,
                     audit_views.AuditLogListView, audit_views.AuditLogDetailView, audit_views.AuditLogFiltersView):
            for method in ("post", "put", "patch", "delete"):
                with self.subTest(view=view, method=method):
                    self.assertEqual(self.request(view, user=user, method=method).status_code, 405)

    def test_invalid_queries_use_api_error_envelope_before_database_access(self):
        user = account("training.add_trainingassignment", "audit.view_auditlog")
        for view, query in ((report_views.AssignmentReportView, "?overdue_only=invalid"),
                            (audit_views.AuditLogListView, "?start_date=invalid")):
            response = self.request(view, user=user, path="/" + query)
            self.assertEqual(response.status_code, 400)
            self.assertEqual(response.data["error"]["code"], "validation_error")
            self.assertTrue(response.data["error"]["fields"])

    def test_options_and_head_keep_read_only_permissions(self):
        user = account("training.add_trainingassignment", "audit.view_auditlog")
        for view in (report_views.AssignmentReportFiltersView, audit_views.AuditLogFiltersView):
            self.assertEqual(self.request(view, user=user, method="options").status_code, 200)
            self.assertEqual(self.request(view, method="options").status_code, 401)
        with patch.object(audit_views.AuditLogListView, "get_queryset", return_value=[]):
            self.assertEqual(self.request(audit_views.AuditLogListView, user=user, method="head").status_code, 200)

    def test_report_filters_preserve_each_collection_pagination(self):
        roles = [SimpleNamespace(pk=i, name=f"Role {i}") for i in range(25)]
        options = {"departments": [], "job_roles": roles, "trainings": [], "training_versions": []}
        user = account("training.add_trainingassignment")
        with patch.object(report_views, "assignment_report_options", return_value=options):
            response = self.request(report_views.AssignmentReportFiltersView, user=user,
                                    path="/api/v1/management/reports/assignments/filters/")
            self.assertEqual(len(response.data["job_roles"]), 20)
            self.assertEqual(response.data["departments"], [])
            metadata = response.data["pagination"]["job_roles"]
            self.assertEqual(metadata["count"], 25)
            self.assertIn("kind=job_roles", metadata["next"])
            self.assertIn("page=2", metadata["next"])
            second = self.request(report_views.AssignmentReportFiltersView, user=user, path=metadata["next"])
            self.assertEqual([row["id"] for row in second.data["job_roles"]], list(range(20, 25)))
            self.assertNotIn("departments", second.data)
            self.assertIsNone(second.data["pagination"]["job_roles"]["next"])
            for query in ("?kind=bad", "?page=2"):
                self.assertEqual(self.request(report_views.AssignmentReportFiltersView, user=user, path="/" + query).status_code, 400)

    def test_audit_actors_are_paginated_without_personal_fields(self):
        actors = [SimpleNamespace(pk=i, get_username=lambda i=i: f"actor-{i}") for i in range(25)]
        with patch.object(audit_views, "get_user_model") as users:
            users.return_value.objects.filter.return_value.only.return_value.order_by.return_value = actors
            response = self.request(audit_views.AuditLogFiltersView, user=account("audit.view_auditlog"))
            second = self.request(audit_views.AuditLogFiltersView, user=account("audit.view_auditlog"),
                                  path=response.data["pagination"]["actors"]["next"])
            invalid = self.request(audit_views.AuditLogFiltersView, user=account("audit.view_auditlog"),
                                   path="/?kind=unknown")
        self.assertEqual(len(response.data["actors"]), 20)
        self.assertEqual(response.data["pagination"]["actors"]["count"], 25)
        self.assertIn("kind=actors", response.data["pagination"]["actors"]["next"])
        self.assertEqual(set(response.data["actors"][0]), {"id", "username", "display_name"})
        self.assertEqual([actor["id"] for actor in second.data["actors"]], list(range(20, 25)))
        self.assertIsNone(second.data["pagination"]["actors"]["next"])
        self.assertEqual(invalid.status_code, 400)


class ManagementReportAuditPresentationTests(SimpleTestCase):
    databases = set()

    def test_actual_audit_snapshots_keep_decimal_percentage_only_changes(self):
        for model, field, entity in ((Lesson, "minimum_watch_percent", "training.lesson"),
                                     (Assessment, "pass_percentage", "assessments.assessment")):
            with self.subTest(field=field):
                target = model(**{field: Decimal("90.00")})
                before = audit_snapshot(target)
                self.assertEqual(before[field], "90.00")
                setattr(target, field, Decimal("85.50"))
                after = audit_snapshot(target)
                data = AuditLogSerializer(event(entity_type=entity, before_data=before, after_data=after)).data
                self.assertEqual(len(data["changes"]), 1)
                self.assertEqual(data["changes"][0]["field"], field)
                self.assertEqual(data["changes"][0]["before_display"], "90.00")
                self.assertEqual(data["changes"][0]["after_display"], "85.50")

    def test_percentage_validation_is_finite_bounded_and_does_not_relax_integer_fields(self):
        for value in ("0.00", "100.00", "90.00", "85.5", 90):
            self.assertEqual(safe_snapshot({"pass_percentage": value}), {"pass_percentage": value})
        for value in ("NaN", "Infinity", "-Infinity", "100.01", "-0.01", "90.001", "9e1",
                      " 90.00 ", "password", True, 90.0, {}, None):
            with self.subTest(value=value):
                self.assertEqual(safe_snapshot({"pass_percentage": value}), {})
        self.assertEqual(safe_snapshot({"employee_id": "90.00", "created_count": "90.00"}), {})

    def test_optional_report_boolean_is_not_false_when_omitted(self):
        query = AssignmentReportQuerySerializer(data={})
        self.assertTrue(query.is_valid())
        self.assertNotIn("overdue_only", query.validated_data)
        for value, expected in (("true", True), ("false", False)):
            query = AssignmentReportQuerySerializer(data={"overdue_only": value})
            self.assertTrue(query.is_valid())
            self.assertIs(query.validated_data["overdue_only"], expected)

    def test_invalid_report_filters_and_audit_dates_are_controlled_errors(self):
        for data in ({"status": "OVERDUE"}, {"department": 0}, {"job_role": "x"},
                     {"training": -1}, {"training_version": "bad"}, {"overdue_only": "maybe"}):
            self.assertFalse(AssignmentReportQuerySerializer(data=data).is_valid())
        for data in ({"actor": "x"}, {"actor": 0}, {"start_date": "bad"},
                     {"action": "x" * 81}, {"target_type": "x" * 101},
                     {"start_date": "2026-11-15", "end_date": "2026-11-14"}):
            self.assertFalse(AuditLogQuerySerializer(data=data).is_valid())
        query = AuditLogQuerySerializer(data={"target_type": " TRAINING.TRAININGVERSION "})
        self.assertTrue(query.is_valid())
        self.assertEqual(query.validated_data["target_type"], "TRAINING.TRAININGVERSION")

    def test_report_fields_null_certificate_and_snapshot_department(self):
        assignment = SimpleNamespace(
            id=7, employee=SimpleNamespace(display_name="Learner", employee_code="L1"),
            department_at_assignment=SimpleNamespace(name="Historical department"),
            job_role_at_assignment=SimpleNamespace(name="Historical role"),
            training_version=SimpleNamespace(title="Pinned version", version_number=2,
                                             training=SimpleNamespace(catalog_title="Course")),
            status="ASSIGNED", get_status_display=lambda: "Assigned", is_overdue=False,
            assigned_at=datetime(2026, 11, 14, tzinfo=timezone.utc), due_at=None, completed_at=None,
        )
        data = AssignmentReportSerializer(assignment).data
        self.assertEqual(data["department_name"], "Historical department")
        for field in ("due_at", "completed_at", "certificate_id", "certificate_number", "is_certificate_revoked"):
            self.assertIsNone(data[field])
        assignment.certificate = SimpleNamespace(pk=12, certificate_number="GN-12", revoked_at=assignment.assigned_at)
        data = AssignmentReportSerializer(assignment).data
        self.assertIsNone(data["certificate_id"])
        self.assertIsNone(data["certificate_number"])
        self.assertTrue(data["is_certificate_revoked"])
        context = {"request": SimpleNamespace(user=account("certifications.view_certificate"))}
        data = AssignmentReportSerializer(assignment, context=context).data
        self.assertEqual(data["certificate_id"], 12)
        self.assertTrue(data["is_certificate_revoked"])
        self.assertNotIn("body", data)

    def test_report_queryset_always_keeps_authoritative_employee_scope(self):
        scoped = TrainingAssignment.objects.filter(employee_id__in=[1, 2])
        with patch.object(report_queries, "assignment_queryset_for_user", return_value=scoped) as scope:
            result = report_queries.assignment_report_queryset(AnonymousUser(), {"department": 999})
        scope.assert_called_once()
        conditions = result.query.where.children
        self.assertEqual(conditions[0].rhs, [1, 2])
        self.assertEqual(conditions[1].rhs, 999)
        self.assertEqual(result.query.order_by, ("-assigned_at", "pk"))
        self.assertIn("certificate", result.query.select_related)
        self.assertIn("is_overdue", result.query.annotations)

    def test_audit_readable_status_changes_and_unchanged_fields(self):
        data = AuditLogSerializer(event(before_data={"status": "DRAFT", "is_active": True},
                                        after_data={"status": "PUBLISHED", "is_active": True})).data
        self.assertEqual(data["action_label"], "Training version published")
        self.assertEqual(data["record_summary"], "Training version #42")
        self.assertEqual(data["detail_kind"], "changes")
        self.assertEqual(len(data["changes"]), 1)
        self.assertEqual(data["changes"][0]["before_display"], "Draft")
        self.assertEqual(data["changes"][0]["after_display"], "Published")

    def test_audit_creation_is_not_misrepresented_as_modification(self):
        data = AuditLogSerializer(event(action="training.module.created", before_data={}, after_data={"position": 1})).data
        self.assertEqual(data["detail_kind"], "creation")
        self.assertEqual(data["changes"][0]["before_display"], "Not recorded")

    def test_snapshot_redaction_is_allowlisted_not_a_secret_key_denylist(self):
        secret = "PRIVATE-SECRET-MARKER"
        snapshot = {name: secret for name in ("password", "token", "body", "url", "status", "position",
                                             "due_at", "is_active", "employee_id", "unanticipated_key")}
        snapshot["nested"] = {"anything": secret}
        snapshot["changed_fields"] = [secret]
        entry = event(before_data=snapshot, after_data={"status": "PUBLISHED"}, reason=secret,
                      actor_label_snapshot=secret, action=secret, entity_type=secret, entity_id=secret)
        data = AuditLogSerializer(entry).data
        self.assertNotIn(secret, str(data))
        self.assertEqual(data["action"], "other")
        self.assertEqual(data["entity_type"], "other")
        self.assertEqual(data["entity_id"], "")
        self.assertTrue({"before_data", "after_data", "reason", "request_id"}.isdisjoint(data))
        self.assertEqual(data["actor_label_snapshot"], "System")

    def test_typed_snapshot_values_reject_nested_or_malformed_values(self):
        self.assertEqual(safe_snapshot({"employee_id": True, "position": -1,
                                        "is_required": "yes", "due_at": "2026-99-99T00:00:00",
                                        "status": {"value": "PUBLISHED"}}), {})
        self.assertEqual(safe_snapshot({"employee_id": 42, "is_required": False,
                                        "due_at": None, "status": "FROZEN"}),
                         {"employee_id": 42, "is_required": False, "due_at": None, "status": "FROZEN"})

    def test_recorded_actor_does_not_echo_untrusted_history_or_mislabel_renamed_account(self):
        actor = SimpleNamespace(get_username=lambda: "current-account")
        data = AuditLogSerializer(event(actor_id=9, actor=actor, actor_label_snapshot="PRIVATE-OLD-LABEL")).data
        self.assertEqual(data["actor_label_snapshot"], "Account #9")
        self.assertNotIn("PRIVATE-OLD-LABEL", str(data))
        self.assertEqual(AuditLogSerializer(event(actor_id=9, actor=actor,
                                                actor_label_snapshot="current-account")).data["actor_label_snapshot"],
                         "current-account")

    def test_audit_queryset_excludes_free_text_and_account_secrets(self):
        queryset = audit_views.audit_queryset()
        fields, deferred = queryset.query.deferred_loading
        self.assertFalse(deferred)
        self.assertIn("actor__username", fields)
        self.assertTrue({"reason", "request_id", "actor__password", "actor__email"}.isdisjoint(fields))

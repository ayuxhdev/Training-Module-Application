"""Certificate management contracts plus isolated-MySQL integration regressions.

CertificateManagementContractTests uses no database. The integration class must
only run in an explicitly approved disposable MySQL environment.
"""

from datetime import timedelta
from types import SimpleNamespace
from unittest.mock import Mock, patch

from django.contrib.auth import get_user_model
from django.contrib.auth.backends import ModelBackend
from django.contrib.auth.models import Group, Permission
from django.core.exceptions import PermissionDenied, ValidationError
from django.db import DatabaseError, OperationalError, transaction
from django.test import SimpleTestCase
from django.urls import resolve, reverse
from django.utils import timezone
from rest_framework.test import APIClient, APIRequestFactory, force_authenticate
from rest_framework_simplejwt.tokens import RefreshToken

from audit.models import AuditLog
from certifications.models import Certificate
from certifications.services import issue_completed_assignment_certificate
from certifications.views import MAX_REVOCATION_REASON_LENGTH
from config.model_test_utils import CurriculumTestCase
from notifications.models import Notification
from organization.models import Employee
from training.models import TrainingAssignment

from . import certificate_management_services as services
from .certificate_management_serializers import (
    CertificateManagementDetailSerializer, CertificateManagementQuerySerializer,
    CertificateManagementSerializer, CertificateRevocationSerializer,
)
from .certificate_management_views import (
    CertificateManagementDetailView, CertificateManagementListView, CertificateRevocationView,
)
from .certificate_views import CertificateDetailView, CertificateListView


class CertificateManagementContractTests(SimpleTestCase):
    def setUp(self):
        self.factory = APIRequestFactory()

    def actor(self, *permissions, active=True, employee=None):
        groups = Mock()
        groups.filter.return_value.exists.return_value = False
        return SimpleNamespace(
            pk=12, is_authenticated=True, is_active=active, employee=employee,
            groups=groups, has_perm=lambda permission: permission in permissions,
            get_username=lambda: "certificate-contract-user",
        )

    def certificate(self, revoked=False):
        return SimpleNamespace(
            id=7, pk=7, assignment_id=15, certificate_number="GN-SNAPSHOT",
            training_title_snapshot="Safety", version_number_snapshot=2,
            employee_name_snapshot="Historical name", employee_code_snapshot="EMP-1",
            issued_at=timezone.now() - timedelta(days=1),
            revoked_at=timezone.now() if revoked else None,
            revocation_reason="Issued in error" if revoked else "",
            _meta=SimpleNamespace(label_lower="certifications.certificate"),
        )

    def test_direct_and_group_effective_permissions_reach_me_capabilities(self):
        from .auth_views import EmployeeMeView

        for source in ("user", "group"):
            user = get_user_model()(pk=123, username="certificate-identity", is_active=True)
            user._meta.get_field("employee").set_cached_value(user, None)
            querysets = {}
            for name in ("user", "group"):
                querysets[name] = Mock()
                rows = [("certifications", "view_certificate"), ("certifications", "change_certificate")] if source == name else []
                querysets[name].values_list.return_value.order_by.return_value = rows
            request = self.factory.get("/api/v1/auth/me/")
            force_authenticate(request, user=user)
            with self.subTest(source=source), \
                 patch.object(ModelBackend, "_get_user_permissions", return_value=querysets["user"]), \
                 patch.object(ModelBackend, "_get_group_permissions", return_value=querysets["group"]):
                response = EmployeeMeView.as_view()(request)
            self.assertEqual(response.status_code, 200)
            self.assertEqual(set(response.data["capabilities"]), {
                services.VIEW_PERMISSION, services.CHANGE_PERMISSION, "management_workspace",
            })
            self.assertIsNone(response.data["employee"])

    def request(self, view, method="get", actor=None, data=None, pk=None):
        request = getattr(self.factory, method)("/api/v1/management/certificates/", data or {}, format="json")
        if actor is not None:
            force_authenticate(request, user=actor)
        return view.as_view()(request, **({"pk": pk} if pk is not None else {}))

    def test_permissions_deny_before_lookup_including_unknown_ids(self):
        for actor in (self.actor(), self.actor("training.add_trainingassignment")):
            for pk in (7, 999999):
                with self.subTest(pk=pk), patch.object(CertificateManagementDetailView, "get_object") as lookup, \
                     patch.object(services, "revoke_certificate") as revoke:
                    self.assertEqual(self.request(CertificateManagementDetailView, actor=actor, pk=pk).status_code, 403)
                    self.assertEqual(self.request(CertificateRevocationView, "post", actor, {"reason": "Error"}, pk).status_code, 403)
                    lookup.assert_not_called()
                    revoke.assert_not_called()

    def test_view_and_change_permissions_are_independent(self):
        with patch.object(CertificateManagementListView, "get_queryset", return_value=[]):
            self.assertEqual(self.request(CertificateManagementListView, actor=self.actor(services.VIEW_PERMISSION)).status_code, 200)
            self.assertEqual(self.request(CertificateManagementListView, actor=self.actor(services.CHANGE_PERMISSION)).status_code, 403)
        with patch.object(services, "revoke_certificate") as revoke:
            self.assertEqual(self.request(CertificateRevocationView, "post", self.actor(services.VIEW_PERMISSION), {"reason": "Error"}, 7).status_code, 403)
            revoke.assert_not_called()

    def test_anonymous_and_ineligible_accounts_are_denied(self):
        self.assertEqual(self.request(CertificateManagementListView).status_code, 401)
        for actor in (
            self.actor(services.VIEW_PERMISSION, active=False),
            self.actor(services.VIEW_PERMISSION, employee=SimpleNamespace(is_active=False)),
        ):
            with patch.object(CertificateManagementListView, "get_queryset") as query:
                self.assertEqual(self.request(CertificateManagementListView, actor=actor).status_code, 403)
                query.assert_not_called()

    def test_reason_validation_is_strict_and_matches_website_bound(self):
        self.assertEqual(services.MAX_REASON_LENGTH, MAX_REVOCATION_REASON_LENGTH)
        for value in (None, "", "  ", "x" * 1001, 123, True, [], {}):
            with self.subTest(value=type(value).__name__):
                serializer = CertificateRevocationSerializer(data={"reason": value})
                self.assertFalse(serializer.is_valid())
        for value in ({}, {"reason": "Error", "revoked_by": 99}, []):
            self.assertFalse(CertificateRevocationSerializer(data=value).is_valid())
        serializer = CertificateRevocationSerializer(data={"reason": "  Reviewed error  "})
        self.assertTrue(serializer.is_valid(), serializer.errors)
        self.assertEqual(serializer.validated_data, {"reason": "Reviewed error"})

    def test_query_validation_and_omitted_status_filter(self):
        self.assertEqual(CertificateManagementQuerySerializer(data={}).is_valid(), True)
        for query in ({"page": 0}, {"page_size": 101}, {"search": "x" * 151}, {"is_revoked": "unknown"}):
            self.assertFalse(CertificateManagementQuerySerializer(data=query).is_valid())
        for query, expected in (({}, None), ({"is_revoked": "true"}, False), ({"is_revoked": "false"}, True)):
            view = CertificateManagementListView()
            view.request = SimpleNamespace(query_params=self.factory.get("/", query).GET)
            with patch("api.v1.certificate_management_views.Certificate") as model:
                queryset = model.objects.all.return_value
                queryset.filter.return_value = queryset
                view.get_queryset()
                if expected is None:
                    queryset.filter.assert_not_called()
                else:
                    queryset.filter.assert_called_once_with(revoked_at__isnull=expected)
                queryset.order_by.assert_called_once_with("-issued_at", "pk")

    def test_read_serializers_expose_only_snapshot_metadata(self):
        certificate = self.certificate()
        certificate.document_file = "private/never-expose.mp4"
        data = CertificateManagementSerializer(certificate).data
        self.assertEqual(set(data), {"id", "certificate_number", "training_title", "version_number",
                                   "issued_at", "is_revoked", "employee_name", "employee_code", "revoked_at"})
        self.assertEqual(data["employee_name"], "Historical name")
        self.assertFalse(data["is_revoked"])
        self.assertIsNone(data["revoked_at"])
        detail = CertificateManagementDetailSerializer(self.certificate(revoked=True)).data
        self.assertEqual(detail["revocation_reason"], "Issued in error")
        self.assertNotIn("private", str(data))

    def test_list_uses_existing_pagination_envelope_and_all_pages(self):
        certificates = []
        for number in range(1, 24):
            certificate = self.certificate()
            certificate.id = certificate.pk = number
            certificates.append(certificate)
        ids = []
        with patch.object(CertificateManagementListView, "get_queryset", return_value=certificates):
            for page in (1, 2, 3):
                response = self.request(CertificateManagementListView, actor=self.actor(services.VIEW_PERMISSION),
                                        data={"page": page, "page_size": 10})
                self.assertEqual(response.status_code, 200)
                self.assertEqual(set(response.data), {"count", "next", "previous", "results"})
                self.assertEqual(response.data["count"], 23)
                self.assertEqual(response.data["next"] is None, page == 3)
                ids.extend(row["id"] for row in response.data["results"])
        self.assertEqual(ids, list(range(1, 24)))

    def test_read_endpoints_do_not_expose_mutation_methods(self):
        actor = self.actor(services.VIEW_PERMISSION, services.CHANGE_PERMISSION)
        self.assertEqual(self.request(CertificateManagementListView, "post", actor).status_code, 405)
        self.assertEqual(self.request(CertificateManagementDetailView, "delete", actor, pk=7).status_code, 405)
        # The shared permission gate has no GET grant on this POST-only action.
        with patch.object(services, "revoke_certificate") as revoke:
            self.assertEqual(self.request(CertificateRevocationView, actor=actor, pk=7).status_code, 403)
            revoke.assert_not_called()

    def test_change_only_receives_status_not_independent_read_data(self):
        actor = self.actor(services.CHANGE_PERMISSION)
        with patch.object(services, "revoke_certificate", return_value=self.certificate(revoked=True)) as revoke:
            response = self.request(CertificateRevocationView, "post", actor, {"reason": " Error "}, 7)
        self.assertEqual(response.status_code, 200)
        self.assertEqual(set(response.data), {"id", "is_revoked", "revoked_at"})
        self.assertTrue(response.data["is_revoked"])
        revoke.assert_called_once_with(actor, 7, "Error")

    def test_errors_use_existing_status_and_error_envelope(self):
        for error, status in ((services.CertificateAlreadyRevoked(), 409), (PermissionDenied(), 403),
                              (ValidationError({"reason": ["Invalid reason"]}), 400)):
            with self.subTest(status=status), patch.object(services, "revoke_certificate", side_effect=error):
                response = self.request(CertificateRevocationView, "post", self.actor(services.CHANGE_PERMISSION), {"reason": "Error"}, 7)
                self.assertEqual(response.status_code, status)
                self.assertIn("error", response.data)

    def test_routes_are_distinct_and_learner_routes_unchanged(self):
        for name, path, view in (
            ("management-certificates", "/api/v1/management/certificates/", CertificateManagementListView),
            ("management-certificate-detail", "/api/v1/management/certificates/7/", CertificateManagementDetailView),
            ("management-certificate-revoke", "/api/v1/management/certificates/7/revoke/", CertificateRevocationView),
            ("certificate-list", "/api/v1/certificates/", CertificateListView),
            ("certificate-detail", "/api/v1/certificates/7/", CertificateDetailView),
        ):
            self.assertEqual(resolve(path).func.cls, view)
            self.assertEqual(reverse("api:v1:" + name, args=[7] if "7/" in path else []), path)

    def test_only_expected_mysql_lock_conflicts_map_to_409(self):
        actor = self.actor(services.CHANGE_PERMISSION)
        for code in (1205, 1213):
            with patch.object(services, "revoke_certificate", side_effect=OperationalError(code, "Private database detail")):
                response = self.request(CertificateRevocationView, "post", actor, {"reason": "Error"}, 7)
                self.assertEqual(response.status_code, 409)
                self.assertNotIn("Private database detail", str(response.data))
        with patch.object(services, "revoke_certificate", side_effect=OperationalError(2006, "Disconnected")):
            with self.assertRaises(OperationalError):
                self.request(CertificateRevocationView, "post", actor, {"reason": "Error"}, 7)

    def test_service_rechecks_authority_and_locks_assignment_before_certificate(self):
        self.service_case()

    def test_service_duplicate_does_not_save_or_audit(self):
        self.service_case(duplicate=True)

    def test_service_permission_loss_while_waiting_does_not_save_or_audit(self):
        self.service_case(revoked_permission=True)

    def test_service_audit_persistence_failure_is_not_deferred(self):
        self.service_case(audit_failure=True)

    def service_case(self, duplicate=False, revoked_permission=False, audit_failure=False):
        # Exercise actual control flow without executing atomic/SQL. Real row-lock
        # serialization and transaction rollback require the pending MySQL run.
        certificate = self.certificate(revoked=duplicate)
        order = []
        certificate.save = Mock(side_effect=lambda: order.append("save"))
        actor = self.actor(services.CHANGE_PERMISSION)

        def authorize(_):
            if revoked_permission and order:
                raise PermissionDenied
            order.append("authorize")
            return actor

        def persist_audit(**kwargs):
            order.append("audit")
            if audit_failure:
                raise DatabaseError("Synthetic audit persistence failure")

        with patch.object(services, "_revoker", side_effect=authorize), \
             patch.object(services, "get_object_or_404", side_effect=[certificate, certificate]), \
             patch.object(services, "TrainingAssignment") as assignment, \
             patch.object(services, "Certificate") as model, \
             patch("audit.models.AuditLog.objects.create", side_effect=persist_audit) as audit, \
             patch("django.db.transaction.on_commit") as deferred:
            assignment.objects.select_for_update.side_effect = lambda: (order.append("assignment_lock") or Mock())
            model.objects.select_for_update.side_effect = lambda: (order.append("certificate_lock") or Mock())
            if duplicate or revoked_permission:
                with self.assertRaises(PermissionDenied if revoked_permission else services.CertificateAlreadyRevoked):
                    services.revoke_certificate.__wrapped__(actor, 7, "Error")
                certificate.save.assert_not_called()
                audit.assert_not_called()
            elif audit_failure:
                with self.assertRaisesRegex(DatabaseError, "audit persistence failure"):
                    services.revoke_certificate.__wrapped__(actor, 7, "Error")
                audit.assert_called_once()
            else:
                result = services.revoke_certificate.__wrapped__(actor, 7, " Error ")
                self.assertIs(result, certificate)
                self.assertEqual(order, ["authorize", "assignment_lock", "certificate_lock", "authorize", "save", "audit"])
                self.assertEqual(certificate.revocation_reason, "Error")
                self.assertIs(certificate.revoked_by, actor)
                self.assertEqual(audit.call_args.kwargs["before_data"], {"revoked_at": None})
                self.assertEqual(audit.call_args.kwargs["actor_label_snapshot"], actor.get_username())
            deferred.assert_not_called()


class CertificateManagementAPITests(CurriculumTestCase):
    """Pending real MySQL validation; never run against protected databases."""

    def setUp(self):
        self.complete_assignment()
        self.certificate = issue_completed_assignment_certificate(self.assignment.pk)
        self.actor = get_user_model().objects.create_user(username="certificate-manager-api")
        self.client = APIClient()
        self.list_url = "/api/v1/management/certificates/"
        self.detail = f"{self.list_url}{self.certificate.pk}/"
        self.revoke_url = self.detail + "revoke/"

    def login(self, user=None):
        user = user or self.actor
        self.client.credentials(HTTP_AUTHORIZATION="Bearer " + str(RefreshToken.for_user(user).access_token))

    def grant(self, *names):
        self.actor.user_permissions.add(*Permission.objects.filter(content_type__app_label="certifications", codename__in=names))
        self.login()

    def revoke(self, **data):
        with self.captureOnCommitCallbacks(execute=True):
            return self.client.post(self.revoke_url, data or {"reason": "Issued in error"}, format="json")

    def events(self):
        return AuditLog.objects.filter(action="certifications.certificate.revoked", entity_id=str(self.certificate.pk))

    def test_administrator_and_coordinator_have_existing_management_permissions(self):
        for role in ("Administrator", "Training Coordinator"):
            with self.subTest(role=role):
                self.actor.groups.set([Group.objects.get(name=role)])
                self.login()
                self.assertEqual(self.client.get(self.list_url).status_code, 200)
                self.assertEqual(self.client.get(self.detail).status_code, 200)
        self.assertEqual(self.revoke().status_code, 200)

    def test_manager_employee_and_foreign_ids_do_not_grant_authority(self):
        self.actor.groups.add(Group.objects.get(name="Manager"))
        manager = Employee.objects.create(employee_code="CERT-MANAGER", display_name="Manager", user=self.actor,
            department=self.department, job_role=self.role, date_joined=self.now.date())
        self.employee.reporting_manager = manager
        self.employee.save()
        for user in (self.actor, self.employee_user):
            self.login(user)
            self.assertEqual(self.client.get(self.list_url).status_code, 403)
            for pk in (self.certificate.pk, 99999999):
                self.assertEqual(self.client.get(f"{self.list_url}{pk}/").status_code, 403)
                self.assertEqual(self.client.post(f"{self.list_url}{pk}/revoke/", {"reason": "Error"}, format="json").status_code, 403)

    def test_explicit_manager_change_permission_is_global_but_does_not_grant_view(self):
        self.actor.groups.add(Group.objects.get(name="Manager"))
        Employee.objects.create(employee_code="CERT-PRIV-MANAGER", display_name="Manager", user=self.actor,
            department=self.department, job_role=self.role, date_joined=self.now.date())
        self.grant("change_certificate")
        self.assertEqual(self.client.get(self.detail).status_code, 403)
        response = self.revoke()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(set(response.data), {"id", "is_revoked", "revoked_at"})

    def test_view_permission_does_not_grant_mutation(self):
        self.grant("view_certificate")
        self.assertEqual(self.client.get(self.detail).status_code, 200)
        self.assertEqual(self.revoke().status_code, 403)
        self.assertFalse(self.events().exists())

    def test_jwt_required_and_browser_session_does_not_authenticate(self):
        self.actor.groups.add(Group.objects.get(name="Administrator"))
        self.client.force_login(self.actor)
        self.assertEqual(self.client.get(self.list_url).status_code, 401)
        self.assertEqual(self.revoke().status_code, 401)

    def test_inactive_user_or_linked_employee_is_denied(self):
        self.grant("view_certificate", "change_certificate")
        self.actor.is_active = False
        self.actor.save()
        self.assertEqual(self.revoke().status_code, 401)
        self.actor.is_active = True
        self.actor.save()
        employee = Employee.objects.create(employee_code="CERT-DISABLED", display_name="Disabled",
            user=self.actor, department=self.department, job_role=self.role, date_joined=self.now.date())
        employee.is_active = False
        employee.deactivation_reason = "Fixture"
        employee.save()
        self.actor.refresh_from_db()
        self.assertFalse(self.actor.is_active)
        # Re-enable only the test login to isolate inactive-Employee denial.
        self.actor.is_active = True
        self.actor.save(update_fields=["is_active"])
        employee.refresh_from_db()
        self.assertFalse(employee.is_active)
        self.assertIsNotNone(employee.deactivated_at)
        self.login()
        self.assertEqual(self.client.get(self.list_url).status_code, 403)
        self.assertEqual(self.revoke().status_code, 403)

    def test_invalid_ids_and_missing_records_return_404_without_audit(self):
        self.grant("view_certificate", "change_certificate")
        for token in ("0", "-1", "bad", "99999999"):
            self.assertEqual(self.client.get(f"{self.list_url}{token}/").status_code, 404)
            self.assertEqual(self.client.post(f"{self.list_url}{token}/revoke/", {"reason": "Error"}, format="json").status_code, 404)
        self.assertFalse(self.events().exists())

    def test_invalid_reasons_and_forged_fields_do_not_change_records(self):
        self.grant("change_certificate")
        for data in ({}, {"reason": " "}, {"reason": None}, {"reason": 1}, {"reason": "x" * 1001},
                     {"reason": "Error", "revoked_by_id": self.actor.pk}, []):
            self.assertEqual(self.client.post(self.revoke_url, data, format="json").status_code, 400)
        self.certificate.refresh_from_db()
        self.assertIsNone(self.certificate.revoked_at)
        self.assertFalse(self.events().exists())

    def test_repeated_revocation_preserves_first_reason_actor_timestamp_and_audit(self):
        self.grant("change_certificate")
        self.assertEqual(self.revoke(reason=" First reason ").status_code, 200)
        before = Certificate.objects.filter(pk=self.certificate.pk).values().get()
        self.assertEqual(self.revoke(reason="Another reason").status_code, 409)
        self.assertEqual(Certificate.objects.filter(pk=self.certificate.pk).values().get(), before)
        self.assertEqual(self.events().count(), 1)
        self.assertEqual(self.events().get().reason, "First reason")

    def test_revocation_preserves_snapshots_assignment_attempt_and_notifications(self):
        self.grant("change_certificate")
        before = Certificate.objects.filter(pk=self.certificate.pk).values().get()
        assignment = TrainingAssignment.objects.filter(pk=self.assignment.pk).values().get()
        attempt = self.certificate.qualifying_final_attempt
        attempt_before = type(attempt).objects.filter(pk=attempt.pk).values().get()
        notifications = list(Notification.objects.order_by("pk").values())
        self.assertEqual(self.revoke().status_code, 200)
        after = Certificate.objects.filter(pk=self.certificate.pk).values().get()
        for field in set(before) - {"revoked_at", "revoked_by_id", "revocation_reason", "updated_at"}:
            self.assertEqual(after[field], before[field], field)
        self.assertEqual(TrainingAssignment.objects.filter(pk=self.assignment.pk).values().get(), assignment)
        self.assertEqual(type(attempt).objects.filter(pk=attempt.pk).values().get(), attempt_before)
        self.assertEqual(list(Notification.objects.order_by("pk").values()), notifications)
        event = self.events().get()
        self.assertEqual(event.actor_id, self.actor.pk)
        self.assertEqual(event.before_data, {"revoked_at": None})
        self.assertEqual(event.after_data["revoked_by_id"], self.actor.pk)

    def test_audit_database_failure_rolls_back_revocation(self):
        self.grant("change_certificate")
        before = Certificate.objects.filter(pk=self.certificate.pk).values().get()
        with patch("audit.models.AuditLog.objects.create", side_effect=DatabaseError("Audit unavailable")):
            with self.assertRaisesRegex(DatabaseError, "Audit unavailable"):
                services.revoke_certificate(self.actor, self.certificate.pk, "Error")
        self.assertEqual(Certificate.objects.filter(pk=self.certificate.pk).values().get(), before)
        self.assertFalse(self.events().exists())

    def test_audit_is_visible_before_commit_and_outer_rollback_removes_both_changes(self):
        self.grant("change_certificate")
        before = Certificate.objects.filter(pk=self.certificate.pk).values().get()
        with self.assertRaisesRegex(RuntimeError, "Abort outer transaction"):
            with transaction.atomic(), self.captureOnCommitCallbacks(execute=False) as callbacks:
                services.revoke_certificate(self.actor, self.certificate.pk, "Error")
                self.assertEqual(self.events().count(), 1)
                self.assertTrue(Certificate.objects.get(pk=self.certificate.pk).revoked_at)
                raise RuntimeError("Abort outer transaction")
        self.assertEqual(callbacks, [])
        self.assertEqual(Certificate.objects.filter(pk=self.certificate.pk).values().get(), before)
        self.assertFalse(self.events().exists())

    def test_management_list_is_paginated_searchable_and_read_only(self):
        self.grant("view_certificate", "change_certificate")
        before = Certificate.objects.filter(pk=self.certificate.pk).values().get()
        listing = self.client.get(self.list_url, {"page_size": 1, "search": self.certificate.employee_code_snapshot})
        self.assertEqual(listing.status_code, 200)
        self.assertEqual(set(listing.data), {"count", "next", "previous", "results"})
        self.assertEqual([row["id"] for row in listing.data["results"]], [self.certificate.pk])
        self.assertEqual(self.client.get(self.list_url, {"search": "no-match"}).data["count"], 0)
        self.assertEqual(self.client.get(self.list_url, {"is_revoked": "false"}).data["count"], 1)
        self.assertEqual(self.client.get(self.list_url, {"is_revoked": "true"}).data["count"], 0)
        self.assertEqual(self.client.get(self.list_url, {"page_size": 101}).status_code, 400)
        self.assertEqual(self.client.delete(self.detail).status_code, 405)
        self.assertEqual(Certificate.objects.filter(pk=self.certificate.pk).values().get(), before)

    def test_management_permissions_do_not_expand_learner_certificate_scope(self):
        self.grant("view_certificate", "change_certificate")
        Employee.objects.create(employee_code="CERT-OTHER", display_name="Other employee", user=self.actor,
            department=self.department, job_role=self.role, date_joined=self.now.date())
        self.assertEqual(self.client.get(f"/api/v1/certificates/{self.certificate.pk}/").status_code, 404)
        self.assertEqual(self.client.get("/api/v1/certificates/").data["count"], 0)
        self.login(self.employee_user)
        self.assertEqual(self.client.get(f"/api/v1/certificates/{self.certificate.pk}/").status_code, 200)

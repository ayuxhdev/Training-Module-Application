"""Database-backed contract tests for management reports and audit APIs.

The report and audit lists use the standard count/next/previous/results
pagination envelope. Filter-option collections are paginated independently;
audit responses contain approved summaries, never raw snapshots or reasons.
Run only against an explicitly approved disposable database.
"""

from datetime import timedelta
from urllib.parse import urlencode, urlsplit

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group, Permission
from django.utils import timezone
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from audit.models import AuditLog
from config.model_test_utils import CurriculumTestCase
from certifications.services import issue_completed_assignment_certificate
from organization.models import Department, Employee
from reports.queries import dashboard_role
from training.models import TrainingAssignment


ASSIGNMENT_REPORT_URL = "/api/v1/management/reports/assignments/"
ASSIGNMENT_REPORT_FILTERS_URL = ASSIGNMENT_REPORT_URL + "filters/"
AUDIT_LOG_URL = "/api/v1/management/audit-logs/"
AUDIT_LOG_FILTERS_URL = AUDIT_LOG_URL + "filters/"


def jwt_client(user):
    return APIClient(
        HTTP_AUTHORIZATION=f"Bearer {RefreshToken.for_user(user).access_token}"
    )


class AssignmentReportContractTests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        groups = Group.objects.in_bulk(field_name="name")
        cls.admin = get_user_model().objects.create_user(username="report-contract-admin")
        cls.admin.groups.add(groups["Administrator"])
        cls.user.groups.add(groups["Training Coordinator"])

        cls.manager = get_user_model().objects.create_user(username="report-contract-manager")
        cls.manager.groups.add(groups["Manager"])
        cls.manager_employee = Employee.objects.create(
            employee_code="REPORT-MANAGER",
            display_name="Report Manager",
            user=cls.manager,
            department=cls.department,
            job_role=cls.role,
            date_joined=cls.now.date(),
        )
        cls.report_employee = Employee.objects.create(
            employee_code="REPORT-EMPLOYEE",
            display_name="Report Employee",
            reporting_manager=cls.manager_employee,
            department=cls.department,
            job_role=cls.role,
            date_joined=cls.now.date(),
        )
        cls.descendant = Employee.objects.create(
            employee_code="REPORT-DESCENDANT",
            display_name="Report Descendant",
            reporting_manager=cls.report_employee,
            department=cls.department,
            job_role=cls.role,
            date_joined=cls.now.date(),
        )
        cls.foreign_department = Department.objects.create(
            code="REPORT-OTHER",
            name="Outside reporting scope",
        )
        cls.foreign_employee = Employee.objects.create(
            employee_code="REPORT-FOREIGN",
            display_name="Outside Employee",
            department=cls.foreign_department,
            job_role=cls.role,
            date_joined=cls.now.date(),
        )

        cls.manager_assignment = cls.assignment_for(cls.manager_employee)
        cls.report_assignment = cls.assignment_for(cls.report_employee)
        overdue_assigned_at = timezone.now() - timedelta(days=2)
        cls.descendant_assignment = cls.assignment_for(
            cls.descendant,
            assigned_at=overdue_assigned_at,
            due_at=overdue_assigned_at + timedelta(hours=1),
        )
        cls.foreign_assignment = cls.assignment_for(cls.foreign_employee)

    @classmethod
    def assignment_for(cls, employee, *, assigned_at=None, due_at=None, status=None):
        assigned_at = assigned_at or cls.now
        status = status or TrainingAssignment.Status.ASSIGNED
        return TrainingAssignment.objects.create(
            employee=employee,
            training_version=cls.version,
            status=status,
            department_at_assignment=employee.department,
            job_role_at_assignment=employee.job_role,
            assigned_by=cls.user,
            assigned_at=assigned_at,
            due_at=due_at,
            started_at=assigned_at if status == TrainingAssignment.Status.IN_PROGRESS else None,
        )

    def setUp(self):
        self.client = APIClient()

    def get(self, url, user):
        return jwt_client(user).get(url)

    def test_administrator_and_coordinator_access_uses_effective_reporting_permission(self):
        permission = "training.add_trainingassignment"
        for user in (self.admin, self.user):
            with self.subTest(user=user.username):
                self.assertTrue(user.has_perm(permission))
                self.assertEqual(dashboard_role(user), "company")
                self.assertEqual(self.get(ASSIGNMENT_REPORT_URL, user).status_code, 200)
                self.assertEqual(self.get(ASSIGNMENT_REPORT_FILTERS_URL, user).status_code, 200)

    def test_manager_sees_only_recursive_reporting_tree_assignments(self):
        self.assertFalse(self.manager.has_perm("training.add_trainingassignment"))
        self.assertEqual(dashboard_role(self.manager), "manager")

        response = self.get(ASSIGNMENT_REPORT_URL, self.manager)
        self.assertEqual(response.status_code, 200, response.json())
        rows = response.json()["results"]
        result_ids = {row["id"] for row in rows}
        self.assertEqual(
            result_ids,
            {
                self.manager_assignment.pk,
                self.report_assignment.pk,
                self.descendant_assignment.pk,
            },
        )
        self.assertNotIn(self.foreign_assignment.pk, result_ids)
        for row in rows:
            self.assertIsNone(row["certificate_id"])
            self.assertIsNone(row["certificate_number"])
            self.assertIsNone(row["is_certificate_revoked"])

        company_response = self.get(ASSIGNMENT_REPORT_URL, self.admin)
        company_ids = {row["id"] for row in company_response.json()["results"]}
        self.assertIn(self.foreign_assignment.pk, company_ids)

    def test_certificate_identifiers_require_independent_view_permission(self):
        self.assertFalse(self.manager.has_perm("certifications.view_certificate"))
        self.employee.reporting_manager = self.report_employee
        self.employee.save()
        self.complete_assignment()
        certificate = issue_completed_assignment_certificate(
            self.assignment.pk,
            actor=self.user,
        )
        self.assertIsNotNone(certificate)

        url = f"{ASSIGNMENT_REPORT_URL}?status={TrainingAssignment.Status.COMPLETED}"
        response = self.get(url, self.manager)
        self.assertEqual(response.status_code, 200, response.json())
        row = next(
            item for item in response.json()["results"]
            if item["id"] == self.assignment.pk
        )
        self.assertIsNone(row["certificate_id"])
        self.assertIsNone(row["certificate_number"])
        self.assertFalse(row["is_certificate_revoked"])

        permission = Permission.objects.get(
            content_type__app_label="certifications",
            codename="view_certificate",
        )
        self.manager.user_permissions.add(permission)
        authorized = self.get(url, self.manager)
        authorized_row = next(
            item for item in authorized.json()["results"]
            if item["id"] == self.assignment.pk
        )
        self.assertEqual(authorized_row["certificate_id"], certificate.pk)
        self.assertEqual(authorized_row["certificate_number"], certificate.certificate_number)

    def test_filter_choices_and_out_of_scope_filter_cannot_expand_manager_scope(self):
        filters = self.get(ASSIGNMENT_REPORT_FILTERS_URL, self.manager)
        self.assertEqual(filters.status_code, 200, filters.json())
        self.assertNotIn(
            self.foreign_department.pk,
            {option["id"] for option in filters.json()["departments"]},
        )

        response = self.get(
            f"{ASSIGNMENT_REPORT_URL}?department={self.foreign_department.pk}",
            self.manager,
        )
        self.assertEqual(response.status_code, 200, response.json())
        self.assertEqual(response.json()["count"], 0)
        self.assertEqual(response.json()["results"], [])
        self.assertNotIn(self.foreign_assignment.pk, {
            row["id"] for row in response.json().get("results", [])
        })

    def test_filter_option_pages_enumerate_only_manager_scoped_departments(self):
        departments = []
        for number in range(24):
            department = Department.objects.create(
                code=f"REPORT-OPTION-{number:02}",
                name=f"Report option {number:02}",
            )
            employee = Employee.objects.create(
                employee_code=f"REPORT-OPT-{number:02}",
                display_name=f"Report option employee {number:02}",
                reporting_manager=self.manager_employee,
                department=department,
                job_role=self.role,
                date_joined=self.now.date(),
            )
            self.assignment_for(employee)
            departments.append(department)

        expected_ids = list(
            Department.objects.filter(
                pk__in=[self.department.pk, *(department.pk for department in departments)],
            ).order_by("name", "pk").values_list("pk", flat=True)
        )
        first_page = self.get(ASSIGNMENT_REPORT_FILTERS_URL, self.manager)
        self.assertEqual(first_page.status_code, 200, first_page.json())
        first_metadata = first_page.json()["pagination"]["departments"]
        self.assertEqual(first_metadata["count"], len(expected_ids))
        first_ids = [option["id"] for option in first_page.json()["departments"]]
        self.assertEqual(first_ids, expected_ids[:20])
        self.assertIn("kind=departments", first_metadata["next"])

        next_page = urlsplit(first_metadata["next"])
        second_page = self.get(
            f"{next_page.path}?{next_page.query}",
            self.manager,
        )
        self.assertEqual(second_page.status_code, 200, second_page.json())
        second_ids = [option["id"] for option in second_page.json()["departments"]]
        self.assertEqual(second_ids, expected_ids[20:])
        self.assertEqual(len(set(first_ids + second_ids)), len(expected_ids))
        self.assertIsNotNone(second_page.json()["pagination"]["departments"]["previous"])
        self.assertIsNone(second_page.json()["pagination"]["departments"]["next"])
        self.assertNotIn("job_roles", second_page.json())

    def test_website_filters_combine_and_valid_empty_combinations_stay_empty(self):
        query = urlencode({
            "status": TrainingAssignment.Status.ASSIGNED,
            "department": self.department.pk,
            "job_role": self.role.pk,
            "training": self.training.pk,
            "training_version": self.version.pk,
            "overdue_only": "true",
        })
        response = self.get(f"{ASSIGNMENT_REPORT_URL}?{query}", self.manager)
        self.assertEqual(response.status_code, 200, response.json())
        self.assertEqual(response.json()["count"], 1)
        self.assertEqual(response.json()["results"][0]["id"], self.descendant_assignment.pk)
        self.assertTrue(response.json()["results"][0]["is_overdue"])

        empty_query = urlencode({
            "status": TrainingAssignment.Status.COMPLETED,
            "overdue_only": "true",
        })
        empty = self.get(f"{ASSIGNMENT_REPORT_URL}?{empty_query}", self.manager)
        self.assertEqual(empty.status_code, 200, empty.json())
        self.assertEqual(empty.json()["count"], 0)
        self.assertEqual(empty.json()["results"], [])

    def test_invalid_filter_syntax_returns_validation_error(self):
        for query in ("status=NOT_A_STATUS", "department=not-an-id"):
            with self.subTest(query=query):
                response = self.get(f"{ASSIGNMENT_REPORT_URL}?{query}", self.admin)
                self.assertEqual(response.status_code, 400, response.json())
                self.assertIn("error", response.json())

    def test_pagination_uses_standard_bounds_and_stable_website_order(self):
        same_time = self.now - timedelta(days=1)
        created = [
            self.assignment_for(
                Employee.objects.create(
                    employee_code=f"REPORT-PAGE-{number:03}",
                    display_name=f"Pagination employee {number}",
                    department=self.department,
                    job_role=self.role,
                    date_joined=self.now.date(),
                ),
                assigned_at=same_time,
            )
            for number in range(105)
        ]
        expected = list(
            TrainingAssignment.objects.filter(
                training_version=self.version,
                status=TrainingAssignment.Status.ASSIGNED,
            ).order_by("-assigned_at", "pk").values_list("pk", flat=True)
        )
        self.assertTrue({assignment.pk for assignment in created}.issubset(set(expected)))

        default_page = self.get(
            f"{ASSIGNMENT_REPORT_URL}?status={TrainingAssignment.Status.ASSIGNED}",
            self.admin,
        )
        self.assertEqual(default_page.status_code, 200, default_page.json())
        self.assertEqual(
            set(default_page.json()),
            {"count", "next", "previous", "results"},
        )
        self.assertEqual(default_page.json()["count"], len(expected))
        self.assertEqual(len(default_page.json()["results"]), 20)
        self.assertIsNone(default_page.json()["previous"])

        first_hundred = self.get(
            f"{ASSIGNMENT_REPORT_URL}?status={TrainingAssignment.Status.ASSIGNED}&page_size=1000",
            self.admin,
        )
        self.assertEqual(len(first_hundred.json()["results"]), 100)
        self.assertIsNone(first_hundred.json()["previous"])
        self.assertIsNotNone(first_hundred.json()["next"])
        first_ids = [row["id"] for row in first_hundred.json()["results"]]
        self.assertEqual(first_ids, expected[:100])

        last_page = self.get(
            f"{ASSIGNMENT_REPORT_URL}?status={TrainingAssignment.Status.ASSIGNED}"
            "&page_size=1000&page=2",
            self.admin,
        )
        self.assertEqual([row["id"] for row in last_page.json()["results"]], expected[100:])
        self.assertIsNotNone(last_page.json()["previous"])
        self.assertIsNone(last_page.json()["next"])
        self.assertEqual(len(first_ids) + len(last_page.json()["results"]), len(expected))

    def test_authentication_inactive_accounts_and_employee_role_are_rejected(self):
        unauthenticated = self.client.get(ASSIGNMENT_REPORT_URL)
        self.assertEqual(unauthenticated.status_code, 401)

        employee_response = self.get(ASSIGNMENT_REPORT_URL, self.employee_user)
        self.assertEqual(employee_response.status_code, 403)

        inactive = get_user_model().objects.create_user(
            username="report-contract-inactive",
            is_active=False,
        )
        inactive_response = jwt_client(inactive).get(ASSIGNMENT_REPORT_URL)
        self.assertEqual(inactive_response.status_code, 401)


class AuditLogContractTests(CurriculumTestCase):
    @classmethod
    def setUpTestData(cls):
        super().setUpTestData()
        groups = Group.objects.in_bulk(field_name="name")
        cls.admin = get_user_model().objects.create_user(username="audit-contract-admin")
        cls.admin.groups.add(groups["Administrator"])
        cls.user.groups.add(groups["Training Coordinator"])
        cls.employee_user.groups.add(groups["Employee"])

        cls.manager = get_user_model().objects.create_user(username="audit-contract-manager")
        cls.manager.groups.add(groups["Manager"])
        cls.manager_employee = Employee.objects.create(
            employee_code="AUDIT-MANAGER",
            display_name="Audit Manager",
            user=cls.manager,
            department=cls.department,
            job_role=cls.role,
            date_joined=cls.now.date(),
        )
        cls.event = cls.audit_event(
            actor=cls.user,
            action="training.trainingversion.published",
            entity_type="training.trainingversion",
            entity_id="1",
            occurred_at=cls.now,
            before_data={"status": "DRAFT"},
            after_data={"status": "PUBLISHED"},
        )

    @classmethod
    def audit_event(
        cls,
        *,
        actor=None,
        actor_label_snapshot=None,
        action="contract.audit_event",
        entity_type="training.trainingversion",
        entity_id="1",
        occurred_at=None,
        before_data=None,
        after_data=None,
        reason="",
    ):
        return AuditLog.objects.create(
            occurred_at=occurred_at or cls.now,
            actor=actor,
            actor_label_snapshot=(
                actor_label_snapshot
                if actor_label_snapshot is not None
                else actor.get_username() if actor else "System"
            ),
            action=action,
            entity_type=entity_type,
            entity_id=entity_id,
            before_data=before_data or {},
            after_data=after_data or {},
            reason=reason,
        )

    def setUp(self):
        self.client = APIClient()

    def get(self, url, user):
        return jwt_client(user).get(url)

    def test_administrator_and_coordinator_group_grants_allow_list_and_detail(self):
        for user in (self.admin, self.user):
            with self.subTest(user=user.username):
                self.assertTrue(user.has_perm("audit.view_auditlog"))
                client = jwt_client(user)
                listed = client.get(AUDIT_LOG_URL)
                self.assertEqual(listed.status_code, 200, listed.json())
                detail = client.get(f"{AUDIT_LOG_URL}{self.event.pk}/")
                self.assertEqual(detail.status_code, 200, detail.json())
                self.assertEqual(detail.json()["id"], self.event.pk)

    def test_manager_and_employee_without_effective_permission_are_denied(self):
        for user in (self.manager, self.employee_user):
            with self.subTest(user=user.username):
                self.assertFalse(user.has_perm("audit.view_auditlog"))
                client = jwt_client(user)
                self.assertEqual(client.get(AUDIT_LOG_URL).status_code, 403)
                self.assertEqual(
                    client.get(f"{AUDIT_LOG_URL}{self.event.pk}/").status_code,
                    403,
                )
                self.assertEqual(
                    client.post(AUDIT_LOG_URL, {"action": "forbidden"}, format="json").status_code,
                    403,
                )

    def test_direct_and_group_grants_are_honored_by_effective_permission(self):
        permission = Permission.objects.get(
            content_type__app_label="audit",
            codename="view_auditlog",
        )
        self.manager.user_permissions.add(permission)
        self.assertTrue(self.manager.has_perm("audit.view_auditlog"))
        manager_client = jwt_client(self.manager)
        self.assertEqual(manager_client.get(AUDIT_LOG_URL).status_code, 200)

        reviewers = Group.objects.create(name="Audit Contract Reviewers")
        reviewers.permissions.add(permission)
        self.employee_user.groups.add(reviewers)
        self.assertTrue(self.employee_user.has_perm("audit.view_auditlog"))
        employee_client = jwt_client(self.employee_user)
        self.assertEqual(employee_client.get(AUDIT_LOG_URL).status_code, 200)

    def test_audit_actor_filter_options_are_paginated_and_scoped_to_recorded_actors(self):
        actors = [
            get_user_model().objects.create_user(username=f"audit-filter-actor-{number:02}")
            for number in range(21)
        ]
        for number, actor in enumerate(actors):
            self.audit_event(actor=actor, action="contract.filter-option", entity_id=str(number))
        expected = [
            actor.pk
            for actor in sorted(
                [self.user, *actors],
                key=lambda actor: (actor.get_username(), actor.pk),
            )
        ]

        first_page = self.get(AUDIT_LOG_FILTERS_URL, self.admin)
        self.assertEqual(first_page.status_code, 200, first_page.json())
        metadata = first_page.json()["pagination"]["actors"]
        self.assertEqual(metadata["count"], len(expected))
        first_ids = [actor["id"] for actor in first_page.json()["actors"]]
        self.assertEqual(first_ids, expected[:20])
        self.assertIn("kind=actors", metadata["next"])

        next_page = urlsplit(metadata["next"])
        second_page = self.get(
            f"{next_page.path}?{next_page.query}",
            self.admin,
        )
        self.assertEqual(second_page.status_code, 200, second_page.json())
        second_ids = [actor["id"] for actor in second_page.json()["actors"]]
        self.assertEqual(second_ids, expected[20:])
        self.assertEqual(len(set(first_ids + second_ids)), len(expected))
        self.assertEqual(
            set(first_page.json()["actors"][0]),
            {"id", "username", "display_name"},
        )
        self.assertIsNone(second_page.json()["pagination"]["actors"]["next"])

    def test_detail_missing_record_is_not_found_and_authentication_is_required(self):
        missing = jwt_client(self.admin).get(f"{AUDIT_LOG_URL}999999999/")
        self.assertEqual(missing.status_code, 404)

        self.assertEqual(self.client.get(AUDIT_LOG_URL).status_code, 401)

        inactive = get_user_model().objects.create_user(
            username="audit-contract-inactive",
            is_active=False,
        )
        self.assertEqual(jwt_client(inactive).get(AUDIT_LOG_URL).status_code, 401)

    def test_website_audit_filters_and_invalid_date_ranges_are_preserved(self):
        matching = self.event
        self.audit_event(
            actor=self.user,
            action="training.lesson.published",
            entity_type="training.lesson",
            entity_id="2",
            occurred_at=self.now,
        )
        query = urlencode({
            "actor": self.user.pk,
            "action": "published",
            "start_date": timezone.localdate(self.now).isoformat(),
            "end_date": timezone.localdate(self.now).isoformat(),
            "target_type": " TRAINING.TRAININGVERSION ",
        })
        response = self.get(f"{AUDIT_LOG_URL}?{query}", self.user)
        self.assertEqual(response.status_code, 200, response.json())
        self.assertEqual(
            [row["id"] for row in response.json()["results"]],
            [matching.pk],
        )

        invalid = urlencode({
            "start_date": (timezone.localdate(self.now) + timedelta(days=1)).isoformat(),
            "end_date": timezone.localdate(self.now).isoformat(),
        })
        invalid_response = self.get(f"{AUDIT_LOG_URL}?{invalid}", self.user)
        self.assertEqual(invalid_response.status_code, 400, invalid_response.json())

        empty = self.get(f"{AUDIT_LOG_URL}?action=no-matching-event", self.user)
        self.assertEqual(empty.status_code, 200, empty.json())
        self.assertEqual(empty.json()["count"], 0)
        self.assertEqual(empty.json()["results"], [])

    def test_audit_pagination_is_bounded_and_newest_first(self):
        events = [
            self.audit_event(
                action="contract.pagination",
                entity_id=str(number),
                occurred_at=self.now + timedelta(seconds=number // 2),
            )
            for number in range(105)
        ]
        expected = [
            event.pk
            for event in sorted(events, key=lambda event: (event.occurred_at, event.pk), reverse=True)
        ]
        query = urlencode({"action": "contract.pagination"})

        default_page = self.get(f"{AUDIT_LOG_URL}?{query}", self.admin)
        self.assertEqual(default_page.status_code, 200, default_page.json())
        self.assertEqual(default_page.json()["count"], 105)
        self.assertEqual(len(default_page.json()["results"]), 20)

        first_hundred = self.get(
            f"{AUDIT_LOG_URL}?{query}&page_size=1000",
            self.admin,
        )
        self.assertEqual([row["id"] for row in first_hundred.json()["results"]], expected[:100])
        self.assertIsNone(first_hundred.json()["previous"])
        self.assertIsNotNone(first_hundred.json()["next"])
        last_page = self.get(
            f"{AUDIT_LOG_URL}?{query}&page_size=1000&page=2",
            self.admin,
        )
        self.assertEqual([row["id"] for row in last_page.json()["results"]], expected[100:])
        self.assertIsNotNone(last_page.json()["previous"])
        self.assertIsNone(last_page.json()["next"])

    def test_detail_and_list_redact_sensitive_snapshot_values(self):
        markers = (
            "CONTRACT-PRIVATE-PASSWORD",
            "CONTRACT-PRIVATE-ACCESS-TOKEN",
            "CONTRACT-PRIVATE-REFRESH-TOKEN",
            "CONTRACT-PRIVATE-API-KEY",
            "CONTRACT-PRIVATE-CREDENTIAL",
            "CONTRACT-PRIVATE-PAYLOAD",
            "CONTRACT-PRIVATE-AUDIT-METADATA",
        )
        event = self.audit_event(
            actor=self.user,
            actor_label_snapshot=markers[6],
            action=markers[6],
            entity_type=markers[6],
            entity_id=markers[6],
            reason=markers[6],
            before_data={
                "password": markers[0],
                "refresh_token": markers[2],
                "credential": markers[4],
            },
            after_data={
                "access_token": markers[1],
                "api_key": markers[3],
                "private_payload": {"value": markers[5]},
                "status": "PUBLISHED",
            },
        )
        client = jwt_client(self.user)
        query = urlencode({"action": markers[6]})
        responses = (
            client.get(f"{AUDIT_LOG_URL}?{query}"),
            client.get(f"{AUDIT_LOG_URL}{event.pk}/"),
        )
        for response in responses:
            self.assertEqual(response.status_code, 200, response.json())
            payload = response.json()
            entry = payload["results"][0] if "results" in payload else payload
            self.assertTrue(
                {"before_data", "after_data", "reason", "request_id"}.isdisjoint(entry)
            )
            rendered = str(entry)
            for marker in markers:
                self.assertNotIn(marker, rendered)
        self.assertEqual(responses[1].json()["action"], "other")
        self.assertEqual(responses[1].json()["entity_type"], "other")
        self.assertEqual(responses[1].json()["entity_id"], "")

    def test_read_endpoints_cannot_mutate_append_only_audit_records(self):
        count_before = AuditLog.objects.count()
        client = jwt_client(self.admin)
        self.assertEqual(client.get(AUDIT_LOG_URL).status_code, 200)
        self.assertEqual(
            client.get(f"{AUDIT_LOG_URL}{self.event.pk}/").status_code,
            200,
        )
        self.assertEqual(client.get(AUDIT_LOG_FILTERS_URL).status_code, 200)
        self.assertEqual(client.post(AUDIT_LOG_URL, {}, format="json").status_code, 405)
        self.assertEqual(
            client.patch(f"{AUDIT_LOG_URL}{self.event.pk}/", {}, format="json").status_code,
            405,
        )
        self.assertEqual(
            client.put(f"{AUDIT_LOG_URL}{self.event.pk}/", {}, format="json").status_code,
            405,
        )
        self.assertEqual(
            client.delete(f"{AUDIT_LOG_URL}{self.event.pk}/").status_code,
            405,
        )
        self.assertEqual(AuditLog.objects.count(), count_before)

"""Audit display and mocked-view regressions; database access is forbidden."""

import json
from copy import deepcopy
from datetime import datetime, timezone
from html.parser import HTMLParser
from types import SimpleNamespace
from unittest.mock import Mock, patch
from uuid import UUID

from django.contrib.auth.models import AnonymousUser, User
from django.core.exceptions import PermissionDenied
from django.template.loader import render_to_string
from django.test import RequestFactory, SimpleTestCase, override_settings
from django.urls import reverse
from django.utils.html import escape

from audit.forms import AuditLogFilterForm
from audit.templatetags.audit_presentation import (
    _snapshot_values,
    audit_action_label,
    audit_changes,
    audit_detail_kind,
    audit_display_value,
    audit_entity_label,
    audit_field_label,
    audit_json,
    audit_snapshot_notice,
    audit_snapshot_side,
)
from audit.views import AUDIT_RESULT_LIMIT, audit_log_list


def event(before=None, after=None, action="training.trainingversion.published", **extra):
    return SimpleNamespace(
        before_data={} if before is None else before,
        after_data={} if after is None else after,
        action=action,
        entity_type="training.trainingversion",
        entity_id="42",
        actor=None,
        actor_label_snapshot="System",
        reason="",
        occurred_at=datetime(2026, 10, 27, 10, 11, 12, 123456, tzinfo=timezone.utc),
        request_id=UUID("fd4eb014-c0b3-4ee9-a607-bae7018c2b66"),
        **extra,
    )


class AuditPresentationHelpersTests(SimpleTestCase):
    databases = set()

    def test_missing_existing_video_and_assessment_events_have_friendly_names(self):
        labels = {
            "training.videowatchsession.started": "Video watch session started",
            "training.videowatchsession.ended": "Video watch session ended",
            "assessments.questionrevision.updated": "Question revision updated",
            "assessments.questionrevision.frozen": "Question revision frozen",
            "assessments.assessment.created": "Assessment created",
            "assessments.assessment.updated": "Assessment updated",
            "assessments.assessmentquestion.updated": "Assessment question updated",
            "training.role_assignment.batch_created": "Role-based assignments created",
            "training.trainingversion.retired": "Training version retired",
        }
        for code, label in labels.items():
            with self.subTest(code=code):
                self.assertEqual(audit_action_label(code), label)
        self.assertEqual(audit_action_label("unknown.event"), "unknown.event")
        self.assertEqual(audit_entity_label("training.videowatchsession"), "Video watch session")
        self.assertEqual(audit_entity_label("training.roletrainingrequirement"), "Job-role training requirement")

    def test_readable_fields_statuses_and_booleans_preserve_unknown_values(self):
        self.assertEqual(audit_field_label("session_id"), "Video session ID")
        self.assertEqual(audit_field_label("unmapped_field"), "Unmapped field")
        for code, label in (("FROZEN", "Frozen"), ("CANCELLED", "Cancelled"),
                            ("SUBMITTED", "Submitted"), ("EXPIRED", "Expired"),
                            ("ABANDONED", "Abandoned")):
            with self.subTest(code=code):
                self.assertEqual(audit_display_value(code, "status"), label)
        self.assertEqual(audit_display_value(True, "completed_normally"), "Yes")
        self.assertEqual(audit_display_value(False, "completed_normally"), "No")
        self.assertEqual(audit_display_value(None), "Not set")
        self.assertEqual(audit_display_value("FUTURE_STATUS", "status"), "FUTURE_STATUS")
        self.assertEqual(audit_display_value("FROZEN", "title"), "FROZEN")

    def test_full_snapshots_exclude_identical_values_and_ignore_object_key_order(self):
        entry = event(
            {"title": "Safety", "status": "DRAFT", "metadata": {"a": 1, "b": [2]}},
            {"title": "Safety", "status": "PUBLISHED", "metadata": {"b": [2], "a": 1}},
        )
        rows = audit_changes(entry)
        self.assertEqual([row["field"] for row in rows], ["status"])
        self.assertEqual(rows[0]["before"], "DRAFT")
        self.assertEqual(rows[0]["after"], "PUBLISHED")

    def test_changed_fields_does_not_override_actual_comparison_or_omit_recorded_changes(self):
        for changed_fields in ([], ["title"], ["title", "status"]):
            with self.subTest(changed_fields=changed_fields):
                entry = event(
                    {"title": "Same", "status": "DRAFT"},
                    {"title": "Same", "status": "PUBLISHED", "changed_fields": changed_fields},
                )
                self.assertEqual([r["field"] for r in audit_changes(entry)], ["status"])

    def test_uncaptured_changed_fields_are_explicit_and_deduplicated(self):
        entry = event(
            {"title": "Same"},
            {"title": "Same", "changed_fields": ["body", "body", None, 3, "title"]},
        )
        rows = audit_changes(entry)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["field"], "body")
        self.assertFalse(rows[0]["captured"])
        self.assertEqual(rows[0]["before"], "Not recorded")
        self.assertEqual(rows[0]["after"], "Not recorded")

    def test_null_is_distinct_from_missing_and_false_is_distinct_from_zero(self):
        entry = event(
            {"same_null": None, "flag": False, "nested": {"v": True}},
            {"same_null": None, "new_null": None, "flag": 0, "nested": {"v": 1}},
        )
        rows = {r["field"]: r for r in audit_changes(entry)}
        self.assertEqual(set(rows), {"new_null", "flag", "nested"})
        self.assertEqual(rows["new_null"]["before"], "Not recorded")
        self.assertIsNone(rows["new_null"]["after"])

    def test_creation_uses_all_recorded_fields_not_only_client_changed_fields(self):
        entry = event(after={"title": "Safety", "status": "DRAFT", "changed_fields": ["title"]},
                      action="training.trainingversion.created")
        self.assertEqual(audit_detail_kind(entry), "creation")
        self.assertEqual([r["field"] for r in audit_changes(entry)], ["title", "status"])

    def test_one_sided_activity_is_not_mislabelled_as_record_creation(self):
        for code in ("training.videowatchsession.ended", "training.lesson.updated",
                     "training.role_assignment.batch_created", "unknown.event"):
            with self.subTest(code=code):
                self.assertEqual(audit_detail_kind(event(after={"status": "COMPLETED"}, action=code)), "snapshot")
        for code in ("training.videowatchsession.started", "assessments.attempt.started",
                     "certifications.certificate.issued"):
            with self.subTest(code=code):
                self.assertEqual(audit_detail_kind(event(after={"id": 1}, action=code)), "creation")

    def test_missing_or_non_object_snapshots_are_handled_without_inventing_values(self):
        for before, after in (({}, {}), ([], None), (None, [])):
            with self.subTest(before=before, after=after):
                entry = event(before, after)
                self.assertEqual(audit_changes(entry), [])
                self.assertEqual(audit_detail_kind(entry), "snapshot")
                self.assertEqual(audit_snapshot_side(entry), "none")
                self.assertEqual(audit_snapshot_notice(entry), "No field snapshots were recorded.")

    def test_metadata_only_changed_fields_does_not_count_as_snapshot_values(self):
        self.assertEqual(_snapshot_values({"changed_fields": ["body"]}), {})
        self.assertEqual(_snapshot_values({"changed_fields": ["body"], "status": "DRAFT"}), {"status": "DRAFT"})
        self.assertEqual(_snapshot_values([]), {})
        self.assertEqual(_snapshot_values(None), {})

    def test_metadata_only_after_data_is_classified_as_snapshot_not_changes(self):
        entry = event(before={"status": "DRAFT"}, after={"changed_fields": ["body"]})
        self.assertEqual(audit_detail_kind(entry), "snapshot")
        self.assertEqual(audit_snapshot_side(entry), "before")
        self.assertEqual(audit_snapshot_notice(entry), "Only a before snapshot was recorded.")
        rows = audit_changes(entry)
        self.assertEqual([r["field"] for r in rows], ["status", "body"])
        status_row = next(r for r in rows if r["field"] == "status")
        body_row = next(r for r in rows if r["field"] == "body")
        self.assertEqual(status_row["recorded"], "DRAFT")
        self.assertTrue(status_row["captured"])
        self.assertFalse(body_row["captured"])

    def test_metadata_only_after_data_without_before_values_classifies_as_snapshot_with_no_snapshots(self):
        entry = event(before={}, after={"changed_fields": ["body"]})
        self.assertEqual(audit_detail_kind(entry), "snapshot")
        self.assertEqual(audit_snapshot_side(entry), "none")
        self.assertEqual(audit_snapshot_notice(entry), "Only changed field names were recorded without snapshot values.")
        rows = audit_changes(entry)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["field"], "body")
        self.assertFalse(rows[0]["captured"])

    def test_metadata_only_before_data_with_after_values_classifies_as_one_sided_after_snapshot(self):
        entry = event(before={"changed_fields": ["title"]}, after={"status": "PUBLISHED"})
        self.assertEqual(audit_detail_kind(entry), "snapshot")
        self.assertEqual(audit_snapshot_side(entry), "after")
        self.assertEqual(audit_snapshot_notice(entry), "Only an after snapshot was recorded.")

    def test_true_before_and_after_snapshots_with_changed_fields_remain_changes(self):
        entry = event(
            before={"status": "DRAFT"},
            after={"status": "PUBLISHED", "changed_fields": ["status"]},
        )
        self.assertEqual(audit_detail_kind(entry), "changes")
        self.assertEqual(audit_snapshot_side(entry), "both")
        self.assertEqual(audit_snapshot_notice(entry), "")
        rows = audit_changes(entry)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["field"], "status")
        self.assertEqual(rows[0]["before"], "DRAFT")
        self.assertEqual(rows[0]["after"], "PUBLISHED")

    def test_snapshot_notice_explicitly_returns_empty_for_both_snapshots(self):
        for before, after in (
            ({"status": "DRAFT"}, {"status": "PUBLISHED"}),
            ({"status": "DRAFT"}, {"status": "PUBLISHED", "changed_fields": ["status"]}),
            ({"status": "DRAFT"}, {"status": "DRAFT"}),
        ):
            with self.subTest(before=before, after=after):
                entry = event(before=before, after=after)
                self.assertEqual(audit_snapshot_side(entry), "both")
                self.assertEqual(audit_snapshot_notice(entry), "")

    def test_presentation_never_mutates_original_nested_snapshots(self):
        entry = event(
            {"status": "DRAFT", "nested": {"items": [1, None]}},
            {"status": "PUBLISHED", "nested": {"items": [1, None]}, "changed_fields": ["status"]},
        )
        original = deepcopy(vars(entry))
        audit_changes(entry)
        audit_detail_kind(entry)
        audit_snapshot_side(entry)
        audit_snapshot_notice(entry)
        audit_json(entry.before_data)
        audit_json(entry.after_data)
        self.assertEqual(vars(entry), original)


class PreContents(HTMLParser):
    def __init__(self, html):
        super().__init__()
        self.blocks = []
        self.inside = False
        self.feed(html)

    def handle_starttag(self, tag, attrs):
        if tag == "pre":
            self.inside = True
            self.blocks.append("")

    def handle_endtag(self, tag):
        if tag == "pre":
            self.inside = False

    def handle_data(self, data):
        if self.inside:
            self.blocks[-1] += data


class AuditPresentationTemplateTests(SimpleTestCase):
    databases = set()

    def render(self, entries):
        request = RequestFactory().get(reverse("audit:audit-log-list"))
        request.user = AnonymousUser()
        form = AuditLogFilterForm(actors=User.objects.none())
        return render_to_string("audit/audit_log_list.html", {
            "audit_logs": entries, "filter_form": form, "audit_result_limit": AUDIT_RESULT_LIMIT,
        }, request=request)

    def overview(self, html):
        return html.split('<details class="audit-raw">', 1)[0]

    def test_modification_shows_only_real_differences_above_unchanged_original_json(self):
        entry = event({"title": "Same title", "status": "DRAFT"},
                      {"title": "Same title", "status": "PUBLISHED"})
        html = self.render([entry])
        overview = self.overview(html)
        self.assertIn("What changed", overview)
        self.assertIn('<th scope="row">Status</th>', overview)
        self.assertNotIn('<th scope="row">Title</th>', overview)
        self.assertIn("Draft", overview)
        self.assertIn("Published", overview)
        self.assertIn(escape(audit_json(entry.before_data)), html)
        self.assertIn(escape(audit_json(entry.after_data)), html)

    def test_creation_is_a_two_column_recorded_snapshot_not_a_modification(self):
        html = self.render([event(after={"title": "Safety", "status": "DRAFT"},
                                  action="training.trainingversion.created")])
        overview = self.overview(html)
        self.assertIn("New record details", overview)
        self.assertIn("Values recorded when this record was created.", overview)
        self.assertIn('<th scope="col">Recorded value</th>', overview)
        self.assertNotIn("What changed", overview)
        self.assertNotIn('<th scope="col">Before</th>', overview)
        self.assertNotIn("Not recorded", overview)
        self.assertIn('aria-label="Recorded values" tabindex="0"', overview)

    def test_partial_snapshots_explain_comparison_is_unavailable(self):
        for before, after, label in (({}, {"status": "PUBLISHED"}, "after"),
                                     ({"status": "DRAFT"}, {}, "before")):
            with self.subTest(label=label):
                overview = self.overview(self.render([event(before, after)]))
                self.assertIn("Recorded details", overview)
                self.assertIn(f"Only a {label} snapshot was recorded." if label == "before" else "Only an after snapshot was recorded.", overview)
                self.assertIn("Changes cannot be determined without both snapshots.", overview)
                self.assertNotIn("What changed", overview)

    def test_metadata_only_after_data_renders_one_sided_before_snapshot_notice(self):
        entry = event(before={"status": "DRAFT"}, after={"changed_fields": ["body"]})
        overview = self.overview(self.render([entry]))
        self.assertIn("Recorded details", overview)
        self.assertIn("Only a before snapshot was recorded.", overview)
        self.assertIn("Changes cannot be determined without both snapshots.", overview)
        self.assertNotIn("What changed", overview)
        self.assertNotIn("Only an after snapshot was recorded.", overview)
        self.assertIn('<th scope="row">Status</th>', overview)
        self.assertIn("Draft", overview)
        self.assertIn('<th scope="row">Body</th>', overview)
        self.assertIn("Not captured in audit snapshots", overview)

    def test_metadata_only_after_data_without_before_values_renders_notice(self):
        entry = event(before={}, after={"changed_fields": ["body"]})
        overview = self.overview(self.render([entry]))
        self.assertIn("Recorded details", overview)
        self.assertIn("Only changed field names were recorded without snapshot values.", overview)
        self.assertIn("Changes cannot be determined without both snapshots.", overview)
        self.assertNotIn("What changed", overview)
        self.assertNotIn("Only an after snapshot was recorded.", overview)
        self.assertNotIn("Only a before snapshot was recorded.", overview)
        self.assertIn('<th scope="row">Body</th>', overview)
        self.assertIn("Not captured in audit snapshots", overview)

    def test_metadata_only_before_data_renders_one_sided_after_snapshot_notice(self):
        entry = event(before={"changed_fields": ["title"]}, after={"status": "PUBLISHED"})
        overview = self.overview(self.render([entry]))
        self.assertIn("Recorded details", overview)
        self.assertIn("Only an after snapshot was recorded.", overview)
        self.assertIn("Changes cannot be determined without both snapshots.", overview)
        self.assertNotIn("What changed", overview)
        self.assertNotIn("Only a before snapshot was recorded.", overview)

    def test_both_snapshots_state_renders_changes_without_any_snapshot_notices(self):
        for entry in (
            event(before={"status": "DRAFT"}, after={"status": "PUBLISHED"}),
            event(before={"status": "DRAFT"}, after={"status": "PUBLISHED", "changed_fields": ["status"]}),
        ):
            with self.subTest(changed_fields="changed_fields" in entry.after_data):
                overview = self.overview(self.render([entry]))
                self.assertIn("What changed", overview)
                self.assertIn("Draft", overview)
                self.assertIn("Published", overview)
                self.assertNotIn("Recorded details", overview)
                self.assertNotIn("Changes cannot be determined without both snapshots.", overview)
                self.assertNotIn("snapshot was recorded", overview)
                self.assertNotIn("Only changed field names were recorded", overview)
                self.assertNotIn("No field snapshots were recorded", overview)

    def test_identical_snapshots_have_clear_no_difference_message(self):
        overview = self.overview(self.render([event({"status": "DRAFT"}, {"status": "DRAFT"})]))
        self.assertIn("No differences between the recorded before and after values.", overview)
        self.assertNotIn('class="audit-change-table', overview)
        self.assertNotIn("Changes cannot be determined without both snapshots.", overview)
        self.assertNotIn("snapshot was recorded", overview)
        self.assertNotIn("Only changed field names were recorded", overview)
        self.assertNotIn("No field snapshots were recorded", overview)

    def test_none_snapshots_state_without_metadata_renders_empty_details_message(self):
        overview = self.overview(self.render([event({}, {})]))
        self.assertIn("No before-and-after details were recorded for this event.", overview)
        self.assertNotIn("Changes cannot be determined without both snapshots.", overview)
        self.assertNotIn("snapshot was recorded", overview)
        self.assertNotIn("Only changed field names were recorded", overview)
        self.assertNotIn("No field snapshots were recorded", overview)

    def test_uncaptured_content_is_named_without_exposing_unrecorded_values(self):
        html = self.render([event({"title": "Same"}, {"title": "Same", "changed_fields": ["body"]})])
        self.assertIn('<th scope="row">Body</th>', self.overview(html))
        self.assertIn("Listed as changed; values not captured in audit snapshots.", self.overview(html))
        self.assertIn('<td colspan="2">', self.overview(html))
        self.assertNotIn("<textarea", html)

    @override_settings(TIME_ZONE="UTC")
    def test_original_json_roundtrips_and_exact_metadata_stay_in_collapsed_details(self):
        entry = event(
            {"status": "DRAFT", "unicode": "Garden’s", "nested": {"flag": False, "value": 0}},
            {"status": "PUBLISHED", "nested": {"items": [None, True, "</pre><script>unsafe</script>"]}},
        )
        original = deepcopy(vars(entry))
        html = self.render([entry])
        blocks = PreContents(html).blocks
        self.assertEqual(len(blocks), 2)
        self.assertEqual(json.loads(blocks[0]), entry.before_data)
        self.assertEqual(json.loads(blocks[1]), entry.after_data)
        technical = html.split('<details class="audit-raw">', 1)[1]
        self.assertIn("training.trainingversion.published", technical)
        self.assertIn("training.trainingversion", technical)
        self.assertIn("<dd>42</dd>", technical)
        self.assertIn(str(entry.request_id), technical)
        self.assertIn(entry.occurred_at.isoformat(), technical)
        self.assertNotIn('<details class="audit-raw" open', html)
        self.assertEqual(vars(entry), original)
        self.assertNotIn("<script>unsafe</script>", html)

    def test_untrusted_event_names_record_names_reason_actor_and_values_are_escaped(self):
        entry = event({"title": "Old"}, {"title": "<script>new</script>"}, action="<img onerror=unsafe>")
        entry.actor_label_snapshot = "<script>actor</script>"
        entry.reason = "<b>Reason & explanation</b>"
        html = self.render([entry])
        for value in (entry.action, entry.after_data["title"], entry.actor_label_snapshot, entry.reason):
            self.assertIn(escape(value), html)
            self.assertNotIn(value, html)
        self.assertIn("View complete event details", html)

    def test_limit_notice_is_accessible_for_empty_and_populated_results_without_pagination(self):
        for entries in ([], [event(after={"status": "PUBLISHED"})]):
            with self.subTest(empty=not entries):
                html = self.render(entries)
                self.assertIn("Showing up to the 200 newest matching events.", html)
                self.assertIn("If more events match, older matches are not shown.", html)
                self.assertIn("Narrow the filters to find earlier activity.", html)
                self.assertIn('aria-describedby="audit-results-limit"', html)
                self.assertIn('id="audit-results-limit"', html)
                self.assertIn('method="get"', html)
                self.assertNotIn('rel="next"', html)
                self.assertIn('aria-label="Audit history results"', html)


class AuditPresentationViewTests(SimpleTestCase):
    databases = set()

    def setUp(self):
        self.request = RequestFactory().get(reverse("audit:audit-log-list"))
        self.request.user = SimpleNamespace(is_authenticated=True, has_perm=Mock(return_value=True))

    def view(self, *, valid=True, filters=None):
        with patch("audit.views.AuditLog.objects") as manager, \
                patch("audit.views.get_user_model") as users, \
                patch("audit.views.AuditLogFilterForm") as form_class, \
                patch("audit.views.render") as render:
            form = form_class.return_value
            form.is_valid.return_value = valid
            form.cleaned_data = filters or dict(actor=None, action="", start_date=None, end_date=None, target_type="")
            audit_log_list(self.request)
        return manager, users, form_class, render

    def test_query_stays_newest_first_and_limited_to_200_without_count_queries(self):
        manager, _, _, render = self.view()
        logs = manager.select_related.return_value
        logs.order_by.assert_called_once_with("-occurred_at", "-pk")
        logs.order_by.return_value.__getitem__.assert_called_once_with(slice(None, 200))
        self.assertEqual(render.call_args.args[2]["audit_result_limit"], 200)
        self.assertEqual(AUDIT_RESULT_LIMIT, 200)
        manager.count.assert_not_called()
        logs.count.assert_not_called()
        self.request.user.has_perm.assert_called_once_with("audit.view_auditlog")

    def test_existing_filters_are_forwarded_unchanged(self):
        filters = dict(actor="actor", action="video", start_date="2026-10-01",
                       end_date="2026-10-27", target_type=" training.videowatchsession ")
        manager, _, _, _ = self.view(filters=filters)
        query = manager.select_related.return_value
        expected = (("actor", "actor"), ("action__icontains", "video"),
                    ("occurred_at__date__gte", "2026-10-01"),
                    ("occurred_at__date__lte", "2026-10-27"),
                    ("entity_type__iexact", "training.videowatchsession"))
        for key, value in expected:
            query.filter.assert_called_once_with(**{key: value})
            query = query.filter.return_value
        query.order_by.assert_called_once_with("-occurred_at", "-pk")

    def test_invalid_filters_remain_empty_with_400_response(self):
        manager, _, _, render = self.view(valid=False)
        logs = manager.select_related.return_value
        logs.none.assert_called_once_with()
        logs.none.return_value.order_by.return_value.__getitem__.assert_called_once_with(slice(None, 200))
        self.assertEqual(render.call_args.kwargs["status"], 400)

    def test_anonymous_and_unauthorized_users_cannot_load_audit_records(self):
        for user in (AnonymousUser(), SimpleNamespace(is_authenticated=True, has_perm=Mock(return_value=False))):
            with self.subTest(user=user), patch("audit.views.AuditLog.objects") as manager:
                self.request.user = user
                if user.is_authenticated:
                    with self.assertRaises(PermissionDenied):
                        audit_log_list(self.request)
                else:
                    self.assertEqual(audit_log_list(self.request).status_code, 302)
                self.assertEqual(manager.mock_calls, [])

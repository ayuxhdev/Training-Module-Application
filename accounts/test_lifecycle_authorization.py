from contextlib import ExitStack
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

from django.contrib.auth import get_user_model
from django.contrib.auth.models import Group
from django.core.exceptions import PermissionDenied
from django.db.transaction import TransactionManagementError
from django.test import RequestFactory, SimpleTestCase

from api.v1 import assessment_management_services, training_management_services
from assessments import views as assessment_views
from training import views as training_views

from . import lifecycle_authorization as authorization


class LifecycleAuthorizationTests(SimpleTestCase):
    permission = "training.change_trainingversion"

    def setUp(self):
        self.actor = MagicMock(pk=71)
        self.current = MagicMock(pk=71, is_active=True, is_superuser=False)
        self.connection = SimpleNamespace(in_atomic_block=True, vendor="mysql")
        self.enterContext(patch.object(authorization, "connections", {"default": self.connection}))
        self.share_locked_first = authorization._share_locked_first
        self.lock = self.enterContext(patch.object(authorization, "_share_locked_first"))
        permissions = self.enterContext(patch.object(authorization.Permission, "objects"))
        permissions.using.return_value.filter.return_value.values_list.return_value = [4]
        self.grant_queryset = self.enterContext(patch.object(Group.permissions.through, "objects"))
        self.grant_queryset.using.return_value.filter.return_value.order_by.return_value.values_list.return_value = [(2, 9)]

    def require(self):
        return authorization.require_lifecycle_permission(self.actor, self.permission, using="default")

    def test_requires_mysql_atomic_block(self):
        for vendor, active in (("mysql", False), ("sqlite", True)):
            with self.subTest(vendor=vendor, active=active):
                self.connection.vendor = vendor
                self.connection.in_atomic_block = active
                with self.assertRaises(TransactionManagementError):
                    self.require()
        self.lock.assert_not_called()

    def test_missing_inactive_and_revoked_actor_ignore_cached_permission(self):
        for current in (None, SimpleNamespace(is_active=False), self.current):
            with self.subTest(current=current):
                self.current.has_perm.return_value = False
                self.lock.reset_mock()
                self.lock.return_value = current
                with self.assertRaises(PermissionDenied):
                    self.require()
                self.lock.assert_called_once()
        self.actor.has_perm.assert_not_called()

    def test_superuser_authority_is_held_on_user_row(self):
        self.current.is_superuser = True
        self.lock.return_value = self.current
        self.assertIs(self.require(), self.current)
        self.lock.assert_called_once()

    def test_direct_authority_requires_live_grant(self):
        self.lock.side_effect = [self.current, SimpleNamespace(pk=3)]
        self.assertIs(self.require(), self.current)
        self.assertIs(self.lock.call_args.args[0].model, get_user_model().user_permissions.through)

    def test_group_authority_requires_live_group_grant_and_membership(self):
        for locked in ((None,), (True, None), (True, True, None), (True, True, True)):
            with self.subTest(locked=locked):
                self.lock.reset_mock(side_effect=True)
                self.lock.side_effect = [self.current, None, *locked]
                if all(locked):
                    self.assertIs(self.require(), self.current)
                else:
                    with self.assertRaises(PermissionDenied):
                        self.require()
                group, grant, membership = [call.args[0] for call in self.lock.call_args_list][2:] + [None] * (3 - len(locked))
                self.assertIs(group.model, Group)
                if grant is not None:
                    self.assertEqual(grant, self.grant_queryset.using.return_value.filter.return_value)
                if membership is not None:
                    self.assertIs(membership.model, get_user_model().groups.through)

    def test_lock_statement_preserves_parameters_and_uses_shared_lock(self):
        query = MagicMock(db="default")
        limited = query.order_by.return_value.__getitem__.return_value
        limited.query.get_compiler.return_value.as_sql.return_value = ("SELECT id FROM auth_user WHERE id = %s LIMIT 1", (71,))
        query.model._default_manager.raw.return_value = [self.current]
        self.assertIs(self.share_locked_first(query), self.current)
        query.model._default_manager.raw.assert_called_once_with(
            "SELECT id FROM auth_user WHERE id = %s LIMIT 1 FOR SHARE", (71,), using="default",
        )


class LifecycleEntrypointTests(SimpleTestCase):
    def test_late_denial_precedes_all_mutation_and_audit(self):
        request = RequestFactory().post("/")
        request.user = MagicMock(is_authenticated=True, pk=71)
        instance = MagicMock(_state=SimpleNamespace(db="default"), status="DRAFT")
        cases = (
            (training_views, "get_object_or_404", training_views.publish_version, (request, 1), {}),
            (training_views, "get_object_or_404", training_views.retire_version, (request, 1), {}),
            (assessment_views, "_locked_draft_revision", assessment_views.freeze_question_revision, (request, 1), {}),
            (assessment_views, "_locked_draft_revision", assessment_views.edit_question_revision, (request, 1), {}),
            (training_management_services, "get_object_or_404", training_management_services.transition_version,
             (request.user, 1), {"publish": True}),
            (assessment_management_services, "_locked_revision", assessment_management_services.freeze_revision,
             (request.user, 1, 1, {}), {}),
            (assessment_management_services, "_locked_revision", assessment_management_services.update_revision,
             (request.user, 1, 1, {}), {}),
        )
        for module, lookup_name, operation, args, kwargs in cases:
            with self.subTest(operation=operation.__name__), ExitStack() as stack:
                stack.enter_context(patch("django.db.transaction.Atomic.__enter__"))
                stack.enter_context(patch("django.db.transaction.Atomic.__exit__", return_value=False))
                lookup = stack.enter_context(patch.object(module, lookup_name, return_value=instance))
                audit = stack.enter_context(patch.object(module, "record_event"))

                def deny(actor, permission, *, using):
                    lookup.assert_called_once()
                    raise PermissionDenied

                stack.enter_context(patch.object(module, "require_lifecycle_permission", side_effect=deny))
                with self.assertRaises(PermissionDenied):
                    operation(*args, **kwargs)
                instance.save.assert_not_called()
                audit.assert_not_called()

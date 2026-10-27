"""Assignment authority, separate from assignment viewing and company reporting."""

from organization.models import Employee
from organization.scopes import employee_scope


COMPANY_ASSIGNMENT_PERMISSION = "training.add_trainingassignment"
TEAM_ASSIGNMENT_PERMISSION = "training.assign_team_trainingassignment"


def _active_user(user):
    return bool(user and user.is_authenticated and user.is_active)


def can_assign_company_training(user):
    # Management-only accounts do not need a linked Employee for global rights.
    return _active_user(user) and user.has_perm(COMPANY_ASSIGNMENT_PERMISSION)


def can_assign_team_training(user):
    return (
        _active_user(user)
        and user.has_perm(TEAM_ASSIGNMENT_PERMISSION)
        and user.groups.filter(name="Manager").exists()
        and Employee.objects.filter(user=user, is_active=True).exists()
    )


def assignable_employees(user):
    """Active assignment recipients within the actor's effective authority."""
    if can_assign_company_training(user):
        return Employee.objects.filter(is_active=True)
    if can_assign_team_training(user):
        return employee_scope(user).filter(is_active=True).exclude(user=user)
    return Employee.objects.none()

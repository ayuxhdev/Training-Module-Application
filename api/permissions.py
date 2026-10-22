from rest_framework.permissions import BasePermission

from .capabilities import can_use_mobile


class IsMobileAccount(BasePermission):
    """Identity access for eligible learners or explicitly authorized portal users."""

    def has_permission(self, request, view):
        return can_use_mobile(request.user)

class IsActiveEmployee(BasePermission):
    """
    Allows access only to authenticated users who have an active Employee record.
    """

    def has_permission(self, request, view):
        user = request.user
        if not user or not user.is_authenticated:
            return False
            
        # Check if the user has an associated Employee record and it's active
        return hasattr(user, 'employee') and user.employee.is_active


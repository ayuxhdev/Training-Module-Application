"""Shared reporting-hierarchy scope; callers apply their operation-specific rules."""

from .models import Employee


def employee_scope(user):
	employee = Employee.objects.filter(user=user).first()
	if not employee:
		return Employee.objects.none()
	if not user.groups.filter(name="Manager").exists():
		return Employee.objects.filter(pk=employee.pk)
	ids = {employee.pk}
	pending = {employee.pk}
	while pending:
		child_ids = set(Employee.objects.filter(reporting_manager_id__in=pending).values_list("pk", flat=True)) - ids
		ids.update(child_ids)
		pending = child_ids
	return Employee.objects.filter(pk__in=ids)

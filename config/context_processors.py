from organization.models import Employee
from reports.queries import dashboard_role


def shell_navigation(request):
	user = request.user
	if not user.is_authenticated:
		return {"shell_role": None, "shell_can_view_certificates": False}
	return {
		"shell_role": dashboard_role(user),
		"shell_can_view_certificates": user.has_perm("certifications.view_certificate")
		or Employee.objects.filter(user=user, is_active=True).exists(),
	}

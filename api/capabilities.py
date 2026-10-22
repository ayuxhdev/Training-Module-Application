"""Mobile discovery only; business endpoints still enforce their own permissions/scope."""

# Deliberately exclude framework User/Group/token administration.
PORTAL_PERMISSIONS = tuple(
    f"{app}.{action}_{model}"
    for app, models in (
        ("organization", ("employee", "department", "jobrole")),
        ("training", ("training", "trainingversion", "module", "lesson")),
        ("assessments", ("question", "questionrevision", "questionoption", "assessment", "assessmentquestion")),
    )
    for model in models
    for action in ("view", "add", "change")
) + (
    "training.add_trainingassignment",
    "certifications.view_certificate",
    "certifications.change_certificate",
    "audit.view_auditlog",
)

REFERENCE_PERMISSIONS = {
    "organization.view_employee", "organization.view_department", "organization.view_jobrole",
}


def mobile_capabilities(user):
    if not user or not user.is_authenticated or not user.is_active:
        return []
    employee = getattr(user, "employee", None)
    # An inactive linked Employee must not regain access through management grants.
    if employee is not None and not employee.is_active:
        return []
    capabilities = {permission for permission in PORTAL_PERMISSIONS if user.has_perm(permission)}
    if employee is None and not user.has_perm("organization.change_employee"):
        capabilities.discard("organization.view_employee")
    if capabilities - REFERENCE_PERMISSIONS:
        capabilities.add("management_workspace")
    if employee is not None:
        capabilities.add("personal_learning")
        # Match the existing portal hierarchy gate; this grants no management mutation.
        if user.groups.filter(name="Manager").exists():
            capabilities.add("team_workspace")
    if user.has_perm("training.add_trainingassignment"):
        capabilities.add("company_dashboard")
        capabilities.add("assignment_report")
    elif "team_workspace" in capabilities:
        capabilities.add("assignment_report")
    return sorted(capabilities)


def can_use_mobile(user):
    return bool(set(mobile_capabilities(user)) & {
        "personal_learning", "management_workspace", "team_workspace",
    })

from django.urls import path

from . import views


app_name = "certifications"

urlpatterns = [
    path("", views.certificate_list, name="certificate-list"),
    path("<int:pk>/", views.certificate_detail, name="certificate-detail"),
    path("<int:pk>/revoke/", views.revoke_certificate, name="certificate-revoke"),
]
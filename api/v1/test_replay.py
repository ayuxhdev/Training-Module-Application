from datetime import timedelta

from django.urls import reverse
from rest_framework.test import APIClient
from rest_framework_simplejwt.tokens import RefreshToken

from config.model_test_utils import CurriculumTestCase
from training.test_replay import ReplayPolicyChecks


class VideoReplayAPITests(ReplayPolicyChecks, CurriculumTestCase):
    namespace = "api:v1"

    def setUp(self):
        self.client = APIClient()
        super().setUp()

    def auth_as(self, user):
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {RefreshToken.for_user(user).access_token}")

    def sign_out(self):
        self.client.credentials()

    def test_api_exposes_replay_capability_and_keeps_media_errors_in_api_contract(self):
        before = self.history()
        response = self.client.get(reverse("api:v1:assignment-detail", args=[self.assignment.pk]))
        self.assertEqual(response.status_code, 200)
        lessons = response.data["modules"][0]["lessons"]
        video = next(lesson for lesson in lessons if lesson["id"] == self.video_lesson.pk)
        self.assertEqual(video["playback_mode"], "read_only_replay")
        self.assertNotIn("video_file", video)
        self.assertNotIn("media_url", video)
        response = self.client.get(self.replay_url(), HTTP_RANGE="bytes=999-")
        self.assertEqual(response.status_code, 416)
        self.assertEqual(response.data["error"]["code"], "range_not_satisfiable")
        self.sign_out()
        response = self.client.get(self.replay_url())
        self.assertEqual(response.status_code, 401)
        self.assertIn("error", response.data)
        self.assertEqual(before, self.history())

    def test_replay_rejects_expired_jwt_and_session_only_authentication(self):
        token = RefreshToken.for_user(self.employee_user).access_token
        token.set_exp(lifetime=timedelta(seconds=-1))
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
        before = self.history()
        self.assertEqual(self.client.get(self.replay_url()).status_code, 401)
        self.sign_out()
        self.client.force_login(self.employee_user)
        self.assertEqual(self.client.get(self.replay_url()).status_code, 401)
        self.assertEqual(before, self.history())

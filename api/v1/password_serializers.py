from collections.abc import Mapping

from rest_framework import serializers
from rest_framework.settings import api_settings


class PasswordChangeSerializer(serializers.Serializer):
    current_password = serializers.CharField(write_only=True, trim_whitespace=False, max_length=4096)
    new_password = serializers.CharField(write_only=True, trim_whitespace=False, max_length=4096)
    confirm_password = serializers.CharField(write_only=True, trim_whitespace=False, max_length=4096)

    def to_internal_value(self, data):
        error_key = api_settings.NON_FIELD_ERRORS_KEY
        if not isinstance(data, Mapping):
            raise serializers.ValidationError({error_key: ["Request body must be an object."]})
        if set(data) - set(self.fields):
            raise serializers.ValidationError({error_key: ["Only password fields are accepted."]})
        return super().to_internal_value(data)

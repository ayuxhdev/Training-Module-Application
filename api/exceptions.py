from rest_framework.views import exception_handler
from rest_framework.exceptions import APIException

def custom_exception_handler(exc, context):
    """
    Custom exception handler that wraps all DRF exceptions in a predictable
    error envelope for Android/mobile clients.
    
    Expected format:
    {
      "error": {
        "code": "...",
        "message": "...",
        "fields": {...}
      }
    }
    """
    # Call REST framework's default exception handler first to get the standard error response
    response = exception_handler(exc, context)

    if response is None:
        return None  # Let Django handle unhandled/500 exceptions normally

    # Build the custom envelope
    error_payload = {
        "code": getattr(exc, "default_code", "error"),
        "message": "An error occurred.",
        "fields": {}
    }

    # Only override if the exception didn't provide a useful code
    if error_payload["code"] == "error":
        if response.status_code == 404:
            error_payload["code"] = "not_found"
        elif response.status_code == 401:
            error_payload["code"] = "not_authenticated"
        elif response.status_code == 403:
            error_payload["code"] = "permission_denied"

    # Extract details and fields based on standard DRF formats
    if isinstance(response.data, dict):
        if "detail" in response.data:
            # Typically AuthenticationFailed, NotAuthenticated, PermissionDenied, NotFound, etc.
            error_payload["message"] = str(response.data.get("detail"))
        else:
            # Typically ValidationError dict: {"field1": ["error1"], "field2": ["error2"]}
            error_payload["code"] = getattr(exc, "default_code", "validation_error")
            if error_payload["code"] == "invalid":
                error_payload["code"] = "validation_error"
            error_payload["message"] = "Invalid input."
            error_payload["fields"] = response.data
    elif isinstance(response.data, list):
        # Typically a top-level ValidationError list
        error_payload["code"] = getattr(exc, "default_code", "validation_error")
        if error_payload["code"] == "invalid":
            error_payload["code"] = "validation_error"
        error_payload["message"] = " ".join(str(item) for item in response.data) if response.data else "Invalid input."

    response.data = {"error": error_payload}
    return response


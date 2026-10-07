class ApiError implements Exception {
  final String message;
  final int? statusCode;
  final String? code;
  final dynamic details;

  ApiError({
    required this.message,
    this.statusCode,
    this.code,
    this.details,
  });

  @override
  String toString() {
    if (statusCode != null) {
      return 'ApiError [$statusCode]: $message';
    }
    return 'ApiError: $message';
  }

  factory ApiError.networkFailure() {
    return ApiError(
      message: 'Network connection failed. Please check your internet connection.',
      code: 'network_failure',
    );
  }

  factory ApiError.timeout() {
    return ApiError(
      message: 'The connection timed out. Please try again.',
      code: 'timeout',
    );
  }

  factory ApiError.unexpected() {
    return ApiError(
      message: 'An unexpected error occurred. Please try again later.',
      code: 'unexpected',
    );
  }

  factory ApiError.fromBackend(int statusCode, Map<String, dynamic> data) {
    // Attempt to extract structured error details if they exist.
    // The backend sometimes returns {"error": "..."} or {"detail": "..."}
    final message = data['error'] ?? data['detail'] ?? 'An API error occurred.';
    return ApiError(
      message: message.toString(),
      statusCode: statusCode,
      details: data,
    );
  }
}


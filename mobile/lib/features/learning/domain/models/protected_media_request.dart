/// Transient native-player configuration. Never persist the headers.
class ProtectedMediaRequest {
  final Uri uri;
  final Map<String, String> headers;

  ProtectedMediaRequest({
    required this.uri,
    required Map<String, String> headers,
  }) : headers = Map.unmodifiable(headers);

  @override
  String toString() => 'ProtectedMediaRequest($uri)';
}

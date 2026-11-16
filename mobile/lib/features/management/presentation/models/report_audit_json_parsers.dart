/// Safe, explicit typed readers for report and audit JSON deserialization.
///
/// Prevents raw [TypeError] exceptions from escaping and ensures malformed
/// authoritative server responses fail closed with a clear [FormatException].
class TypedJsonReader {
  TypedJsonReader._();

  static int readRequiredInt(
    Map<String, dynamic> json,
    String key, {
    int? minValue,
  }) {
    final value = json[key];
    if (value is! int) {
      throw FormatException(
        'Invalid or missing required integer field "$key".',
      );
    }
    if (minValue != null && value < minValue) {
      throw FormatException('Field "$key" must be at least $minValue.');
    }
    return value;
  }

  static int? readOptionalInt(
    Map<String, dynamic> json,
    String key, {
    int? minValue,
  }) {
    final value = json[key];
    if (value == null) return null;
    if (value is! int) {
      throw FormatException('Invalid integer field "$key".');
    }
    if (minValue != null && value < minValue) {
      throw FormatException('Field "$key" must be at least $minValue.');
    }
    return value;
  }

  static bool readRequiredBool(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! bool) {
      throw FormatException(
        'Invalid or missing required boolean field "$key".',
      );
    }
    return value;
  }

  static bool? readOptionalBool(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! bool) {
      throw FormatException('Invalid boolean field "$key".');
    }
    return value;
  }

  static String readRequiredString(
    Map<String, dynamic> json,
    String key, {
    bool allowEmpty = true,
  }) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('Invalid or missing required string field "$key".');
    }
    final trimmed = value.trim();
    if (!allowEmpty && trimmed.isEmpty) {
      throw FormatException('Required string field "$key" must not be empty.');
    }
    return trimmed;
  }

  static String? readOptionalString(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String) {
      throw FormatException('Invalid string field "$key".');
    }
    return value.trim();
  }

  static DateTime readRequiredDateTime(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String) {
      throw FormatException(
        'Invalid or missing required timestamp field "$key".',
      );
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw FormatException('Invalid timestamp format for field "$key".');
    }
    return parsed;
  }

  static DateTime? readOptionalDateTime(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return null;
    if (value is! String) {
      throw FormatException('Invalid timestamp field "$key".');
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw FormatException('Invalid timestamp format for field "$key".');
    }
    return parsed;
  }

  static String readEnumString(
    Map<String, dynamic> json,
    String key,
    Set<String> validValues,
  ) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('Invalid or missing required enum field "$key".');
    }
    final normalized = value.trim().toUpperCase();
    if (!validValues.contains(normalized)) {
      throw FormatException(
        'Invalid value "$value" for field "$key". Expected one of: ${validValues.join(", ")}.',
      );
    }
    return normalized;
  }

  static List<dynamic> readOptionalList(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value == null) return const [];
    if (value is! List) {
      throw FormatException('Field "$key" must be a list.');
    }
    return value;
  }

  static Map<String, dynamic> readMap(dynamic item, String contextName) {
    if (item is! Map<String, dynamic>) {
      throw FormatException(
        'Invalid $contextName element; expected JSON object.',
      );
    }
    return item;
  }
}

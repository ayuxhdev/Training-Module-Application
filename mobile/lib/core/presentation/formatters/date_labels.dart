/// Calendar date in the device timezone, including when the server sends UTC.
String localDateLabel(DateTime value) => _calendarDateLabel(value.toLocal());

/// Calendar date of an assignment deadline in the API representation.
/// Dart parses offset-bearing timestamps as UTC, matching Django's timezone.
/// Legacy date-only fields retain their calendar date without conversion.
String assignmentDeadlineLabel(DateTime value) => _calendarDateLabel(value);

String _calendarDateLabel(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

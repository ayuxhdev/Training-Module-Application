import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/presentation/formatters/date_labels.dart';

void main() {
  test('deadlines keep the API day across offset boundaries', () {
    expect(
      assignmentDeadlineLabel(DateTime.parse('2026-11-26T23:59:59.999999Z')),
      '2026-11-26',
    );
    expect(
      assignmentDeadlineLabel(DateTime.parse('2026-11-27T05:29:59+05:30')),
      '2026-11-26',
    );
  });

  test('legacy date-only deadlines retain their calendar fields', () {
    expect(assignmentDeadlineLabel(DateTime.parse('2026-03-04')), '2026-03-04');
  });

  test('other date labels continue to use the device timezone', () {
    final value = DateTime.parse('2026-11-26T23:59:59Z');
    final local = value.toLocal();
    expect(
      localDateLabel(value),
      '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}',
    );
  });
}

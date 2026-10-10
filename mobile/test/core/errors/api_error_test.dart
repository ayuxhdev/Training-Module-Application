import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/errors/api_error.dart';

void main() {
  test('parses structured backend message, code and field errors', () {
    final fields = {
      'username': ['Required.'],
    };
    final error = ApiError.fromBackend(400, {
      'error': {
        'message': 'Invalid input.',
        'code': 'validation_error',
        'fields': fields,
      },
    });
    expect(error.message, 'Invalid input.');
    expect(error.code, 'validation_error');
    expect(error.details, fields);
    expect(error.statusCode, 400);
  });

  test('preserves legacy error and detail responses', () {
    for (final key in ['error', 'detail']) {
      final data = {key: 'Not allowed.'};
      final error = ApiError.fromBackend(403, data);
      expect(error.message, 'Not allowed.');
      expect(error.details, data);
    }
  });

  test('malformed or missing error values produce a readable fallback', () {
    for (final error in [
      null,
      42,
      {},
      {'message': [], 'code': 42},
      {'message': ''},
    ]) {
      final parsed = ApiError.fromBackend(500, {'error': error});
      expect(parsed.message, 'An API error occurred.');
      expect(parsed.code, isNull);
    }
  });
}

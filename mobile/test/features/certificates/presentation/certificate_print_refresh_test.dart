import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:training_app/core/errors/api_error.dart';
import 'package:training_app/features/auth/domain/models/auth_state.dart';
import 'package:training_app/features/auth/domain/models/employee.dart';
import 'package:training_app/features/auth/presentation/controllers/auth_controller.dart';
import 'package:training_app/features/certificates/data/services/certificate_pdf_generator.dart';
import 'package:training_app/features/certificates/data/services/certificate_print_service.dart';
import 'package:training_app/features/certificates/domain/models/certificate_print_data.dart';
import 'package:training_app/features/certificates/presentation/widgets/certificate_print_section.dart';

CertificatePrintData _record({
  int id = 42,
  bool revoked = false,
  String title = 'Loaded title',
}) => CertificatePrintData(
  certificateId: id,
  certificateNumber: 'SERVER-$id',
  employeeName: 'Server employee',
  employeeCode: 'EMP-42',
  trainingTitle: title,
  versionNumber: 3,
  issuedAt: DateTime.utc(2026, 6, 15),
  isRevoked: revoked,
  revokedAt: revoked ? DateTime.utc(2026, 11, 16) : null,
  revocationReason: revoked ? 'Server revocation reason' : null,
);

class _Auth extends AuthController {
  AuthState _identity(String name) => AuthAuthenticated(
    Employee(
      username: name,
      employeeCode: name,
      displayName: name,
      department: 'QA',
      jobRole: 'Employee',
      isActive: true,
    ),
  );
  @override
  AuthState build() => _identity('original');
  void switchUser(String name) => state = _identity(name);
}

class _Printer implements CertificatePrintService {
  final records = <CertificatePrintData>[];
  bool result = true;
  @override
  Future<Uint8List> generatePdf(
    CertificatePrintData data, {
    PdfPageFormat format = PdfPageFormat.a4,
  }) async => Uint8List(0);
  @override
  Future<bool> printCertificate(
    CertificatePrintData data, {
    PdfPageFormat format = PdfPageFormat.a4,
    bool Function()? canPrint,
  }) async {
    if (canPrint?.call() == false) return false;
    records.add(data);
    return result;
  }
}

class _DelayedGeneration extends PlatformCertificatePrintService {
  final generated = Completer<Uint8List>();
  @override
  Future<Uint8List> generatePdf(
    CertificatePrintData data, {
    PdfPageFormat format = PdfPageFormat.a4,
  }) => generated.future;
}

void main() {
  late _Auth auth;
  late _Printer printer;
  late ProviderContainer container;
  setUp(() {
    auth = _Auth();
    printer = _Printer();
    container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWith(() => auth),
        certificatePrintServiceProvider.overrideWithValue(printer),
      ],
    );
  });
  tearDown(() => container.dispose());

  Future<void> show(
    WidgetTester tester,
    Future<CertificatePrintData> Function(CancelToken) refresh,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: CertificatePrintSection(
              printData: _record(),
              refresh: refresh,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester) async {
    await tester.tap(find.text('Print / Save as PDF'));
    await tester.pump();
  }

  testWidgets('neutral print wording has no accreditation or signature claim', (
    tester,
  ) async {
    await show(tester, (_) async => _record());
    expect(
      find.textContaining('Print or save a copy of this certificate.'),
      findsOneWidget,
    );
    expect(find.textContaining('accredited'), findsNothing);
    expect(find.textContaining('digitally signed'), findsNothing);
    expect(find.text('Print / Save as PDF'), findsOneWidget);
  });

  testWidgets('print uses refreshed server fields, never cached title', (
    tester,
  ) async {
    var requests = 0;
    await show(tester, (_) async {
      requests++;
      return _record(title: 'Fresh server title');
    });
    await tap(tester);
    await tester.pumpAndSettle();
    expect(requests, 1);
    expect(printer.records.single.trainingTitle, 'Fresh server title');
    expect(printer.records.single.certificateNumber, 'SERVER-42');
    expect(printer.records.single.versionNumber, 3);
  });

  testWidgets(
    'revocation after screen load is preserved by fresh print payload',
    (tester) async {
      await show(tester, (_) async => _record(revoked: true));
      await tap(tester);
      await tester.pumpAndSettle();
      expect(printer.records.single.isRevoked, isTrue);
      expect(printer.records.single.revokedAt, DateTime.utc(2026, 11, 16));
      expect(
        printer.records.single.revocationReason,
        'Server revocation reason',
      );
    },
  );

  for (final status in [401, 403, 404]) {
    testWidgets('refresh HTTP $status never prints loaded certificate', (
      tester,
    ) async {
      await show(
        tester,
        (_) async => throw ApiError(
          message: 'private JWT diagnostic',
          statusCode: status,
        ),
      );
      await tap(tester);
      await tester.pumpAndSettle();
      expect(printer.records, isEmpty);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('private JWT'), findsNothing);
      expect(find.text('Retry'), findsNothing);
    });
  }

  for (final error in [ApiError.networkFailure(), ApiError.timeout()]) {
    testWidgets(
      'refresh ${error.code} prevents stale print and allows explicit retry',
      (tester) async {
        var requests = 0;
        await show(tester, (_) async {
          requests++;
          if (requests == 1) throw error;
          return _record(title: 'Recovered server title');
        });
        await tap(tester);
        await tester.pumpAndSettle();
        expect(printer.records, isEmpty);
        expect(requests, 1); // No automatic print retry.
        expect(find.textContaining('Check your connection'), findsOneWidget);
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(requests, 2);
        expect(printer.records.single.trainingTitle, 'Recovered server title');
      },
    );
  }

  testWidgets('duplicate taps during refresh are ignored', (tester) async {
    final pending = Completer<CertificatePrintData>();
    var requests = 0;
    await show(tester, (_) {
      requests++;
      return pending.future;
    });
    await tap(tester);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.onPressed, isNull);
    expect(requests, 1);
    pending.complete(_record());
    await tester.pumpAndSettle();
    expect(printer.records, hasLength(1));
  });

  testWidgets(
    'account switch cancels refresh and rejects late data even after switching back',
    (tester) async {
      final pending = Completer<CertificatePrintData>();
      CancelToken? token;
      await show(tester, (requests) {
        token = requests;
        return pending.future;
      });
      await tap(tester);
      auth.switchUser('different-account');
      await tester.pump();
      expect(token!.isCancelled, isTrue);
      auth.switchUser('original');
      await tester.pump();
      pending.complete(_record());
      await tester.pumpAndSettle();
      expect(printer.records, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    },
  );

  testWidgets(
    'disposal cancels pending refresh without print or late UI updates',
    (tester) async {
      final pending = Completer<CertificatePrintData>();
      CancelToken? token;
      await show(tester, (requests) {
        token = requests;
        return pending.future;
      });
      await tap(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(token!.isCancelled, isTrue);
      pending.complete(_record());
      await tester.pumpAndSettle();
      expect(printer.records, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending refresh deadline cancels request and never falls back to cached data',
    (tester) async {
      final pending = Completer<CertificatePrintData>();
      CancelToken? token;
      await show(tester, (requests) {
        token = requests;
        return pending.future;
      });
      await tap(tester);
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(token!.isCancelled, isTrue);
      expect(printer.records, isEmpty);
      expect(find.textContaining('Check your connection'), findsOneWidget);
      pending.complete(_record());
      await tester.pumpAndSettle();
      expect(printer.records, isEmpty);
    },
  );

  testWidgets('unexpected certificate ID in refresh is not printed', (
    tester,
  ) async {
    await show(tester, (_) async => _record(id: 99));
    await tap(tester);
    await tester.pumpAndSettle();
    expect(printer.records, isEmpty);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('native print cancellation is clean and is not replayed', (
    tester,
  ) async {
    printer.result = false;
    var requests = 0;
    await show(tester, (_) async {
      requests++;
      return _record();
    });
    await tap(tester);
    await tester.pumpAndSettle();
    expect(printer.records, hasLength(1));
    expect(requests, 1);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Print / Save as PDF'), findsOneWidget);
  });

  test('production service rejects owner change during PDF generation before native handoff', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final channelCalls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('net.nfet.printing'), (
          call,
        ) async {
          channelCalls.add(call);
          return true;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('net.nfet.printing'),
            null,
          );
    });

    final service = _DelayedGeneration();
    var current = true;
    final running = service.printCertificate(
      _record(),
      canPrint: () => current,
    );
    current = false;
    service.generated.complete(Uint8List.fromList([37, 80, 68, 70]));
    expect(await running, isFalse);
    expect(
      channelCalls,
      isEmpty,
      reason: 'Native print handoff must not be reached when context changes.',
    );
  });

  test('production service prevents previous account bytes from crossing platform channel when account changes before onLayout', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final defaultBinaryMessenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    final channelCalls = <MethodCall>[];
    int? capturedJobId;

    defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('net.nfet.printing'),
      (call) async {
        channelCalls.add(call);
        if (call.method == 'printPdf') {
          capturedJobId = call.arguments['job'] as int?;
          return 1;
        }
        return true;
      },
    );
    addTearDown(() {
      defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('net.nfet.printing'),
        null,
      );
    });

    final service = PlatformCertificatePrintService(
      generator: CertificatePdfGenerator(
        regularFont: pw.Font.helvetica(),
        boldFont: pw.Font.helveticaBold(),
      ),
    );

    var canPrint = true;
    unawaited(service.printCertificate(
      _record(),
      canPrint: () => canPrint,
    ));

    // Allow PDF generation to complete and printPdf to be dispatched to native channel
    await Future<void>.delayed(Duration.zero);
    expect(channelCalls.map((c) => c.method), contains('printPdf'));
    expect(capturedJobId, isNotNull);

    // Account switch occurs: canPrint becomes false before native requests onLayout
    canPrint = false;

    // Simulate Native OS dispatching 'onLayout' callback back into Flutter
    final onLayoutMessage = const StandardMethodCodec().encodeMethodCall(
      MethodCall('onLayout', {
        'job': capturedJobId,
        'width': 595.28,
        'height': 841.89,
        'marginLeft': 0.0,
        'marginTop': 0.0,
        'marginRight': 0.0,
        'marginBottom': 0.0,
      }),
    );

    ByteData? responseBytes;
    await defaultBinaryMessenger.handlePlatformMessage(
      'net.nfet.printing',
      onLayoutMessage,
      (data) {
        responseBytes = data;
      },
    );

    // The response returned from Flutter to Native is NOT valid PDF bytes.
    // It must be an error envelope (PlatformException) because onLayout threw ApiError(code: 'print_cancelled').
    expect(
      () => const StandardMethodCodec().decodeEnvelope(responseBytes!),
      throwsA(
        isA<PlatformException>().having(
          (e) => e.message,
          'message',
          contains('The print context changed'),
        ),
      ),
      reason: 'Previous account PDF bytes must never cross platform channel on account switch.',
    );
  });

  test('after Android rejects layout on account switch, printing finishes cancellation and current account can print cleanly', () async {
    final defaultBinaryMessenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    final channelCalls = <MethodCall>[];
    final capturedJobIds = <int>[];

    defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('net.nfet.printing'),
      (call) async {
        channelCalls.add(call);
        if (call.method == 'printPdf') {
          final job = call.arguments['job'] as int?;
          if (job != null) capturedJobIds.add(job);
          return 1;
        }
        return true;
      },
    );
    addTearDown(() {
      defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('net.nfet.printing'),
        null,
      );
    });

    final service = PlatformCertificatePrintService(
      generator: CertificatePdfGenerator(
        regularFont: pw.Font.helvetica(),
        boldFont: pw.Font.helveticaBold(),
      ),
    );

    // User 1 initiates print
    var user1CanPrint = true;
    unawaited(service.printCertificate(
      _record(id: 101, title: 'User 1 Training'),
      canPrint: () => user1CanPrint,
    ));

    await Future<void>.delayed(Duration.zero);
    expect(capturedJobIds.length, 1);
    final user1JobId = capturedJobIds.first;

    // User 1 switches account -> user1CanPrint becomes false
    user1CanPrint = false;

    // Native sends onLayout for User 1's job
    final user1OnLayout = const StandardMethodCodec().encodeMethodCall(
      MethodCall('onLayout', {
        'job': user1JobId,
        'width': 595.28,
        'height': 841.89,
        'marginLeft': 0.0,
        'marginTop': 0.0,
        'marginRight': 0.0,
        'marginBottom': 0.0,
      }),
    );

    ByteData? user1ResponseBytes;
    await defaultBinaryMessenger.handlePlatformMessage(
      'net.nfet.printing',
      user1OnLayout,
      (data) => user1ResponseBytes = data,
    );

    // Verify error envelope returned
    expect(
      () => const StandardMethodCodec().decodeEnvelope(user1ResponseBytes!),
      throwsA(isA<PlatformException>().having(
        (e) => e.message,
        'message',
        contains('The print context changed'),
      )),
    );

    // Now User 2 logs in and views their certificate
    var user2CanPrint = true;
    unawaited(service.printCertificate(
      _record(id: 202, title: 'User 2 Training'),
      canPrint: () => user2CanPrint,
    ));

    await Future<void>.delayed(Duration.zero);
    expect(capturedJobIds.length, 2);
    final user2JobId = capturedJobIds.last;
    expect(user2JobId, isNot(equals(user1JobId)));

    // Native requests layout for User 2
    final user2OnLayout = const StandardMethodCodec().encodeMethodCall(
      MethodCall('onLayout', {
        'job': user2JobId,
        'width': 595.28,
        'height': 841.89,
        'marginLeft': 0.0,
        'marginTop': 0.0,
        'marginRight': 0.0,
        'marginBottom': 0.0,
      }),
    );

    ByteData? user2ResponseBytes;
    await defaultBinaryMessenger.handlePlatformMessage(
      'net.nfet.printing',
      user2OnLayout,
      (data) => user2ResponseBytes = data,
    );

    // User 2 layout succeeds with actual PDF bytes
    final user2Decoded = const StandardMethodCodec().decodeEnvelope(user2ResponseBytes!) as Uint8List?;
    expect(user2Decoded, isNotNull);
    expect(user2Decoded!, isNotEmpty);
  });
}

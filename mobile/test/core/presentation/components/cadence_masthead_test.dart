import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:training_app/core/presentation/components/cadence_masthead.dart';

Widget app({double scale = 1, VoidCallback? onPressed}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(
      appBar: CadenceMasthead(
        action: IconButton(
          tooltip: 'Notifications',
          onPressed: onPressed ?? () {},
          icon: const Icon(Icons.notifications_outlined),
        ),
      ),
      body: const Text('Dashboard'),
    ),
  ),
);
void main() {
  testWidgets('original asset uses contain and has one accessible brand name', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, CadenceMasthead.logoAsset);
    expect(image.fit, BoxFit.contain);
    expect(image.width, 144);
    expect(image.height, 72);
    expect(
      find.bySemanticsLabel("Garden's Need Training Module"),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 1.5, 2.0]) {
      testWidgets('masthead fits width $width at ${scale}x text', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(app(scale: scale));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final size = tester.getSize(find.byType(IconButton));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      });
    }
  }
  testWidgets(
    'notification action supports keyboard and tap without duplicate activation',
    (tester) async {
      var calls = 0;
      await tester.pumpWidget(app(onPressed: () => calls++));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(IconButton));
      expect(calls, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(calls, 2);
    },
  );
}

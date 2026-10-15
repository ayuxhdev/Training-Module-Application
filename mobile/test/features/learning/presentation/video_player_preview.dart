import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

bool _fontsLoaded = false;

/// Optional host previews use existing SDK fonts, never production assets.
Future<void> loadPlayerPreviewFonts(WidgetTester tester) async {
  const directory = String.fromEnvironment('PLAYER_PREVIEW_FONTS');
  if (directory.isEmpty || _fontsLoaded) return;
  await tester.runAsync(() async {
    for (final entry in {
      'Roboto': ['roboto-regular.ttf', 'roboto-bold.ttf'],
      'MaterialIcons': ['materialicons-regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final file in entry.value) {
        loader.addFont(
          File('$directory/$file').readAsBytes().then(ByteData.sublistView),
        );
      }
      await loader.load();
    }
  });
  _fontsLoaded = true;
}

Future<void> capturePlayerPreview(
  WidgetTester tester,
  Key boundaryKey,
  String name,
) async {
  const directory = String.fromEnvironment('PLAYER_PREVIEW_DIR');
  if (directory.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(boundaryKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  });
}

// NOTE: This test is intentionally skipped. It was used to rasterize the SVG
// app icon to a 1024x1024 PNG during development but times out in CI/test
// environments. The actual icon PNG is generated offline (e.g., via Inkscape)
// and checked into assets/app_icon/app_icon_1024.png. Keeping this file for
// local dev reference if needed.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('generate 1024x1024 app icon PNG from SVG', (tester) async {
    // Arrange
    const String svgAsset =
        'assets/app_icon/icon_variant_ticket_rainbow_meter.svg';
    const String outPath = 'assets/app_icon/app_icon_1024.png';

    final repaintKey = GlobalKey();
    final svgContents = await File(svgAsset).readAsString();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: repaintKey,
            child: SizedBox(
              width: 1024,
              height: 1024,
              child: SvgPicture.string(svgContents, fit: BoxFit.contain),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // Act & Assert inside runAsync to avoid test pump deadlocks.
    await tester.runAsync(() async {
      final boundary = repaintKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      expect(byteData, isNotNull);
      final Uint8List pngBytes = byteData!.buffer.asUint8List();
      await File(outPath).writeAsBytes(pngBytes);

      // Assert
      final file = File(outPath);
      expect(await file.exists(), isTrue);
      expect(await file.length(), greaterThan(1024));
    });
  }, skip: true);
}

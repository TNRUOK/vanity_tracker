import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:vanity_tracker/services/ocr/packaging_image_prep.dart';

Future<ui.Image> decode(Uint8List png) async {
  final codec = await ui.instantiateImageCodec(png);
  return (await codec.getNextFrame()).image;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 900 x 207 synthetic label (see test/fixtures/packaging_ocr).
  final label = File('test/fixtures/packaging_ocr/clean_labels.png').readAsBytesSync();

  testWidgets('original size is kept without enhancement; small images are upscaled for OCR', (tester) async {
    await tester.runAsync(() async {
      final plain = await PackagingImagePrep.prepare(label, enhance: false);
      expect((plain.width, plain.height), (900, 207));
      expect(plain.steps, isEmpty);

      final enhanced = await PackagingImagePrep.prepare(label);
      expect(enhanced.width, PackagingImagePrep.minLongEdge, reason: 'long edge raised to 1600 px');
      expect(enhanced.steps, containsAll(['upscaled 1.8x', 'grayscale + contrast stretch']));

      final small = File('test/fixtures/packaging_ocr/small_text.png').readAsBytesSync(); // 420 x 120
      final s = await PackagingImagePrep.prepare(small);
      expect(s.width, 1260, reason: 'upscaling is capped at 3x');
    });
  });

  testWidgets('enhanced output is grayscale (R = G = B)', (tester) async {
    await tester.runAsync(() async {
      final colored = File('test/fixtures/packaging_ocr/embossed_silver.png').readAsBytesSync();
      final p = await PackagingImagePrep.prepare(colored);
      final img = await decode(p.pngBytes);
      final px = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
      for (var i = 0; i < px.length; i += 4 * 997) {
        expect(px[i], px[i + 1]);
        expect(px[i + 1], px[i + 2]);
      }
    });
  });

  testWidgets('quarter-turn rotation swaps the sides; crop keeps the chosen region', (tester) async {
    await tester.runAsync(() async {
      final r = await PackagingImagePrep.prepare(label, quarterTurns: 1, enhance: false);
      expect((r.width, r.height), (207, 900));
      expect(r.steps, ['rotated 90°']);

      final c = await PackagingImagePrep.prepare(label, crop: const ui.Rect.fromLTWH(0, 0, 0.5, 0.5), enhance: false);
      expect((c.width, c.height), (450, 104));
      expect(c.steps, ['cropped']);
      // A degenerate crop falls back to the whole image instead of failing.
      final whole = await PackagingImagePrep.prepare(label, crop: const ui.Rect.fromLTWH(0.5, 0.5, 0, 0), enhance: false);
      expect(whole.width, 900);
    });
  });

  testWidgets('unreadable, empty and oversized input fail with a clear message', (tester) async {
    await tester.runAsync(() async {
      await expectLater(PackagingImagePrep.prepare(Uint8List(0)), throwsA(isA<ImagePrepException>()));
      await expectLater(
        PackagingImagePrep.prepare(Uint8List.fromList(List.filled(64, 7))),
        throwsA(isA<ImagePrepException>().having((e) => e.message, 'message', contains('could not be read as an image'))),
      );
      await expectLater(
        PackagingImagePrep.prepare(Uint8List(PackagingImagePrep.maxInputBytes + 1)),
        throwsA(isA<ImagePrepException>().having((e) => e.message, 'message', contains('25 MB'))),
      );
    });
  });
}

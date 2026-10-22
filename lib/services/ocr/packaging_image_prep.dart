import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

/// A prepared image for OCR (PNG) and the steps that produced it.
class PreparedImage {
  final Uint8List pngBytes;
  final int width;
  final int height;
  final List<String> steps;
  const PreparedImage(this.pngBytes, this.width, this.height, this.steps);
}

class ImagePrepException implements Exception {
  final String message;
  ImagePrepException(this.message);
  @override
  String toString() => message;
}

/// Bounded preprocessing for packaging photos, with dart:ui only (same code on web and
/// mobile, no extra package):
///
/// * rotation by quarter turns and cropping to a region the user zoomed into;
/// * upscaling small images so tiny print reaches a readable size (at most 3x, to about
///   1600 px on the long edge) and downscaling very large photos (to 2400 px);
/// * when [enhance] is set: grayscale and a 1 %–99 % contrast stretch.
///
/// Measured in a real browser on the synthetic packaging corpus (test/fixtures/packaging_ocr):
/// this fixed a tilted label's date and recovered labels on an embossed silver surface,
/// without losing text elsewhere. Blur and binarization were tried and are NOT used: blur
/// turned "4021A" into "S021A", and hard thresholds erase fine embossed strokes.
class PackagingImagePrep {
  static const minLongEdge = 1600;
  static const maxLongEdge = 2400;
  static const maxUpscale = 3.0;
  static const maxInputBytes = 25 * 1024 * 1024;

  /// [crop] is a normalized rectangle (0..1) in the rotated image; null = whole image.
  static Future<PreparedImage> prepare(
    Uint8List bytes, {
    int quarterTurns = 0,
    ui.Rect? crop,
    bool enhance = true,
  }) async {
    if (bytes.isEmpty) throw ImagePrepException('The image is empty.');
    if (bytes.length > maxInputBytes) {
      throw ImagePrepException('The image is larger than 25 MB. Choose a smaller photo or crop it first.');
    }
    final turns = quarterTurns % 4;
    final steps = <String>[];

    // instantiateImageCodec / decodeImageFromPixels work on web and mobile alike
    // (ui.ImageDescriptor is not implemented in Flutter web).
    ui.Image src;
    try {
      var codec = await ui.instantiateImageCodec(bytes);
      src = (await codec.getNextFrame()).image;
      codec.dispose();
      // Very large photos are decoded again at a reduced size (enough for a crop at full detail).
      const decodeCap = 4000;
      final long = math.max(src.width, src.height);
      if (long > decodeCap) {
        final w = (src.width * decodeCap / long).round(), h = (src.height * decodeCap / long).round();
        src.dispose();
        codec = await ui.instantiateImageCodec(bytes, targetWidth: w, targetHeight: h);
        src = (await codec.getNextFrame()).image;
        codec.dispose();
      }
    } catch (e) {
      throw ImagePrepException('The file could not be read as an image ($e).');
    }

    try {
      final rw = turns.isOdd ? src.height : src.width;
      final rh = turns.isOdd ? src.width : src.height;
      final c = _clampCrop(crop);
      if (crop != null) steps.add('cropped');
      if (turns != 0) steps.add('rotated ${turns * 90}°');
      final cw = c.width * rw, ch = c.height * rh;
      final long = math.max(cw, ch);
      double scale = 1;
      if (enhance && long < minLongEdge) scale = math.min(maxUpscale, minLongEdge / long);
      if (long * scale > maxLongEdge) scale = maxLongEdge / long;
      if (scale > 1.01) steps.add('upscaled ${scale.toStringAsFixed(1)}x');
      if (scale < 0.99) steps.add('downscaled ${scale.toStringAsFixed(2)}x');
      final outW = math.max(1, (cw * scale).round());
      final outH = math.max(1, (ch * scale).round());

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.scale(scale);
      canvas.translate(-c.left * rw, -c.top * rh);
      switch (turns) {
        case 1:
          canvas.translate(src.height.toDouble(), 0);
          canvas.rotate(math.pi / 2);
        case 2:
          canvas.translate(src.width.toDouble(), src.height.toDouble());
          canvas.rotate(math.pi);
        case 3:
          canvas.translate(0, src.width.toDouble());
          canvas.rotate(-math.pi / 2);
      }
      canvas.drawImage(src, ui.Offset.zero, ui.Paint()..filterQuality = ui.FilterQuality.high);
      final picture = recorder.endRecording();
      var out = await picture.toImage(outW, outH);
      picture.dispose();

      if (enhance) {
        final rgba = await out.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (rgba != null) {
          final pixels = _grayscaleStretch(rgba.buffer.asUint8List());
          steps.add('grayscale + contrast stretch');
          out.dispose();
          out = await _fromPixels(pixels, outW, outH);
        }
      }
      final png = await out.toByteData(format: ui.ImageByteFormat.png);
      out.dispose();
      if (png == null) throw ImagePrepException('The prepared image could not be encoded.');
      return PreparedImage(png.buffer.asUint8List(), outW, outH, steps);
    } finally {
      src.dispose();
    }
  }

  static ui.Rect _clampCrop(ui.Rect? crop) {
    if (crop == null) return const ui.Rect.fromLTWH(0, 0, 1, 1);
    final l = crop.left.clamp(0.0, 1.0), t = crop.top.clamp(0.0, 1.0);
    final r = crop.right.clamp(0.0, 1.0), b = crop.bottom.clamp(0.0, 1.0);
    if (r - l < 0.02 || b - t < 0.02) return const ui.Rect.fromLTWH(0, 0, 1, 1);
    return ui.Rect.fromLTRB(l, t, r, b);
  }

  /// Luminance, then a linear stretch so the darkest 1 % become black and the brightest
  /// 1 % white (alpha is kept).
  static Uint8List _grayscaleStretch(Uint8List rgba) {
    final n = rgba.length ~/ 4;
    final hist = List<int>.filled(256, 0);
    final lum = Uint8List(n);
    for (var i = 0, p = 0; i < n; i++, p += 4) {
      final y = (0.299 * rgba[p] + 0.587 * rgba[p + 1] + 0.114 * rgba[p + 2]).round().clamp(0, 255);
      lum[i] = y;
      hist[y]++;
    }
    var lo = 0, hi = 255, acc = 0;
    for (; lo < 255; lo++) {
      acc += hist[lo];
      if (acc > n * 0.01) break;
    }
    acc = 0;
    for (; hi > 0; hi--) {
      acc += hist[hi];
      if (acc > n * 0.01) break;
    }
    final span = math.max(1, hi - lo);
    final out = Uint8List(rgba.length);
    for (var i = 0, p = 0; i < n; i++, p += 4) {
      final v = ((lum[i] - lo) * 255 / span).round().clamp(0, 255);
      out[p] = v;
      out[p + 1] = v;
      out[p + 2] = v;
      out[p + 3] = rgba[p + 3];
    }
    return out;
  }

  static Future<ui.Image> _fromPixels(Uint8List pixels, int w, int h) {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(pixels, w, h, ui.PixelFormat.rgba8888, done.complete);
    return done.future;
  }
}

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'phash.dart';

/// Device-side photo checks run before a tree photo is submitted.
///
/// Everything here is ADVISORY. It exists to save an honest user a rejected
/// submission (a blurry or dark photo) and to show what the photo carries. It is
/// not evidence of authenticity: the app is user-controlled code, EXIF can be
/// edited or absent, and the server makes the real decision.
enum NoteLevel { info, warning }

class PrecheckNote {
  const PrecheckNote(this.code, this.level, this.message);

  final String code;
  final NoteLevel level;
  final String message;
}

class PhotoPrecheck {
  const PhotoPrecheck({
    required this.readable,
    required this.notes,
    this.width = 0,
    this.height = 0,
    this.bytes = 0,
    this.phash = '',
    this.sharpness,
    this.brightness,
    this.exifCapturedAt,
    this.cameraModel,
    this.hasGps = false,
  });

  /// False only when the file cannot be decoded as an image at all.
  final bool readable;
  final List<PrecheckNote> notes;
  final int width;
  final int height;
  final int bytes;
  final String phash;

  /// Variance of the Laplacian on a downscaled grey image. Higher is sharper.
  final double? sharpness;

  /// Mean luma, 0 to 255.
  final double? brightness;

  final DateTime? exifCapturedAt;
  final String? cameraModel;
  final bool hasGps;

  bool get hasWarnings => notes.any((n) => n.level == NoteLevel.warning);
}

/// Thresholds are uncalibrated starting points, not validated cut-offs. They
/// only decide whether to show a hint, never whether to accept a photo.
class PrecheckLimits {
  static const minShortSide = 480;
  static const minBytes = 20 * 1024;
  static const blurBelow = 60.0;
  static const darkBelow = 45.0;
  static const brightAbove = 225.0;
  static const exifSkewMinutes = 15;
  static const analysisEdge = 256;
}

/// Entry point for `compute()`; must stay top-level.
PhotoPrecheck analysePhotoBytes(Uint8List raw) => analysePhoto(raw);

PhotoPrecheck analysePhoto(Uint8List raw, {DateTime? now}) {
  final clock = now ?? DateTime.now();
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(raw);
  } catch (_) {
    return _unreadable(raw.length);
  }
  if (decoded == null) return _unreadable(raw.length);

  final notes = <PrecheckNote>[];
  final shortSide = math.min(decoded.width, decoded.height);

  if (shortSide < PrecheckLimits.minShortSide || raw.length < PrecheckLimits.minBytes) {
    notes.add(const PrecheckNote(
      'low_resolution',
      NoteLevel.warning,
      'This photo is small or heavily compressed. A closer, clearer shot is '
          'more likely to be accepted.',
    ));
  }

  final stats = _lumaStats(decoded);
  if (stats.sharpness < PrecheckLimits.blurBelow) {
    notes.add(const PrecheckNote(
      'maybe_blurry',
      NoteLevel.warning,
      'This photo may be blurry. Hold steady and let the camera focus.',
    ));
  }
  if (stats.brightness < PrecheckLimits.darkBelow) {
    notes.add(const PrecheckNote(
      'too_dark',
      NoteLevel.warning,
      'This photo looks very dark. Try again in better light.',
    ));
  } else if (stats.brightness > PrecheckLimits.brightAbove) {
    notes.add(const PrecheckNote(
      'too_bright',
      NoteLevel.warning,
      'This photo looks overexposed. Avoid pointing the camera at the sky.',
    ));
  }

  // --- EXIF: supporting information only ------------------------------------
  DateTime? capturedAt;
  String? model;
  var hasGps = false;
  try {
    final exif = decoded.exif;
    if (!exif.isEmpty) {
      capturedAt = parseExifDate(exif.exifIfd.data[0x9003]?.toString());
      final make = exif.imageIfd.make?.trim();
      final mdl = exif.imageIfd.model?.trim();
      model = [if (make != null && make.isNotEmpty) make, if (mdl != null && mdl.isNotEmpty) mdl]
          .join(' ');
      if (model.isEmpty) model = null;
      hasGps = exif.gpsIfd.data.containsKey(0x0002);
    }
  } catch (_) {
    // Malformed metadata is not the user's problem and not a finding.
  }

  if (capturedAt == null) {
    notes.add(const PrecheckNote(
      'no_exif',
      NoteLevel.info,
      'No camera metadata found. Many phones and apps leave it out, so this '
          'is normal and is not held against you.',
    ));
  } else {
    final skew = clock.difference(capturedAt).inMinutes;
    if (skew.abs() > PrecheckLimits.exifSkewMinutes) {
      notes.add(PrecheckNote(
        'exif_time_offset',
        NoteLevel.info,
        'The time stored in the photo differs from your phone clock by '
            '${skew.abs()} minutes. This can be caused by clock or timezone '
            'settings; it is only a note.',
      ));
    }
  }

  return PhotoPrecheck(
    readable: true,
    notes: notes,
    width: decoded.width,
    height: decoded.height,
    bytes: raw.length,
    phash: _safeHash(raw),
    sharpness: stats.sharpness,
    brightness: stats.brightness,
    exifCapturedAt: capturedAt,
    cameraModel: model,
    hasGps: hasGps,
  );
}

PhotoPrecheck _unreadable(int bytes) => PhotoPrecheck(
      readable: false,
      bytes: bytes,
      notes: const [
        PrecheckNote(
          'unreadable',
          NoteLevel.warning,
          'This photo could not be read. Please take it again.',
        ),
      ],
    );

String _safeHash(Uint8List raw) {
  try {
    return PHash.ofBytes(raw);
  } catch (_) {
    return '';
  }
}

/// EXIF dates look like `2026:11:04 10:30:00` and carry no timezone.
DateTime? parseExifDate(String? value) {
  if (value == null) return null;
  final m = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})').firstMatch(value.trim());
  if (m == null) return null;
  final parts = [for (var i = 1; i <= 6; i++) int.parse(m.group(i)!)];
  if (parts[0] < 2000 || parts[1] < 1 || parts[1] > 12 || parts[2] < 1 || parts[2] > 31) {
    return null;
  }
  if (parts[3] > 23 || parts[4] > 59 || parts[5] > 59) return null;
  return DateTime(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]);
}

class _LumaStats {
  const _LumaStats(this.sharpness, this.brightness);
  final double sharpness;
  final double brightness;
}

_LumaStats _lumaStats(img.Image source) {
  final longest = math.max(source.width, source.height);
  final small = longest > PrecheckLimits.analysisEdge
      ? img.copyResize(
          source,
          width: source.width >= source.height ? PrecheckLimits.analysisEdge : null,
          height: source.height > source.width ? PrecheckLimits.analysisEdge : null,
          interpolation: img.Interpolation.average,
        )
      : source;

  final w = small.width;
  final h = small.height;
  final luma = List<double>.filled(w * h, 0);
  var sum = 0.0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = small.getPixel(x, y).luminanceNormalized * 255.0;
      luma[y * w + x] = v;
      sum += v;
    }
  }
  final mean = w * h == 0 ? 0.0 : sum / (w * h);
  if (w < 3 || h < 3) return _LumaStats(0, mean);

  var n = 0;
  var lapSum = 0.0;
  var lapSq = 0.0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final c = luma[y * w + x];
      final lap = 4 * c -
          luma[(y - 1) * w + x] -
          luma[(y + 1) * w + x] -
          luma[y * w + x - 1] -
          luma[y * w + x + 1];
      lapSum += lap;
      lapSq += lap * lap;
      n++;
    }
  }
  final meanLap = lapSum / n;
  return _LumaStats(lapSq / n - meanLap * meanLap, mean);
}

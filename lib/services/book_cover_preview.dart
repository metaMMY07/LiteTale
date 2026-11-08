import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class BookCoverPreview {
  const BookCoverPreview(this.bytes, this.color);
  final Uint8List bytes;
  final Color color;
}

/// Small display-only previews. They never fetch images or alter reader caches.
class BookCoverPreviewCache {
  static final instance = BookCoverPreviewCache();
  final _previews = <String, BookCoverPreview>{};
  final _revealed = <String, int?>{};
  final _pending = <String>{};
  int _weight = 0;
  static const maxEntries = 256, maxBytes = 8 * 1024 * 1024;

  BookCoverPreview? lookup(String key) {
    final preview = _previews.remove(key);
    if (preview != null) _previews[key] = preview;
    return preview;
  }

  bool wasRevealed(String key) => _revealed.containsKey(key);
  int? revealedPixels(String key) => _revealed[key];

  void reveal(String key, {int? pixels}) {
    final previous = _revealed.remove(key);
    _revealed[key] = pixels ?? previous;
    while (_revealed.length > maxEntries) {
      _revealed.remove(_revealed.keys.first);
    }
  }

  void _put(String key, BookCoverPreview preview) {
    _weight -= _previews.remove(key)?.bytes.length ?? 0;
    _previews[key] = preview;
    _weight += preview.bytes.length;
    while (_previews.length > maxEntries || _weight > maxBytes) {
      _weight -= _previews.remove(_previews.keys.first)!.bytes.length;
    }
  }

  /// At most two source images are retained for thumbnail work, with no queue.
  Future<BookCoverPreview?> capture(String key, ui.Image image) async {
    final cached = lookup(key);
    if (cached != null) return cached;
    if (_pending.contains(key) || _pending.length >= 2) return null;
    _pending.add(key);
    final owned = image.clone();
    ui.Image? small;
    try {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      final fitted = applyBoxFit(
        BoxFit.cover,
        Size(owned.width.toDouble(), owned.height.toDouble()),
        const Size(32, 48),
      );
      canvas.drawImageRect(
        owned,
        Alignment.center.inscribe(
          fitted.source,
          Offset.zero & Size(owned.width.toDouble(), owned.height.toDouble()),
        ),
        const Rect.fromLTWH(0, 0, 32, 48),
        Paint()..filterQuality = FilterQuality.low,
      );
      final picture = recorder.endRecording();
      try {
        small = await picture.toImage(32, 48);
      } finally {
        picture.dispose();
      }
      final rgba = await small.toByteData(format: ui.ImageByteFormat.rawRgba);
      final png = await small.toByteData(format: ui.ImageByteFormat.png);
      if (rgba == null || png == null) return null;
      var red = 0, green = 0, blue = 0, count = 0;
      for (var i = 0; i < rgba.lengthInBytes; i += 16) {
        if (rgba.getUint8(i + 3) < 128) continue;
        red += rgba.getUint8(i);
        green += rgba.getUint8(i + 1);
        blue += rgba.getUint8(i + 2);
        count++;
      }
      final preview = BookCoverPreview(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        count == 0
            ? const Color(0xFF808080)
            : Color.fromARGB(255, red ~/ count, green ~/ count, blue ~/ count),
      );
      _put(key, preview);
      return preview;
    } catch (_) {
      return null; // Optional presentation work never fails the real cover.
    } finally {
      small?.dispose();
      owned.dispose();
      _pending.remove(key);
    }
  }

  /// Decode a site-supplied BlurHash without another network request.
  Future<BookCoverPreview?> fromUrl(String key, String url) async {
    final cached = lookup(key);
    if (cached != null) return cached;
    final match = RegExp(r'[?&]placeholder=([^&#]*)').firstMatch(url);
    if (match == null || _pending.contains(key) || _pending.length >= 2) {
      return null;
    }
    _pending.add(key);
    ui.Image? image;
    try {
      final hash = Uri.decodeComponent(match.group(1)!);
      const alphabet =
          '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#\u0024%*+,-.:;=?@[]^_{|}~';
      int decode(String value) {
        var result = 0;
        for (final c in value.split('')) {
          final n = alphabet.indexOf(c);
          if (n < 0) throw const FormatException('Invalid BlurHash');
          result = result * 83 + n;
        }
        return result;
      }

      if (hash.length < 6 || hash.length > 166) return null;
      final size = decode(hash[0]), nx = size % 9 + 1, ny = size ~/ 9 + 1;
      if (ny > 9 || hash.length != 4 + 2 * nx * ny) return null;
      double linear(int value) {
        final v = value / 255;
        return v <= .04045
            ? v / 12.92
            : math.pow((v + .055) / 1.055, 2.4).toDouble();
      }

      int srgb(double v) => ((v <= .0031308
                  ? v * 12.92
                  : 1.055 * math.pow(v.clamp(0, 1), 1 / 2.4) - .055) *
              255)
          .round()
          .clamp(0, 255);
      final dc = decode(hash.substring(2, 6));
      final factors = <(double, double, double)>[
        (linear(dc >> 16), linear((dc >> 8) & 255), linear(dc & 255)),
      ];
      final maximum = (decode(hash[1]) + 1) / 166;
      double ac(int v) {
        final n = (v - 9) / 9;
        return n.sign * n * n * maximum;
      }

      for (var i = 1; i < nx * ny; i++) {
        final n = decode(hash.substring(4 + i * 2, 6 + i * 2));
        factors.add((ac(n ~/ 361), ac(n ~/ 19 % 19), ac(n % 19)));
      }
      final pixels = Uint8List(32 * 48 * 4);
      for (var y = 0; y < 48; y++) {
        for (var x = 0; x < 32; x++) {
          var r = 0.0, g = 0.0, b = 0.0;
          for (var j = 0; j < ny; j++) {
            for (var i = 0; i < nx; i++) {
              final basis =
                      math.cos(math.pi * x * i / 32) *
                      math.cos(math.pi * y * j / 48),
                  c = factors[i + j * nx];
              r += c.$1 * basis;
              g += c.$2 * basis;
              b += c.$3 * basis;
            }
          }
          final p = (y * 32 + x) * 4;
          pixels[p] = srgb(r);
          pixels[p + 1] = srgb(g);
          pixels[p + 2] = srgb(b);
          pixels[p + 3] = 255;
        }
      }
      final buffer = await ui.ImmutableBuffer.fromUint8List(pixels);
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: 32,
        height: 48,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      final codec = await descriptor.instantiateCodec();
      try {
        image = (await codec.getNextFrame()).image;
      } finally {
        codec.dispose();
        descriptor.dispose();
        buffer.dispose();
      }
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return null;
      final preview = BookCoverPreview(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        Color(0xFF000000 | dc),
      );
      _put(key, preview);
      return preview;
    } catch (_) {
      return null;
    } finally {
      image?.dispose();
      _pending.remove(key);
    }
  }
}

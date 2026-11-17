import 'dart:io';
import 'dart:typed_data';

import 'protocol.dart';

/// A captured screen image: 32-bit pixels, [stride] bytes per row.
class RawFrame {
  RawFrame(this.width, this.height, this.stride, this.pixels, this.format);
  final int width, height, stride;
  final Uint8List pixels;
  final int format; // PixelFmt
}

/// A JPEG-compressed screen image from a host that compresses natively (Android).
class JpegFrame {
  JpegFrame(this.seq, this.width, this.height, this.jpeg);
  final int seq, width, height;
  final Uint8List jpeg;
}

/// Tile-based delta encoder: only 64x64 tiles that changed since the previous
/// frame are sent, packed as 24-bit pixels and deflate-compressed.
class FrameEncoder {
  FrameEncoder({this.tile = 64, int level = 4}) : _zlib = ZLibCodec(level: level);

  final int tile;
  final ZLibCodec _zlib;
  Uint32List? _prev;
  int _pw = 0, _ph = 0;

  void reset() => _prev = null;

  /// Returns a [Msg.frame] message, or null if nothing changed.
  Uint8List? encode(RawFrame f, {double scale = 1.0}) {
    final cur = _normalize(f, scale);
    final w = _lastW, h = _lastH;
    final prev = (_prev != null && _pw == w && _ph == h) ? _prev : null;

    final rects = <int>[]; // x,y,w,h
    var pixelCount = 0;
    for (var ty = 0; ty < h; ty += tile) {
      final th = (ty + tile > h) ? h - ty : tile;
      var runStart = -1;
      for (var tx = 0; tx < w + tile; tx += tile) {
        bool changed = false;
        if (tx < w) {
          final tw = (tx + tile > w) ? w - tx : tile;
          changed = prev == null || _tileDiffers(cur, prev, w, tx, ty, tw, th);
        }
        if (changed && runStart < 0) runStart = tx;
        if (!changed && runStart >= 0) {
          final rw = (tx > w ? w : tx) - runStart;
          rects.addAll([runStart, ty, rw, th]);
          pixelCount += rw * th;
          runStart = -1;
        }
      }
    }
    _prev = cur;
    _pw = w;
    _ph = h;
    if (rects.isEmpty) return null;

    final packed = Uint8List(pixelCount * 3);
    var o = 0;
    for (var r = 0; r < rects.length; r += 4) {
      final rx = rects[r], ry = rects[r + 1], rw = rects[r + 2], rh = rects[r + 3];
      for (var y = ry; y < ry + rh; y++) {
        var i = y * w + rx;
        final end = i + rw;
        while (i < end) {
          final v = cur[i++];
          packed[o] = v & 0xff;
          packed[o + 1] = (v >> 8) & 0xff;
          packed[o + 2] = (v >> 16) & 0xff;
          o += 3;
        }
      }
    }
    final z = _zlib.encode(packed);
    final nr = rects.length ~/ 4;
    final headLen = 8 + nr * 8;
    final out = Uint8List(headLen + z.length);
    final bd = ByteData.sublistView(out);
    bd.setUint8(0, Msg.frame);
    bd.setUint16(1, w);
    bd.setUint16(3, h);
    bd.setUint8(5, f.format);
    bd.setUint16(6, nr);
    for (var r = 0; r < nr; r++) {
      for (var k = 0; k < 4; k++) {
        bd.setUint16(8 + r * 8 + k * 2, rects[r * 4 + k]);
      }
    }
    out.setRange(headLen, out.length, z);
    return out;
  }

  int _lastW = 0, _lastH = 0;

  Uint32List _normalize(RawFrame f, double scale) {
    final src = f.pixels.buffer.asUint32List(f.pixels.offsetInBytes, (f.stride * f.height) ~/ 4);
    final sp = f.stride ~/ 4;
    if (scale >= 0.999) {
      _lastW = f.width;
      _lastH = f.height;
      if (sp == f.width) return Uint32List.fromList(src);
      final out = Uint32List(f.width * f.height);
      for (var y = 0; y < f.height; y++) {
        out.setRange(y * f.width, (y + 1) * f.width, src, y * sp);
      }
      return out;
    }
    final w = (f.width * scale).round().clamp(1, f.width);
    final h = (f.height * scale).round().clamp(1, f.height);
    _lastW = w;
    _lastH = h;
    final out = Uint32List(w * h);
    final xs = Int32List(w);
    for (var x = 0; x < w; x++) {
      xs[x] = (x * f.width) ~/ w;
    }
    for (var y = 0; y < h; y++) {
      final row = ((y * f.height) ~/ h) * sp;
      final o = y * w;
      for (var x = 0; x < w; x++) {
        out[o + x] = src[row + xs[x]];
      }
    }
    return out;
  }

  static bool _tileDiffers(Uint32List a, Uint32List b, int w, int tx, int ty, int tw, int th) {
    for (var y = ty; y < ty + th; y++) {
      var i = y * w + tx;
      final end = i + tw;
      while (i < end) {
        if (a[i] != b[i]) return true;
        i++;
      }
    }
    return false;
  }
}

/// Applies [Msg.frame] messages onto a 32-bit framebuffer.
class FrameDecoder {
  final ZLibCodec _zlib = ZLibCodec();
  Uint8List? fb;
  int width = 0, height = 0, format = PixelFmt.bgra;

  void apply(Uint8List msg) {
    final bd = ByteData.sublistView(msg);
    final w = bd.getUint16(1), h = bd.getUint16(3);
    format = bd.getUint8(5);
    final nr = bd.getUint16(6);
    if (fb == null || w != width || h != height) {
      width = w;
      height = h;
      fb = Uint8List(w * h * 4);
    }
    final buf = fb!;
    final headLen = 8 + nr * 8;
    final px = Uint8List.fromList(_zlib.decode(Uint8List.sublistView(msg, headLen)));
    var p = 0;
    for (var r = 0; r < nr; r++) {
      final rx = bd.getUint16(8 + r * 8), ry = bd.getUint16(10 + r * 8);
      final rw = bd.getUint16(12 + r * 8), rh = bd.getUint16(14 + r * 8);
      if (rx + rw > w || ry + rh > h) throw const FormatException('bad rect');
      for (var y = ry; y < ry + rh; y++) {
        var o = (y * w + rx) * 4;
        final end = o + rw * 4;
        while (o < end) {
          buf[o] = px[p];
          buf[o + 1] = px[p + 1];
          buf[o + 2] = px[p + 2];
          buf[o + 3] = 255;
          o += 4;
          p += 3;
        }
      }
    }
  }
}

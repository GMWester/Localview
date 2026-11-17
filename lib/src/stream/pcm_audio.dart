import 'dart:typed_data';

import 'package:mp_audio_stream/mp_audio_stream.dart';

/// Plays the sound an Android host sends (PCM s16le, stereo, 48 kHz) on this device.
class PcmPlayer {
  static AudioStream? _stream;
  static int _users = 0;
  bool _open = false;

  /// null on success, else why the sound cannot play here.
  String? start() {
    if (_open) return null;
    try {
      if (_users == 0) {
        final a = getAudioStream();
        // Short buffer: the sound should stay in step with the picture.
        if (a.init(bufferMilliSec: 400, waitingBufferMilliSec: 60, channels: 2, sampleRate: 48000, fadeOnExhaust: true) != 0) {
          return 'This device has no sound output';
        }
        _stream = a;
      }
      _users++;
      _open = true;
      return null;
    } catch (e) {
      return 'Sound cannot play here: $e';
    }
  }

  void push(Uint8List pcm) {
    final a = _stream;
    if (!_open || a == null || pcm.length < 4) return;
    final n = pcm.length ~/ 2;
    final s = ByteData.sublistView(pcm);
    final f = Float32List(n);
    for (var i = 0; i < n; i++) {
      f[i] = s.getInt16(i * 2, Endian.little) / 32768.0;
    }
    a.push(f);
  }

  void stop() {
    if (!_open) return;
    _open = false;
    if (--_users == 0) {
      try {
        _stream?.uninit();
      } catch (_) {}
      _stream = null;
    }
  }
}

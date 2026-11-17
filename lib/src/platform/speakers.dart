// "Sound only on the controlling device": silences this computer's speakers while the sound
// is streamed to a viewer, and restores them afterwards.
//
// Windows: mutes the default output device (Core Audio IAudioEndpointVolume). The system
//   sound capture (WASAPI loopback) keeps receiving the sound on most audio drivers.
// Linux (PulseAudio / PipeWire): moves all sound to a private null sink "localview_stream",
//   which Localview captures; the real speakers get nothing.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

abstract class Speakers {
  /// Silences (true) or restores (false) this computer's speakers. Returns an error or null.
  Future<String?> silence(bool on);

  /// Linux: name of the capture device that carries the sound while silenced.
  String? get captureHint => null;
}

Speakers? createSpeakers() {
  if (Platform.isWindows) return _WinSpeakers();
  if (Platform.isLinux) return _PulseSpeakers();
  return null;
}

// ------------------------------------------------------------------ Windows (Core Audio via COM)

final class _Guid extends Struct {
  @Uint32()
  external int d1;
  @Uint16()
  external int d2;
  @Uint16()
  external int d3;
  @Array(8)
  external Array<Uint8> d4;
}

Pointer<_Guid> _guid(String s) {
  final h = s.replaceAll('-', '');
  final g = calloc<_Guid>();
  g.ref.d1 = int.parse(h.substring(0, 8), radix: 16);
  g.ref.d2 = int.parse(h.substring(8, 12), radix: 16);
  g.ref.d3 = int.parse(h.substring(12, 16), radix: 16);
  for (var i = 0; i < 8; i++) {
    g.ref.d4[i] = int.parse(h.substring(16 + i * 2, 18 + i * 2), radix: 16);
  }
  return g;
}

/// Function [index] of the COM object's vtable.
Pointer<NativeFunction<T>> _vt<T extends Function>(int obj, int index) {
  final vtable = Pointer<IntPtr>.fromAddress(Pointer<IntPtr>.fromAddress(obj).value);
  return Pointer<NativeFunction<T>>.fromAddress(vtable[index]);
}

class _WinSpeakers extends Speakers {
  bool? _wasMuted;

  int _endpointVolume() {
    final ole = DynamicLibrary.open('ole32.dll');
    final coInit = ole.lookupFunction<Int32 Function(Pointer<Void>, Uint32), int Function(Pointer<Void>, int)>('CoInitializeEx');
    final coCreate = ole.lookupFunction<
        Int32 Function(Pointer<_Guid>, Pointer<Void>, Uint32, Pointer<_Guid>, Pointer<IntPtr>),
        int Function(Pointer<_Guid>, Pointer<Void>, int, Pointer<_Guid>, Pointer<IntPtr>)>('CoCreateInstance');
    coInit(nullptr, 2); // already initialized on the UI thread: S_FALSE / RPC_E_CHANGED_MODE are fine
    final clsid = _guid('BCDE0395-E52F-467C-8E3D-C4579291692E'); // MMDeviceEnumerator
    final iidEnum = _guid('A95664D2-9614-4F35-A746-DE8DB63617E6'); // IMMDeviceEnumerator
    final iidVol = _guid('5CDF2C82-841E-4546-9722-0CF74078229A'); // IAudioEndpointVolume
    final out = calloc<IntPtr>();
    try {
      if (coCreate(clsid, nullptr, 0x17 /* CLSCTX_ALL */, iidEnum, out) != 0) throw StateError('no audio device enumerator');
      final enumerator = out.value;
      // IMMDeviceEnumerator::GetDefaultAudioEndpoint(eRender, eConsole)
      final getDefault = _vt<Int32 Function(IntPtr, Int32, Int32, Pointer<IntPtr>)>(enumerator, 4)
          .asFunction<int Function(int, int, int, Pointer<IntPtr>)>();
      final hr = getDefault(enumerator, 0, 0, out);
      _release(enumerator);
      if (hr != 0) throw StateError('no default audio output');
      final device = out.value;
      // IMMDevice::Activate(IID_IAudioEndpointVolume)
      final activate = _vt<Int32 Function(IntPtr, Pointer<_Guid>, Uint32, Pointer<Void>, Pointer<IntPtr>)>(device, 3)
          .asFunction<int Function(int, Pointer<_Guid>, int, Pointer<Void>, Pointer<IntPtr>)>();
      final hr2 = activate(device, iidVol, 0x17, nullptr, out);
      _release(device);
      if (hr2 != 0) throw StateError('no volume control on the audio output');
      return out.value;
    } finally {
      calloc.free(clsid);
      calloc.free(iidEnum);
      calloc.free(iidVol);
      calloc.free(out);
    }
  }

  static void _release(int obj) =>
      _vt<Uint32 Function(IntPtr)>(obj, 2).asFunction<int Function(int)>()(obj);

  @override
  Future<String?> silence(bool on) async {
    try {
      final vol = _endpointVolume();
      try {
        final getMute = _vt<Int32 Function(IntPtr, Pointer<Int32>)>(vol, 15).asFunction<int Function(int, Pointer<Int32>)>();
        final setMute = _vt<Int32 Function(IntPtr, Int32, Pointer<Void>)>(vol, 14).asFunction<int Function(int, int, Pointer<Void>)>();
        if (on) {
          final m = calloc<Int32>();
          getMute(vol, m);
          _wasMuted ??= m.value != 0;
          calloc.free(m);
          setMute(vol, 1, nullptr);
        } else {
          setMute(vol, (_wasMuted ?? false) ? 1 : 0, nullptr);
          _wasMuted = null;
        }
      } finally {
        _release(vol);
      }
      return null;
    } catch (e) {
      return '$e';
    }
  }
}

// ------------------------------------------------------------------ Linux (PulseAudio / PipeWire)

class _PulseSpeakers extends Speakers {
  static const _sink = 'localview_stream';
  String? _previous;
  String? _module;

  Future<String> _pactl(List<String> args) async {
    final r = await Process.run('pactl', args);
    if (r.exitCode != 0) throw StateError('pactl ${args.first}: ${r.stderr}'.trim());
    return (r.stdout as String).trim();
  }

  Future<void> _moveAll(String sink) async {
    final list = await _pactl(['list', 'short', 'sink-inputs']);
    for (final line in list.split('\n')) {
      final id = line.split(RegExp(r'\s+')).first;
      if (id.isEmpty) continue;
      try {
        await _pactl(['move-sink-input', id, sink]);
      } catch (_) {}
    }
  }

  @override
  String? get captureHint => _module == null ? null : 'Localview stream';

  @override
  Future<String?> silence(bool on) async {
    try {
      if (on) {
        if (_module != null) return null;
        _previous = await _pactl(['get-default-sink']);
        _module = await _pactl([
          'load-module',
          'module-null-sink',
          'sink_name=$_sink',
          'sink_properties=device.description=Localview-stream',
        ]);
        await _pactl(['set-default-sink', _sink]);
        await _moveAll(_sink);
      } else {
        final prev = _previous;
        if (prev != null && prev.isNotEmpty) {
          await _pactl(['set-default-sink', prev]);
          await _moveAll(prev);
        }
        if (_module != null) await _pactl(['unload-module', _module!]);
        _module = null;
        _previous = null;
      }
      return null;
    } catch (e) {
      return 'PulseAudio/PipeWire (pactl) is needed: $e';
    }
  }
}


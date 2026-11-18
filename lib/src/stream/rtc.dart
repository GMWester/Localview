// Game mode: hardware-accelerated low-latency video (H.264 preferred) and
// system audio over WebRTC. Offers/answers/ICE candidates are exchanged
// inside the Localview end-to-end encrypted session, so the DTLS-SRTP keys
// are authenticated by the pairing/password handshake (no MITM possible).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
// ignore: implementation_imports
import 'package:flutter_webrtc/src/native/media_stream_impl.dart' show MediaStreamNative;

import '../config.dart';
import '../platform/android.dart' show androidChannel;
import '../protocol.dart';

/// Streaming quality requested by the controller.
class GameModeSettings {
  const GameModeSettings(
      {this.fps = 60, this.bitrateKbps = 20000, this.maxHeight = 1080, this.audio = true, this.video = true, this.monitor});
  final int fps;

  /// Which of the host's screens to stream (MonitorInfo.osIndex); null = the first one.
  final int? monitor;

  GameModeSettings onMonitor(int? m) =>
      GameModeSettings(fps: fps, bitrateKbps: bitrateKbps, maxHeight: maxHeight, audio: audio, video: video, monitor: m);
  final int bitrateKbps;
  final int maxHeight; // 0 = native
  final bool audio;
  final bool video;

  Map<String, Object?> toJson() =>
      {'fps': fps, 'bitrate': bitrateKbps, 'height': maxHeight, 'audio': audio, 'video': video, 'monitor': ?monitor};
  factory GameModeSettings.fromJson(Map<String, dynamic> j) => GameModeSettings(
        fps: (j['fps'] as int? ?? 60).clamp(15, 144),
        bitrateKbps: (j['bitrate'] as int? ?? 20000).clamp(1000, 150000),
        maxHeight: j['height'] as int? ?? 1080,
        audio: j['audio'] as bool? ?? true,
        video: j['video'] as bool? ?? true,
        monitor: j['monitor'] as int?,
      );

  static const presets = <(String, GameModeSettings)>[
    ('720p · 60 fps · 10 Mbps', GameModeSettings(fps: 60, bitrateKbps: 10000, maxHeight: 720)),
    ('1080p · 60 fps · 20 Mbps', GameModeSettings(fps: 60, bitrateKbps: 20000, maxHeight: 1080)),
    ('1080p · 120 fps · 40 Mbps', GameModeSettings(fps: 120, bitrateKbps: 40000, maxHeight: 1080)),
    ('1440p · 60 fps · 35 Mbps', GameModeSettings(fps: 60, bitrateKbps: 35000, maxHeight: 1440)),
    ('4K · 60 fps · 80 Mbps', GameModeSettings(fps: 60, bitrateKbps: 80000, maxHeight: 2160)),
    ('Native · 90 fps · 60 Mbps (VR headsets)', GameModeSettings(fps: 90, bitrateKbps: 60000, maxHeight: 0)),
  ];
}

Map<String, dynamic> _rtcConfig() => {
      'sdpSemantics': 'unified-plan',
      // LAN builds never contact a STUN server; WAN/combined use STUN for NAT traversal.
      'iceServers': kHasWan
          ? [
              {'urls': 'stun:stun.l.google.com:19302'},
              {'urls': 'stun:stun.cloudflare.com:3478'},
            ]
          : <Map<String, String>>[],
      'bundlePolicy': 'max-bundle',
    };

/// Platforms whose host can capture the screen through WebRTC.
bool get rtcHostSupported => Platform.isWindows || Platform.isMacOS || Platform.isLinux || Platform.isAndroid;

bool? _usable;

/// libwebrtc aborts the process if its audio device module cannot start, which
/// happens on Linux without a PulseAudio/PipeWire server. Check first.
Future<bool> rtcUsable() async {
  if (_usable != null) return _usable!;
  if (!Platform.isLinux) return _usable = true;
  try {
    final r = await Process.run('pactl', ['info']).timeout(const Duration(seconds: 3));
    return _usable = r.exitCode == 0;
  } catch (_) {
    return _usable = false;
  }
}

Future<void> _preferH264(RTCRtpTransceiver t) async {
  try {
    final caps = await getRtpSenderCapabilities('video');
    final codecs = caps.codecs ?? [];
    int rank(RTCRtpCodecCapability c) {
      final m = c.mimeType.toLowerCase();
      if (m == 'video/h264') return 0; // hardware encode/decode almost everywhere
      if (m == 'video/h265' || m == 'video/hevc') return 1;
      if (m == 'video/vp8') return 2;
      if (m == 'video/vp9') return 3;
      if (m == 'video/av1') return 4;
      return 5; // rtx/red/ulpfec keep working after the media codecs
    }

    codecs.sort((a, b) => rank(a).compareTo(rank(b)));
    if (codecs.isNotEmpty) await t.setCodecPreferences(codecs);
  } catch (e) {
    debugPrint('codec preference not applied: $e');
  }
}

/// Host side of one game-mode stream.
class RtcHostSession {
  RtcHostSession(this.send);
  final void Function(Uint8List msg) send;
  RTCPeerConnection? _pc;
  MediaStream? _screen;
  MediaStream? _extraAudio;

  Future<void> start(GameModeSettings s) async {
    await stop();
    if (Platform.isAndroid) {
      // The running screen capture feeds a hardware-encoded video track (RtcScreen.kt); no second
      // "start recording" prompt. The sound keeps its own path (PCM over the session).
      await WebRTC.initialize(); // creates the factory the capture registers its track with
      final m = await androidChannel.invokeMapMethod<String, Object?>('rtcScreenStart');
      if (m == null) throw StateError('screen capture is not running');
      _screen = MediaStreamNative.fromMap({...m, 'ownerTag': 'local'});
      await _connect(s, withAudio: false);
      return;
    }
    final sources = await desktopCapturer.getSources(types: [SourceType.Screen]);
    final video = <String, dynamic>{
      if (sources.isNotEmpty)
        'deviceId': {'exact': (s.monitor != null && s.monitor! < sources.length ? sources[s.monitor!] : sources.first).id},
      'mandatory': {'frameRate': s.fps.toDouble()},
    };
    // Windows/Linux: system audio loopback comes with the screen capture.
    _screen = await navigator.mediaDevices
        .getDisplayMedia({'video': video, 'audio': s.audio && !Platform.isMacOS});
    await _connect(s, withAudio: true);
  }

  Future<void> _connect(GameModeSettings s, {required bool withAudio}) async {
    final pc = await createPeerConnection(_rtcConfig());
    _pc = pc;
    pc.onIceCandidate = (c) {
      if (c.candidate != null) {
        send(jsonMsg(Msg.rtcIce, {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex}));
      }
    };

    final vt = _screen!.getVideoTracks();
    if (vt.isEmpty) throw StateError('screen capture produced no video');
    if (s.video) await _addVideo(pc, vt.first, s);
    _audioCount = 0;
    if (withAudio) await _addAudio(pc, s);
    final offer = await pc.createOffer({});
    await pc.setLocalDescription(offer);
    send(jsonMsg(Msg.rtcOffer, {'sdp': offer.sdp, 'type': offer.type, 'audio': _audioCount > 0, 'video': s.video}));
  }

  int _audioCount = 0;

  Future<void> _addVideo(RTCPeerConnection pc, MediaStreamTrack track, GameModeSettings s) async {
    final vt = [track];
    final vTrans = await pc.addTransceiver(
      track: vt.first,
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly, streams: [_screen!]),
    );
    await _preferH264(vTrans);
    try {
      final p = vTrans.sender.parameters;
      final enc = (p.encodings == null || p.encodings!.isEmpty) ? [RTCRtpEncoding()] : p.encodings!;
      final srcH = (vt.first.getSettings()['height'] as num?)?.toDouble() ?? 0;
      for (final e in enc) {
        e.maxBitrate = s.bitrateKbps * 1000;
        e.maxFramerate = s.fps;
        if (s.maxHeight > 0 && srcH > s.maxHeight) e.scaleResolutionDownBy = srcH / s.maxHeight;
      }
      p.encodings = enc;
      p.degradationPreference = RTCDegradationPreference.MAINTAIN_FRAMERATE;
      await vTrans.sender.setParameters(p);
    } catch (e) {
      debugPrint('encoder parameters not applied: $e');
    }
  }

  Future<void> _addAudio(RTCPeerConnection pc, GameModeSettings s) async {
    final audioTracks = <MediaStreamTrack>[..._screen!.getAudioTracks()];
    if (s.audio && audioTracks.isEmpty) {
      // macOS (and fallback): use a loopback input device such as BlackHole if present.
      final dev = await _loopbackInput();
      if (dev != null) {
        _extraAudio = await navigator.mediaDevices.getUserMedia({
          'audio': {
            'deviceId': {'exact': dev},
            'echoCancellation': false,
            'noiseSuppression': false,
            'autoGainControl': false,
          },
          'video': false,
        });
        audioTracks.addAll(_extraAudio!.getAudioTracks());
      }
    }
    for (final a in audioTracks) {
      final t = await pc.addTransceiver(
        track: a,
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendOnly, streams: [_screen!]),
      );
      _audioSenders.add(t.sender);
    }
    _audioCount = audioTracks.length;
  }

  final List<RTCRtpSender> _audioSenders = [];

  /// Re-captures the system sound (e.g. after the sound moved to another output on Linux).
  Future<void> reloadAudio() async {
    if (_audioSenders.isEmpty) return;
    final dev = await _loopbackInput();
    if (dev == null) return;
    final old = _extraAudio;
    final fresh = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'deviceId': {'exact': dev},
        'echoCancellation': false,
        'noiseSuppression': false,
        'autoGainControl': false,
      },
      'video': false,
    });
    final tracks = fresh.getAudioTracks();
    if (tracks.isEmpty) return;
    await _audioSenders.first.replaceTrack(tracks.first);
    _extraAudio = fresh;
    for (final x in old?.getTracks() ?? const <MediaStreamTrack>[]) {
      await x.stop();
    }
  }

  static Future<String?> _loopbackInput() async {
    try {
      final devs = await navigator.mediaDevices.enumerateDevices();
      // While the speakers are silenced on Linux, the sound plays into Localview's own sink.
      for (final d in devs) {
        if (d.kind == 'audioinput' && d.label.toLowerCase().contains('localview')) return d.deviceId;
      }
      for (final d in devs) {
        if (d.kind != 'audioinput') continue;
        final l = d.label.toLowerCase();
        if (l.contains('blackhole') || l.contains('loopback') || l.contains('soundflower') || l.contains('monitor of')) {
          return d.deviceId;
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> handle(Uint8List m) async {
    switch (m[0]) {
      case Msg.rtcRequest:
        try {
          if (!rtcHostSupported) throw UnsupportedError('this device cannot stream in game mode');
          await start(GameModeSettings.fromJson(jsonBody(m)));
        } catch (e) {
          send(jsonMsg(Msg.rtcError, {'error': '$e'}));
          await stop();
        }
      case Msg.rtcAnswer:
        final j = jsonBody(m);
        await _pc?.setRemoteDescription(RTCSessionDescription(j['sdp'] as String?, j['type'] as String?));
      case Msg.rtcIce:
        final j = jsonBody(m);
        await _pc?.addCandidate(
            RTCIceCandidate(j['candidate'] as String?, j['sdpMid'] as String?, j['sdpMLineIndex'] as int?));
      case Msg.rtcStop:
        await stop();
    }
  }

  Future<void> stop() async {
    final pc = _pc;
    _pc = null;
    if (Platform.isAndroid && _screen != null) {
      try {
        await androidChannel.invokeMethod('rtcScreenStop');
      } catch (_) {}
    }
    for (final s in [_screen, _extraAudio]) {
      for (final t in s?.getTracks() ?? const <MediaStreamTrack>[]) {
        try {
          await t.stop();
        } catch (_) {}
      }
      try {
        await s?.dispose();
      } catch (_) {}
    }
    _screen = null;
    _extraAudio = null;
    _audioSenders.clear();
    try {
      await pc?.close();
      await pc?.dispose();
    } catch (_) {}
  }
}

/// Controller side of a game-mode stream.
class RtcClient extends ChangeNotifier {
  RtcClient(this.send);
  final void Function(Uint8List msg) send;
  final RTCVideoRenderer renderer = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  bool _init = false;
  bool active = false; // first frame shown
  bool hasAudio = false;
  String? error;

  /// Plays the remote sound here (false: muted on this device).
  bool playAudio = true;
  final List<MediaStreamTrack> _remoteAudio = [];

  void setAudioEnabled(bool on) {
    playAudio = on;
    for (final t in _remoteAudio) {
      t.enabled = on;
    }
  }
  String stats = '';
  Timer? _statsTimer;
  int _lastBytes = 0;
  DateTime _lastAt = DateTime.now();

  Future<void> start(GameModeSettings s) async {
    if (!_init) {
      await renderer.initialize();
      _init = true;
    }
    renderer.onFirstFrameRendered = () {
      active = true;
      notifyListeners();
    };
    renderer.onResize = notifyListeners;
    error = null;
    send(jsonMsg(Msg.rtcRequest, s.toJson()));
  }

  Future<void> handle(Uint8List m) async {
    try {
      switch (m[0]) {
        case Msg.rtcOffer:
          final j = jsonBody(m);
          hasAudio = j['audio'] == true;
          final pc = await createPeerConnection(_rtcConfig());
          _pc = pc;
          pc.onIceCandidate = (c) {
            if (c.candidate != null) {
              send(jsonMsg(Msg.rtcIce, {'candidate': c.candidate, 'sdpMid': c.sdpMid, 'sdpMLineIndex': c.sdpMLineIndex}));
            }
          };
          pc.onTrack = (e) {
            if (e.track.kind == 'audio') {
              e.track.enabled = playAudio;
              _remoteAudio.add(e.track);
            }
            if (e.track.kind == 'video' && e.streams.isNotEmpty) {
              renderer.srcObject = e.streams.first;
              notifyListeners();
            }
          };
          pc.onConnectionState = (st) {
            if (st == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
              error = 'Game mode connection failed (UDP blocked?). Using compatibility mode.';
              unawaited(stop());
            }
          };
          await pc.setRemoteDescription(RTCSessionDescription(j['sdp'] as String?, j['type'] as String?));
          final answer = await pc.createAnswer({});
          await pc.setLocalDescription(answer);
          send(jsonMsg(Msg.rtcAnswer, {'sdp': answer.sdp, 'type': answer.type}));
          _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _poll());
        case Msg.rtcIce:
          final j = jsonBody(m);
          await _pc?.addCandidate(
              RTCIceCandidate(j['candidate'] as String?, j['sdpMid'] as String?, j['sdpMLineIndex'] as int?));
        case Msg.rtcError:
          error = 'Game mode unavailable: ${jsonBody(m)['error']}. Using compatibility mode.';
          await stop(notifyHost: false);
      }
    } catch (e) {
      error = 'Game mode failed: $e';
      await stop();
    }
    notifyListeners();
  }

  Future<void> _poll() async {
    final pc = _pc;
    if (pc == null) return;
    try {
      double? n(Object? v) => v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
      double? fps, rtt, loss;
      int bytes = 0;
      for (final r in await pc.getStats()) {
        final v = r.values;
        if (r.type == 'inbound-rtp' && v['kind'] == 'video') {
          fps = n(v['framesPerSecond']);
          bytes = n(v['bytesReceived'])?.toInt() ?? 0;
          final lost = n(v['packetsLost']) ?? 0;
          final got = n(v['packetsReceived']) ?? 0;
          if (got + lost > 0) loss = lost / (got + lost) * 100;
        }
        if (r.type == 'candidate-pair' && v['state'] == 'succeeded' && n(v['currentRoundTripTime']) != null) {
          rtt = n(v['currentRoundTripTime'])! * 1000;
        }
      }
      final now = DateTime.now();
      final secs = now.difference(_lastAt).inMilliseconds / 1000;
      final mbps = secs > 0 && _lastBytes > 0 ? (bytes - _lastBytes) * 8 / secs / 1e6 : 0;
      _lastBytes = bytes;
      _lastAt = now;
      stats = '${renderer.videoWidth}×${renderer.videoHeight} · ${fps?.toStringAsFixed(0) ?? '–'} fps · '
          '${mbps.toStringAsFixed(1)} Mbps · ${rtt?.toStringAsFixed(0) ?? '–'} ms'
          '${loss != null && loss > 0.1 ? ' · ${loss.toStringAsFixed(1)}% loss' : ''}';
      notifyListeners();
    } catch (_) {}
  }

  Future<void> stop({bool notifyHost = true}) async {
    _statsTimer?.cancel();
    _statsTimer = null;
    if (notifyHost) send(Uint8List.fromList([Msg.rtcStop]));
    final pc = _pc;
    _pc = null;
    active = false;
    try {
      renderer.srcObject = null;
      await pc?.close();
      await pc?.dispose();
    } catch (_) {}
    notifyListeners();
  }

  @override
  Future<void> dispose() async {
    await stop();
    if (_init) await renderer.dispose();
    super.dispose();
  }
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:localview/src/platform/speakers.dart';

/// "Sound only on the controlling device" on Linux: playing streams move to Localview's own
/// sink (captured, not audible) and come back afterwards. Needs a PulseAudio/PipeWire server.
void main() {
  bool hasPulse() {
    try {
      return Platform.isLinux && Process.runSync('pactl', ['info']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<String> pactl(List<String> a) async => ((await Process.run('pactl', a)).stdout as String).trim();
  Future<Set<String>> sinkOfInputs() async {
    final sinks = {
      for (final l in (await pactl(['list', 'short', 'sinks'])).split('\n'))
        if (l.trim().isNotEmpty) l.split(RegExp(r'\s+'))[0]: l.split(RegExp(r'\s+'))[1],
    };
    return {
      for (final l in (await pactl(['list', 'short', 'sink-inputs'])).split('\n'))
        if (l.trim().isNotEmpty) sinks[l.split(RegExp(r'\s+'))[1]] ?? '?',
    };
  }

  test('silence moves the sound to Localview\'s sink and back', () async {
    final before = await pactl(['get-default-sink']);
    final player = await Process.start('pacat', ['--playback', '/dev/zero']);
    addTearDown(player.kill);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(await sinkOfInputs(), {before});

    final sp = createSpeakers()!;
    expect(await sp.silence(true), isNull);
    expect(await pactl(['get-default-sink']), 'localview_stream');
    expect(await sinkOfInputs(), {'localview_stream'});
    expect(await pactl(['list', 'short', 'sources']), contains('localview_stream.monitor'));
    expect(sp.captureHint, isNotNull);

    expect(await sp.silence(false), isNull);
    expect(await pactl(['get-default-sink']), before);
    expect(await sinkOfInputs(), {before});
    expect(await pactl(['list', 'short', 'sinks']), isNot(contains('localview_stream')));
  }, skip: hasPulse() ? false : 'needs a PulseAudio / PipeWire server');
}

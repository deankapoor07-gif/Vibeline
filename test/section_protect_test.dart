// Automatic changes while a set plays (cleaner vocals, the next mashup)
// must never replace the part playing or the next 45 s with audio that
// isn't mixed yet: that is what made the music stop and catch up.
// Run with HOME set to an empty folder (it writes section files there).
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/mixer.dart';
import 'package:vibeline/sections.dart';

Map<String, dynamic> plan(double gain) => {
      'duration': 150.0,
      'clips': [
        {'path': '/x/a.flac', 'outStart': 0.0, 'srcStart': 0.0, 'srcEnd': 150.0, 'rate': 1.0, 'pitchCents': 0.0, 'gainDb': gain},
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var renderOpen = true;
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('vibeline/mixer'), (call) async {
      if (call.method == 'render') {
        if (!renderOpen) await Completer<void>().future; // stays unrendered
        final out = (call.arguments as Map)['out'] as String;
        File(out).writeAsStringSync('x');
        return out;
      }
      return null;
    });
  });

  Future<SectionEngine> rendered(double Function() playhead) async {
    final e = SectionEngine(Mixer(), playhead);
    renderOpen = true;
    await e.setPlan(plan(0), [50, 100]);
    for (var i = 0; i < 100 && !e.allReady; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(e.allReady, isTrue);
    renderOpen = false;
    return e;
  }

  test('protected: the part playing and the next 45 s keep their audio', () async {
    expect(Platform.environment['HOME'], isNot(contains('/Users/dean')), reason: 'run with HOME set to an empty folder');
    var pos = 40.0;
    final e = await rendered(() => pos);
    final old = [for (final s in e.sections) s.hash];
    await e.setPlan(plan(-1), [50, 100], protect: true);
    expect(e.sections[0].hash, old[0]); // playing
    expect(e.sections[1].hash, old[1]); // starts within 45 s
    expect(e.sections[0].path, isNotNull);
    expect(e.sections[1].path, isNotNull);
    expect(e.sections[2].hash, isNot(old[2])); // far ahead: takes the change
    pos = 0;
  });

  test('not protected (your own edits): everything takes the change', () async {
    final e = await rendered(() => 40.0);
    final old = [for (final s in e.sections) s.hash];
    await e.setPlan(plan(-2), [50, 100]);
    for (var k = 0; k < 3; k++) {
      expect(e.sections[k].hash, isNot(old[k]));
    }
  });
}

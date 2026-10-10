// Puts samples on the sample lane and writes the render plan.
// Skipped unless VIBELINE_REAL=1.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/mashup.dart';
import 'package:vibeline/vibe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('sample lane', () async {
    final lib = MusicLibrary()..useMusicApp = false;
    await lib.scan();
    final vibe = parseVibe('party, mix genres, my shazams');
    final maker = MashupMaker(vibe, seed: 3);
    final rng = math.Random(3);
    final ranked = lib.tracks.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    final pool = ranked.take(80).map((e) => e.$1).toList();
    await lib.analyze(pool, (d, t) {});
    final session = MashupSession.start(maker, pool);
    await session.fill(lib, 2, (s) {}, () {});
    session.layout();
    final song = lib.tracks.firstWhere((t) => t.title.contains('Uptown Funk'));
    final synced = await session.addSample(0, song, lib); // locked to the beat, over the intro
    final acapella = await session.addSample(1, lib.tracks.firstWhere((t) => t.title.contains('1999')), lib);
    await lib.separate([acapella.track], (d, t, c) {});
    acapella
      ..vocalOnly = true
      ..bar = 8;
    final free = await session.addSample(1, lib.tracks.firstWhere((t) => t.title == 'Kiss'), lib);
    free
      ..sync = false
      ..bar = 24
      ..bars = 8;
    final plan = session.layout();
    final clips = (plan.renderJson['clips'] as List).cast<Map<String, dynamic>>();
    for (final s in [synced, acapella, free]) {
      final c = clips.firstWhere((c) => c['path'] == (s.vocalOnly ? s.track.stems!.paths['vocals'] : s.track.path));
      print('${s.track.title}: starts ${(c['outStart'] as num).toStringAsFixed(1)}s, ${s.bars} bars, '
          '${c['warp'] != null ? 'synced' : 'free-running'}, gain ${(c['gainDb'] as num).toStringAsFixed(1)} dB, vocal only ${s.vocalOnly}');
    }
    File(Platform.environment['VIBELINE_PLAN_OUT']!).writeAsStringSync(jsonEncode(plan.renderJson));
  }, skip: Platform.environment['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 20)));
}

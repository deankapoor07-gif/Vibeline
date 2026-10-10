// Times the work done on the UI thread. Skipped unless VIBELINE_REAL=1.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/mashup.dart';
import 'package:vibeline/vibe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('ui-thread costs', () async {
    final lib = MusicLibrary();
    await lib.scan();
    final vibe = parseVibe('party, mix genres, my shazams');
    final maker = MashupMaker(vibe, seed: 3);
    final rng = math.Random(3);
    final ranked = lib.tracks.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    await lib.analyze(ranked.take(500).map((e) => e.$1).toList(), (d, t) {});
    final analysed = lib.tracks.where((t) => t.analysis != null).toList();
    final pool = ranked.take(80).map((e) => e.$1).toList();
    final session = MashupSession.start(maker, pool);
    await session.fill(lib, 6, (s) {}, () {});
    final m = session.mashups.first;
    var sw = Stopwatch()..start();
    for (final t in analysed) {
      maker.fit(t, m.beat, nearTempo: m.tempo);
    }
    print('fit scoring for ${analysed.length} songs: ${sw.elapsedMilliseconds} ms');
    sw = Stopwatch()..start();
    for (final t in analysed) {
      maker.fit(t, m.beat, nearTempo: m.tempo);
    }
    print('  again (cached?): ${sw.elapsedMilliseconds} ms');
    sw = Stopwatch()..start();
    final plan = session.layout();
    print('layout: ${sw.elapsedMilliseconds} ms');
    sw = Stopwatch()..start();
    final s = jsonEncode(plan.renderJson);
    print('render json: ${(s.length / 1e6).toStringAsFixed(1)} MB in ${sw.elapsedMilliseconds} ms');
  }, skip: Platform.environment['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 30)));
}

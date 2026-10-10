// Inserts a beat break and a beat-with-AI-vocal into a real mashup set.
// Skipped unless VIBELINE_REAL=1.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/mashup.dart';
import 'package:vibeline/vibe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('insert beats into a set', () async {
    final lib = MusicLibrary();
    await lib.scan();
    final vibe = parseVibe('party, mix genres, my shazams');
    final maker = MashupMaker(vibe, seed: 3);
    final rng = math.Random(3);
    final ranked = lib.tracks.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    final pool = ranked.take(80).map((e) => e.$1).toList();
    await lib.analyze(pool, (d, t) {});
    final session = MashupSession.start(maker, pool);
    await session.fill(lib, 3, (s) {}, () {});
    final before = session.layout();
    final countBefore = before.mashups.length;
    final song = lib.tracks.firstWhere((t) => t.title.contains('Uptown Funk'));
    final sw = Stopwatch()..start();
    expect(await session.insertBeat(0, song, false, lib, (s) {}), isNull);
    print('beat break inserted in ${sw.elapsed.inSeconds}s');
    sw.reset();
    final song2 = lib.tracks.firstWhere((t) => t.title.contains('1999'));
    final err = await session.insertBeat(2, song2, true, lib, (s) {});
    print('beat + vocal: ${err ?? 'ok'} in ${sw.elapsed.inSeconds}s');
    final after = session.layout();
    for (final m in after.mashups) {
      print('${m.beatOnly ? 'BEAT BREAK' : m.vocal.title} / ${m.beat.title} · ${m.playedBpm.toStringAsFixed(1)} BPM · ${m.start.toStringAsFixed(1)}–${m.end.toStringAsFixed(1)}');
    }
    print('before ${before.duration.toStringAsFixed(0)}s, after ${after.duration.toStringAsFixed(0)}s, clips ${(after.renderJson['clips'] as List).length}');
    expect(after.mashups.length, countBefore + 2);
  }, skip: Platform.environment['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 30)));
}

// Builds an anchor-mode mashup set and writes the render plan.
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
  test('anchor mode set', () async {
    final lib = MusicLibrary()..useMusicApp = false;
    await lib.scan();
    final vibe = parseVibe(Platform.environment['VIBELINE_VIBE'] ?? 'party, mix genres, my shazams');
    final maker = MashupMaker(vibe, seed: 5);
    final rng = math.Random(5);
    final ranked = lib.tracks.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    final pool = ranked.take(120).map((e) => e.$1).toList();
    final sw = Stopwatch()..start();
    await lib.analyze(pool, (d, t) {});
    print('analysed ${pool.length} in ${sw.elapsed.inSeconds}s');
    final session = MashupSession.start(maker, pool)..anchorMode = true;
    await session.fill(lib, int.tryParse(Platform.environment['VIBELINE_COUNT'] ?? '') ?? 4, (s) {}, () {});
    final a = session.anchor!;
    print('ANCHOR: ${a.track.artist} – ${a.track.title} · ${a.tempo.toStringAsFixed(1)} BPM · key ${a.camelot} · loop from bar ${a.loopStart}');
    final plan = session.layout();
    for (final m in plan.mashups) {
      print('${m.vocal.title} (vocal ${m.vocalShift >= 0 ? '+' : ''}${m.vocalShift} st) OVER ${m.beat.title} (beat ${m.beatShift >= 0 ? '+' : ''}${m.beatShift} st, key ${m.beatGrid.camelot}) · '
          'vocal ${m.vocalIn.toStringAsFixed(1)}–${m.vocalOut.toStringAsFixed(1)}s (${m.vocalBars} bars)');
    }
    print(plan.summary);
    final out = Platform.environment['VIBELINE_PLAN_OUT'];
    if (out != null) File(out).writeAsStringSync(jsonEncode({...plan.renderJson, 'cuts': plan.cuts}));
  }, skip: Platform.environment['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 60)));
}

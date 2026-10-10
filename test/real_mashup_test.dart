// Builds a mashup set from the real music folder and writes the render plan
// (plus section cuts) to $VIBELINE_PLAN_OUT. Skipped unless VIBELINE_REAL=1.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/mashup.dart';
import 'package:vibeline/vibe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  test('make a mashup set from the real library', () async {
    final lib = MusicLibrary();
    await lib.scan();
    final vibe = parseVibe(env['VIBELINE_VIBE'] ?? 'party, mix genres, my shazams');
    final maker = MashupMaker(vibe, seed: 3);
    final rng = math.Random(3);
    final ranked = lib.tracks.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    final count = int.tryParse(env['VIBELINE_COUNT'] ?? '') ?? maker.mashupCount;
    final pool = ranked.take(math.max(80, count * 4)).map((e) => e.$1).toList();
    final sw = Stopwatch()..start();
    await lib.analyze(pool, (d, t) {});
    print('vibe: ${vibe.summary} · ${vibe.minutes} min · $count mashups · analysed ${pool.length} in ${sw.elapsed.inSeconds}s');
    final session = MashupSession.start(maker, pool);
    sw.reset();
    await session.fill(lib, count, (s) {}, () {});
    print('made ${session.mashups.length} mashups in ${sw.elapsed.inSeconds}s');
    if (env['VIBELINE_TEMPO_TEST'] == '1' && session.mashups.length >= 3) {
      session.mashups[1].tempoScale = 1.08;
      session.mashups[2].tempoScale = session.mashups[2].vocalNaturalScale;
      print('tempo test: mashup 2 at 1.08x, mashup 3 matched to its vocal (${session.mashups[2].vocalNaturalScale.toStringAsFixed(3)}x)');
    }
    final plan = session.layout();
    for (final m in plan.mashups) {
      print('${m.beatOnly ? 'BEAT BREAK' : '${m.vocal.artist} – ${m.vocal.title}'}  OVER  ${m.beat.artist} – ${m.beat.title}');
      print('   ${m.styleLine} · ${m.playedBpm.toStringAsFixed(1)} BPM · key ${m.keyMatch} (vocal ${m.vocalShift} st, '
          '${m.vocalCents.toStringAsFixed(0)}¢ total, beat ${m.beatCents.toStringAsFixed(0)}¢, vocal level ${m.autoVocalDb.toStringAsFixed(1)} dB) · '
          '${m.start.toStringAsFixed(1)}–${m.end.toStringAsFixed(1)}s');
    }
    print('${plan.summary} · ${plan.duration.toStringAsFixed(0)}s · ${(plan.renderJson['clips'] as List).length} clips · cuts ${plan.cuts.map((c) => c.toStringAsFixed(1)).join(', ')}');
    final out = env['VIBELINE_PLAN_OUT'];
    if (out != null) File(out).writeAsStringSync(jsonEncode({...plan.renderJson, 'cuts': plan.cuts}));
  }, skip: env['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 120)));
}

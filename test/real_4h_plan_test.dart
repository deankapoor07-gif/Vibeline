// Dry run: can the library supply a 4-hour mashup set? Plans the whole
// sequence (no stem splitting). Skipped unless VIBELINE_REAL=1.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/mashup.dart';
import 'package:vibeline/vibe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('plan a 4 hour set', () async {
    final lib = MusicLibrary();
    await lib.scan();
    final vibe = parseVibe(Platform.environment['VIBELINE_VIBE'] ?? 'festival, 4 hours, mix genres, my shazams');
    final maker = MashupMaker(vibe, seed: 1);
    final count = maker.mashupCount;
    final rng = math.Random(1);
    final ranked = lib.tracks.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    final pool = ranked.take(math.max(80, count * 4)).map((e) => e.$1).toList();
    final sw = Stopwatch()..start();
    await lib.analyze(pool, (d, t) {
      if (d % 50 == 0) print('  analysed $d / $t');
    });
    print('vibe ${vibe.summary}: $count mashups wanted; analysed ${pool.length} songs in ${sw.elapsed.inSeconds}s');
    sw.reset();
    final session = MashupSession.start(maker, pool);
    print('ranked pairings in ${sw.elapsed.inMilliseconds} ms');
    final plan = session.dryRun(count);
    print('planned ${plan.length} of $count mashups');
    final tempos = plan.map((p) => p.$2.round()).toList();
    print('tempo journey: ${[for (var i = 0; i < tempos.length; i += 6) tempos[i]].join(' → ')}');
    print('distinct songs: ${plan.expand((p) => p.$1.split('|')).toSet().length}');
  }, skip: Platform.environment['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 60)));
}

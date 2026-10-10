// Plans a mix from the real music folder and writes the render plan to
// $VIBELINE_PLAN_OUT. Skipped unless VIBELINE_REAL=1.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/models.dart';
import 'package:vibeline/planner.dart';
import 'package:vibeline/vibe.dart';
import 'dart:math' as math;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  test('plan a mix from the real library', () async {
    final lib = MusicLibrary();
    await lib.scan();
    print('${lib.tracks.length} tracks, ${lib.shazamMatches} shazam');
    final vibe = parseVibe(env['VIBELINE_VIBE'] ?? 'Aussie rock crowd, high energy, smooth transitions');
    print('vibe: ${vibe.summary} target ${vibe.targetBpm}');
    final rng = math.Random(1);
    final ranked = lib.tracks.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    final wanted = ranked.take(math.max(48, vibe.trackCount * 5)).map((e) => e.$1).toList();
    final sw = Stopwatch()..start();
    await lib.analyze(wanted, (d, t) {});
    print('analysed in ${sw.elapsed.inSeconds}s');
    final plan = MixPlanner(vibe, seed: 1).plan(wanted)!;
    print(plan.summary);
    for (var i = 0; i < plan.tracks.length; i++) {
      final p = plan.tracks[i];
      print('${i + 1}. ${p.track.artist} – ${p.track.title} [${p.track.genre} ${p.track.year}]${p.track.shazam ? ' (shazam)' : ''} '
          'key ${p.grid.camelot}${p.pitchSemitones != 0 ? ' shift ${p.pitchSemitones}' : ''} bpm ${p.grid.bpm.toStringAsFixed(1)} rate ${p.rate.toStringAsFixed(3)} '
          'mix ${p.outStart.toStringAsFixed(1)}–${p.outEnd.toStringAsFixed(1)} src ${p.srcStart.toStringAsFixed(1)}–${p.srcEnd.toStringAsFixed(1)}');
      if (i < plan.transitions.length) {
        final t = plan.transitions[i];
        print('     ↳ ${t.type.label} ${t.bars} bars, keys ${t.keyMatch}, at ${t.start.toStringAsFixed(1)}s');
      }
    }
    print('duration ${plan.duration.toStringAsFixed(1)}s');
    final out = env['VIBELINE_PLAN_OUT'];
    if (out != null) File(out).writeAsStringSync(jsonEncode(plan.toRenderJson()));
  }, skip: env['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 20)));
}

// Plans a theme-night blend mix (Mashup Mode off) the way the app does and
// reports the tempo stretching and where vocals overlap in each blend.
// Skipped unless VIBELINE_REAL=1. VIBELINE_THEME=Kiwi.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/planner.dart';
import 'package:vibeline/vibe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('theme blend mix', () async {
    final lib = MusicLibrary();
    await lib.loadSettings();
    await lib.scan();
    final theme = Platform.environment['VIBELINE_THEME'] ?? 'Kiwi';
    final vibe = parseTheme(Platform.environment['VIBELINE_VIBE'] ?? 'party, mix genres, my shazams', theme);
    final note = fitThemeLength(vibe, vibe.minutesAvailable(lib.tracks, mashups: false));
    final rng = math.Random(5);
    final pool = lib.tracks.where(vibe.fits).toList()
      ..sort((a, b) => tagScore(b, vibe, rng).compareTo(tagScore(a, vibe, rng)));
    await lib.analyze(pool, (d, t) {});
    fitThemeTempo(vibe, pool);
    print('TEMPO ${vibe.targetBpm}');
    if (Platform.environment['VIBELINE_SEPARATE'] == '1') await lib.separate(pool.where((t) => t.analysis != null).toList(), (d, n, c) {});
    print('THEME $theme · ${pool.length} songs · target ${vibe.minutes.round()} min / ${vibe.trackCount} songs · $note');
    final plan = MixPlanner(vibe, seed: 5).plan(pool);
    if (plan == null) {
      print('NO PLAN');
      return;
    }
    print('PLAN ${plan.summary} · ${(plan.duration / 60).toStringAsFixed(1)} min');
    for (final t in plan.tracks) {
      final g = t.grid;
      print('  ${t.track.title} · own ${g.steadyBpm.toStringAsFixed(0)} bpm · comes in at ${((t.rate - 1) * 100).toStringAsFixed(1)}% → home ${((t.homeRate - 1) * 100).toStringAsFixed(1)}% · key ${t.pitchSemitones} '
          '(${((t.rate - 1) * 100).toStringAsFixed(1)}%) · in ${t.outStart.toStringAsFixed(0)}s–${t.outEnd.toStringAsFixed(0)}s');
    }
    final out = Platform.environment['VIBELINE_PLAN_OUT'];
    if (out != null) File(out).writeAsStringSync(jsonEncode(plan.toRenderJson()));
    String pct(double? v) => v == null ? '?' : '${(v * 100).round()}%';
    for (var i = 0; i < plan.transitions.length; i++) {
      final x = plan.transitions[i];
      final a = plan.tracks[i], b = plan.tracks[i + 1];
      print('  blend ${i + 1}: ${x.type.name} ${x.bars} bars at ${x.start.toStringAsFixed(0)}s · '
          'sung: A ${pct(a.vocalsBetween(x.start, x.end))} · B ${pct(b.vocalsBetween(x.start, x.end))}');
    }
  }, skip: Platform.environment['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 60)));
}

// Builds a theme-night mashup set the way the app does and reports how it went.
// Skipped unless VIBELINE_REAL=1. VIBELINE_THEME=Kiwi, VIBELINE_ANCHOR_ON=1.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/mashup.dart';
import 'package:vibeline/vibe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('theme mashup set', () async {
    final lib = MusicLibrary();
    await lib.loadSettings();
    await lib.scan();
    final theme = Platform.environment['VIBELINE_THEME'] ?? 'Kiwi';
    final vibe = parseTheme(Platform.environment['VIBELINE_VIBE'] ?? 'party, mix genres, my shazams', theme);
    final anchorOn = Platform.environment['VIBELINE_ANCHOR_ON'] == '1';
    var pool = lib.tracks.where(vibe.fits).toList();
    final note = fitThemeLength(vibe, vibe.minutesAvailable(lib.tracks, mashups: true));
    print('THEME $theme: ${pool.length} songs · note: $note · target ${vibe.minutes.toStringAsFixed(0)} min');
    final maker = MashupMaker(vibe, seed: 5);
    final rng = math.Random(5);
    final ranked = pool.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    pool = ranked.map((e) => e.$1).toList();
    await lib.analyze(pool, (d, t) {});
    fitThemeTempo(vibe, pool);
    print('TEMPO ${vibe.targetBpm}');
    final ok = pool.where((t) => t.analysis != null).toList();
    print('analysed ${ok.length}/${pool.length}: '
        '${ok.map((t) => '${t.title} ${t.analysis!.steadyBpm.toStringAsFixed(0)}bpm ${t.analysis!.camelot}').join(' | ')}');
    final session = MashupSession.start(maker, pool)..anchorMode = anchorOn;
    final statuses = <String>[];
    await session.fill(lib, maker.mashupCount, (s) => statuses.add(s), () {});
    print('wanted ${maker.mashupCount}, made ${session.mashups.length}');
    for (final m in session.mashups) {
      print('  ${m.vocal.title} OVER ${m.beat.title} · ${m.tempo.toStringAsFixed(0)} bpm');
    }
    print('last statuses: ${statuses.reversed.take(5).toList().reversed.join(' / ')}');
    final out = Platform.environment['VIBELINE_PLAN_OUT'];
    if (out != null && session.mashups.isNotEmpty) {
      final plan = session.layout();
      File(out).writeAsStringSync(jsonEncode({...plan.renderJson, 'cuts': plan.cuts}));
    }
  }, skip: Platform.environment['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 60)));
}

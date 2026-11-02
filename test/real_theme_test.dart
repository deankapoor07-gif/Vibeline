// Builds a theme-night mashup set the way the app does and reports how it went.
// Skipped unless VIBELINE_REAL=1. VIBELINE_THEME=Kiwi, VIBELINE_ANCHOR_ON=1.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/auto_fx.dart';
import 'package:vibeline/fx_deck.dart';
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
    final singers = lib.tracks.where(vibe.fits).toList();
    var pool = lib.tracks.toList();
    final note = fitThemeLength(vibe, vibe.minutesAvailable(lib.tracks, mashups: true));
    print('THEME $theme: ${pool.length} songs · note: $note · target ${vibe.minutes.toStringAsFixed(0)} min');
    final maker = MashupMaker(vibe, seed: 5);
    final rng = math.Random(5);
    final ranked = pool.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2));
    final all = ranked.map((e) => e.$1).toList();
    // As the app does: every song in theme (they sing) plus the best others as beats.
    pool = {...singers, ...all.where((t) => !vibe.fits(t)).take(math.max(80, maker.mashupCount * 4))}.toList();
    await lib.analyze(pool, (d, t) {});
    fitThemeTempo(vibe, singers);
    print('TEMPO ${vibe.targetBpm} · ${singers.length} singers · ${pool.length} songs in the pool');
    final session = MashupSession.start(maker, pool)..anchorMode = anchorOn;
    final statuses = <String>[];
    await session.fill(lib, maker.mashupCount, (s) => statuses.add(s), () {});
    print('wanted ${maker.mashupCount}, made ${session.mashups.length}');
    for (final m in session.mashups) {
      print('  ${m.vocal.title} OVER ${m.beat.title} · ${m.tempo.toStringAsFixed(0)} bpm · voice speed ${((m.vocalSpeed - 1) * 100).toStringAsFixed(1)}% · key ${m.vocalShift} · pitch ${(m.vocalCents / 100).toStringAsFixed(2)} semitones');
    }
    print('last statuses: ${statuses.reversed.take(5).toList().reversed.join(' / ')}');
    final out = Platform.environment['VIBELINE_PLAN_OUT'];
    if (out != null && session.mashups.isNotEmpty) {
      final plan = session.layout();
      File(out).writeAsStringSync(jsonEncode({...plan.renderJson, 'cuts': plan.cuts}));
      // Timing check data: for each mashup beat, the matching moment in the
      // vocal song and in the beat song (from the warp maps), with the drums.
      final align = <Map<String, dynamic>>[];
      final clips = (plan.renderJson['clips'] as List).cast<Map<String, dynamic>>();
      for (final m in session.mashups) {
        if (m.beatOnly || m.vocal.stems == null || m.beat.stems == null) continue;
        final vp = m.vocal.stems!.paths, bp = m.beat.stems!.paths;
        final vClip = clips.where((c) => c['path'] == vp['vocals'] && c['warp'] != null).firstOrNull;
        final bClip = clips
            .where((c) => bp.values.contains(c['path']) && c['warp'] != null)
            .fold<Map<String, dynamic>?>(null, (a, c) => a == null || (c['warp'] as List).length > (a['warp'] as List).length ? c : a);
        if (vClip == null || bClip == null || vp['drums'] == null || bp['drums'] == null) continue;
        align.add({
          'vocal': m.vocal.title, 'beat': m.beat.title,
          'vocalDrums': vp['drums'], 'beatDrums': bp['drums'],
          'vocalWarp': vClip['warp'], 'beatWarp': bClip['warp'],
          'vocalBars': m.vocalBars, 'acapella': m.acapellaBars,
        });
      }
      File('$out.align.json').writeAsStringSync(jsonEncode(align));
      final cues = mashupFx(session.mashups);
      File('$out.fx.json').writeAsStringSync(jsonEncode({
        'fx': cues,
        'grid': [for (final m in session.mashups) ...m.beatTimes],
      }));
      for (final c in cues) {
        print('  FX ${BeatFx.values[c['kind'] as int].label} ${c['beats']} beat · ${(c['start'] as double).toStringAsFixed(1)}–${(c['end'] as double).toStringAsFixed(1)}s');
      }
      print(plan.summary);
      for (final m in session.mashups) {
        print('  ${m.vocal.title}: in ${m.start.toStringAsFixed(1)}s · vocal ${m.vocalIn.toStringAsFixed(1)}s'
            '${m.acapellaBars > 0 ? ' · ACAPELLA ${m.acapellaBars} bars, drop ${m.beatTimes[(Mashup.introBars + m.acapellaBars) * 4].toStringAsFixed(1)}s' : ''}');
      }
    }
  }, skip: Platform.environment['VIBELINE_REAL'] != '1', timeout: const Timeout(Duration(minutes: 60)));
}

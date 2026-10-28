import 'dart:math' as math;

import 'models.dart';
import 'vibe.dart';

// ---------------------------------------------------------
// HARMONY (Camelot wheel)
// ---------------------------------------------------------
int _camNum(String c) => int.tryParse(c.substring(0, c.length - 1)) ?? 0;
String _camLetter(String c) => c.isEmpty ? '' : c.substring(c.length - 1);

/// Moving a song up one semitone moves it 7 steps round the Camelot wheel.
String shiftCamelot(String code, int semitones) {
  if (code.length < 2) return code;
  final n = (((_camNum(code) - 1 + 7 * semitones) % 12) + 12) % 12 + 1;
  return '$n${_camLetter(code)}';
}

/// 1 = same key, ~0.8 = neighbours on the wheel, low = clashing keys.
double keyCompat(String a, String b) {
  if (a.length < 2 || b.length < 2) return 0.5;
  final na = _camNum(a), nb = _camNum(b);
  final d = math.min((na - nb).abs(), 12 - (na - nb).abs());
  final sameLetter = _camLetter(a) == _camLetter(b);
  if (d == 0) return sameLetter ? 1.0 : 0.8;
  if (d == 1) return sameLetter ? 0.85 : 0.4;
  if (d == 2 && sameLetter) return 0.5;
  return 0.1;
}

class _Harmony {
  final int shift;
  final double score;
  final String label;
  const _Harmony(this.shift, this.score, this.label);
}

/// Best way to bring song B in after A: as-is, or nudged ±1 semitone.
_Harmony _bestHarmony(String playedA, String b) {
  var best = const _Harmony(0, -1, 'clash');
  for (final s in const [0, 1, -1]) {
    final c = keyCompat(playedA, shiftCamelot(b, s));
    final score = c - (s == 0 ? 0 : 0.12);
    if (score > best.score) {
      final label = c >= 0.99
          ? (s == 0 ? 'perfect' : 'shifted')
          : c >= 0.8
              ? (s == 0 ? 'compatible' : 'shifted')
              : c >= 0.45
                  ? 'energy'
                  : 'clash';
      best = _Harmony(s, score, label);
    }
  }
  return best;
}

// ---------------------------------------------------------
// PLANNER
// ---------------------------------------------------------
class _Cand {
  final LibraryTrack track;
  final Analysis grid;
  final double tagScore;
  _Cand(this.track, this.grid, this.tagScore);
  double get bpm => grid.steadyBpm;
  String get family => genreFamily(track.genre);
}

class _Beam {
  final List<int> order;
  final double score;
  final List<String> playedKeys;
  const _Beam(this.order, this.score, this.playedKeys);
}

class MixPlanner {
  final VibeProfile vibe;
  final math.Random rng;
  MixPlanner(this.vibe, {int? seed}) : rng = math.Random(seed);

  /// Picks the master tempo and the songs that can sit at it (straight, or
  /// counted at half/double time), within the ±8% a DJ would pitch a deck.
  List<_Cand> _candidates(List<LibraryTrack> pool, double tempo, double maxStretch) {
    final out = <_Cand>[];
    for (final t in pool) {
      final a = t.analysis;
      if (a == null || a.barCount < 40 || a.beats.length < 64) continue;
      final steady = a.steadyBpm;
      var best = 1.0;
      for (final f in const [0.5, 1.0, 2.0]) {
        if ((math.log(tempo / (steady * f))).abs() < (math.log(tempo / (steady * best))).abs()) best = f;
      }
      final eff = steady * best;
      if ((tempo / eff - 1).abs() > maxStretch) continue;
      var s = tagScore(t, vibe, rng);
      if (a.danceability < 1.0 && vibe.targetBpm > 105) s -= 1.0;
      if (a.tempoDrift > 0.03) s -= 0.8; // drifting live takes are harder to keep locked
      out.add(_Cand(t, a.scaled(best), s));
    }
    return out;
  }

  MixPlan? plan(List<LibraryTrack> pool) {
    // Settle on a master tempo near the vibe's target that most songs can reach.
    var tempo = vibe.targetBpm;
    var bestCount = -1;
    for (var d = -6; d <= 6; d += 2) {
      final t = vibe.targetBpm + d;
      final c = _candidates(pool, t, 0.06).length - d.abs() * 0.3;
      if (c > bestCount) {
        bestCount = c.round();
        tempo = t;
      }
    }
    var cands = _candidates(pool, tempo, 0.06);
    if (cands.length < vibe.trackCount) cands = _candidates(pool, tempo, 0.09);
    if (cands.length < 2) return null;

    final order = _sequence(cands, math.min(vibe.trackCount, cands.length));
    return _build(order.map((i) => cands[i]).toList(), tempo);
  }

  // ---------------------------------------------------------------- order

  List<int> _sequence(List<_Cand> cands, int count) {
    const width = 40;
    var beams = <_Beam>[];
    for (var i = 0; i < cands.length; i++) {
      final c = cands[i];
      final s = c.tagScore - 2.5 * (c.grid.energy - vibe.energyAt(0)).abs();
      beams.add(_Beam([i], s, [c.grid.camelot]));
    }
    beams.sort((a, b) => b.score.compareTo(a.score));
    beams = beams.take(width).toList();

    for (var step = 1; step < count; step++) {
      final p = count == 1 ? 0.0 : step / (count - 1);
      final next = <_Beam>[];
      for (final b in beams) {
        final prev = cands[b.order.last];
        final usedArtists = {for (final i in b.order) cands[i].track.artist.toLowerCase()};
        final usedSongs = {for (final i in b.order) cands[i].track.songKey};
        for (var j = 0; j < cands.length; j++) {
          if (b.order.contains(j) || usedSongs.contains(cands[j].track.songKey)) continue;
          final c = cands[j];
          final h = _bestHarmony(b.playedKeys.last, c.grid.camelot);
          var s = c.tagScore;
          s += 1.4 * h.score;
          s -= 2.5 * (c.grid.energy - vibe.energyAt(p)).abs();
          // Each song is matched to the last one's own tempo, then ridden home
          // to its own: neighbours more than 8% apart can't be matched cleanly.
          final gap = (prev.bpm / c.bpm - 1).abs();
          s -= 6 * gap + (gap > 0.08 ? 20 : 0);
          if (usedArtists.contains(c.track.artist.toLowerCase())) s -= 2.5;
          if (vibe.mixGenres) {
            if (c.family != prev.family) s += 0.6;
            if (c.track.year > 0 && prev.track.year > 0 && (c.track.year - prev.track.year).abs() >= 10) s += 0.3;
          } else if (c.family == prev.family) {
            s += 0.25;
          }
          next.add(_Beam([...b.order, j], b.score + s, [...b.playedKeys, shiftCamelot(c.grid.camelot, h.shift)]));
        }
      }
      next.sort((a, b) => b.score.compareTo(a.score));
      beams = next.take(width).toList();
      if (beams.isEmpty) break;
    }
    return beams.first.order;
  }

  // ---------------------------------------------------------------- timing

  /// First bar where the song properly kicks in (after a quiet intro).
  int _dropBar(Analysis g) {
    for (var b = g.firstBar; b < g.barCount - 4; b++) {
      final e = (g.barEnergy[b] + g.barEnergy[b + 1] + g.barEnergy[b + 2] + g.barEnergy[b + 3]) / 4;
      if (e >= 0.7) return b;
    }
    return g.firstBar;
  }

  double _meanEnergy(Analysis g, int from, int to) {
    final a = from.clamp(0, g.barCount - 1), b = to.clamp(a + 1, g.barCount);
    var s = 0.0;
    for (var i = a; i < b; i++) {
      s += g.barEnergy[i];
    }
    return s / (b - a);
  }

  /// Source time of the start of [bar] (clamped to the song).
  double _barTime(Analysis g, int bar) => g.beats[g.beatIndexOfBar(bar).clamp(0, g.beats.length - 1)];

  /// How much of bars [from]–[to] are sung (0..1); null until the song's
  /// stems are known.
  double? _sung(LibraryTrack t, Analysis g, int from, int to) =>
      t.vocalsBetweenSrc(_barTime(g, from), _barTime(g, to));

  /// Bars a song is singing in (null when its stems aren't known yet).
  final _sungCache = <LibraryTrack, List<bool>?>{};
  List<bool>? _sungBars(LibraryTrack t, Analysis g) => _sungCache.putIfAbsent(t, () {
        if (t.stems == null) return null;
        return [for (var b = 0; b < g.barCount; b++) (_sung(t, g, b, b + 1) ?? 0) > 0.5];
      });

  /// How badly A (from bar [m]) and B (from bar [inB]) sing over each other
  /// in a [blend]-bar overlap: each bar both sing counts by how loud the
  /// quieter of the two is there (A fades out as B fades in), so a bar at
  /// either edge barely counts and one mid-blend counts most. Unknown vocals
  /// never clash.
  double _vocalClash(List<bool>? a, int m, List<bool>? b, int inB, int blend) {
    if (a == null || b == null) return 0;
    var clash = 0.0;
    for (var j = 0; j < blend; j++) {
      final x = m + j, y = inB + j;
      if (x < a.length && y < b.length && y >= 0 && a[x] && b[y]) {
        final p = (j + 0.5) / blend;
        clash += math.min(1 - p, p) * 2; // 0 at the edges, 1 in the middle
      }
    }
    return clash;
  }

  /// How good a place bar [m] is to start mixing out of a song: a phrase
  /// boundary just after a big section (chorus) ends, near [target].
  double _mixOutScore(Analysis g, int m, int target, int blend) {
    final before = _meanEnergy(g, m - 8, m);
    final after = _meanEnergy(g, m, m + blend);
    return 0.5 * before + (before - after) - (m - target).abs() / 32;
  }

  /// The transition into B: its type and length, the bar A starts mixing out
  /// at, and the bar of B that comes in. Tries the longest blend the keys
  /// allow first and takes the best spot where the two never sing at the same
  /// time (B's intro under A's outro, or A's last chorus over B's instrumental
  /// intro); shorter blends next; an echo-out (no overlap) last.
  (TransitionType, int, int, int) _blendPoints(LibraryTrack ta, Analysis ga, LibraryTrack tb, Analysis gb, _Harmony h,
      int earliest, int target, int solo) {
    final sungA = _sungBars(ta, ga), sungB = _sungBars(tb, gb);
    final drop = _dropBar(gb);
    final preferred = _transition(h);
    final options = <(TransitionType, int)>[
      preferred,
      if (preferred.$1 != TransitionType.echoOut && preferred.$2 > 8)
        vibe.smooth ? (TransitionType.filterSweep, 8) : (TransitionType.dropSwap, 8),
      // Songs whose beat wanders (live band takes) can't sit on top of each
      // other for long without flamming: those get the 8-bar blend at most.
    ].where((o) => o.$2 <= 8 || (ga.tempoDrift <= 0.03 && gb.tempoDrift <= 0.03)).toList();
    for (final (type, blend) in options) {
      if (type == TransitionType.echoOut) break;
      final latest = ga.lastBar - blend;
      (int, int)? best;
      var bestScore = -1e9;
      for (var m = math.min(earliest, latest); m <= latest; m++) {
        if ((m - ga.firstBar) % 8 != 0 && m != latest) continue;
        final base = _mixOutScore(ga, m, target, blend);
        // B comes in so its main section lands as A leaves, or earlier in its
        // intro if that's what keeps the vocals apart.
        final ideal = math.max(gb.firstBar, drop - blend);
        for (var inB = ideal; inB >= gb.firstBar; inB -= 4) {
          if (inB + blend + solo + 8 > gb.lastBar) continue;
          final clash = _vocalClash(sungA, m, sungB, inB, blend);
          if (clash > 1.0) continue; // about a bar of both singing loud, at most
          final s = base - (ideal - inB) / 16 - 2 * clash;
          if (s > bestScore) {
            bestScore = s;
            best = (m, inB);
          }
        }
      }
      if (best != null) return (type, blend, best.$1, best.$2);
    }
    // No overlap without clashing singers or keys. With B's stems known, just
    // its drums come in under A (no vocals, no key to clash) and the rest of
    // B lands on the phrase as A leaves: still a real blend.
    final stemBlend = _stemBlendPoints(ga, tb, gb, sungB, drop, earliest, target, solo);
    if (stemBlend != null) return stemBlend;
    // Otherwise A echoes away and B drops in clean.
    const blend = 4;
    final latest = ga.lastBar - blend;
    var m = latest, bestScore = -1e9;
    for (var x = math.min(earliest, latest); x <= latest; x++) {
      if ((x - ga.firstBar) % 8 != 0) continue;
      final s = _mixOutScore(ga, x, target, blend);
      if (s > bestScore) {
        bestScore = s;
        m = x;
      }
    }
    return (TransitionType.echoOut, blend, m, gb.firstBar);
  }

  /// A stem blend into B: B's drums alone under A for the blend, everything
  /// of B from the bar A leaves. B comes in where its drums are playing all
  /// through the blend, landing (ideally) on its main section and at the
  /// start of a line rather than mid-sentence. Null without B's stems.
  (TransitionType, int, int, int)? _stemBlendPoints(
      Analysis ga, LibraryTrack tb, Analysis gb, List<bool>? sungB, int drop, int earliest, int target, int solo) {
    final drums = tb.stems?.curves['drums'];
    if (tb.stems?.paths['drums'] == null || drums == null || drums.isEmpty) return null;
    final hop = tb.stems!.curveHop;
    final sorted = [...drums]..sort();
    final usual = sorted[sorted.length * 2 ~/ 3]; // the drums' level once they're going
    // Share of bars [from, to) with the drums going.
    double drumsShare(int from, int to) {
      var n = 0;
      for (var bar = from; bar < to; bar++) {
        final i = (_barTime(gb, bar) / hop).round().clamp(0, drums.length - 1);
        final j = (_barTime(gb, bar + 1) / hop).round().clamp(i + 1, drums.length);
        if (drums.sublist(i, j).reduce((a, b) => a + b) / (j - i) >= usual - 9) n++;
      }
      return n / (to - from);
    }

    for (final blend in [if (ga.tempoDrift <= 0.03 && gb.tempoDrift <= 0.03) 16, 8]) {
      final at = _stemBlendAt(ga, gb, sungB, drop, earliest, target, solo, blend, drumsShare);
      if (at != null) return at;
    }
    return null;
  }

  (TransitionType, int, int, int)? _stemBlendAt(Analysis ga, Analysis gb, List<bool>? sungB, int drop, int earliest,
      int target, int solo, int blend, double Function(int, int) drumsShare) {
    final latest = ga.lastBar - blend;
    var m = latest, bestM = -1e9;
    for (var x = math.min(earliest, latest); x <= latest; x++) {
      if ((x - ga.firstBar) % 8 != 0) continue;
      final s = _mixOutScore(ga, x, target, blend);
      if (s > bestM) {
        bestM = s;
        m = x;
      }
    }
    final ideal = math.max(gb.firstBar, drop - blend);
    int? inB;
    var best = -1e9;
    for (var b = gb.firstBar; b <= ideal + 16; b += 4) {
      if (b + blend + solo + 8 > gb.lastBar) continue;
      // Drums through most of the blend, and in the first bars (or B is silent).
      final share = drumsShare(b, b + blend);
      if (share < 0.7 || drumsShare(b, b + 2) < 0.5) continue;
      final land = b + blend;
      final midLine = sungB != null && land > 0 && land < sungB.length && sungB[land - 1] && sungB[land];
      final s = 3 * share - (b - ideal).abs() / 8 - (midLine ? 1.0 : 0);
      if (s > best) {
        best = s;
        inB = b;
      }
    }
    if (inB == null) return null;
    return (TransitionType.stemBlend, blend, m, inB);
  }

  /// Playback rate for a song: set by the master tempo, fine-tuned to the
  /// beats right around the blend so drifting songs stay locked. How far it
  /// may follow depends on how clean those beats are.
  double _anchoredRate(Analysis g, LocalGrid local, double tempo, double outBeat) {
    final anchored = 60 / g.steadyBpm / (60 / tempo);
    final matched = local.period / outBeat;
    final room = local.trustworthy ? 0.05 : 0.02;
    return matched.clamp(anchored * (1 - room), anchored * (1 + room)).clamp(0.85, 1.15);
  }

  (TransitionType, int) _transition(_Harmony h) {
    if (h.score >= 0.75) return vibe.smooth ? (TransitionType.bassSwap, 16) : (TransitionType.dropSwap, 8);
    if (h.score >= 0.4) return vibe.smooth ? (TransitionType.filterSweep, 8) : (TransitionType.dropSwap, 8);
    return (TransitionType.echoOut, 4);
  }

  MixPlan _build(List<_Cand> order, double tempo) {
    final targetPlay = vibe.smooth ? 64 : 48;
    final solo = vibe.smooth ? 16 : 8;
    final tracks = <PlannedTrack>[];
    final transitions = <PlannedTransition>[];

    // Files can differ by 20 dB, so level each song properly.
    double gainFor(Analysis a) => (-13.5 - a.loudnessDb).clamp(-12.0, 20.0);

    // First song: starts at its first musical bar, at the master tempo.
    final c0 = order.first;
    final g0 = c0.grid;
    final in0 = g0.firstBar;
    final fit0 = g0.fit(g0.beatIndexOfBar(in0), g0.beatIndexOfBar(in0 + 32));
    final first = PlannedTrack(
      track: c0.track,
      grid: g0,
      rate: 1.0, // the first song plays at its own speed and key
      pitchSemitones: 0,
      gainDb: gainFor(g0),
      deck: 0,
    )
      ..srcStart = math.max(0, fit0.timeOfBeat(g0.beatIndexOfBar(in0)))
      ..outStart = 0;
    first.keys.add(const Keyframe(0));
    tracks.add(first);

    var inBar = in0; // bar where the current song entered
    var prevBlend = 0; // bars the current song spent blending in
    var playedKey = g0.camelot;

    for (var i = 1; i <= order.length; i++) {
      final a = tracks.last;
      final ga = a.grid;
      final isLast = i == order.length;

      if (isLast) {
        // Let the final song ride out, fading over its last 8 bars.
        final m = math.min(ga.lastBar - 7, inBar + targetPlay + 16).clamp(inBar + prevBlend + 8, ga.barCount - 1);
        final end = math.min(m + 8, ga.barCount);
        final fit = ga.fit(ga.beatIndexOfBar(m), ga.beatIndexOfBar(end));
        final x0 = a.mixAt(fit.timeOfBeat(ga.beatIndexOfBar(m)));
        final x1 = a.mixAt(fit.timeOfBeat(ga.beatIndexOfBar(end)));
        a.keys
          ..add(Keyframe(x0))
          ..add(Keyframe(x1, gain: 0, lpf: 2500));
        a.srcEnd = math.min(a.track.duration, fit.timeOfBeat(ga.beatIndexOfBar(end)) + 0.2);
        a.outEnd = a.mixAt(a.srcEnd);
        break;
      }

      final next = order[i];
      final h = _bestHarmony(playedKey, next.grid.camelot);
      final gb = next.grid;

      // Where A starts mixing out and where B comes in: the longest blend
      // the keys allow that never has both songs singing at once.
      final earliest = math.max(inBar + prevBlend + solo, inBar + (vibe.smooth ? 40 : 32));
      final (type, blend, m, inB) = _blendPoints(a.track, ga, next.track, gb, h, earliest, inBar + targetPlay, solo);

      // Line the two songs' beats up using the beats around the blend.
      final fitA = ga.fit(ga.beatIndexOfBar(m), ga.beatIndexOfBar(m + math.max(blend, 8)));
      final fitB = gb.fit(gb.beatIndexOfBar(inB), gb.beatIndexOfBar(inB + math.max(blend, 16)));
      // Seconds per beat in the mix right now (A's local tempo, trusted only
      // within 2% of its steady tempo).
      final trustA = fitA.trustworthy ? 0.05 : 0.02;
      final periodA = fitA.period.clamp(60 / ga.steadyBpm * (1 - trustA), 60 / ga.steadyBpm * (1 + trustA));
      final outBeat = periodA / a.rateAt(a.mixAt(fitA.timeOfBeat(ga.beatIndexOfBar(m))));
      // B is matched to A as it plays now (A has ridden home to its own tempo).
      final rateB = _anchoredRate(gb, fitB, 60 / outBeat, outBeat);
      double barX(int j) => a.mixAt(fitA.timeOfBeat(ga.beatIndexOfBar(m + j)));

      final b = PlannedTrack(
        track: next.track,
        grid: gb,
        rate: rateB,
        pitchSemitones: h.shift,
        gainDb: gainFor(gb),
        deck: i % 2,
      );
      final entryBar = type == TransitionType.echoOut ? blend : 0;
      b.srcStart = math.max(0, fitB.timeOfBeat(gb.beatIndexOfBar(inB)));
      b.outStart = barX(entryBar);

      // A leaves.
      a.srcEnd = math.min(a.track.duration, fitA.timeOfBeat(ga.beatIndexOfBar(m + blend)) + 0.1);
      a.outEnd = a.mixAt(a.srcEnd);
      _automate(type, a, b, barX, outBeat, blend: blend, bassFits: h.score >= 0.4);
      // Once B has the floor, ride it home to its own speed and key, done by
      // the time it can start mixing out.
      b
        ..rampFrom = barX(blend)
        ..rampLen = solo * 4 * outBeat
        ..homeRate = 1.0;
      if (const [TransitionType.echoOut, TransitionType.dropSwap, TransitionType.stemBlend].contains(type)) a.outEnd += 2.5;

      transitions.add(PlannedTransition(type, blend, h.label, barX(0), barX(blend)));
      tracks.add(b);
      inBar = inB;
      prevBlend = type == TransitionType.echoOut ? 0 : blend;
      playedKey = shiftCamelot(gb.camelot, h.shift);
    }

    final duration = tracks.map((t) => t.outEnd).reduce(math.max) + 1.0;
    final bpms = tracks.map((t) => t.playedBpm).toList();
    final lo = bpms.reduce(math.min).round(), hi = bpms.reduce(math.max).round();
    final summary = '${vibe.summary} · ${tracks.length} songs · ${lo == hi ? '$lo' : '$lo–$hi'} BPM';
    return MixPlan(tracks, transitions, duration, summary);
  }

  /// The DJ moves for each transition type, as EQ / filter / volume / echo
  /// automation on both decks. [x] gives the mix time of bar j of the blend.
  void _automate(TransitionType type, PlannedTrack a, PlannedTrack b, double Function(int) x, double beat,
      {int blend = 16, bool bassFits = false}) {
    const kill = -30.0;
    switch (type) {
      case TransitionType.stemBlend:
        // B's drums ride under A (and its bassline swaps in halfway when the
        // keys allow); on the last beat all of B crossfades in and A throws
        // an echo and filters away.
        final half = x(blend ~/ 2), land = x(blend);
        final stems = b.track.stems!.paths;
        final until = b.srcAt(land) + 1;
        b.layers.add(StemLayer(stems['drums']!, until, [
          Keyframe(x(0), gain: 0, high: -6),
          Keyframe(x(4), gain: 0.9),
          Keyframe(land - beat),
          Keyframe(land, gain: 0),
        ]));
        if (bassFits && stems['bass'] != null) {
          b.layers.add(StemLayer(stems['bass']!, until, [
            Keyframe(half - beat * 0.25, gain: 0),
            Keyframe(half),
            Keyframe(land - beat),
            Keyframe(land, gain: 0),
          ]));
        }
        b.keys.addAll([Keyframe(x(0), gain: 0), Keyframe(land - beat, gain: 0), Keyframe(land)]);
        a.echoTime = beat * 0.75;
        a.keys.addAll([
          Keyframe(x(0)),
          if (bassFits) ...[Keyframe(half - beat * 0.25), Keyframe(half, low: kill)],
          Keyframe(x(blend - 2), low: bassFits ? kill : 0),
          Keyframe(land - beat, gain: 0.85, low: kill, hpf: 300, echo: 0.4),
          Keyframe(land, gain: 0, low: kill, hpf: 600, echo: 0.5),
        ]);
      case TransitionType.bassSwap:
        // B creeps in with no bass; on bar 8 the basslines swap; A filters away.
        a.keys.addAll([
          Keyframe(x(0)),
          Keyframe(x(8) - beat * 0.25),
          Keyframe(x(8), low: kill),
          Keyframe(x(12), low: kill),
          Keyframe(x(16), gain: 0, low: kill, hpf: 450),
        ]);
        b.keys.addAll([
          Keyframe(x(0), gain: 0, low: kill, high: -6),
          Keyframe(x(4), gain: 0.75, low: kill, high: -3),
          Keyframe(x(8) - beat * 0.25, gain: 0.95, low: kill),
          Keyframe(x(8)),
        ]);
      case TransitionType.filterSweep:
        // A sweeps up through a high-pass while B opens up from a low-pass.
        a.keys.addAll([
          Keyframe(x(0)),
          Keyframe(x(4), hpf: 120),
          Keyframe(x(8) - beat, gain: 0.8, low: -20, hpf: 1400),
          Keyframe(x(8), gain: 0, low: -20, hpf: 1600),
        ]);
        b.keys.addAll([
          Keyframe(x(0), gain: 0, low: kill, lpf: 300),
          Keyframe(x(2), gain: 0.85, low: kill, lpf: 450),
          Keyframe(x(8) - beat * 0.25, low: kill, lpf: 7000),
          Keyframe(x(8)),
        ]);
      case TransitionType.dropSwap:
        // B rumbles underneath thinned out; A builds up and throws an echo;
        // everything swaps on the downbeat.
        a.echoTime = beat * 0.5;
        a.keys.addAll([
          Keyframe(x(0)),
          Keyframe(x(6), hpf: 200),
          Keyframe(x(8) - beat, hpf: 900, echo: 0.35),
          Keyframe(x(8) - beat * 0.1, hpf: 900, echo: 0.35),
          Keyframe(x(8), gain: 0, hpf: 900, echo: 0.35),
        ]);
        b.keys.addAll([
          Keyframe(x(0), gain: 0, low: kill, hpf: 300),
          Keyframe(x(2), gain: 0.45, low: kill, hpf: 300),
          Keyframe(x(8) - beat * 0.1, gain: 0.6, low: kill, hpf: 450),
          Keyframe(x(8)),
        ]);
      case TransitionType.echoOut:
        // Keys clash, so no overlap: A echoes away and B drops in clean.
        a.echoTime = beat * 0.75;
        a.keys.addAll([
          Keyframe(x(0)),
          Keyframe(x(2)),
          Keyframe(x(3), echo: 0.45),
          Keyframe(x(4) - beat, gain: 0.8, echo: 0.6, hpf: 300),
          Keyframe(x(4), gain: 0, echo: 0.6, hpf: 300),
        ]);
        b.keys.add(Keyframe(x(4)));
    }
  }
}

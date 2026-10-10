import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'library.dart';
import 'models.dart';
import 'planner.dart';
import 'tuning.dart';
import 'vibe.dart';

// ---------------------------------------------------------
// MASHUP MODEL
// ---------------------------------------------------------

/// One stem of one song, as a lane in a mashup.
class StemLane {
  final String stem; // vocals / other / bass / drums (Demucs names)
  final bool fromVocalSong;
  bool muted;
  bool solo = false;

  StemLane(this.stem, this.fromVocalSong, {this.muted = false});

  String get label => switch (stem) {
        'vocals' => 'Vocals',
        'other' => 'Melody',
        'bass' => 'Bass',
        _ => 'Drums',
      };

  Color get color => switch (stem) {
        'vocals' => Colors.pinkAccent,
        'other' => Colors.cyanAccent,
        'bass' => Colors.amberAccent,
        _ => Colors.greenAccent,
      };
}

/// A vocal from one song over the beat (melody + bass + drums) of another,
/// or a beat break (instrumental only).
class Mashup {
  LibraryTrack vocal;
  LibraryTrack beat;
  Analysis vocalGrid; // tempo-scaled
  Analysis beatGrid; // at its natural tempo
  final bool beatOnly;

  // Pitch of the vocal: whole semitones (key match) plus fine cents by ear.
  int vocalShift = 0;
  int autoShift = 0;
  double fineCents = 0;

  // Your volume faders (dB), applied live on top of the automatic balance.
  double vocalDb = 0;
  double beatDb = 0;

  /// Tempo of this mashup relative to the beat's own speed (1.0 = natural).
  /// Below 1 drags the beat out (slower), above 1 tightens it (faster); the
  /// vocal always follows the beat.
  double tempoScale = 1.0;

  // Structure, in bars of each song's (scaled) grid.
  int beatStart = 0; // beat song bar the mashup starts on
  int vocalStart = 0; // vocal song bar the singing starts on
  int vocalBars = 32;
  static const introBars = 8;
  static const outroBars = 8;

  late List<StemLane> lanes;

  Mashup(this.vocal, this.beat, this.vocalGrid, this.beatGrid, {this.beatOnly = false}) {
    lanes = [
      StemLane('vocals', true, muted: beatOnly),
      StemLane('other', false),
      StemLane('bass', false),
      StemLane('drums', false),
      // Off by default; unmute to layer them in.
      StemLane('vocals', false, muted: true),
      if (!beatOnly) ...[
        StemLane('other', true, muted: true),
        StemLane('bass', true, muted: true),
        StemLane('drums', true, muted: true),
      ],
    ];
  }

  int get totalBars => introBars + vocalBars + outroBars;

  bool laneAudible(StemLane l) {
    final anySolo = lanes.any((x) => x.solo);
    return anySolo ? l.solo : !l.muted;
  }

  double? get _vocalHz => vocal.stems?.tuning['vocals'] ?? vocal.analysis?.tuning;
  double? get _beatHz => beat.stems?.tuning['other'] ?? beat.analysis?.tuning;

  /// Cents applied to the beat song's stems (retunes it to 432 Hz, or 0).
  double get beatCents => Tuning.toReference(_beatHz);

  /// Cents applied to the vocal: key shift + tuning match + your fine-tune.
  double get vocalCents => vocalShift * 100 + Tuning.vocalCents(_vocalHz, _beatHz) + fineCents;

  /// The part baked into the render (automatic key shift + tuning match)…
  double get renderedVocalCents => autoShift * 100 + Tuning.vocalCents(_vocalHz, _beatHz);

  /// …and your adjustment on top, applied live by the player (instant).
  double get liveVocalCents => (vocalShift - autoShift) * 100 + fineCents;

  /// Automatic vocal level, relative to the beat as recorded: every vocal is
  /// aimed at the same place, about 2.5 dB under the full beat while singing,
  /// whatever volume its file was saved at.
  double get autoVocalDb {
    final vVocal = vocal.stems?.levels['vocals'];
    final bInst = beat.stems?.levels['instrumental'] ?? beat.analysis?.loudnessDb;
    if (vVocal == null || bInst == null) return 1.0;
    return (bInst - vVocal - 2.5).clamp(-24.0, 24.0);
  }

  /// Levels the beat song to a common loudness. Files in a library can differ
  /// by 20 dB (some are saved much quieter), so without this a quiet file's
  /// beat would drop away next to a loud one.
  double get beatGainDb {
    final bInst = beat.stems?.levels['instrumental'];
    if (bInst != null) return (-14.0 - bInst).clamp(-12.0, 20.0);
    final l = beat.analysis?.loudnessDb;
    return l == null ? 0 : (-13.5 - l).clamp(-12.0, 20.0);
  }

  /// How far the vocal's own tuning was corrected automatically (for display).
  double get autoTuneCents => Tuning.vocalCents(_vocalHz, _beatHz) - beatCents;

  String get keyMatch {
    if (beatOnly) return 'beat';
    final c = keyCompat(beatGrid.camelot, shiftCamelot(vocalGrid.camelot, vocalShift));
    if (c >= 0.99) return vocalShift == autoShift && vocalShift != 0 ? 'shifted' : 'perfect';
    if (c >= 0.8) return 'compatible';
    if (c >= 0.45) return 'loose';
    return 'clash';
  }

  double get tempo => beatGrid.steadyBpm;

  /// The tempo at which the vocal plays at its own natural speed (no stretch).
  double get vocalNaturalScale => beatOnly ? 1.0 : (vocalGrid.steadyBpm / beatGrid.steadyBpm).clamp(0.85, 1.15);

  /// How fast the vocal is playing vs. its original (1.0 = untouched).
  double get vocalSpeed => beatOnly ? 1.0 : beatGrid.steadyBpm * tempoScale / vocalGrid.steadyBpm;

  String get styleLine {
    String fam(LibraryTrack t) {
      final g = t.genre.isEmpty ? 'Mystery' : t.genre;
      return t.year > 0 ? '$g ${t.year}' : g;
    }

    return beatOnly ? 'Beat break · ${fam(beat)}' : '${fam(vocal)} vocal × ${fam(beat)} beat';
  }

  // Filled in when the set is laid out.
  double start = 0; // mix time of bar 0
  double vocalIn = 0; // mix time the vocal enters
  double vocalOut = 0;
  double end = 0;
  double vocalRate = 1;
  double playedBpm = 0;
  List<double> beatTimes = const []; // mix time of every beat of this mashup
}

/// A sound, loop or acapella placed on the sample lane over a mashup. It is
/// anchored to its mashup (and a bar in it), so it moves with the mashup.
class SamplePlacement {
  final LibraryTrack track;
  Mashup anchor;
  int bar; // bar of the anchor mashup it starts on
  int bars; // how long it plays, in bars
  double db = 0; // your volume on top of the automatic level
  double fade = 2.0; // seconds of fade in and out
  bool vocalOnly = false; // play just the singing (acapella)
  bool sync; // lock its beat to the mashup's (songs with a beat)

  SamplePlacement(this.track, this.anchor, {this.bar = 0, this.bars = 16}) : sync = track.analysis != null;

  bool get canSync => track.analysis != null;

  /// Automatic level: sits under the music (about −20 dB average).
  double get autoDb {
    final l = track.level ?? track.analysis?.loudnessDb;
    if (l == null) return -6;
    return (-21.0 - l).clamp(-18.0, 18.0);
  }
}

class MashupSetPlan {
  final List<Mashup> mashups;
  final double duration;
  final String summary;
  final Map<String, dynamic> renderJson;
  final List<double> cuts; // section boundaries (where blends finish)
  MashupSetPlan(this.mashups, this.duration, this.summary, this.renderJson, this.cuts);

  /// Your live pitch and volume moves for each mashup, for the player.
  /// Beat regions change hands halfway through each blend.
  Map<String, dynamic> get liveMap => {
        'vocal': [
          for (final m in mashups)
            if (!m.beatOnly && (m.liveVocalCents != 0 || m.vocalDb != 0))
              {'start': m.vocalIn - 4, 'end': m.vocalOut + 3, 'cents': m.liveVocalCents, 'db': m.vocalDb}
        ],
        'beat': [
          for (var i = 0; i < mashups.length; i++)
            if (mashups[i].beatDb != 0)
              {
                'start': i == 0 ? 0.0 : (mashups[i].start + mashups[i].vocalIn) / 2,
                'end': i + 1 < mashups.length ? (mashups[i + 1].start + mashups[i + 1].vocalIn) / 2 : duration + 5,
                'db': mashups[i].beatDb,
              }
        ],
      };
}

// ---------------------------------------------------------
// MASHUP MAKER
// ---------------------------------------------------------

class _Pair {
  final LibraryTrack vocal, beat;
  final Analysis vGrid, bGrid;
  final int shift;
  final double score;
  _Pair(this.vocal, this.beat, this.vGrid, this.bGrid, this.shift, this.score);
  double get tempo => bGrid.steadyBpm;
  String get key => '${vocal.path}|${beat.path}';
}

class MashupMaker {
  final VibeProfile vibe;
  final math.Random rng;
  MashupMaker(this.vibe, {int? seed}) : rng = math.Random(seed);

  int get mashupCount => (vibe.minutes / 2.1).round().clamp(2, 160);

  // ------------------------------------------------------------- tempo

  /// Scales a song to the tempo closest to [tempo] (half / double time).
  static Analysis? fitTo(Analysis a, double tempo, double maxStretch) {
    var best = 1.0;
    for (final f in const [0.5, 1.0, 2.0]) {
      if ((math.log(tempo / (a.steadyBpm * f))).abs() < (math.log(tempo / (a.steadyBpm * best))).abs()) best = f;
    }
    if ((tempo / (a.steadyBpm * best) - 1).abs() > maxStretch) return null;
    return a.scaled(best);
  }

  /// A beat plays at its own tempo, counted in the range that suits the vibe.
  Analysis _natural(Analysis a) => fitTo(a, vibe.targetBpm, 10)!;

  /// The tempo the set should be at a point in it (0..1): it rises with the
  /// energy curve, and in long sets it travels in gentle waves.
  double targetTempo(double p) {
    final span = math.max(0.01, vibe.peakEnergy - vibe.startEnergy);
    final lift = ((vibe.energyAt(p) - vibe.startEnergy) / span).clamp(0.0, 1.0);
    final waves = vibe.minutes > 45 ? 0.04 * math.sin(p * math.pi * 2 * (vibe.minutes / 50)) : 0.0;
    return vibe.targetBpm * (0.94 + 0.08 * lift + waves);
  }

  // ------------------------------------------------------------- pairing

  /// Every vocal-song / beat-song pairing worth trying, best first.
  /// Mashups are about contrast: different genres and eras score higher.
  List<_Pair> rankPairs(List<LibraryTrack> pool, {LibraryTrack? onlyBeat}) {
    final songs = pool.where((t) => t.analysis != null && t.analysis!.barCount >= 40).toList();
    final tags = {for (final t in songs) t.path: tagScore(t, vibe, rng)};
    final pairs = <_Pair>[];
    final beats = onlyBeat != null ? [onlyBeat] : songs;
    for (final b in beats) {
      if (b.analysis == null) continue;
      final bg = _natural(b.analysis!);
      final tb = bg.steadyBpm;
      if (onlyBeat == null && (tb < vibe.targetBpm * 0.78 || tb > vibe.targetBpm * 1.22)) continue;
      // A good beat grooves and keeps steady time.
      var bScore = 0.6 * ((b.analysis!.danceability - 1.0).clamp(-0.5, 1.0));
      if (b.analysis!.tempoDrift > 0.03) bScore -= 1.2;
      bScore -= 1.5 * (math.log(tb / vibe.targetBpm)).abs();
      for (final v in songs) {
        if (identical(v, b) || v.artist.toLowerCase() == b.artist.toLowerCase()) continue;
        final vg = fitTo(v.analysis!, tb, 0.14);
        if (vg == null) continue;
        if (v.stems != null && v.stems!.vocalShare < 0.08) continue; // no real vocal
        // Key: shift the vocal up to 3 semitones to sit on the beat.
        var shift = 0, compat = -1.0;
        for (final s in const [0, 1, -1, 2, -2, 3, -3]) {
          final c = keyCompat(bg.camelot, shiftCamelot(vg.camelot, s)) - 0.07 * s.abs();
          if (c > compat) {
            compat = c;
            shift = s;
          }
        }
        if (compat < 0.6) continue;
        final stretch = (tb / vg.steadyBpm - 1).abs();
        var s = 1.5 * compat - 4.0 * stretch + bScore;
        s += 0.55 * (tags[v.path]! + (tags[b.path] ?? 0));
        if (vibe.vocalFamily != null) s += genreFamily(v.genre) == vibe.vocalFamily ? 2.0 : -2.0;
        if (vibe.beatFamily != null) s += genreFamily(b.genre) == vibe.beatFamily ? 2.0 : -2.0;
        final contrast = genreFamily(v.genre) != genreFamily(b.genre);
        s += contrast ? 1.2 : -0.4;
        if (v.year > 0 && b.year > 0 && (v.year - b.year).abs() >= 10) s += 0.5;
        if (v.analysis!.tempoDrift > 0.04) s -= 0.4;
        s += rng.nextDouble() * 0.5;
        pairs.add(_Pair(v, b, vg, bg, shift, s));
      }
    }
    pairs.sort((a, b) => b.score.compareTo(a.score));
    return pairs;
  }

  /// Best pairing to follow [prev] at set position [p]: its beat must be
  /// within 6% of the tempo the set is at, so the blend can match it.
  _Pair? pickNext(List<_Pair> ranked, Mashup? prev, double p, Set<String> used, Set<String> rejected) {
    final target = targetTempo(p);
    _Pair? best;
    var bestScore = -1e9;
    var looked = 0;
    for (final x in ranked) {
      if (used.contains(x.vocal.path) || used.contains(x.beat.path) || rejected.contains(x.key)) continue;
      if (prev != null && (math.log(x.tempo / prev.tempo)).abs() > math.log(1.06)) continue;
      var s = x.score - 9 * (math.log(x.tempo / target)).abs() - 2 * (x.bGrid.energy - vibe.energyAt(p)).abs();
      if (prev != null) s += keyCompat(prev.beatGrid.camelot, x.bGrid.camelot);
      if (s > bestScore) {
        bestScore = s;
        best = x;
      }
      if (++looked > 4000) break; // ranked best-first; no need to scan everything
    }
    return best;
  }

  /// Turns a pairing into a mashup once stems are known. Returns null if the
  /// vocal song turns out to have too little singing.
  Mashup? build(_Pair p) {
    final vs = p.vocal.stems, bs = p.beat.stems;
    if (vs == null || bs == null || vs.vocalShare < 0.08) return null;
    final m = Mashup(p.vocal, p.beat, p.vGrid, p.bGrid)
      ..vocalShift = p.shift
      ..autoShift = p.shift;
    if (!_placeVocal(m)) return null;
    return m;
  }

  /// How well [vocal] would sit on [beat]: (key shift, key score 0..1,
  /// vocal stretch as a fraction). Null if the tempos are too far apart.
  ({int shift, double key, double stretch, Analysis vGrid, Analysis bGrid})? fit(LibraryTrack vocal, LibraryTrack beat,
      {double? nearTempo}) {
    final va = vocal.analysis, ba = beat.analysis;
    if (va == null || ba == null) return null;
    final bg = nearTempo != null ? fitTo(ba, nearTempo, 10)! : _natural(ba);
    final vg = fitTo(va, bg.steadyBpm, 0.25);
    if (vg == null) return null;
    var shift = 0, best = -1.0;
    for (final s in const [0, 1, -1, 2, -2, 3, -3]) {
      final c = keyCompat(bg.camelot, shiftCamelot(vg.camelot, s)) - 0.07 * s.abs();
      if (c > best) {
        best = c;
        shift = s;
      }
    }
    final key = keyCompat(bg.camelot, shiftCamelot(vg.camelot, shift));
    return (shift: shift, key: key, stretch: bg.steadyBpm / vg.steadyBpm - 1, vGrid: vg, bGrid: bg);
  }

  /// A mashup of exactly these two songs (your pick), or a reason it can't be.
  (Mashup?, String?) pairOf(LibraryTrack vocal, LibraryTrack beat, {double? nearTempo}) {
    if (identical(vocal, beat)) return (null, 'Pick a different song — that one is already in this mashup.');
    final f = fit(vocal, beat, nearTempo: nearTempo);
    if (f == null) return (null, 'The tempos of "${vocal.title}" and "${beat.title}" are too far apart to match.');
    if ((vocal.stems?.vocalShare ?? 1) < 0.08) {
      return (null, '"${vocal.title}" has hardly any singing, so it can\'t be the vocal. Try it as a beat.');
    }
    final m = build(_Pair(vocal, beat, f.vGrid, f.bGrid, f.shift, 0));
    if (m == null) return (null, 'Couldn\'t find a clean vocal section in "${vocal.title}".');
    return (m, null);
  }

  /// An instrumental break from [song] (its own vocals muted).
  Mashup? beatBreak(LibraryTrack song, {int bars = 16, double? nearTempo}) {
    if (song.analysis == null || song.stems == null) return null;
    final g = nearTempo != null ? fitTo(song.analysis!, nearTempo, 10)! : _natural(song.analysis!);
    final m = Mashup(song, song, g, g, beatOnly: true)..vocalBars = bars;
    _placeBeat(m);
    return m;
  }

  /// Rebuilds a mashup with the roles flipped (the beat song sings).
  Mashup? swapped(Mashup m) {
    if (m.beatOnly || m.beat.stems == null || m.vocal.stems == null) return null;
    final bg = _natural(m.vocal.analysis!);
    final vg = fitTo(m.beat.analysis!, bg.steadyBpm, 0.16);
    if (vg == null) return null;
    var shift = 0, compat = -1.0;
    for (final s in const [0, 1, -1, 2, -2, 3, -3]) {
      final c = keyCompat(bg.camelot, shiftCamelot(vg.camelot, s)) - 0.07 * s.abs();
      if (c > compat) {
        compat = c;
        shift = s;
      }
    }
    return build(_Pair(m.beat, m.vocal, vg, bg, shift, 0));
  }

  // ------------------------------------------------------------- structure

  double _vocalAt(Mashup m, int bar) {
    final g = m.vocalGrid;
    final a = g.beatIndexOfBar(bar), b = g.beatIndexOfBar(bar + 1);
    if (a < 0 || b >= g.beats.length) return 0;
    return m.vocal.stems!.vocalBetween(m.vocal.analysis!.beats, g.beats[a], g.beats[b]);
  }

  double _meanVocal(Mashup m, int from, int to) {
    var s = 0.0;
    for (var i = from; i < to; i++) {
      s += _vocalAt(m, i);
    }
    return s / math.max(1, to - from);
  }

  double _meanEnergy(Analysis g, int from, int to) {
    final a = from.clamp(0, g.barCount - 1), b = to.clamp(a + 1, g.barCount);
    var s = 0.0;
    for (var i = a; i < b; i++) {
      s += g.barEnergy[i];
    }
    return s / (b - a);
  }

  /// Chooses the vocal section (verse into chorus, starting on a fresh line)
  /// and the part of the beat it rides on.
  bool _placeVocal(Mashup m) {
    final vg = m.vocalGrid, bg = m.beatGrid;
    final beatRoom = bg.lastBar - bg.firstBar - Mashup.introBars - Mashup.outroBars;
    var best = -1e9;
    var bestStart = -1, bestLen = 0;
    for (final len in const [48, 40, 32, 24, 16]) {
      if (len > beatRoom) continue;
      for (var s = vg.firstBar; s + len <= vg.lastBar; s++) {
        if ((s - vg.firstBar) % 4 != 0) continue;
        final first = _vocalAt(m, s);
        if (first < 0.35) continue;
        final fresh = _vocalAt(m, s - 1) < 0.45 ? 0.4 : 0.0; // a new line, not mid-sentence
        final endsClean = _vocalAt(m, s + len) < 0.45 ? 0.4 : -0.3;
        // Avoid sections with a long stretch of no singing (solos, breakdowns).
        var gap = 0, longest = 0;
        for (var b = s; b < s + len; b++) {
          gap = _vocalAt(m, b) < 0.15 ? gap + 1 : 0;
          longest = math.max(longest, gap);
        }
        if (longest >= 6) continue;
        final gapPenalty = longest >= 3 ? 0.4 : 0.0;
        final score = 1.2 * _meanVocal(m, s, s + len) + 0.5 * _meanEnergy(vg, s, s + len) + fresh + endsClean +
            len / 48 - (s - vg.firstBar) / 400 - gapPenalty;
        if (score > best) {
          best = score;
          bestStart = s;
          bestLen = len;
        }
      }
      if (bestStart >= 0 && best > 1.2) break;
    }
    if (bestStart < 0) return false;
    m
      ..vocalStart = bestStart
      ..vocalBars = bestLen;
    _placeBeat(m);
    return true;
  }

  /// The strongest groove of the beat song that fits, on an 8-bar phrase.
  void _placeBeat(Mashup m) {
    final bg = m.beatGrid;
    var bBest = -1e9;
    var bStart = bg.firstBar;
    for (var s = bg.firstBar; s + m.totalBars <= bg.lastBar + 1; s++) {
      if ((s - bg.firstBar) % 8 != 0) continue;
      final groove = _meanEnergy(bg, s + Mashup.introBars, s + Mashup.introBars + m.vocalBars);
      final score = groove - (s - bg.firstBar) / 300;
      if (score > bBest) {
        bBest = score;
        bStart = s;
      }
    }
    m.beatStart = bStart;
  }

  // ------------------------------------------------------------- layout

  /// Lays the mashups end to end (each one's 8-bar instrumental intro blends
  /// over the previous one's outro) and builds the render plan. Each beat
  /// plays at its own tempo: it comes in matched to the previous beat, then
  /// eases to its natural speed over 16 bars, so the set's tempo can travel.
  MashupSetPlan layout(List<Mashup> ms, {Map<String, dynamic>? warmth, List<SamplePlacement> samples = const []}) {
    final clips = <Map<String, dynamic>>[];
    final cuts = <double>[];
    List<double>? prevOutro; // previous mashup's outro beats in mix time
    double? nextStart;
    const kill = -30.0;

    for (var i = 0; i < ms.length; i++) {
      final m = ms[i];
      final bg = m.beatGrid, vg = m.vocalGrid;
      final group = (i % 2) * 8;
      final start = nextStart ?? 0.0;

      // Beat map: song time of each beat -> mix time, with the tempo ramp.
      final bBase = bg.beatIndexOfBar(m.beatStart);
      final totalBeats = m.totalBars * 4;
      double src(int n) => bg.smoothBeat(bBase + n);
      // During the blend (first 32 beats) every beat is pinned to the matching
      // beat of the outgoing song, so even drifting live recordings stay locked;
      // afterwards the tempo eases to this song's own speed over 16 bars.
      final outT = <double>[start];
      final pinned = prevOutro != null && prevOutro.length >= 33;
      if (pinned) {
        for (var n = 1; n <= 32; n++) {
          outT.add(prevOutro[n]);
        }
      }
      final s = m.tempoScale;
      final rEntry = pinned
          ? ((src(32) - src(28)) / (outT[32] - outT[28])).clamp(0.8, 1.2)
          : s;
      double rateAt(int n) {
        if (n < 32) return rEntry;
        if (n < 96) return rEntry + (s - rEntry) * (n - 32) / 64;
        return s;
      }

      for (var n = outT.length - 1; n <= totalBeats; n++) {
        outT.add(outT.last + (src(n + 1) - src(n)) / rateAt(n));
      }
      final beatWarp = [
        for (var n = 0; n <= totalBeats + 1; n++) [outT[n], src(n)]
      ];
      double barX(int bar) => outT[(bar * 4).clamp(0, totalBeats + 1)];
      double beatLen(int bar) => (barX(bar + 1) - barX(bar)) / 4;
      final srcStartB = src(0);
      final srcEndB = src(totalBeats) + 0.05;
      final outroBar = Mashup.introBars + m.vocalBars;

      // Vocal: each beat of the vocal song pinned to the matching beat of the
      // beat song (warp map), so even a drifting live vocal stays locked. Two
      // beats of pre-roll catch pickup notes sung just before the line.
      final vEntryBeat = vg.beatIndexOfBar(m.vocalStart);
      final warp = <List<double>>[
        for (var n = -2; n <= m.vocalBars * 4 + 2; n++)
          [n + 32 >= 0 ? outT[n + 32] : start - (src(0) - bg.smoothBeat(bBase + n + 32)), vg.smoothBeat(vEntryBeat + n)]
      ];
      final vIn = barX(Mashup.introBars);
      final vOut = barX(outroBar);
      final outStartV = warp.first[0];
      final srcStartV = math.max(0.0, warp.first[1]);
      final srcEndV = warp.last[1] + 0.05;
      final preRollOut = vIn - outStartV;

      m
        ..beatTimes = List.unmodifiable(outT)
        ..start = start
        ..vocalIn = vIn
        ..vocalOut = vOut
        ..end = barX(m.totalBars)
        ..vocalRate = (warp.last[1] - warp.first[1]) / (warp.last[0] - warp.first[0])
        ..playedBpm = bg.steadyBpm * m.tempoScale;
      // Cuts go where the blend into this mashup is over. The first mashup is
      // also cut where its vocal enters, so the opening renders in a second
      // or two and the set can start straight away.
      cuts.add(vIn);

      // Blend keyframes shared by every stem of this mashup.
      List<Keyframe> head() {
        if (i == 0) return [Keyframe(start)];
        return [
          Keyframe(barX(0), gain: 0, low: kill, high: -6),
          Keyframe(barX(3), gain: 0.8, low: kill),
          Keyframe(barX(4) - beatLen(3) * 0.25, gain: 0.95, low: kill),
          Keyframe(barX(4)),
        ];
      }

      List<Keyframe> tail({required bool last}) {
        final o = outroBar;
        if (last) return [Keyframe(barX(o + 4)), Keyframe(barX(o + 8), gain: 0, lpf: 2500)];
        return [
          Keyframe(barX(o)),
          Keyframe(barX(o + 4) - beatLen(o + 3) * 0.25),
          Keyframe(barX(o + 4), low: kill),
          Keyframe(barX(o + 6), low: kill),
          Keyframe(barX(o + 8), gain: 0, low: kill, hpf: 450),
        ];
      }

      final isLast = i == ms.length - 1;
      final vBeat = beatLen(outroBar - 1);
      for (var li = 0; li < m.lanes.length; li++) {
        final lane = m.lanes[li];
        if (!m.laneAudible(lane)) continue;
        final song = lane.fromVocalSong ? m.vocal : m.beat;
        final path = song.stems!.paths[lane.stem]!;

        if (lane.fromVocalSong && !m.beatOnly) {
          final keys = lane.stem == 'vocals'
              // The featured vocal: rides in over the groove, leaves with an echo.
              ? [
                  Keyframe(outStartV, gain: 0),
                  Keyframe(outStartV + preRollOut * 0.5, gain: 1),
                  Keyframe(vOut - vBeat),
                  Keyframe(vOut - vBeat * 0.5, echo: 0.4),
                  Keyframe(vOut, gain: 0, echo: 0.5),
                ]
              // Vocal song's own backing stems (only when unmuted).
              : [Keyframe(outStartV, gain: 0), Keyframe(vIn, gain: 1), Keyframe(vOut - vBeat), Keyframe(vOut, gain: 0)];
          clips.add(_clip(path, srcStartV, srcEndV, outStartV, m.vocalRate, m.renderedVocalCents, group + li, vBeat * 0.75,
              keys, gainDb: m.beatGainDb + (lane.stem == 'vocals' ? m.autoVocalDb : m.autoVocalDb - 1.5), warp: warp, bus: 1));
          continue;
        }
        if (lane.fromVocalSong) continue; // beat break: no vocal-song lanes
      }

      // Beat song stems: summed into one clip (one time-stretch instead of
      // three — much faster), with a little build into the drop.
      final beatStems = [
        for (final lane in m.lanes)
          if (!lane.fromVocalSong && m.laneAudible(lane)) m.beat.stems!.paths[lane.stem]!
      ];
      if (beatStems.isNotEmpty) {
        final keys = <Keyframe>[...head()];
        if (!m.beatOnly) {
          keys.addAll([
            Keyframe(barX(Mashup.introBars - 2)),
            Keyframe(barX(Mashup.introBars) - beatLen(Mashup.introBars - 1) * 0.25, low: kill, hpf: 250),
            Keyframe(barX(Mashup.introBars)),
          ]);
        }
        keys.addAll(tail(last: isLast));
        keys.sort((a, b) => a.t.compareTo(b.t));
        clips.add(_clip(beatStems.first, srcStartB, srcEndB, start, 1.0, m.beatCents, group, beatLen(0) * 0.5, keys,
            gainDb: m.beatGainDb, warp: beatWarp, mix: beatStems.skip(1).toList()));
      }
      nextStart = barX(outroBar);
      prevOutro = outT.sublist(outroBar * 4, math.min(outT.length, outroBar * 4 + 33));
    }

    // Samples on the sample lane.
    for (final s in samples) {
      if (!ms.contains(s.anchor) || s.anchor.beatTimes.length < 8) continue;
      final clip = _sampleClip(s, ms.indexOf(s.anchor));
      if (clip != null) clips.add(clip);
    }

    final duration = ms.isEmpty ? 0.0 : ms.last.end + 1.5;
    final mins = (duration / 60).round();
    final summary = '${vibe.summary} · ${ms.length} mashups · ${mins >= 60 ? '${mins ~/ 60}h ${mins % 60}m' : '$mins min'}';
    final json = <String, dynamic>{'duration': duration, 'clips': clips, if (warmth != null) 'warmth': warmth};
    return MashupSetPlan(ms, duration, summary, json, cuts);
  }

  /// Mix time of beat n of a mashup (extrapolated past its end).
  static double _beatAt(Mashup m, int n) {
    final b = m.beatTimes;
    if (n < 0) return b.first + n * (b[1] - b[0]);
    if (n < b.length) return b[n];
    final last = b.length - 1;
    return b[last] + (n - last) * (b[last] - b[last - 1]);
  }

  Map<String, dynamic>? _sampleClip(SamplePlacement s, int index) {
    final t = s.track;
    final path = s.vocalOnly ? t.stems?.paths['vocals'] : t.path;
    if (path == null) return null;
    final startBeat = s.bar * 4, beats = s.bars * 4;
    final t0 = _beatAt(s.anchor, startBeat), t1 = _beatAt(s.anchor, startBeat + beats);
    final cents = Tuning.toReference(s.vocalOnly ? (t.stems?.tuning['vocals'] ?? t.tuningHz) : (t.tuningHz ?? t.analysis?.tuning));
    final gain = s.autoDb + s.db + (s.vocalOnly ? 4 : 0); // a vocal alone measures quieter
    final f = math.min(s.fade, (t1 - t0) / 3);
    final keys = [
      Keyframe(t0, gain: f > 0 ? 0 : 1),
      Keyframe(t0 + f),
      Keyframe(t1 - f),
      Keyframe(t1, gain: 0),
    ];
    final a = t.analysis;
    if (s.sync && a != null) {
      // Lock its beats to the mashup's beats, from its first downbeat.
      final g = MashupMaker.fitTo(a, s.anchor.tempo * s.anchor.tempoScale, 0.25);
      if (g != null) {
        final first = g.beatIndexOfBar(g.firstBar);
        final warp = <List<double>>[
          for (var n = 0; n <= beats && first + n < g.beats.length; n++) [_beatAt(s.anchor, startBeat + n), g.smoothBeat(first + n)]
        ];
        if (warp.length >= 2) {
          return _clip(path, math.max(0, warp.first[1]), warp.last[1] + 0.05, warp.first[0], 1.0, cents, 0, 0.25, keys,
              gainDb: gain, warp: warp);
        }
      }
    }
    // Free-running (ambient sounds, or sync off): plays at its own speed.
    final len = math.min(t.duration > 0 ? t.duration : 600.0, t1 - t0);
    return _clip(path, 0, len, t0, 1.0, cents, 0, 0.25, keys.map((k) => k.t > t0 + len ? Keyframe(t0 + len, gain: 0) : k).toList(),
        gainDb: gain);
  }

  Map<String, dynamic> _clip(String path, double srcStart, double srcEnd, double outStart, double rate, double cents,
          int deck, double echoTime, List<Keyframe> keys,
          {double gainDb = 0, List<List<double>>? warp, int bus = 0, List<String> mix = const []}) =>
      {
        'path': path,
        'srcStart': srcStart,
        'srcEnd': srcEnd,
        'outStart': outStart,
        'rate': rate,
        'pitchCents': cents,
        'gainDb': gainDb,
        'deck': deck,
        'echoTime': echoTime,
        'keys': keys.map((k) => k.toJson()).toList(),
        if (warp != null) 'warp': warp,
        if (bus != 0) 'bus': bus,
        if (mix.isNotEmpty) 'mix': mix,
      };
}

// ---------------------------------------------------------
// SESSION (the current set, built progressively, with spares)
// ---------------------------------------------------------

/// The mashups in the set, plus the ranked pairings to draw new ones from.
/// Long sets are built in the background, a few mashups at a time.
class MashupSession {
  final MashupMaker maker;
  final List<LibraryTrack> pool;
  final List<_Pair> _ranked;
  final List<Mashup> mashups = [];
  final List<SamplePlacement> samples = [];

  /// Samples follow their slot when a mashup is replaced (swap / shuffle / pick).
  void _reanchor(Mashup old, Mashup now) {
    for (final s in samples) {
      if (identical(s.anchor, old)) s.anchor = now;
    }
  }

  /// Puts a sound/song on the sample lane over mashup [i].
  Future<SamplePlacement> addSample(int i, LibraryTrack t, MusicLibrary lib) async {
    await lib.analyze([t], (d, n) {});
    final m = mashups[i];
    // Beat songs default to 16 bars over the intro blend; ambient sounds to
    // about 30 s.
    final s = SamplePlacement(t, m, bar: 0, bars: t.analysis != null ? 16 : math.max(4, (30 / (240 / m.tempo)).round()));
    samples.add(s);
    return s;
  }
  final Set<String> _rejected = {};
  bool cancelled = false;
  int target = 0;

  MashupSession(this.maker, this.pool, this._ranked);

  static MashupSession start(MashupMaker maker, List<LibraryTrack> pool) =>
      MashupSession(maker, pool, maker.rankPairs(pool));

  Set<String> get _used => {for (final m in mashups) ...[m.vocal.path, m.beat.path]};

  /// Keeps adding mashups until there are [count]. Calls [onAdded] after each
  /// batch so the set can start playing while the rest is prepared.
  Future<void> fill(MusicLibrary lib, int count, void Function(String status) onStatus, void Function() onAdded) async {
    target = count;
    var misses = 0;
    while (!cancelled && mashups.length < target && misses < 6) {
      // Plan the next few, then split all their stems in one go (faster).
      final picks = <_Pair>[];
      final used = _used;
      Mashup? prevSim = mashups.isEmpty ? null : mashups.last;
      double prevTempo = prevSim?.tempo ?? 0;
      final batch = mashups.length < 2 ? 2 : 4;
      for (var k = 0; k < batch && mashups.length + picks.length < target; k++) {
        final p = (mashups.length + picks.length) / math.max(1, target - 1);
        final pick = maker.pickNext(_ranked, prevSim, p, used, _rejected);
        if (pick == null) break;
        if (prevTempo > 0 && (math.log(pick.tempo / prevTempo)).abs() > math.log(1.06)) break;
        picks.add(pick);
        used
          ..add(pick.vocal.path)
          ..add(pick.beat.path);
        prevTempo = pick.tempo;
        prevSim = null; // later picks in the batch chain on tempo only
      }
      if (picks.isEmpty) break;
      final songs = {for (final p in picks) ...[p.vocal, p.beat]}.toList();
      await lib.separate(songs, (d, t, c) {
        onStatus('Splitting stems for mashup ${mashups.length + 1}–${mashups.length + picks.length} of $target'
            '${c == null ? '' : ' · ${c.title}'}');
      });
      if (cancelled) return;
      var added = 0;
      for (final p in picks) {
        final m = maker.build(p);
        if (m == null) {
          _rejected.add(p.key);
          continue;
        }
        mashups.add(m);
        added++;
      }
      misses = added == 0 ? misses + 1 : 0;
      if (added > 0) onAdded();
    }
  }

  Future<Mashup?> _another(MusicLibrary lib, Mashup? prev, double p, Set<String> avoid, void Function(String) onStatus) async {
    for (var attempt = 0; attempt < 6; attempt++) {
      final pick = maker.pickNext(_ranked, prev, p, {..._used, ...avoid}, _rejected);
      if (pick == null) return null;
      await lib.separate([pick.vocal, pick.beat], (d, t, c) => onStatus('Splitting stems${c == null ? '' : ' · ${c.title}'}'));
      final m = maker.build(pick);
      if (m != null) return m;
      _rejected.add(pick.key);
    }
    return null;
  }

  Future<bool> shuffle(int i, MusicLibrary lib, void Function(String status) onStatus) async {
    final old = mashups[i];
    final m = await _another(lib, i > 0 ? mashups[i - 1] : null, i / math.max(1, mashups.length - 1),
        {old.vocal.path, old.beat.path}, onStatus);
    if (m == null) return false;
    _reanchor(old, m);
    mashups[i] = m;
    return true;
  }

  bool swap(int i) {
    final m = maker.swapped(mashups[i]);
    if (m == null) return false;
    _reanchor(mashups[i], m);
    mashups[i] = m;
    return true;
  }

  /// Puts [song] in after mashup [i]: as a beat break, or with an AI vocal on it.
  Future<String?> insertBeat(int i, LibraryTrack song, bool withVocal, MusicLibrary lib, void Function(String) onStatus) async {
    onStatus('Listening to ${song.title}…');
    await lib.analyze([song], (d, t) {});
    if (song.analysis == null) return 'Couldn\'t read the beat in "${song.title}".';
    if (withVocal) {
      final pairs = maker.rankPairs(pool, onlyBeat: song).where((p) => !_used.contains(p.vocal.path)).toList();
      for (final p in pairs.take(5)) {
        onStatus('Finding a vocal for ${song.title}…');
        await lib.separate([p.vocal, song], (d, t, c) => onStatus('Splitting stems${c == null ? '' : ' · ${c.title}'}'));
        final m = maker.build(p);
        if (m != null) {
          mashups.insert(i + 1, m);
          return null;
        }
      }
      return 'Couldn\'t find a vocal that fits "${song.title}" — try Beat only.';
    }
    await lib.separate([song], (d, t, c) => onStatus('Splitting stems · ${song.title}'));
    final m = maker.beatBreak(song, nearTempo: mashups.isEmpty ? null : mashups[i.clamp(0, mashups.length - 1)].tempo);
    if (m == null) return 'Couldn\'t split "${song.title}".';
    mashups.insert(i + 1, m);
    return null;
  }

  /// Swaps the vocal (or the beat) of mashup [i] for a song you picked.
  /// Returns an error message, or null when done.
  Future<String?> replace(int i, LibraryTrack song,
      {required bool asVocal, required MusicLibrary lib, required void Function(String) onStatus}) async {
    final old = mashups[i];
    onStatus('Listening to ${song.title}…');
    await lib.analyze([song], (d, t) {});
    if (song.analysis == null) return 'Couldn\'t read the beat in "${song.title}".';
    final vocal = asVocal ? song : (old.beatOnly ? null : old.vocal);
    final beat = asVocal ? old.beat : song;
    await lib.separate([song, if (vocal != null) vocal, beat],
        (d, t, c) => onStatus('Splitting stems${c == null ? '' : ' · ${c.title}'}'));
    Mashup? m;
    if (vocal == null) {
      // Replacing the beat of a beat break: still a beat break.
      m = maker.beatBreak(song, nearTempo: i > 0 ? mashups[i - 1].tempo : null);
      if (m == null) return 'Couldn\'t split "${song.title}".';
    } else {
      final (made, err) = maker.pairOf(vocal, beat, nearTempo: asVocal ? old.tempo : null);
      if (made == null) return err;
      m = made;
    }
    _reanchor(old, m);
    // Keep your settings for the half that didn't change.
    if (asVocal) {
      m
        ..beatDb = old.beatDb
        ..tempoScale = old.tempoScale;
    } else {
      m.vocalDb = old.vocalDb;
    }
    mashups[i] = m;
    return null;
  }

  MashupSetPlan layout({Map<String, dynamic>? warmth}) => maker.layout(mashups, warmth: warmth, samples: samples);

  /// Plans [count] pairings in order without splitting stems: (pair key, tempo).
  /// Used to check a library can supply a long set.
  List<(String, double)> dryRun(int count) {
    final out = <(String, double)>[];
    final used = <String>{};
    double? prevTempo;
    for (var i = 0; i < count; i++) {
      final p = i / math.max(1, count - 1);
      final target = maker.targetTempo(p);
      _Pair? best;
      var bestScore = -1e9;
      for (final x in _ranked) {
        if (used.contains(x.vocal.path) || used.contains(x.beat.path)) continue;
        if (prevTempo != null && (math.log(x.tempo / prevTempo)).abs() > math.log(1.06)) continue;
        final s = x.score - 9 * (math.log(x.tempo / target)).abs();
        if (s > bestScore) {
          bestScore = s;
          best = x;
        }
      }
      if (best == null) break;
      used
        ..add(best.vocal.path)
        ..add(best.beat.path);
      prevTempo = best.tempo;
      out.add((best.key, best.tempo));
    }
    return out;
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'auto_fx.dart';
import 'deck_view.dart';
import 'fx_deck.dart';
import 'intros.dart';
import 'library.dart';
import 'library_panel.dart';
import 'mashup.dart';
import 'mashup_widgets.dart';
import 'mixer.dart';
import 'models.dart';
import 'planner.dart';
import 'prestretch.dart';
import 'empty_screen.dart';
import 'mixer_panel.dart';
import 'prompt_song.dart';
import 'rig.dart';
import 'theme_picker.dart';
import 'sections.dart';
import 'storage_view.dart';
import 'tuning.dart';
import 'vibe.dart';

void main() {
  runApp(const VibelineApp());
}

class VibelineApp extends StatelessWidget {
  const VibelineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'D-Jay Noodles',
      debugShowCheckedModeBanner: false,
      theme: rigTheme(ThemeData.dark().copyWith(
        scaffoldBackgroundColor: kInk,
        primaryColor: kPink,
        colorScheme: const ColorScheme.dark(primary: kPink, secondary: kTeal, surface: kPanel),
      )),
      home: const TimelineWorkspaceScreen(),
    );
  }
}

const _trackColors = [
  Colors.amber,
  Colors.cyan,
  Colors.purple,
  Colors.pinkAccent,
  Colors.lightGreen,
  Colors.deepOrange,
  Colors.lightBlue,
  Colors.teal,
];

String _clock(double s) {
  final t = s.isFinite ? s.round() : 0;
  return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
}

enum Phase { idle, working, ready, error }

// ---------------------------------------------------------
// MAIN WORKSPACE SCREEN
// ---------------------------------------------------------
class TimelineWorkspaceScreen extends StatefulWidget {
  const TimelineWorkspaceScreen({super.key});

  @override
  State<TimelineWorkspaceScreen> createState() => _TimelineWorkspaceScreenState();
}

class _TimelineWorkspaceScreenState extends State<TimelineWorkspaceScreen> {
  final _library = MusicLibrary();
  final _mixer = Mixer();
  late final SectionEngine _sections = SectionEngine(_mixer, () => _position)..onChanged = _sectionsChanged;
  final _scroll = ScrollController();
  late final TextEditingController _vibeController = TextEditingController(text: _currentVibePrompt);
  final _themeController = TextEditingController(); // theme night: "80s", "punk", "Halloween"…

  String _currentVibePrompt = "Party, mix genres, my Shazams";
  Phase _phase = Phase.idle;
  String _status = 'Starting up…';
  String? _background; // long-set preparation running behind the scenes
  String? _themeNote; // a theme night that's short of songs
  bool _preparing = false; // more mashups still being made behind the scenes
  double? _progress;
  bool _scanned = false;
  bool _mashupMode = true;
  bool _anchorOn = true; // anchor-beat mode (Dean's structure)
  bool _warmthOn = true;
  VibeProfile? _vibe;

  // Classic blend mix
  MixPlan? _plan;
  // Mashup set
  MashupSession? _session;
  MashupSetPlan? _mashPlan;
  final Set<int> _expanded = {};

  // Song library panel
  bool _libraryOpen = true;
  // The mixer between the decks.
  double _vocalFader = kFaderHome, _beatFader = kFaderHome, _crossfader = 0, _master = 0;
  int? _libTarget;
  bool _libAsVocal = true;
  String? _analyseStatus;

  double _duration = 0;
  double _position = 0;
  bool _playing = false;
  bool _waiting = false;
  bool _heldAtEnd = false; // reached the end while the next mashup is still being made
  int _currentIndex = -1;
  Timer? _ticker;
  Timer? _relayout;

  // Live FX panel
  late final FxSettings _fx = FxSettings(_mixer);
  bool _fxOpen = false;
  bool _autoFxOn = true;
  List<Map<String, dynamic>> _autoCues = const []; // Auto FX moves in this set
  List<double> _beatGrid = const []; // mix time of every beat
  Set<double> _downbeats = const {}; // the beats in it that start a bar

  // Vocals made studio-clean with Rubber Band; lays out again as each is ready.
  late final Prestretcher _pre = Prestretcher(_library)
    ..onReady = () {
      if (mounted && _mashupMode && _mashPlan != null) _scheduleRelayout();
    };

  // Simple: the Now Playing decks. Pro: every card, knob and slider.
  bool _pro = false;
  late final WaveCache _waves = WaveCache(_mixer)
    ..onLoaded = () {
      if (mounted && !_pro) setState(() {});
    };
  // Deck mute buttons: cut the singer or the beat out, live.
  bool _muteVocal = false, _muteBeat = false;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    SectionEngine.clearPartFiles();
    Prestretcher.clearPartFiles();
    _startup();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _ticker?.cancel();
    _relayout?.cancel();
    _vibeController.dispose();
    _themeController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _busy => _phase == Phase.working;
  bool get _hasContent => _mashupMode ? _mashPlan != null : _plan != null;
  /// The main button: nothing to re-mix until there's a set.
  String get _goLabel => _hasContent ? 'Re-Mix' : 'Make my set';
  bool get _playable => _sections.sections.isNotEmpty;

  void _set(String status, {double? progress, Phase phase = Phase.working}) {
    if (!mounted) return;
    setState(() {
      _status = status;
      _progress = progress;
      _phase = phase;
    });
  }

  bool _autoplayPending = false;

  void _sectionsChanged() {
    if (!mounted) return;
    setState(() {});
    // Start playing only once the opening is rendered (no silent start).
    if (_autoplayPending && _sections.sections.isNotEmpty && _sections.sections.first.path != null) {
      _autoplayPending = false;
      _mixer.play(from: 0);
      setState(() => _playing = true);
    }
  }

  Future<void> _startup() async {
    await _library.loadSettings();
    await _scan();
  }

  Future<void> _scan() async {
    final problem = await _library.checkSetup();
    if (problem != null) {
      _set(problem, phase: Phase.error);
      return;
    }
    _set('Reading your music folder…');
    await _library.scan();
    await _library.loadKnown(); // so the Songs panel can show BPM and key
    _scanned = true;
    final inCloud = _library.inCloudCount;
    _set(
      '${_library.tracks.length - inCloud} songs found · ${_library.shazamMatches} of them are Shazams. '
      '${inCloud == 0 ? '' : '$inCloud more ${inCloud == 1 ? 'is' : 'are'} only in iCloud and left out. '}'
      'Type a vibe and press $_goLabel.',
      phase: _hasContent ? Phase.ready : Phase.idle,
    );
  }

  Future<void> _searchWholeMac() async {
    if (_busy) return;
    _library.wholeMac = true;
    await _library.saveSettings();
    await _scan();
  }

  Future<void> _chooseFolder() async {
    if (_busy) return;
    final r = await Process.run('osascript', ['-e', 'POSIX path of (choose folder with prompt "Pick the folder with your music")']);
    final path = (r.stdout as String).trim();
    if (r.exitCode != 0 || path.isEmpty) return;
    _library.folder = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    _library.wholeMac = false;
    await _library.saveSettings();
    await _scan();
  }

  Map<String, dynamic>? get _warmth =>
      _warmthOn && _vibe != null ? {'drive': _vibe!.drive, 'crackle': _vibe!.crackle} : null;

  // ------------------------------------------------------------- Re-Mix AI

  /// [seed]: a song to build the set around ("mix <song>" in the vibe box,
  /// or a song's mix button in the Songs panel).
  Future<void> _remix({LibraryTrack? seed}) async {
    if (_busy) return;
    _currentVibePrompt = _vibeController.text.trim().isEmpty ? _currentVibePrompt : _vibeController.text.trim();
    try {
      if (!_scanned) await _scan();
      if (_phase == Phase.error) return;
      _stopLearning();
      _set('Getting your songs ready…');
      await _library.loadKnown();
      var prompt = _currentVibePrompt;
      if (seed == null) {
        final found = songFromPrompt(prompt, _library.tracks);
        if (found != null && found.track == null) {
          _set('Couldn\'t find "${found.query}" in your songs. Check the spelling, or find it in the Songs panel and press its mix button.',
              phase: Phase.error);
          return;
        }
        if (found != null) (seed, prompt) = (found.track, found.rest);
      }
      if (seed != null && !_mashupMode) _setMode(true);
      _session?.cancelled = true;
      await _stopPlayback();
      setState(() {
        _position = 0;
        _background = null;
      });

      final vibe = parseTheme(prompt, _themeController.text);
      _vibe = vibe;
      final rng = math.Random();
      var pool = _library.tracks.toList();
      if (vibe.shazamOnly) {
        final mine = pool.where((t) => t.shazam).toList();
        if (mine.length >= 8) pool = mine;
      }
      // A theme night ("80s", "punk", "Halloween"): only songs that fit, at
      // least 20 minutes, or as long as those songs allow (and say so).
      _themeNote = fitThemeLength(vibe, vibe.minutesAvailable(pool, mashups: _mashupMode));
      // A theme night themes the singing: mashup beats and blend bridges can
      // come from the whole library.
      final ranked = pool.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2));

      if (_mashupMode) {
        await _makeMashups(vibe, ranked.map((e) => e.$1).toList(), seed: seed);
      } else {
        await _makeBlendMix(vibe, ranked.map((e) => e.$1).toList());
      }
    } catch (e) {
      _set('Something went wrong: $e', phase: Phase.error);
    }
  }

  Future<void> _makeBlendMix(VibeProfile vibe, List<LibraryTrack> all) async {
    // A theme night: its songs play, and other songs' beats can bridge
    // between two that don't blend well.
    final ranked = vibe.themed ? all.where(vibe.fits).toList() : all;
    final bridges = vibe.themed ? all.where((t) => !vibe.fits(t)).take(60).toList() : <LibraryTrack>[];
    final bridgeClock = ProgressClock();
    await _library.analyze(bridges, (done, total) {
      _set('Finding beats to bridge with… $done / $total${bridgeClock.tick(done, total)}', progress: total == 0 ? null : done / total);
    });
    final batch = math.max(48, vibe.trackCount * 5);
    final seed = DateTime.now().millisecondsSinceEpoch; // same seed: same songs when planned again below
    MixPlan? plan;
    var wanted = <LibraryTrack>[];
    for (var round = 0; round < 3; round++) {
      wanted = ranked.take(batch * (round + 1)).toList();
      final clock = ProgressClock();
      await _library.analyze(wanted, (done, total) {
        _set('Listening to songs for "${vibe.summary}"… $done / $total${clock.tick(done, total)}', progress: total == 0 ? null : done / total);
      });
      _set('Planning the set…');
      fitThemeTempo(vibe, wanted);
      plan = MixPlanner(vibe, seed: seed).plan(wanted, bridges: bridges);
      if (plan != null && plan.tracks.length >= math.min(vibe.trackCount, 4)) break;
    }
    if (plan == null) {
      _set('Couldn\'t find enough songs that mix together for that vibe. Try a broader vibe.', phase: Phase.error);
      return;
    }
    // Where each chosen song sings, so no blend has two vocals at once: split
    // them (first time only) and plan again with that known.
    final chosen = plan.tracks.map((t) => t.track).toList();
    if (chosen.any((t) => t.stems == null)) {
      await _library.separate(chosen, (done, total, c) {
        _set('Finding where the singing is · ${c?.title ?? ''} · $done / $total (first time only, about 20 s a song)',
            progress: total == 0 ? null : done / total);
      });
      plan = MixPlanner(vibe, seed: seed).plan(wanted, bridges: bridges) ?? plan;
    }
    // Prepared intros (scratches, drops) ride on their songs, on the beat.
    plan.introClips = introClips(plan, await Intro.loadAll());
    final intros = plan.introClips.length;
    setState(() => _plan = plan);
    await _publish(plan.toRenderJson(), plan.cuts, plan.duration,
        intros == 0 ? plan.summary : '${plan.summary} · $intros intro${intros == 1 ? '' : 's'}',
        autoplay: true);
  }

  Future<void> _makeMashups(VibeProfile vibe, List<LibraryTrack> ranked, {LibraryTrack? seed, bool anchor = true}) async {
    final maker = MashupMaker(vibe);
    final count = maker.mashupCount;
    final anchorOn = _anchorOn && anchor;
    // Long sets need a bigger pool of songs to draw from. Anchor mode needs
    // more again: every beat has to fit the anchor's tempo and key (80 songs
    // left 2–3 mashups for a 5-mashup set).
    // A theme night: every song that fits the theme (they sing), plus the
    // best of the rest of the library as beats.
    final singers = ranked.where(vibe.fits).toList();
    final wanted = anchorOn ? math.max(240, count * 6) : math.max(80, count * 4);
    final candidates = MusicLibrary.limitPool({
      ...singers,
      ...ranked.where((t) => !vibe.themed || !vibe.fits(t)).take(wanted),
    }.toList());
    // Start from songs already known; only wait for new ones if there aren't
    // enough, or not enough that suit what was asked for. The rest are learned
    // in the background once the set is made.
    final bool Function(LibraryTrack)? suits = vibe.themed
        ? vibe.fits
        : vibe.genres.isNotEmpty
            ? (t) => vibe.genres.contains(genreFamily(t.genre))
            : null;
    final clock = ProgressClock();
    await _library.analyze(MusicLibrary.songsToAnalyseFirst(candidates, minReady: wanted, matchMin: count * 4, matches: suits), (done, total) {
      _set('Listening to songs for "${vibe.summary}"… $done / $total${clock.tick(done, total)}', progress: total == 0 ? null : done / total);
    });
    final pool = candidates.where((t) => t.analysis != null).toList();
    fitThemeTempo(vibe, singers);
    _set('Pairing vocals with beats…');
    final session = MashupSession.start(maker, pool)..anchorMode = anchorOn;
    setState(() {
      _session = session;
      _mashPlan = null;
      _expanded.clear();
    });
    if (seed != null) {
      final err = await session.seed(seed, _library.tracks, _library, (s) => _set(s));
      if (session.cancelled) return;
      if (err != null) {
        _set(err, phase: Phase.error);
        return;
      }
    }
    var started = false;
    // Builds progressively: plays as soon as the first mashups are ready and
    // keeps preparing the rest in the background.
    final filling = session.fill(_library, count, (s) {
      if (started) {
        if (mounted && !session.cancelled) setState(() => _background = s);
      } else {
        _set('Making mashups · $s');
      }
    }, () {
      if (session.cancelled) return;
      if (!started) {
        started = true;
        _relayoutMashups(autoplay: true);
      } else {
        _scheduleRelayout();
      }
    });
    _preparing = true;
    try {
      await filling;
    } finally {
      if (mounted) {
        setState(() {
          _preparing = false;
          _heldAtEnd = false;
        });
      }
    }
    if (session.cancelled) return;
    // A theme night rarely has enough songs near one tempo for the anchor
    // beat (Kiwi: 3 of 10 with it, 9 of 10 without). Make it without.
    if (session.anchorMode && vibe.themed && session.mashups.length < count * 0.6) {
      _themeNote = 'Anchor beat needs more songs at one tempo than this theme has, so this set is made without it.';
      return _makeMashups(vibe, ranked, seed: seed, anchor: false);
    }
    if (session.mashups.isEmpty) {
      _set('Couldn\'t find vocals and beats that fit together for that vibe. Try a broader vibe.', phase: Phase.error);
      return;
    }
    _learnInBackground(candidates);
    setState(() => _background = session.mashups.length < count
        ? 'Prepared ${session.mashups.length} of $count mashups — ran out of good pairings for this vibe'
        : null);
    _scheduleRelayout();
  }

  int _learnRun = 0;
  String? _learnStatus;

  void _stopLearning() {
    _learnRun++;
    _learnStatus = null;
  }

  /// Analyses the songs a set didn't wait for, ready for the next one.
  Future<void> _learnInBackground(List<LibraryTrack> songs) async {
    _stopLearning();
    final run = _learnRun;
    final clock = ProgressClock();
    try {
      await _library.analyze(songs, (done, total) {
        final left = clock.tick(done, total);
        if (mounted && run == _learnRun && done % 5 == 0) {
          setState(() => _learnStatus = 'Learning more of your songs for next time: $done / $total$left');
        }
      }, gentle: true, stop: () => run != _learnRun);
    } catch (_) {}
    if (mounted && run == _learnRun) setState(() => _learnStatus = null);
  }

  void _scheduleRelayout() {
    _relayout?.cancel();
    _relayout = Timer(const Duration(milliseconds: 300), () => _relayoutMashups());
  }

  /// Lays out the mashup set again (after any edit) and updates the sections;
  /// only the sections whose sound changed get re-rendered.
  Future<void> _relayoutMashups({bool autoplay = false}) async {
    final session = _session;
    if (session == null || session.mashups.isEmpty) return;
    // Remember where every beat was, to keep playing from the same musical
    // moment if this edit moves the music under the playhead.
    final before = {for (final m in session.mashups) m: (m.beatTimes, m.start)};
    final beforeByIndex = [for (final m in session.mashups) (m.beatTimes, m.start, m.end)];
    final p = _position;
    final plan = session.layout(warmth: _warmth);
    setState(() {
      _mashPlan = plan;
      _duration = plan.duration;
    });
    await _publish(plan.renderJson, plan.cuts, plan.duration, plan.summary,
        autoplay: autoplay, remap: autoplay ? null : _remapAround(p, before, beforeByIndex, plan.mashups));
    // Held at the end waiting for this mashup: carry on.
    if (_heldAtEnd && plan.duration > p + 1) {
      _heldAtEnd = false;
      await _mixer.play(from: p);
      if (mounted) setState(() => _playing = true);
    }
  }

  /// Old→new mix-time pairs around the playhead, or null if nothing under it moved.
  List<List<double>>? _remapAround(double p, Map<Mashup, (List<double>, double)> before,
      List<(List<double>, double, double)> beforeByIndex, List<Mashup> now) {
    if (!_playing) return null;
    final pairs = <List<double>>[];
    for (var i = 0; i < now.length; i++) {
      final m = now[i];
      final old = before[m];
      if (old == null) {
        // A new mashup in this slot (swap / shuffle / replace): keep playing
        // the same distance into it.
        if (i < beforeByIndex.length && m.beatTimes.isNotEmpty) {
          final (_, oStart, oEnd) = beforeByIndex[i];
          if (oEnd >= p - 30 && oStart <= p + 240) {
            final len = math.min(oEnd - oStart, m.end - m.start);
            for (var t = 0.0; t <= len; t += 1.0) {
              pairs.add([oStart + t, m.start + t]);
            }
          }
        }
        continue;
      }
      final (oldBeats, _) = old;
      if (oldBeats.isEmpty || oldBeats.last < p - 30 || oldBeats.first > p + 240) continue;
      final n = math.min(oldBeats.length, m.beatTimes.length);
      for (var k = 0; k < n; k++) {
        pairs.add([oldBeats[k], m.beatTimes[k]]);
      }
    }
    if (pairs.isEmpty) return null;
    pairs.sort((a, b) => a[0].compareTo(b[0]));
    // Keep it strictly increasing (overlapping blends belong to two mashups).
    final clean = <List<double>>[];
    for (final q in pairs) {
      if (clean.isEmpty || (q[0] > clean.last[0] + 1e-3 && q[1] > clean.last[1] + 1e-3)) clean.add(q);
    }
    final moved = clean.any((q) => (q[0] - p).abs() < 20 && (q[1] - q[0]).abs() > 0.002);
    return moved ? clean : null;
  }

  Future<void> _publish(Map<String, dynamic> json, List<double> cuts, double duration, String summary,
      {bool autoplay = false, List<List<double>>? remap}) async {
    if (_warmth != null) json['warmth'] = _warmth;
    if (_mashupMode) json = _pre.apply(json);
    _duration = duration;
    _beatGrid = _computeBeatGrid();
    _autoCues = _mashupMode ? mashupFx(_mashPlan?.mashups ?? const []) : (_plan == null ? const [] : blendFx(_plan!));
    await _mixer.setBeatGrid(_beatGrid);
    await _mixer.setLiveMap(_liveMap);
    await _sections.setPlan(json, cuts, remap: remap);
    _set('Ready · ${_clock(duration)} · $summary', phase: Phase.ready);
    _startTicker();
    if (autoplay) {
      _autoplayPending = true;
      _sectionsChanged();
    }
  }

  /// Mix time of every beat in the set (for the Beat FX and the BPM readout).
  List<double> _computeBeatGrid() {
    final out = <double>[];
    final bars = <double>[];
    if (_mashupMode) {
      for (final m in _mashPlan?.mashups ?? const <Mashup>[]) {
        out.addAll(m.beatTimes);
        for (var k = 0; k < m.beatTimes.length; k += 4) {
          bars.add(m.beatTimes[k]);
        }
      }
    } else {
      for (final p in _plan?.tracks ?? const <PlannedTrack>[]) {
        final a = p.track.analysis;
        if (a == null) continue;
        for (var i = 0; i < a.beats.length; i++) {
          final t = a.beats[i];
          if (t < p.srcStart || t > p.srcEnd) continue;
          out.add(p.mixAt(t));
          if ((i - a.barPhase) % 4 == 0) bars.add(p.mixAt(t));
        }
      }
    }
    out.sort();
    bars.sort();
    // Where two songs overlap their beats coincide: keep one of each.
    final clean = <double>[];
    for (final t in out) {
      if (clean.isEmpty || t - clean.last > 0.18) clean.add(t);
    }
    final down = <double>{};
    var j = 0;
    for (final t in clean) {
      while (j < bars.length && bars[j] < t - 0.06) {
        j++;
      }
      if (j < bars.length && (bars[j] - t).abs() <= 0.06) down.add(t);
    }
    _downbeats = down;
    return clean;
  }

  /// Tempo at the playhead, averaged over a few beats.
  double? get _bpmNow {
    final g = _beatGrid;
    if (g.length < 6) return null;
    var lo = 0, hi = g.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (g[mid] <= _position) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    final a = lo.clamp(0, g.length - 5);
    return 60 * 4 / (g[a + 4] - g[a]);
  }

  Future<void> _stopPlayback() async {
    await _mixer.pause();
    _ticker?.cancel();
    if (mounted) {
      setState(() {
        _playing = false;
        _currentIndex = -1;
      });
    }
  }

  // ------------------------------------------------------------- Mashup edits

  void _edit(void Function() change) {
    setState(change);
    _scheduleRelayout();
  }

  /// Volume moves are applied live by the player, like faders on DJ
  /// hardware: instant, nothing re-mixed. (Pitch moves re-render the mashup.)
  void _live(void Function() change) {
    setState(change);
    _pushLive();
  }

  /// The levels the set was made with, before the mixer's faders.
  Map<String, dynamic> get _planLive =>
      Map<String, dynamic>.from((_mashupMode ? _mashPlan?.liveMap : null) ?? const {'vocal': [], 'beat': []});

  Map<String, dynamic> get _liveMap {
    final (xVocal, xBeat) = crossfadeDb(_crossfader);
    return {
      ..._withExtras(_planLive),
      'trimVocal': faderDb(_vocalFader) + xVocal + masterDb(_master),
      'trimBeat': faderDb(_beatFader) + xBeat + masterDb(_master),
    };
  }

  Map<String, dynamic> _withExtras(Map<String, dynamic> levels) => {
        ...levels,
        'fx': _autoFxOn ? _autoCues : const [],
        'muteVocal': _muteVocal,
        'muteBeat': _muteBeat,
      };

  // Slider moves are sent at most every 50 ms (the last value always goes),
  // so dragging never floods the audio side with messages.
  DateTime _lastLivePush = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _livePushTimer;

  Future<void> _pushLive() async {
    const gap = Duration(milliseconds: 50);
    final since = DateTime.now().difference(_lastLivePush);
    if (since >= gap) {
      _livePushTimer?.cancel();
      _lastLivePush = DateTime.now();
      await _mixer.setLiveMap(_liveMap);
    } else {
      _livePushTimer?.cancel();
      _livePushTimer = Timer(gap - since, _pushLive);
    }
  }

  Future<void> _swap(int i) async {
    if (_session == null) return;
    if (!_session!.swap(i)) {
      _set('Can\'t swap that one: "${_session!.mashups[i].beat.title}" doesn\'t have enough singing, or its tempo is too far off.',
          phase: Phase.ready);
      return;
    }
    _scheduleRelayout();
  }

  Future<void> _shuffle(int i) async {
    if (_session == null) return;
    _set('Finding a new pairing…', phase: Phase.ready);
    final ok = await _session!.shuffle(i, _library, (s) => _set('New pairing · $s', phase: Phase.ready));
    if (!ok) {
      _set('No more pairings left for this vibe — try Re-Mix.', phase: Phase.ready);
      return;
    }
    _scheduleRelayout();
  }

  Future<void> _insertBeat(int afterIndex) async {
    final session = _session;
    if (session == null) return;
    final choice = await showDialog<(LibraryTrack, bool)>(
      context: context,
      builder: (_) => InsertBeatDialog(tracks: _library.tracks),
    );
    if (choice == null) return;
    final (song, withVocal) = choice;
    final err = await session.insertBeat(afterIndex, song, withVocal, _library, (s) => _set(s, phase: Phase.ready));
    if (err != null) {
      _set(err, phase: Phase.ready);
      return;
    }
    _set('Added "${song.title}" ${withVocal ? 'with a vocal' : 'as a beat break'}', phase: Phase.ready);
    _scheduleRelayout();
  }

  /// Puts a song you picked into mashup [i] as its vocal or its beat.
  Future<void> _replace(int i, LibraryTrack song, bool asVocal) async {
    final session = _session;
    if (session == null || i < 0 || i >= session.mashups.length) return;
    _set('Putting "${song.title}" in as the ${asVocal ? 'vocal' : 'beat'}…', phase: Phase.ready);
    final err = await session.replace(i, song, asVocal: asVocal, lib: _library, onStatus: (s) => _set(s, phase: Phase.ready));
    if (err != null) {
      _set(err, phase: Phase.ready);
      return;
    }
    _set('"${song.title}" is now the ${asVocal ? 'vocal' : 'beat'} of mashup ${i + 1}', phase: Phase.ready);
    _scheduleRelayout();
  }

  Future<void> _addSample(int i, LibraryTrack t) async {
    final session = _session;
    if (session == null || i >= session.mashups.length) return;
    _set('Adding "${t.title}" to the sample lane…', phase: Phase.ready);
    await session.addSample(i, t, _library);
    _set('"${t.title}" is on the sample lane over mashup ${i + 1} — use the arrows to move it', phase: Phase.ready);
    _scheduleRelayout();
  }

  /// Plays just one part of a sample (its singing, or its instruments without
  /// drums and bass), splitting its stems the first time.
  Future<void> _toggleSamplePart(SamplePlacement s, {required bool melody}) async {
    if (melody ? s.melodyOnly : s.vocalOnly) {
      _edit(() => melody ? s.melodyOnly = false : s.vocalOnly = false);
      return;
    }
    if (s.track.stems == null) {
      _set('Splitting "${s.track.title}" to get its ${melody ? 'melody' : 'vocal'}…', phase: Phase.ready);
      await _library.separate([s.track], (d, t, c) {});
      if (s.track.stems == null) {
        _set('Couldn\'t split "${s.track.title}".', phase: Phase.ready);
        return;
      }
      _set('${melody ? 'Melody' : 'Acapella'} ready: "${s.track.title}"', phase: Phase.ready);
    }
    _edit(() {
      s.vocalOnly = !melody;
      s.melodyOnly = melody;
    });
  }

  Future<void> _analyseAll() async {
    final todo = _library.tracks.where((t) => t.analysis == null && !t.inCloud).toList();
    if (todo.isEmpty) return;
    _stopLearning();
    setState(() => _analyseStatus = 'Analysing ${todo.length} songs…');
    final clock = ProgressClock();
    await _library.analyze(todo, (d, t) {
      final left = clock.tick(d, t);
      if (mounted && (d % 10 == 0 || d == t)) setState(() => _analyseStatus = 'Analysing songs… $d / $t$left');
    });
    if (mounted) setState(() => _analyseStatus = null);
  }

  Future<void> _toggleAnchor(bool on) async {
    setState(() => _anchorOn = on);
    final session = _session;
    if (session == null) return;
    if (on && session.anchor == null) {
      final pick = session.maker.anchorCandidates(session.pool);
      if (pick.isEmpty) return;
      final err = await session.setAnchor(pick.first, _library, (s) => _set(s, phase: Phase.ready));
      if (err != null) _set(err, phase: Phase.ready);
    } else if (on) {
      await session.setAnchor(session.anchor!.track, _library, (s) => _set(s, phase: Phase.ready));
    } else {
      session.anchorMode = false;
    }
    _scheduleRelayout();
  }

  Future<void> _makeAnchor(LibraryTrack t) async {
    final session = _session;
    if (session == null) return;
    final err = await session.setAnchor(t, _library, (s) => _set(s, phase: Phase.ready));
    if (err != null) {
      _set(err, phase: Phase.ready);
      return;
    }
    setState(() => _anchorOn = true);
    _set('"${t.title}" is the anchor beat', phase: Phase.ready);
    _scheduleRelayout();
  }

  Future<void> _toggleWarmth(bool on) async {
    setState(() => _warmthOn = on);
    _rerenderAll();
  }

  Future<void> _toggle432(bool on) async {
    setState(() => Tuning.use432 = on);
    _rerenderAll();
  }

  void _rerenderAll() {
    if (!_hasContent) return;
    if (_mashupMode) {
      _scheduleRelayout();
    } else if (_plan != null) {
      _publish(_plan!.toRenderJson(), _plan!.cuts, _plan!.duration, _plan!.summary);
    }
  }

  void _setMode(bool mashup) {
    if (_busy || mashup == _mashupMode) return;
    _session?.cancelled = true;
    _stopPlayback();
    _sections.setPlan({'duration': 0.0, 'clips': []}, []);
    setState(() {
      _mashupMode = mashup;
      _position = 0;
      _background = null;
      _status = mashup
          ? 'Mashups: vocals from one song over the beat of another. Press Make my set.'
          : 'Blend: a DJ set that blends whole songs. Press Make my set.';
      _phase = Phase.idle;
    });
  }

  // ------------------------------------------------------------- Playback

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      final (pos, playing, waiting) = await _mixer.position();
      if (!mounted) return;
      final idx = _indexAt(pos);
      setState(() {
        _position = pos;
        _playing = playing;
        _waiting = waiting;
      });
      // The end of what's ready: wait there for the next mashup (and carry on
      // from the same spot), or stop if the set is finished. Never run on
      // into silence.
      if (playing && _duration > 0 && pos >= _duration - 0.05) {
        await _mixer.pause();
        if (!mounted) return;
        setState(() {
          _playing = false;
          _position = _duration;
          _heldAtEnd = _mashupMode && _preparing;
        });
      }
      if (idx != _currentIndex) {
        setState(() => _currentIndex = idx);
        _scrollTo(idx);
      }
    });
  }

  /// Start times of each item (song or mashup) as heard.
  List<double> get _itemStarts {
    if (_mashupMode) {
      final ms = _mashPlan?.mashups ?? const <Mashup>[];
      return [for (var i = 0; i < ms.length; i++) i == 0 ? 0.0 : (ms[i].start + ms[i - 1].end) / 2];
    }
    final plan = _plan;
    if (plan == null) return const [];
    return [
      for (var i = 0; i < plan.tracks.length; i++)
        i == 0 ? 0.0 : (plan.transitions[i - 1].start + plan.transitions[i - 1].end) / 2
    ];
  }

  int _indexAt(double pos) {
    final starts = _itemStarts;
    var idx = -1;
    for (var i = 0; i < starts.length; i++) {
      if (pos >= starts[i]) idx = i;
    }
    return idx;
  }

  void _scrollTo(int i) {
    if (i < 0 || !_scroll.hasClients) return;
    final step = _mashupMode ? 384.0 : 360.0;
    final target = (i * step - 120).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(target, duration: const Duration(milliseconds: 600), curve: Curves.easeInOut);
  }

  Future<void> _togglePlay() async {
    if (!_playable) {
      if (!_busy) await _remix();
      return;
    }
    if (_playing) {
      await _mixer.pause();
      if (mounted) setState(() => _playing = false);
    } else {
      // Always pass the last known mix time so native resume can't start at 0 / empty.
      // At the end of a finished set, play starts it again.
      final from = _duration > 0 && _position >= _duration - 0.1 && !_heldAtEnd ? 0.0 : _position;
      await _mixer.play(from: from);
      if (mounted) setState(() => _playing = true);
    }
  }

  /// Jumps to item [i] (a mashup or song): crossfades there while playing,
  /// or starts playing from there.
  Future<void> _jumpTo(int i) async {
    final starts = _itemStarts;
    if (!_playable || i < 0 || i >= starts.length) return;
    double t = starts[i];
    if (_mashupMode && i > 0) t = _mashPlan!.mashups[i].start;
    if (!_mashupMode && i > 0) t = _plan!.transitions[i - 1].start;
    if (_playing) {
      await _mixer.seek(t); // crossfades to the new spot
    } else {
      await _mixer.play(from: t);
      if (mounted) setState(() => _playing = true);
    }
  }

  Future<StorageReport> _scanStorage() async {
    const cache = 'Library/Caches/Vibeline';
    final home = MusicLibrary.home;
    final r = await _mixer.storageScan({
      StoreKind.songs.name: '$home/$cache/stems',
      StoreKind.pieces.name: SectionEngine.dir,
      StoreKind.stretched.name: Prestretcher.dir,
      StoreKind.mixes.name: '$home/Music/D-Jay Noodles',
      StoreKind.working.name: '$home/$cache/mixes',
    });
    final pieces = <String, StoredItem>{};
    final items = <StoredItem>[];
    for (final row in (r['items'] as List? ?? const []).cast<List<dynamic>>()) {
      final kind = StoreKind.values.byName(row[0] as String);
      final path = row[1] as String;
      final size = (row[3] as num).toInt();
      final added = DateTime.fromMillisecondsSinceEpoch(((row[4] as num) * 1000).toInt());
      if (kind == StoreKind.pieces) {
        // A piece and its separate vocal layer are one thing.
        final base = path.endsWith('.vox.m4a') ? path.substring(0, path.length - 8) : path;
        final had = pieces[base];
        pieces[base] = StoredItem(kind, base, 'Set piece, added ${_timeOfDay(added)}', size + (had?.size ?? 0),
            had?.added ?? added, [...?had?.paths, path]);
      } else if (kind == StoreKind.stretched) {
        final clean = path.endsWith('.clean.flac');
        items.add(StoredItem(kind, path, '${clean ? 'Clean vocal' : 'Vocal or beat'}, added ${_timeOfDay(added)}', size, added));
      } else {
        items.add(StoredItem(kind, path, kind == StoreKind.songs ? row[2] as String : (row[2] as String).replaceAll(RegExp(r'\.m4a$'), ''), size, added));
      }
    }
    return StorageReport([...items, ...pieces.values], (r['free'] as num? ?? 0).toInt());
  }

  String _timeOfDay(DateTime t) => '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'am' : 'pm'}';

  /// What the open set needs: its pieces, the files its clips play, and the
  /// songs its mashups come from.
  Set<String> _storageInUse() {
    String folder(String p) => p.substring(0, p.lastIndexOf('/'));
    final locked = <String>{};
    void add(String p) => locked
      ..add(p)
      ..add(folder(p));
    for (final s in _sections.sections) {
      locked.add('${SectionEngine.dir}/${s.hash}.m4a');
      for (final c in (s.json['clips'] as List).cast<Map<String, dynamic>>()) {
        add(c['path'] as String);
        for (final m in (c['mix'] as List?) ?? const []) {
          add(m as String);
        }
      }
    }
    final session = _session;
    if (session != null) {
      for (final t in [for (final m in session.mashups) ...[m.vocal, m.beat], if (session.anchor != null) session.anchor!.track]) {
        t.stems?.paths.values.forEach(add);
      }
    }
    return locked;
  }

  void _openStorage() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => StoragePage(
        scan: _scanStorage,
        trash: _mixer.trash,
        locked: _storageInUse(),
        canRemove: !_busy && !_preparing,
        onRemoved: (removed) {
          // A song whose split was removed is split again when next used.
          final gone = removed.toSet();
          for (final t in _library.tracks) {
            final any = t.stems?.paths.values.first;
            if (any != null && gone.contains(any.substring(0, any.lastIndexOf('/')))) {
              t.stems = null;
              t.analysis?.pinTo(null);
            }
          }
        },
      ),
    ));
  }

  bool _saving = false;

  Future<void> _export() async {
    if (_saving) return;
    if (!_sections.allReady) {
      _set('Not saved yet: ${_sections.sections.length - _sections.ready} parts of this set are still being mixed. Press Save again once they\'re done.', phase: Phase.ready);
      return;
    }
    if (_mashupMode && _pre.busy) {
      _set('Not saved yet: ${_pre.left} vocals and beats are still being cleaned up. Press Save again once they\'re done.', phase: Phase.ready);
      return;
    }
    setState(() => _saving = true);
    try {
      await _saveSet();
    } catch (e) {
      _set('Couldn\'t save this set: $e', phase: Phase.error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveSet() async {
    final dir = Directory('${MusicLibrary.home}/Music/D-Jay Noodles');
    await dir.create(recursive: true);
    final now = DateTime.now();
    final stamp =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}.${now.minute.toString().padLeft(2, '0')}';
    final theme = _themeController.text.trim();
    final name = [_currentVibePrompt, if (theme.isNotEmpty) theme].join(' ').replaceAll(RegExp(r'[^A-Za-z0-9 ,&-]'), '').trim();
    final kind = _mashupMode ? 'Mashups' : 'Mix';
    final base = '${dir.path}/D-Jay Noodles $kind – ${name.length > 50 ? name.substring(0, 50) : name} – $stamp';
    // Never replace a set that's already saved.
    var dest = '$base.m4a';
    for (var n = 2; File(dest).existsSync(); n++) {
      dest = '$base ($n).m4a';
    }
    _set('Saving your set… this can take a minute.', phase: Phase.ready);
    await _sections.export(dest, {..._withExtras(_planLive), 'grid': _beatGrid, 'muteVocal': false, 'muteBeat': false});
    await Process.run('open', ['-R', dest]);
    _set('Saved to Music › D-Jay Noodles', phase: Phase.ready);
  }

  // ------------------------------------------------------------- UI

  Color get _accent => _mashupMode ? kPink : kYellow;

  // ------------------------------------------------------------- Keyboard

  /// The computer keyboard is the controller: space plays, the arrows skip,
  /// 1–8 are the FX pads (tap to keep on, hold for just while held). Ignored
  /// while you're typing in a box.
  bool _onKey(KeyEvent e) {
    final focus = FocusManager.instance.primaryFocus?.context?.widget;
    if (focus is EditableText) return false;
    final k = e.logicalKey;
    final digit = [
      LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit3, LogicalKeyboardKey.digit4,
      LogicalKeyboardKey.digit5, LogicalKeyboardKey.digit6, LogicalKeyboardKey.digit7, LogicalKeyboardKey.digit8,
    ].indexOf(k);
    if (digit >= 0) {
      if (!_playable || e is KeyRepeatEvent) return true;
      final f = QuickPads.pads[digit].$1;
      setState(() => e is KeyDownEvent ? _fx.press(f) : _fx.release(f));
      return true;
    }
    if (e is! KeyDownEvent) return false;
    if (k == LogicalKeyboardKey.keyS) {
      _scratch();
      return true;
    }
    if (k == LogicalKeyboardKey.space) {
      _togglePlay();
      return true;
    }
    if (k == LogicalKeyboardKey.arrowLeft && _playable) {
      _previous();
      return true;
    }
    if (k == LogicalKeyboardKey.arrowRight && _playable) {
      _jumpTo(_currentIndex + 1);
      return true;
    }
    return false;
  }

  /// Back to the start of this mashup / song, or the one before if it's
  /// only just begun.
  void _previous() {
    final starts = _itemStarts;
    final int cur = _currentIndex.clamp(0, math.max(0, starts.length - 1));
    final double into = starts.isEmpty ? 0 : _position - starts[cur];
    _jumpTo(math.max(0, cur - (into > 3 ? 0 : 1)));
  }

  Future<void> _seekTo(double t) async {
    if (!_playable) return;
    if (_playing) {
      await _mixer.seek(t);
    } else {
      await _mixer.play(from: t);
      if (mounted) setState(() => _playing = true);
    }
  }

  // ------------------------------------------------------------- Now Playing

  String _keyLabel(String k) => switch (k) {
        'perfect' => 'Keys perfect',
        'shifted' => 'Key shifted to match',
        'compatible' => 'Keys compatible',
        'loose' => 'Keys loose',
        _ => 'Keys clash',
      };

  List<DeckInfo> get _decks {
    final i = math.max(0, _currentIndex);
    if (_mashupMode) {
      final ms = _mashPlan?.mashups ?? const <Mashup>[];
      if (ms.isEmpty) return _emptyDecks;
      final m = ms[i.clamp(0, ms.length - 1)];
      final beat = DeckInfo('BEAT', m.beat.title, m.beat.artist, kTeal, [
        if (!m.beatOnly) (_keyLabel(m.keyMatch), m.keyMatch == 'clash' ? Colors.redAccent : const Color(0xFF7DFF5A)),
      ], bpm: m.playedBpm.toStringAsFixed(1), keyCode: shiftCamelot(m.beatGrid.camelot, m.beatShift));
      if (m.beatOnly) return [const DeckInfo('VOCAL', 'Beat break', 'No vocal in this part', kPink, [], loaded: false), beat];
      return [
        DeckInfo('VOCAL', m.vocal.title, m.vocal.artist, kPink, [
          ('${(m.vocalSpeed * 100).round()}% speed', kPink),
          if (m.acapellaBars > 0) ('Acapella drop', kYellow),
        ], bpm: m.playedBpm.toStringAsFixed(1), keyCode: shiftCamelot(m.vocalGrid.camelot, m.vocalShift)),
        beat,
      ];
    }
    final ts = _plan?.tracks ?? const <PlannedTrack>[];
    if (ts.isEmpty) return _emptyDecks;
    DeckInfo deck(String role, PlannedTrack p, Color c) => DeckInfo(role, p.track.title, p.track.artist, c, [
          if (p.bridge) ('Beat bridge', kYellow),
        ], bpm: p.playedBpm.toStringAsFixed(1), keyCode: shiftCamelot(p.grid.camelot, p.pitchSemitones));
    final cur = i.clamp(0, ts.length - 1);
    return [
      deck('NOW', ts[cur], kPink),
      if (cur + 1 < ts.length) deck('NEXT', ts[cur + 1], kTeal) else const DeckInfo('NEXT', 'Last song in the set', '', kTeal, [], loaded: false),
    ];
  }

  static const _emptyDecks = [
    DeckInfo('DECK A', 'No song loaded', '', kPink, [], loaded: false),
    DeckInfo('DECK B', 'No song loaded', '', kTeal, [], loaded: false),
  ];

  String get _heading {
    final n = _mashupMode ? (_mashPlan?.mashups.length ?? 0) : (_plan?.tracks.length ?? 0);
    final what = _mashupMode ? 'mashup' : 'song';
    return 'Now playing · $what ${math.max(1, _currentIndex + 1)} of $n${_preparing ? '+' : ''}';
  }

  String get _upNext {
    final starts = _itemStarts;
    final next = _currentIndex + 1;
    if (next >= starts.length) return _preparing ? 'Making the next mashup…' : 'Last one in the set';
    final title = _mashupMode ? _mashPlan!.mashups[next].vocal.title : _plan!.tracks[next].track.title;
    final cue = _autoFxOn
        ? _autoCues.where((c) => (c['start'] as double) > _position && (c['start'] as double) < starts[next] + 20).firstOrNull
        : null;
    final fx = cue == null ? '' : ' · ${BeatFx.values[cue['kind'] as int].label.toLowerCase()} coming';
    return 'Up next in ${_clock(math.max(0, starts[next] - _position))} · $title$fx';
  }

  List<OverviewItem> get _overviewItems {
    final starts = _itemStarts;
    final labels = _mashupMode
        ? [for (final m in _mashPlan?.mashups ?? const <Mashup>[]) m.beatOnly ? m.beat.title : m.vocal.title]
        : [for (final t in _plan?.tracks ?? const <PlannedTrack>[]) t.track.title];
    return [
      for (var i = 0; i < starts.length && i < labels.length; i++)
        OverviewItem(starts[i], i + 1 < starts.length ? starts[i + 1] : _duration, '${i + 1} ${labels[i]}',
            !_mashupMode && _plan!.tracks[i].bridge ? kYellow : kSetColors[i % kSetColors.length]),
    ];
  }

  List<(double, MarkKind)> get _marks => [
        if (_mashupMode)
          for (final m in _mashPlan?.mashups ?? const <Mashup>[])
            if (m.acapellaBars > 0) (m.vocalIn, MarkKind.drop),
        if (!_mashupMode)
          for (final t in _plan?.tracks ?? const <PlannedTrack>[])
            if (t.bridge) (t.outStart, MarkKind.bridge),
        if (_autoFxOn)
          for (final c in _autoCues) (c['start'] as double, MarkKind.fx),
      ];

  void _setMute({bool? vocal, bool? beat}) {
    setState(() {
      _muteVocal = vocal ?? _muteVocal;
      _muteBeat = beat ?? _muteBeat;
    });
    _mixer.setLiveMap(_liveMap);
  }

  /// The main screen, laid out like a DJ deck: waveform, turntables with the
  /// mixer between them, then your songs across the bottom.
  Widget _rigView() {
    return LayoutBuilder(
      builder: (context, box) {
        final fxOpen = _fxOpen && _playable;
        final showSongs = !fxOpen && _libraryOpen && box.maxHeight >= 340;
        final songsHeight = (box.maxHeight * 0.3).clamp(130.0, 300.0);
        return Column(children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
              child: NowPlayingView(
                decks: _decks,
                sections: _sections.sections,
                waves: _waves,
                position: _position,
                playing: _playing,
                heading: _heading,
                upNext: _upNext,
                beats: _beatGrid,
                downbeats: _downbeats,
                vocalMuted: _muteVocal,
                beatMuted: _muteBeat,
                trailing: _scratchButton(),
                top: _playable ? null : _emptyTop(),
                overview: _playable && _duration > 0
                    ? SetOverview(items: _overviewItems, marks: _marks, position: _position, duration: _duration, onSeek: _seekTo)
                    : null,
                mixer: _mixerPanel,
              ),
            ),
          ),
          if (fxOpen)
            SizedBox(
              height: 168,
              child: Row(children: [
                Expanded(child: FxDeck(fx: _fx, hasVocal: _mashupMode, bpm: _bpmNow, accent: _accent)),
                if (box.maxWidth >= 1000)
                  Container(
                    width: 230,
                    color: const Color(0xFF121218),
                    padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
                    child: XYPad(fx: _fx, onChanged: () => setState(() {}), moreOpen: true, onMore: _closeFx),
                  ),
              ]),
            ),
          if (showSongs) SizedBox(height: songsHeight, child: _songs(wide: true)),
        ]);
      },
    );
  }

  Widget _emptyTop() => EmptyScreen(
        busy: _busy,
        mashup: _mashupMode,
        scanned: _scanned,
        problem: _phase == Phase.error,
        songCount: _library.tracks.length,
        goLabel: _goLabel,
        accent: _mashupMode ? kMashupAccent : Colors.amber,
        onExample: (e) => setState(() {
          _vibeController.text = e;
          _currentVibePrompt = e;
        }),
        onChooseFolder: _chooseFolder,
        onWholeMac: _searchWholeMac,
      );

  Widget _mixerPanel(double Function(bool vocal) level) {
    double scale(double fader, double cross) => math.pow(10, (faderDb(fader) + cross + masterDb(_master)) / 20).toDouble();
    final (xVocal, xBeat) = crossfadeDb(_crossfader);
    return MixerPanel(
      hasVocal: _mashupMode,
      vocalFader: _vocalFader,
      beatFader: _beatFader,
      crossfader: _crossfader,
      master: _master,
      muteVocal: _muteVocal,
      muteBeat: _muteBeat,
      fx: _fx,
      meterVocal: level(true) * scale(_vocalFader, xVocal),
      meterBeat: level(false) * scale(_beatFader, xBeat),
      onVocalFader: (v) => _live(() => _vocalFader = v),
      onBeatFader: (v) => _live(() => _beatFader = v),
      onCrossfader: (v) => _live(() => _crossfader = v),
      onMaster: (v) => _live(() => _master = v),
      onMuteVocal: () => _setMute(vocal: !_muteVocal),
      onMuteBeat: () => _setMute(beat: !_muteBeat),
      onKnob: () => setState(() {}),
    );
  }

  /// Closing the FX panel stops its effect; the mixer's knobs stay where they are.
  void _closeFx() {
    _fx.on = false;
    _fx.sendBeat();
    setState(() => _fxOpen = false);
  }

  Widget _songs({required bool wide}) => LibraryPanel(
        wide: wide,
        tracks: _library.tracks,
        mashups: _mashupMode ? (_mashPlan?.mashups ?? const []) : const [],
        maker: _session?.maker,
        target: (_libTarget ?? math.max(0, _currentIndex)).clamp(0, math.max(0, (_mashPlan?.mashups.length ?? 1) - 1)),
        asVocal: _libAsVocal,
        busy: _busy,
        analyseStatus: _analyseStatus,
        onTarget: (i) => setState(() => _libTarget = i),
        onRole: (v) => setState(() => _libAsVocal = v),
        onUse: (song, asVocal) =>
            _replace((_libTarget ?? math.max(0, _currentIndex)).clamp(0, (_mashPlan?.mashups.length ?? 1) - 1), song, asVocal),
        onAnalyseAll: _analyseAll,
        onAnchor: _makeAnchor,
        onMixAround: (song) => _remix(seed: song),
        onClose: () => setState(() => _libraryOpen = false),
      );

  bool _scratchLit = false;

  /// One push-and-pull of the record per tap; tap quickly to scratch.
  void _scratch() {
    if (!_playable || !_playing) return;
    _mixer.scratch();
    setState(() => _scratchLit = true);
    Future.delayed(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _scratchLit = false);
    });
  }

  Widget _scratchButton() => Tooltip(
        message: 'Tap quickly a few times to scratch the record (key S).\n'
            'Keys: space play · ← → skip · 1–8 FX pads · S scratch',
        child: Listener(
          onPointerDown: (_) => _scratch(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 60),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: _scratchLit ? kYellow : kPanel,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: _scratchLit ? kYellow : kYellow.withValues(alpha: 0.5)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.album, size: 15, color: _scratchLit ? kInk : kYellow),
              const SizedBox(width: 6),
              Text('SCRATCH', style: TextStyle(fontSize: 11, letterSpacing: 0.7, fontWeight: FontWeight.w700, color: _scratchLit ? kInk : kYellow)),
            ]),
          ),
        ),
      );

  /// How much music your library has for the theme typed, as you type it.
  String? get _themeHint {
    final th = _themeController.text.trim();
    if (th.isEmpty || _library.tracks.isEmpty) return null;
    final v = parseTheme('', th);
    final mins = v.minutesAvailable(_library.tracks, mashups: _mashupMode).round();
    if (mins < 4) return 'Hardly any songs for this theme';
    return mins >= 20 ? 'About $mins min of music · mix will be 20+ min' : 'Only about $mins min of music for this theme';
  }

  String get _readiness {
    if (!_playable) return '';
    final ahead = _sections.readyAhead;
    final parts = <String>[];
    if (!_sections.allReady) parts.add('${_sections.ready}/${_sections.sections.length} sections mixed · ${_clock(ahead)} ready ahead');
    if (_background != null) parts.add(_background!);
    if (_themeNote != null) parts.add(_themeNote!);
    return parts.join(' · ');
  }

  /// A top-bar button's icon and name, so nobody has to guess what it does.
  Widget _barLabel(IconData icon, String label, Color color) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(label.toUpperCase(), style: TextStyle(fontSize: 11, letterSpacing: 0.7, fontWeight: FontWeight.w700, color: color)),
        ]),
      );

  Widget _barButton({required IconData icon, required String label, String? tooltip, Color color = Colors.white70, VoidCallback? onPressed}) {
    final button = TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4), minimumSize: const Size(0, 36)),
      child: _barLabel(icon, label, onPressed == null ? Colors.white30 : color),
    );
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }

  @override
  Widget build(BuildContext context) {
    final statusLine = [_status, if (_themeHint != null) _themeHint!, if (_readiness.isNotEmpty) _readiness, if (_learnStatus != null) _learnStatus!].join('   ·   ');
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 50,
        titleSpacing: 16,
        title: Row(children: [
          const Text.rich(TextSpan(children: [
            TextSpan(text: 'D-JAY ', style: TextStyle(color: Colors.white)),
            TextSpan(text: 'NOODLES', style: TextStyle(color: kPink)),
          ]), style: TextStyle(fontSize: 14, letterSpacing: 2, fontWeight: FontWeight.w800)),
          const SizedBox(width: 20),
          Tooltip(
            message: 'Simple: the decks, waveform and pads.\nPro: every mashup card with all its knobs and sliders.',
            child: SegmentedButton<bool>(
              showSelectedIcon: false,
              style: SegmentedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                selectedBackgroundColor: Colors.white,
                selectedForegroundColor: kInk,
                foregroundColor: Colors.white70,
                side: const BorderSide(color: Colors.white24),
                textStyle: const TextStyle(fontSize: 11, letterSpacing: 0.7, fontWeight: FontWeight.w700),
              ),
              segments: const [
                ButtonSegment(value: false, label: Text('SIMPLE')),
                ButtonSegment(value: true, label: Text('PRO')),
              ],
              selected: {_pro},
              onSelectionChanged: (v) => setState(() => _pro = v.first),
            ),
          ),
        ]),
        backgroundColor: kInk,
        surfaceTintColor: Colors.transparent,
        actions: [
          _barButton(
              icon: Icons.library_music,
              label: 'Songs',
              color: _libraryOpen ? kRigAmber : Colors.white70,
              onPressed: () => setState(() => _libraryOpen = !_libraryOpen),
            ),
          _barButton(
            icon: Icons.storage,
            label: 'Storage',
            tooltip: 'What the app keeps on your Mac',
            onPressed: _openStorage,
          ),
          PopupMenuButton<bool>(
            tooltip: 'Where to find your music',
            enabled: !_busy,
            child: _barLabel(Icons.folder_open, 'Music', _busy ? Colors.white30 : Colors.white70),
            onSelected: (whole) async {
              if (!whole) return _chooseFolder();
              await _searchWholeMac();
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: true, checked: _library.wholeMac, child: const Text('Search the whole Mac')),
              CheckedPopupMenuItem(
                value: false,
                checked: !_library.wholeMac,
                child: Text(_library.wholeMac ? 'Just one folder…' : 'Just one folder: ${_library.folder.split('/').last}…'),
              ),
            ],
          ),
          _barButton(
            icon: Icons.file_download,
            label: _saving ? 'Saving…' : 'Save',
            tooltip: 'Save the whole set to your Music folder',
            onPressed: !_playable || _busy || _saving ? null : _export,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          // 1. VIBE ENGINE PROMPT BAR
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: kPanel, borderRadius: BorderRadius.circular(3)),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(
              children: [
                const Text('VIBE', style: TextStyle(fontSize: 10, letterSpacing: 1, fontWeight: FontWeight.w700, color: Colors.white54)),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _vibeController,
                    decoration: InputDecoration(
                      hintText: _mashupMode
                          ? 'e.g. country vocals over hip hop, 2 hours'
                          : 'Crowd vibe, e.g. rave, cafe chill, Aussie rock',
                      hintStyle: const TextStyle(fontSize: 14, color: Colors.white54),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onSubmitted: (value) {
                      setState(() => _currentVibePrompt = value);
                      _remix();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                ThemePicker(controller: _themeController, locked: _busy, onChanged: () => setState(() {})),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    foregroundColor: kInk,
                    textStyle: const TextStyle(fontSize: 12, letterSpacing: 0.7, fontWeight: FontWeight.w800),
                    minimumSize: const Size(0, 32),
                  ),
                  onPressed: _busy ? null : _remix,
                  icon: _busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70))
                      : const Icon(Icons.play_arrow, size: 16),
                  label: Text(_goLabel.toUpperCase()),
                ),
              ],
            ),
            ]),
          ),

          // 2. TOOLBAR: mode + tuning
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: kInk,
            width: double.infinity,
            child: Row(children: [
              Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                RigToggle(
                  label: 'Mashups',
                  on: _mashupMode,
                  locked: _busy,
                  tooltip: 'On: vocals from one song over the beat of another.\nOff: songs blended one after the other.',
                  onChanged: _setMode,
                ),
                if (_mashupMode)
                  RigToggle(
                    label: 'Anchor beat',
                    on: _anchorOn,
                    locked: _busy,
                    tooltip: 'Anchor beat: one steady groove the set comes home to. New vocals come in over it,\n'
                        'the mashup\'s own beat takes over once the vocal settles, and it cuts back to the anchor now and then.',
                    onChanged: _toggleAnchor,
                  ),
                RigToggle(
                  label: '432 Hz',
                  on: Tuning.use432,
                  tooltip: 'Retune every song, beat and vocal to A = 432 Hz before it plays.\nOff: songs keep their own tuning.',
                  onChanged: _toggle432,
                ),
              ],
            ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  statusLine,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, height: 1.2, color: _phase == Phase.error ? Colors.redAccent : Colors.white70),
                ),
              ),
            ]),
          ),
          SizedBox(
            height: 2,
            child: _busy
                ? LinearProgressIndicator(value: _progress, color: _accent, backgroundColor: Colors.white10)
                : const Divider(height: 2, thickness: 1, color: kLine),
          ),

          // 3. THE DECKS (or, in Pro with a set loaded, every card)
          Expanded(
            child: !_pro || !_hasContent
                ? _rigView()
                : Row(
                    children: [
                      Expanded(child: _mashupMode ? _mashupTimeline() : _blendTimeline()),
                      if (_mashupMode && _libraryOpen) _songs(wide: false),
                    ],
                  ),
          ),

          // 4. LIVE FX AND THE WHOLE SET, in Pro
          if (_pro && _hasContent && _fxOpen && _playable) FxDeck(fx: _fx, hasVocal: _mashupMode, bpm: _bpmNow, accent: _accent),
          if (_pro && _hasContent && _playable && _duration > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: SetOverview(
                items: _overviewItems,
                marks: _marks,
                position: _position,
                duration: _duration,
                onSeek: _seekTo,
              ),
            ),

          // 6. PLAYBACK & TRANSPORT DOCK
          Container(
            height: 68,
            decoration: const BoxDecoration(color: kInk, border: Border(top: BorderSide(color: kLine))),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Back (←)',
                  icon: const Icon(Icons.skip_previous),
                  onPressed: !_playable ? null : _previous,
                ),
                Tooltip(
                  message: _playing ? 'Pause (space)' : 'Play (space)',
                  child: InkWell(
                    onTap: _togglePlay,
                    borderRadius: BorderRadius.circular(kRigCorner),
                    child: Container(
                      width: 52,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _playing ? kRigGreen : kRigFace,
                        borderRadius: BorderRadius.circular(kRigCorner),
                        border: Border.all(color: kRigGreen, width: 1.5),
                      ),
                      child: Icon(_playing ? Icons.pause : Icons.play_arrow, size: 26, color: _playing ? kInk : kRigGreen),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Next (→)',
                  icon: const Icon(Icons.skip_next),
                  onPressed: !_playable ? null : () => _jumpTo(_currentIndex + 1),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 150,
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(
                        text: !_playable ? '--:--' : _clock(_position),
                        style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text: !_playable ? '  / --:--' : '  / ${_clock(_duration)}',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                    ]),
                    style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ),
                if (_waiting || _heldAtEnd)
                  Tooltip(
                    message: _heldAtEnd ? 'Making the next mashup…' : 'Mixing this part…',
                    child: const Padding(
                      padding: EdgeInsets.only(right: 10),
                      child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  ),
                if (!_pro && _playable)
                  Expanded(child: SizedBox(height: 40, child: QuickPads(fx: _fx, oneRow: true, onChanged: () => setState(() {}))))
                else
                  const Spacer(),
                const SizedBox(width: 10),
                RigToggle(
                  label: 'FX',
                  on: _fxOpen,
                  tooltip: 'Live effects: Colour FX knobs and Beat FX pads',
                  onChanged: !_playable
                      ? null
                      : (_) {
                          if (_fxOpen) return _closeFx();
                          setState(() => _fxOpen = true);
                        },
                ),
                const SizedBox(width: 6),
                RigToggle(
                  label: 'Auto FX',
                  on: _autoFxOn,
                  tooltip: 'Auto FX: the set throws in echoes, rolls and sweeps by itself at the changeovers',
                  onChanged: (on) {
                    setState(() => _autoFxOn = on);
                    _mixer.setLiveMap(_liveMap);
                  },
                ),
                const SizedBox(width: 6),
                RigToggle(
                  // The exact settings are detail for Pro.
                  label: _warmthOn && _pro && _vibe != null
                      ? 'Warmth ${_vibe!.drive.toStringAsFixed(1)} · ${(_vibe!.crackle * 100).round()}%'
                      : 'Warmth',
                  on: _warmthOn,
                  tooltip: 'Warmth: gives the whole set the sound of tape and vinyl, to suit your vibe',
                  onChanged: _toggleWarmth,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _mashupTimeline() {
    final ms = _mashPlan!.mashups;
    final more = _background != null;
    return ListView.builder(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
      itemCount: ms.length + 1 + (more ? 1 : 0),
      itemBuilder: (context, k) {
        if (k == 0) {
          final anc = _session?.anchorMode == true ? _session?.anchor : null;
          return Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Align(alignment: Alignment.topLeft, child: MashupLaneHeader(anchor: anc)));
        }
        final i = k - 1;
        if (i >= ms.length) {
          return Padding(
            padding: const EdgeInsets.only(left: 24, top: 70),
            child: SizedBox(
              width: 200,
              child: Column(children: [
                // Only while still working: a finished "ran out of pairings"
                // note mustn't look like it's stuck loading.
                if (_preparing) ...[
                  const CircularProgressIndicator(color: kMashupAccent),
                  const SizedBox(height: 12),
                ],
                Text(_background ?? '', textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, color: Colors.white54)),
              ]),
            ),
          );
        }
        final m = ms[i];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AcapellaBlock(mashup: m, live: i == _currentIndex && _position >= m.vocalIn && _position <= m.vocalOut),
                  SampleStrip(
                    mashup: m,
                    samples: _session?.samples.where((s) => identical(s.anchor, m)).toList() ?? const [],
                    busy: _busy,
                    onDrop: (t) => _addSample(i, t),
                    onAdd: () async {
                      final t = await showDialog<LibraryTrack>(
                          context: context, builder: (_) => AddSoundDialog(tracks: _library.tracks));
                      if (t != null) _addSample(i, t);
                    },
                    onChange: (s, change) => _edit(change),
                    onRemove: (s) => _edit(() => _session?.samples.remove(s)),
                    onToggleVocal: (s) => _toggleSamplePart(s, melody: false),
                    onToggleMelody: (s) => _toggleSamplePart(s, melody: true),
                  ),
                  const SizedBox(height: 10),
                  TrackStemLaneWidget(
                    mashup: m,
                    expanded: _expanded.contains(i),
                    isCurrent: i == _currentIndex,
                    busy: _busy,
                    position: _position,
                    onToggleStems: () => setState(() => _expanded.contains(i) ? _expanded.remove(i) : _expanded.add(i)),
                    onTap: () => _jumpTo(i),
                    onSwap: () => _swap(i),
                    onShuffle: () => _shuffle(i),
                    onToggleMute: (lane) => _edit(() => lane.muted = !lane.muted),
                    onToggleSolo: (lane) => _edit(() => lane.solo = !lane.solo),
                    onShift: (d) => _edit(() => m.vocalShift = (m.vocalShift + d).clamp(-6, 6)),
                    onFine: (c) => _edit(() => m.fineCents = c),
                    onResetPitch: () => _edit(() {
                      m.vocalShift = m.autoShift;
                      m.fineCents = 0;
                    }),
                    onVocalDb: (db) => _live(() => m.vocalDb = db),
                    onBeatDb: (db) => _live(() => m.beatDb = db),
                    onTempo: (s) => _edit(() => m.tempoScale = s.clamp(0.85, 1.15)),
                    anchorMode: _session?.anchorMode == true,
                    onDrop: (song, asVocal) => _replace(i, song, asVocal),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 68),
              child: MashupBridge(onAdd: () => _insertBeat(i)),
            ),
          ],
        );
      },
    );
  }

  Widget _blendTimeline() {
    final plan = _plan!;
    return ListView.builder(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(32),
      itemCount: plan.tracks.length,
      itemBuilder: (context, i) => Row(
        children: [
          TrackTimelineNode(
            planned: plan.tracks[i],
            color: _trackColors[i % _trackColors.length],
            isCurrent: i == _currentIndex,
            position: _position,
            onTap: () => _jumpTo(i),
          ),
          if (i < plan.tracks.length - 1) TransitionBridgeNode(transition: plan.transitions[i]),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------
// INDIVIDUAL TRACK TIMELINE BLOCK WIDGET
// ---------------------------------------------------------
class TrackTimelineNode extends StatelessWidget {
  final PlannedTrack planned;
  final Color color;
  final bool isCurrent;
  final double position;
  final VoidCallback onTap;

  const TrackTimelineNode({
    super.key,
    required this.planned,
    required this.color,
    required this.isCurrent,
    required this.position,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = planned.track;
    final stretch = (planned.rate - 1) * 100;
    final key = shiftCamelot(planned.grid.camelot, planned.pitchSemitones);
    final playedFrac = ((position - planned.outStart) / (planned.outEnd - planned.outStart)).clamp(0.0, 1.0);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: 280,
        height: 160,
        decoration: BoxDecoration(
          color: isCurrent ? const Color(0xFF34343F) : const Color(0xFF2C2C35),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: color.withValues(alpha: isCurrent ? 1 : 0.6), width: isCurrent ? 3 : 2),
          boxShadow: [
            BoxShadow(
              color: isCurrent ? color.withValues(alpha: 0.35) : Colors.black.withValues(alpha: 0.4),
              blurRadius: isCurrent ? 18 : 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Track Header metadata
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
              ),
              child: Row(
                children: [
                  Text(key, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.amber)),
                  if (planned.pitchSemitones != 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(
                        planned.pitchSemitones > 0 ? '▲${planned.pitchSemitones}' : '▼${-planned.pitchSemitones}',
                        style: const TextStyle(fontSize: 10, color: Colors.amberAccent),
                      ),
                    ),
                  if (planned.bridge) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(color: Colors.orangeAccent.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(3)),
                      child: const Text('BEAT BRIDGE', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.orangeAccent)),
                    ),
                  ],
                  if (t.shazam) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(color: Colors.lightBlueAccent.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(3)),
                      child: const Text('SHAZAM', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.lightBlueAccent)),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    "${planned.playedBpm.toStringAsFixed(1)} BPM",
                    style: const TextStyle(fontSize: 12, color: Colors.white70),
                  ),
                  if (stretch.abs() >= 0.1)
                    Text(
                      '  ${stretch > 0 ? '+' : ''}${stretch.toStringAsFixed(1)}%',
                      style: const TextStyle(fontSize: 10, color: Colors.white38),
                    ),
                ],
              ),
            ),

            // Track Info
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16), overflow: TextOverflow.ellipsis),
                  Text(
                    [t.artist, if (t.genre.isNotEmpty) t.genre, if (t.year > 0) '${t.year}'].join(' · '),
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),

            const Spacer(),

            // Waveform: the part of the song used in the mix is lit, and the
            // played part fills in while it plays.
            Container(
              height: 40,
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black38,
                borderRadius: BorderRadius.circular(3),
              ),
              child: CustomPaint(
                size: Size.infinite,
                painter: _WaveformPainter(
                  peaks: planned.grid.waveform,
                  color: color,
                  usedFrom: planned.srcStart / t.duration,
                  usedTo: planned.srcEnd / t.duration,
                  played: planned.srcAt(planned.outStart + playedFrac * (planned.outEnd - planned.outStart)) / t.duration,
                  showPlayed: isCurrent || playedFrac >= 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> peaks;
  final Color color;
  final double usedFrom, usedTo, played;
  final bool showPlayed;

  _WaveformPainter({
    required this.peaks,
    required this.color,
    required this.usedFrom,
    required this.usedTo,
    required this.played,
    required this.showPlayed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;
    final w = size.width / peaks.length;
    final mid = size.height / 2;
    final paint = Paint()..strokeWidth = math.max(1, w * 0.7);
    for (var i = 0; i < peaks.length; i++) {
      final f = (i + 0.5) / peaks.length;
      final used = f >= usedFrom && f <= usedTo;
      final done = showPlayed && used && f <= played;
      paint.color = done
          ? color
          : used
              ? color.withValues(alpha: 0.45)
              : Colors.white.withValues(alpha: 0.12);
      final h = math.max(1.0, peaks[i] * (size.height / 2 - 4));
      final x = i * w + w / 2;
      canvas.drawLine(Offset(x, mid - h), Offset(x, mid + h), paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.played != played || old.showPlayed != showPlayed || old.peaks != peaks || old.usedFrom != usedFrom;
}

// ---------------------------------------------------------
// TRANSITION BRIDGE NODE (The overlap zone between tracks)
// ---------------------------------------------------------
class TransitionBridgeNode extends StatelessWidget {
  final PlannedTransition transition;
  const TransitionBridgeNode({super.key, required this.transition});

  @override
  Widget build(BuildContext context) {
    final keyColor = switch (transition.keyMatch) {
      'perfect' || 'compatible' => Colors.greenAccent,
      'shifted' => Colors.lightBlueAccent,
      'energy' => Colors.amber,
      _ => Colors.redAccent,
    };
    return Tooltip(
      message: '${transition.type.label} over ${transition.bars} bars · keys: ${transition.keyMatch}',
      child: Container(
        width: 80,
        height: 160,
        color: Colors.transparent,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                height: 2,
                color: Colors.amber.shade700,
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.amber.shade900.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: Colors.amber.shade700),
                ),
                child: Text(
                  transition.type.label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.amber),
                ),
              ),
              const SizedBox(height: 4),
              Text('${transition.bars} bars', style: const TextStyle(fontSize: 9, color: Colors.white54)),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.music_note, size: 10, color: keyColor),
                  Text(transition.keyMatch, style: TextStyle(fontSize: 9, color: keyColor)),
                ],
              ),
              const SizedBox(height: 6),
              Container(
                height: 2,
                color: Colors.amber.shade700,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

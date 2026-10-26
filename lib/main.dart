import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'library.dart';
import 'library_panel.dart';
import 'mashup.dart';
import 'mashup_widgets.dart';
import 'mixer.dart';
import 'models.dart';
import 'planner.dart';
import 'sections.dart';
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
      title: 'Vibeline',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0E0E12),
        primaryColor: const Color(0xFF6200EE),
      ),
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

  String _currentVibePrompt = "Party, mix genres, my Shazams";
  Phase _phase = Phase.idle;
  String _status = 'Starting up…';
  String? _background; // long-set preparation running behind the scenes
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
  bool _libraryOpen = false;
  int? _libTarget;
  bool _libAsVocal = true;
  String? _analyseStatus;

  double _duration = 0;
  double _position = 0;
  bool _playing = false;
  bool _waiting = false;
  int _currentIndex = -1;
  Timer? _ticker;
  Timer? _relayout;

  @override
  void initState() {
    super.initState();
    SectionEngine.prune();
    _startup();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _relayout?.cancel();
    _vibeController.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _busy => _phase == Phase.working;
  bool get _hasContent => _mashupMode ? _mashPlan != null : _plan != null;
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
    _scanned = true;
    _set(
      '${_library.tracks.length} songs found · ${_library.shazamMatches} of them are Shazams. '
      'Type a vibe and hit Re-Mix AI.',
      phase: _hasContent ? Phase.ready : Phase.idle,
    );
  }

  Future<void> _chooseFolder() async {
    if (_busy) return;
    final r = await Process.run('osascript', ['-e', 'POSIX path of (choose folder with prompt "Pick the folder with your music")']);
    final path = (r.stdout as String).trim();
    if (r.exitCode != 0 || path.isEmpty) return;
    _library.folder = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    await _library.saveSettings();
    await _scan();
  }

  Map<String, dynamic>? get _warmth =>
      _warmthOn && _vibe != null ? {'drive': _vibe!.drive, 'crackle': _vibe!.crackle} : null;

  // ------------------------------------------------------------- Re-Mix AI

  Future<void> _remix() async {
    if (_busy) return;
    _currentVibePrompt = _vibeController.text.trim().isEmpty ? _currentVibePrompt : _vibeController.text.trim();
    try {
      if (!_scanned) await _scan();
      if (_phase == Phase.error) return;
      _session?.cancelled = true;
      await _stopPlayback();
      setState(() {
        _position = 0;
        _background = null;
      });

      final vibe = parseVibe(_currentVibePrompt);
      _vibe = vibe;
      final rng = math.Random();
      var pool = _library.tracks.toList();
      if (vibe.shazamOnly) {
        final mine = pool.where((t) => t.shazam).toList();
        if (mine.length >= 8) pool = mine;
      }
      final ranked = pool.map((t) => (t, tagScore(t, vibe, rng))).toList()..sort((a, b) => b.$2.compareTo(a.$2));

      if (_mashupMode) {
        await _makeMashups(vibe, ranked.map((e) => e.$1).toList());
      } else {
        await _makeBlendMix(vibe, ranked.map((e) => e.$1).toList());
      }
    } catch (e) {
      _set('Something went wrong: $e', phase: Phase.error);
    }
  }

  Future<void> _makeBlendMix(VibeProfile vibe, List<LibraryTrack> ranked) async {
    final batch = math.max(48, vibe.trackCount * 5);
    MixPlan? plan;
    for (var round = 0; round < 3; round++) {
      final wanted = ranked.take(batch * (round + 1)).toList();
      await _library.analyze(wanted, (done, total) {
        _set('Listening to songs for "${vibe.summary}"… $done / $total', progress: total == 0 ? null : done / total);
      });
      _set('Planning the set…');
      plan = MixPlanner(vibe).plan(wanted);
      if (plan != null && plan.tracks.length >= math.min(vibe.trackCount, 4)) break;
    }
    if (plan == null) {
      _set('Couldn\'t find enough songs that mix together for that vibe. Try a broader vibe.', phase: Phase.error);
      return;
    }
    setState(() => _plan = plan);
    await _publish(plan.toRenderJson(), plan.cuts, plan.duration, plan.summary, autoplay: true);
  }

  Future<void> _makeMashups(VibeProfile vibe, List<LibraryTrack> ranked) async {
    final maker = MashupMaker(vibe);
    final count = maker.mashupCount;
    // Long sets need a bigger pool of songs to draw from. Anchor mode needs
    // more again: every beat has to fit the anchor's tempo and key (80 songs
    // left 2–3 mashups for a 5-mashup set).
    final pool = ranked.take(_anchorOn ? math.max(240, count * 6) : math.max(80, count * 4)).toList();
    await _library.analyze(pool, (done, total) {
      _set('Listening to songs for "${vibe.summary}"… $done / $total', progress: total == 0 ? null : done / total);
    });
    _set('Pairing vocals with beats…');
    final session = MashupSession.start(maker, pool)..anchorMode = _anchorOn;
    setState(() {
      _session = session;
      _mashPlan = null;
      _expanded.clear();
    });
    var started = false;
    // Builds progressively: plays as soon as the first mashups are ready and
    // keeps preparing the rest in the background.
    final filling = session.fill(_library, count, (s) {
      if (started) {
        if (mounted) setState(() => _background = s);
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
    await filling;
    if (session.cancelled) return;
    if (session.mashups.isEmpty) {
      _set('Couldn\'t find vocals and beats that fit together for that vibe. Try a broader vibe.', phase: Phase.error);
      return;
    }
    setState(() => _background = session.mashups.length < count
        ? 'Prepared ${session.mashups.length} of $count mashups — ran out of good pairings for this vibe'
        : null);
    _scheduleRelayout();
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
    _duration = duration;
    await _mixer.setLiveMap(_liveMap);
    await _sections.setPlan(json, cuts, remap: remap);
    _set('Ready · ${_clock(duration)} · $summary', phase: Phase.ready);
    _startTicker();
    if (autoplay) {
      _autoplayPending = true;
      _sectionsChanged();
    }
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

  Map<String, dynamic> get _liveMap => (_mashupMode ? _mashPlan?.liveMap : null) ?? const {'vocal': [], 'beat': []};

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
      _set('No more pairings left for this vibe — try Re-Mix AI.', phase: Phase.ready);
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

  Future<void> _toggleSampleVocal(SamplePlacement s) async {
    if (s.vocalOnly) {
      _edit(() => s.vocalOnly = false);
      return;
    }
    if (s.track.stems == null) {
      _set('Splitting "${s.track.title}" to get its vocal…', phase: Phase.ready);
      await _library.separate([s.track], (d, t, c) {});
      if (s.track.stems == null) {
        _set('Couldn\'t split "${s.track.title}".', phase: Phase.ready);
        return;
      }
      _set('Acapella ready: "${s.track.title}"', phase: Phase.ready);
    }
    _edit(() => s.vocalOnly = true);
  }

  Future<void> _analyseAll() async {
    final todo = _library.tracks.where((t) => t.analysis == null).toList();
    if (todo.isEmpty) return;
    setState(() => _analyseStatus = 'Analysing ${todo.length} songs…');
    await _library.analyze(todo, (d, t) {
      if (mounted && (d % 10 == 0 || d == t)) setState(() => _analyseStatus = 'Analysing songs… $d / $t');
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
    _set('⚓ "${t.title}" is the anchor beat', phase: Phase.ready);
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
          ? 'Mashup Mode: vocals from one song over the beat of another. Hit Re-Mix AI.'
          : 'Blend Mode: a DJ set that blends whole songs. Hit Re-Mix AI.';
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
      final from = _position;
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

  Future<void> _export() async {
    if (!_sections.allReady) {
      _set('Still preparing ${_sections.sections.length - _sections.ready} sections — save again in a moment.', phase: Phase.ready);
      return;
    }
    final dir = Directory('${MusicLibrary.home}/Music/Vibeline');
    await dir.create(recursive: true);
    final now = DateTime.now();
    final stamp =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}.${now.minute.toString().padLeft(2, '0')}';
    final name = _currentVibePrompt.replaceAll(RegExp(r'[^A-Za-z0-9 ,&-]'), '').trim();
    final kind = _mashupMode ? 'Mashups' : 'Mix';
    final dest = '${dir.path}/Vibeline $kind – ${name.length > 50 ? name.substring(0, 50) : name} – $stamp.m4a';
    _set('Saving…', phase: Phase.ready);
    await _sections.export(dest, _liveMap);
    await Process.run('open', ['-R', dest]);
    _set('Saved to Music › Vibeline', phase: Phase.ready);
  }

  // ------------------------------------------------------------- UI

  Color get _accent => _mashupMode ? kMashupAccent : Colors.amber;

  String get _readiness {
    if (!_playable) return '';
    final ahead = _sections.readyAhead;
    final parts = <String>[];
    if (!_sections.allReady) parts.add('${_sections.ready}/${_sections.sections.length} sections mixed · ${_clock(ahead)} ready ahead');
    if (_background != null) parts.add(_background!);
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final statusLine = [_status, if (_readiness.isNotEmpty) _readiness].join('   ·   ');
    return Scaffold(
      appBar: AppBar(
        title: Text(_mashupMode ? 'Vibeline — Timeline & Mashup Studio' : 'Vibeline'),
        backgroundColor: const Color(0xFF181820),
        actions: [
          if (_mashupMode)
            TextButton.icon(
              onPressed: () => setState(() => _libraryOpen = !_libraryOpen),
              icon: Icon(Icons.library_music, color: _libraryOpen ? kMashupAccent : Colors.white70, size: 18),
              label: Text('Songs', style: TextStyle(color: _libraryOpen ? kMashupAccent : Colors.white70)),
            ),
          IconButton(
            tooltip: 'Choose music folder',
            icon: const Icon(Icons.folder_open),
            onPressed: _busy ? null : _chooseFolder,
          ),
          IconButton(
            tooltip: _playing ? 'Pause' : 'Play',
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
            onPressed: _togglePlay,
          ),
          IconButton(
            tooltip: 'Save the whole set to your Music folder',
            icon: const Icon(Icons.file_download),
            onPressed: !_playable || _busy ? null : _export,
          ),
        ],
      ),
      body: Column(
        children: [
          // 1. VIBE ENGINE PROMPT BAR
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            color: const Color(0xFF181820),
            child: Row(
              children: [
                Icon(Icons.psychology, color: _accent),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _vibeController,
                    decoration: InputDecoration(
                      hintText: _mashupMode
                          ? "Describe the mashups (e.g. 'country vocals over hip hop', 'festival, 4 hours, mix genres')..."
                          : "Enter crowd vibe (e.g., 'Rave', 'Cafe chill', 'Aussie rock')...",
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onSubmitted: (value) {
                      setState(() => _currentVibePrompt = value);
                      _remix();
                    },
                  ),
                ),
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _mashupMode ? Colors.purpleAccent : Colors.amber.shade700,
                    foregroundColor: _mashupMode ? Colors.white : Colors.black,
                  ),
                  onPressed: _busy ? null : _remix,
                  icon: _busy
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70))
                      : const Icon(Icons.auto_awesome, size: 16),
                  label: const Text('Re-Mix AI'),
                ),
              ],
            ),
          ),

          // 2. TOOLBAR: mode + tuning
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
            color: const Color(0xFF14141A),
            child: Row(
              children: [
                Icon(Icons.layers, color: _mashupMode ? kMashupAccent : Colors.white38, size: 18),
                const SizedBox(width: 8),
                Text(
                  _mashupMode ? "Mashup Mode: ACTIVE" : "Mashup Mode: OFF",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _mashupMode ? Colors.white : Colors.white54),
                ),
                Switch(value: _mashupMode, activeColor: kMashupAccent, onChanged: _busy ? null : _setMode),
                if (_mashupMode) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: 'Anchor beat: one steady groove the set comes home to. New vocals come in over it,\n'
                        'the mashup\'s own beat takes over once the vocal settles, and it cuts back to the anchor now and then.',
                    child: Row(children: [
                      const Text('⚓', style: TextStyle(fontSize: 13)),
                      const SizedBox(width: 4),
                      const Text('Anchor beat', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                      Switch(value: _anchorOn, activeThumbColor: kMashupAccent, onChanged: _busy ? null : _toggleAnchor),
                    ]),
                  ),
                ],
                const SizedBox(width: 16),
                Tooltip(
                  message: 'Retune every song, beat and vocal to A = 432 Hz before it plays.\nOff: songs keep their own tuning.',
                  child: Row(children: [
                    const Icon(Icons.tune, size: 16, color: Colors.white54),
                    const SizedBox(width: 6),
                    Text(Tuning.use432 ? 'Tuning: 432 Hz' : 'Tuning: original',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    Switch(value: Tuning.use432, activeColor: _accent, onChanged: _toggle432),
                  ]),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    statusLine,
                    textAlign: TextAlign.right,
                    style: TextStyle(fontSize: 11, color: _phase == Phase.error ? Colors.redAccent : Colors.white60),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 2,
            child: _busy
                ? LinearProgressIndicator(value: _progress, color: _accent, backgroundColor: Colors.white10)
                : const Divider(height: 2, thickness: 1, color: Colors.white24),
          ),

          // 3. TIMELINE
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: !_hasContent
                      ? _EmptyTimeline(busy: _busy, mashup: _mashupMode)
                      : (_mashupMode ? _mashupTimeline() : _blendTimeline()),
                ),
                if (_mashupMode && _libraryOpen)
                  LibraryPanel(
                    tracks: _library.tracks,
                    mashups: _mashPlan?.mashups ?? const [],
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
                    onClose: () => setState(() => _libraryOpen = false),
                  ),
              ],
            ),
          ),

          // 4. PLAYBACK & TRANSPORT DOCK
          Container(
            height: 72,
            color: const Color(0xFF181820),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous),
                  onPressed: !_playable
                      ? null
                      : () {
                          final starts = _itemStarts;
                          final int cur = _currentIndex.clamp(0, math.max(0, starts.length - 1));
                          final double into = starts.isEmpty ? 0 : _position - starts[cur];
                          _jumpTo(math.max(0, cur - (into > 3 ? 0 : 1)));
                        },
                ),
                IconButton(
                  icon: Icon(_playing ? Icons.pause_circle_filled : Icons.play_circle_fill, size: 46, color: _accent),
                  onPressed: _togglePlay,
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  onPressed: !_playable ? null : () => _jumpTo(_currentIndex + 1),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 120,
                  child: Text(
                    !_playable ? '--:-- / --:--' : '${_clock(_position)} / ${_clock(_duration)}',
                    style: const TextStyle(color: Colors.white70, fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ),
                if (_waiting)
                  const Row(children: [
                    SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 8),
                    Text('Mixing this part…', style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ]),
                const Spacer(),
                Tooltip(
                  message: 'Tape saturation + vinyl crackle on the master output, flavoured by your vibe',
                  child: Row(
                    children: [
                      Text(
                        _warmthOn
                            ? 'Analog Warmth: ON${_vibe == null ? '' : ' (drive ${_vibe!.drive.toStringAsFixed(1)} · crackle ${(_vibe!.crackle * 100).round()}%)'}'
                            : 'Analog Warmth: OFF',
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      Switch(value: _warmthOn, activeColor: _accent, onChanged: _toggleWarmth),
                    ],
                  ),
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
                const CircularProgressIndicator(color: kMashupAccent),
                const SizedBox(height: 12),
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
                    onToggleVocal: _toggleSampleVocal,
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

class _EmptyTimeline extends StatelessWidget {
  final bool busy;
  final bool mashup;
  const _EmptyTimeline({required this.busy, required this.mashup});

  @override
  Widget build(BuildContext context) {
    final accent = mashup ? kMashupAccent : Colors.amber;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(mashup ? Icons.call_split : Icons.graphic_eq, size: 56, color: accent.withValues(alpha: busy ? 0.8 : 0.35)),
          const SizedBox(height: 12),
          Text(
            busy ? (mashup ? 'Cooking up mashups…' : 'Building your mix…') : (mashup ? 'Your mashups will appear here' : 'Your mix will appear here'),
            style: const TextStyle(fontSize: 18, color: Colors.white70),
          ),
          const SizedBox(height: 6),
          Text(
            mashup
                ? 'Try: "Party, mix genres, my Shazams", "country vocals over hip hop" or "festival, 4 hours"\nFirst time splits stems: about 20 seconds a song. Long sets keep preparing while they play.'
                : 'Try: "Party, mix genres, modern, my Shazams" or "Cafe chill, 80s"',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38),
          ),
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
          borderRadius: BorderRadius.circular(12),
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
                  if (t.shazam) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(color: Colors.lightBlueAccent.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(4)),
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
                borderRadius: BorderRadius.circular(6),
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
                  borderRadius: BorderRadius.circular(4),
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

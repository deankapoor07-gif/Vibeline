import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'deck_view.dart' show kPanel, kPink, kTeal, kYellow, QuickPads;
import 'fx_deck.dart';
import 'mixer.dart';
import 'mixer_panel.dart';
import 'phone_set.dart';
import 'rig.dart' show kRigAmber;

/// The iPhone app: plays sets made on the Mac (sent with its iPhone button
/// through iCloud Drive), with live decks, mixer and FX.
class PhoneApp extends StatelessWidget {
  const PhoneApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'D-Jay Noodles',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: _bg,
          colorScheme: const ColorScheme.dark(primary: kPink, secondary: kTeal, surface: kPanel),
        ),
        home: const PhoneHome(),
      );
}

const _bg = Color(0xFF09090D);
const _line = Color(0xFF26262E);
const _channel = MethodChannel('vibeline/phone');

TextStyle _label(Color c, {double size = 10}) =>
    TextStyle(fontSize: size, fontWeight: FontWeight.w800, letterSpacing: 1.6, color: c);

String _clock(double s) {
  final t = s.isFinite ? s.round().clamp(0, 359999) : 0;
  final h = t ~/ 3600, m = (t % 3600) ~/ 60, sec = t % 60;
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}' : '$m:${sec.toString().padLeft(2, '0')}';
}

Widget _logo() => Row(mainAxisSize: MainAxisSize.min, children: [
      const Text('D-JAY', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
      const SizedBox(width: 6),
      Text('NOODLES', style: _label(kPink, size: 11).copyWith(letterSpacing: 4)),
    ]);

/// A square lit button, like the ones on DJ gear.
class _LitButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color color;
  final bool lit;
  final VoidCallback? onTap;
  const _LitButton(this.label, {this.icon, this.color = kRigAmber, this.lit = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final on = onTap != null;
    final c = on ? color : Colors.white24;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: lit ? c.withValues(alpha: 0.22) : const Color(0xFF15151C),
          border: Border.all(color: lit ? c : c.withValues(alpha: 0.6), width: 1.2),
          borderRadius: BorderRadius.circular(3),
          boxShadow: lit ? [BoxShadow(color: c.withValues(alpha: 0.35), blurRadius: 10)] : null,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 16, color: c), if (label.isNotEmpty) const SizedBox(width: 6)],
          if (label.isNotEmpty) Text(label, style: _label(c, size: 11)),
        ]),
      ),
    );
  }
}

// ===================================================================== Sets

class _Entry {
  final String name;
  PhoneSet? onPhone;
  PhoneSet? inCloud;
  bool cloudPending = false; // in iCloud, description not downloaded yet
  _Entry(this.name);
  PhoneSet? get any => onPhone ?? inCloud;
}

class PhoneHome extends StatefulWidget {
  const PhoneHome({super.key});
  @override
  State<PhoneHome> createState() => _PhoneHomeState();
}

class _PhoneHomeState extends State<PhoneHome> {
  String? _docs;
  String? _folder;
  List<_Entry> _sets = [];
  bool _loading = true;
  String? _busyName;
  double? _progress;
  String? _message;

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress' && mounted) setState(() => _progress = (call.arguments as num).toDouble());
    });
    _start();
  }

  Future<void> _start() async {
    _docs = await _channel.invokeMethod<String>('documents');
    _folder = await _channel.invokeMethod<String>('folderName');
    await _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final byName = <String, _Entry>{};
    final local = Directory('$_docs/Sets');
    if (local.existsSync()) {
      for (final d in local.listSync().whereType<Directory>()) {
        if (d.path.endsWith('.part')) continue;
        final s = PhoneSet.read(d.path);
        if (s == null) continue;
        final name = d.path.split('/').last;
        (byName[name] ??= _Entry(name)).onPhone = s;
      }
    }
    if (_folder != null) {
      try {
        final list = await _channel.invokeListMethod<Map<dynamic, dynamic>>('listSets') ?? const [];
        for (final m in list) {
          final name = m['name'] as String;
          final e = byName[name] ??= _Entry(name);
          final json = m['json'] as String?;
          if (json == null) {
            e.cloudPending = true;
          } else {
            try {
              e.inCloud = PhoneSet.fromJson(Map<String, dynamic>.from(_decode(json)));
            } catch (_) {
              e.cloudPending = true;
            }
          }
        }
      } catch (e) {
        _message = 'Couldn\'t read the iCloud folder: $e';
      }
    }
    final sets = byName.values.toList()
      ..sort((a, b) => (b.any?.created ?? DateTime(0)).compareTo(a.any?.created ?? DateTime(0)));
    if (mounted) {
      setState(() {
        _sets = sets;
        _loading = false;
      });
    }
  }

  static Map<dynamic, dynamic> _decode(String s) => jsonDecode(s) as Map<dynamic, dynamic>;

  Future<void> _pickFolder() async {
    final name = await _channel.invokeMethod<String>('pickFolder');
    if (name == null) return;
    setState(() {
      _folder = name;
      _message = null;
    });
    await _refresh();
  }

  Future<void> _open(_Entry e) async {
    if (_busyName != null) return;
    var set = e.onPhone;
    if (set == null) {
      final cloud = e.inCloud;
      if (cloud == null) {
        setState(() => _message = 'That set is still arriving from iCloud. Give it a minute and pull down to refresh.');
        return;
      }
      setState(() {
        _busyName = e.name;
        _progress = 0;
        _message = null;
      });
      try {
        final files = [for (final s in cloud.sections) ...[s.file, ?s.vox]];
        final path = await _channel.invokeMethod<String>('download', {'name': e.name, 'files': files});
        set = path == null ? null : PhoneSet.read(path);
      } catch (err) {
        _message = 'Couldn\'t get that set from iCloud: $err';
      }
      if (mounted) {
        setState(() {
          _busyName = null;
          _progress = null;
        });
      }
      await _refresh();
    }
    if (set == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => PhonePlayer(set: set!)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
              child: Row(children: [
                _logo(),
                const Spacer(),
                _LitButton('', icon: Icons.refresh, color: Colors.white70, onTap: _loading ? null : _refresh),
                const SizedBox(width: 8),
                _LitButton('FOLDER', icon: Icons.folder_open, color: kRigAmber, onTap: _pickFolder),
              ]),
            ),
            const Divider(height: 1, color: _line),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(_message!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ),
            Expanded(child: _body()),
          ]),
        ),
      );

  Widget _body() {
    if (_folder == null && _sets.isEmpty && !_loading) return _welcome();
    return RefreshIndicator(
      onRefresh: _refresh,
      color: kPink,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        children: [
          Text(_folder == null ? 'SETS ON THIS PHONE' : 'YOUR SETS · ICLOUD › ${_folder!.toUpperCase()}', style: _label(Colors.white54)),
          const SizedBox(height: 10),
          if (_sets.isEmpty && !_loading)
            const Padding(
              padding: EdgeInsets.only(top: 30),
              child: Text(
                'No sets yet. On your Mac, make a set and press iPhone at the top. It shows here once iCloud has uploaded it.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, height: 1.5),
              ),
            ),
          for (final e in _sets) ...[_tile(e), const SizedBox(height: 10)],
        ],
      ),
    );
  }

  Widget _welcome() => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('PLAY YOUR SETS ON THE GO', textAlign: TextAlign.center, style: _label(Colors.white, size: 15)),
          const SizedBox(height: 18),
          const Text(
            '1.  On your Mac, make a set in D-Jay Noodles and press iPhone at the top.\n\n'
            '2.  Here, press Choose folder and pick iCloud Drive › D-Jay Noodles.\n\n'
            'Your sets then show up here by themselves.',
            style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.45),
          ),
          const SizedBox(height: 28),
          Center(child: _LitButton('CHOOSE FOLDER', icon: Icons.folder_open, color: kPink, lit: true, onTap: _pickFolder)),
        ]),
      );

  Widget _tile(_Entry e) {
    final s = e.any;
    final mash = s?.mashups ?? false;
    final c = mash ? kPink : kYellow;
    final busy = _busyName == e.name;
    final d = s?.created;
    final when = d == null ? '' : '${d.day} ${const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][d.month - 1]} · ';
    return GestureDetector(
      onTap: () => _open(e),
      child: Container(
        decoration: BoxDecoration(color: kPanel, border: Border.all(color: _line), borderRadius: BorderRadius.circular(3)),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 4, color: c),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(mash ? 'MASHUPS' : 'MIX', style: _label(c)),
                    const Spacer(),
                    Text(
                      e.onPhone != null ? 'ON PHONE' : (e.cloudPending ? 'ARRIVING…' : 'IN ICLOUD'),
                      style: _label(e.onPhone != null ? kTeal : Colors.white38),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Text(s?.title ?? e.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    s == null ? 'Waiting for iCloud' : '$when${_clock(s.duration)} · ${s.parts.length} ${mash ? 'mashups' : 'songs'}',
                    style: const TextStyle(color: Colors.white54, fontSize: 13),
                  ),
                  if (busy) ...[
                    const SizedBox(height: 10),
                    LinearProgressIndicator(value: _progress, color: kTeal, backgroundColor: _line, minHeight: 3),
                    const SizedBox(height: 4),
                    Text('Copying to your phone… ${((_progress ?? 0) * 100).round()}%', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ]),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ===================================================================== Player

class PhonePlayer extends StatefulWidget {
  final PhoneSet set;
  const PhonePlayer({super.key, required this.set});
  @override
  State<PhonePlayer> createState() => _PhonePlayerState();
}

class _PhonePlayerState extends State<PhonePlayer> {
  final _mixer = Mixer();
  late final FxSettings _fx = FxSettings(_mixer);
  Timer? _ticker;
  double _position = 0;
  bool _playing = false;
  double _vocalFader = kFaderHome, _beatFader = kFaderHome, _crossfader = 0, _master = 0;
  final _eqVocal = [0.0, 0.0, 0.0], _eqBeat = [0.0, 0.0, 0.0];
  bool _muteVocal = false, _muteBeat = false;
  bool _autoFx = true;
  Float32List? _wave; // low, mid, high, peak every 10 ms of the whole set
  bool _dragging = false;

  PhoneSet get s => widget.set;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    _load();
  }

  Future<void> _load() async {
    await _mixer.setTimeline(s.rows(s.folder));
    await _mixer.setBeatGrid(s.grid);
    await _mixer.setEq([0, 0, 0], [0, 0, 0]);
    await _pushLive();
    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) async {
      final (pos, playing, _) = await _mixer.position();
      if (!mounted || _dragging) return;
      if (playing && pos >= s.duration - 0.05) {
        await _mixer.pause();
      }
      setState(() {
        _position = math.min(pos, s.duration);
        _playing = playing && pos < s.duration - 0.05;
      });
    });
    unawaited(_loadWave());
  }

  /// The whole set's waveform: made once from its sections, then kept with it.
  Future<void> _loadWave() async {
    final cache = File('${s.folder}/wave.bin');
    if (cache.existsSync()) {
      final b = cache.readAsBytesSync();
      if (mounted) setState(() => _wave = b.buffer.asFloat32List(b.offsetInBytes, b.lengthInBytes ~/ 4));
      return;
    }
    final total = (s.duration * 100).ceil();
    final w = Float32List(total * 4);
    for (final sec in s.sections) {
      final bins = await _mixer.waveform(['${s.folder}/${sec.file}', if (sec.vox != null) '${s.folder}/${sec.vox}']);
      final from = (sec.start * 100).round();
      for (var i = 0; i + 3 < bins.length; i += 4) {
        final k = from + i ~/ 4;
        if (k >= total) break;
        for (var j = 0; j < 4; j++) {
          w[k * 4 + j] = math.max(w[k * 4 + j], bins[i + j]);
        }
      }
      if (mounted) setState(() => _wave = w);
    }
    try {
      cache.writeAsBytesSync(w.buffer.asUint8List());
    } catch (_) {}
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _mixer.pause();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  // ----------------------------------------------------------- live

  Map<String, dynamic> get _liveMap {
    final (xVocal, xBeat) = crossfadeDb(_crossfader);
    return {
      ...s.live,
      'fx': _autoFx ? (s.live['fx'] ?? const []) : const [],
      'grid': s.grid,
      'muteVocal': _muteVocal,
      'muteBeat': _muteBeat,
      'trimVocal': faderDb(_vocalFader) + xVocal + masterDb(_master),
      'trimBeat': faderDb(_beatFader) + xBeat + masterDb(_master),
    };
  }

  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _pushTimer;
  Future<void> _pushLive() async {
    const gap = Duration(milliseconds: 50);
    final since = DateTime.now().difference(_lastPush);
    _pushTimer?.cancel();
    if (since >= gap) {
      _lastPush = DateTime.now();
      await _mixer.setLiveMap(_liveMap);
    } else {
      _pushTimer = Timer(gap - since, _pushLive);
    }
  }

  void _live(void Function() change) {
    setState(change);
    _pushLive();
  }

  // ----------------------------------------------------------- transport

  Future<void> _togglePlay() async {
    if (_playing) {
      await _mixer.pause();
      setState(() => _playing = false);
    } else {
      final from = _position >= s.duration - 0.5 ? 0.0 : _position;
      await _mixer.play(from: from);
      setState(() => _playing = true);
    }
  }

  Future<void> _seek(double t) async {
    t = t.clamp(0.0, math.max(0.0, s.duration - 1));
    setState(() => _position = t);
    if (_playing) {
      await _mixer.seek(t);
    } else {
      await _mixer.play(from: t);
      setState(() => _playing = true);
    }
  }

  void _skip(int dir) {
    if (s.parts.isEmpty) return;
    final i = s.partAt(_position);
    final into = _position - s.parts[i].start;
    final target = dir > 0 ? i + 1 : (into > 3 ? i : i - 1);
    if (target >= s.parts.length) return;
    _seek(s.parts[math.max(0, target)].start);
  }

  // ----------------------------------------------------------- decks

  /// What decks A and B show now, as (role, deck, colour, from, to).
  List<_DeckNow> get _decks {
    if (s.parts.isEmpty) return const [];
    final i = s.partAt(_position);
    final p = s.parts[i];
    if (s.mashups) {
      PhoneBeatSpan? span;
      for (final b in s.beatSpans) {
        if (b.start > _position) break;
        span = b;
      }
      final other = span != null && p.beat != null && span.deck.title != p.beat!.title;
      final beat = other
          ? PhoneDeck(span.deck.title, span.deck.artist,
              bpm: p.beat!.bpm, key: span.deck.key, tag: span.home ? 'Anchor beat' : 'Next beat coming')
          : p.beat;
      return [
        _DeckNow('VOCAL', p.vocal ?? const PhoneDeck('Beat break', 'No vocal in this part'), kPink, p.start, p.end, loaded: p.vocal != null),
        _DeckNow('BEAT', beat ?? const PhoneDeck('No beat', ''), kTeal, p.start, p.end),
      ];
    }
    // Songs take turns on deck A and deck B, as on real decks.
    _DeckNow deck(int k, Color c) {
      if (k >= s.parts.length) return _DeckNow('NEXT', const PhoneDeck('Last song in the set', ''), c, 0, 0, loaded: false);
      final q = s.parts[k];
      final role = k == i
          ? 'NOW'
          : _position >= q.start && _position < q.end
              ? (q.start > p.start ? 'MIXING IN' : 'MIXING OUT')
              : 'NEXT';
      return _DeckNow(role, q.song!, c, q.start, q.end);
    }

    final a = i.isEven ? i : i + 1, b = i.isOdd ? i : i + 1;
    return [deck(a, kPink), deck(b, kTeal)];
  }

  double? get _bpmNow {
    final g = s.grid;
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

  // ----------------------------------------------------------- layout

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: LayoutBuilder(builder: (context, box) {
            final wide = box.maxWidth > box.maxHeight;
            return wide ? _landscape(box) : _portrait(box);
          }),
        ),
      );

  Widget _top() => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
        child: Row(children: [
          IconButton(icon: const Icon(Icons.chevron_left, size: 28), onPressed: () => Navigator.of(context).pop()),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.mashups ? 'MASHUPS' : 'MIX', style: _label(s.mashups ? kPink : kYellow)),
              Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
            ]),
          ),
          const SizedBox(width: 8),
          _LitButton('AUTO FX', color: kRigAmber, lit: _autoFx, onTap: () => _live(() => _autoFx = !_autoFx)),
        ]),
      );

  Widget _transport() {
    final i = s.parts.isEmpty ? 0 : s.partAt(_position);
    final bpm = _bpmNow;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(children: [
        _LitButton('', icon: Icons.skip_previous, color: Colors.white70, onTap: () => _skip(-1)),
        const SizedBox(width: 8),
        _LitButton('', icon: _playing ? Icons.pause : Icons.play_arrow, color: const Color(0xFF7DFF5A), lit: _playing, onTap: _togglePlay),
        const SizedBox(width: 8),
        _LitButton('', icon: Icons.skip_next, color: Colors.white70, onTap: () => _skip(1)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${_clock(_position)} / ${_clock(s.duration)}',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
            Text(
              '${s.mashups ? 'MASHUP' : 'SONG'} ${i + 1} OF ${s.parts.length}${bpm == null ? '' : ' · ${bpm.toStringAsFixed(1)} BPM'}',
              style: _label(Colors.white54, size: 9),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _waves({required double zoomHeight, required double overviewHeight}) => Column(children: [
        SizedBox(
          height: zoomHeight,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) => _dragging = true,
            onHorizontalDragUpdate: (d) => setState(() => _position = (_position - d.delta.dx / 12).clamp(0.0, s.duration)),
            onHorizontalDragEnd: (_) {
              _dragging = false;
              _seek(_position);
            },
            child: CustomPaint(painter: _WavePainter(_wave, _position, zoomed: true, duration: s.duration), size: Size.infinite),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: overviewHeight,
          child: LayoutBuilder(builder: (context, box) {
            void at(double x) => _seek(x / box.maxWidth * s.duration);
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) => at(d.localPosition.dx),
              child: CustomPaint(
                painter: _WavePainter(_wave, _position, zoomed: false, duration: s.duration, parts: [for (final p in s.parts) p.start]),
                size: Size.infinite,
              ),
            );
          }),
        ),
      ]);

  Widget _mixerPanel() => MixerPanel(
        hasVocal: s.mashups,
        vocalFader: _vocalFader,
        beatFader: _beatFader,
        crossfader: _crossfader,
        master: _master,
        eqVocal: _eqVocal,
        eqBeat: _eqBeat,
        muteVocal: _muteVocal,
        muteBeat: _muteBeat,
        fx: _fx,
        meterVocal: _level(true),
        meterBeat: _level(false),
        onVocalFader: (v) => _live(() => _vocalFader = v),
        onBeatFader: (v) => _live(() => _beatFader = v),
        onCrossfader: (v) => _live(() => _crossfader = v),
        onMaster: (v) => _live(() => _master = v),
        onEq: (vocal, band, v) {
          setState(() => (vocal ? _eqVocal : _eqBeat)[band] = v);
          _mixer.setEq(_eqVocal.map(eqDb).toList(), _eqBeat.map(eqDb).toList());
        },
        onMuteVocal: () => _live(() => _muteVocal = !_muteVocal),
        onMuteBeat: () => _live(() => _muteBeat = !_muteBeat),
        onKnob: () => setState(() {}),
      );

  /// A meter reading from the waveform at the playhead (0..1).
  double _level(bool vocal) {
    final w = _wave;
    if (w == null || !_playing) return 0;
    final k = (_position * 100).round();
    if (k * 4 + 3 >= w.length) return 0;
    final (xVocal, xBeat) = crossfadeDb(_crossfader);
    final db = vocal ? faderDb(_vocalFader) + xVocal : faderDb(_beatFader) + xBeat;
    final mute = vocal ? _muteVocal : _muteBeat;
    if (mute) return 0;
    return (w[k * 4 + 3] * math.pow(10, (db + masterDb(_master)) / 20)).clamp(0.0, 1.0).toDouble();
  }

  Widget _pads() => SizedBox(height: 92, child: QuickPads(fx: _fx, onChanged: () => setState(() {})));

  Widget _deckCard(_DeckNow d) {
    final into = (_position - d.from).clamp(0.0, math.max(0.001, d.to - d.from));
    final share = d.to > d.from ? into / (d.to - d.from) : 0.0;
    return Container(
      decoration: BoxDecoration(color: kPanel, border: Border.all(color: d.loaded ? d.color.withValues(alpha: 0.55) : _line)),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(width: 7, height: 7, color: d.loaded ? d.color : Colors.white24),
          const SizedBox(width: 6),
          Expanded(child: Text(d.role, style: _label(d.loaded ? d.color : Colors.white38, size: 9))),
        ]),
        const SizedBox(height: 6),
        Text(d.deck.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, height: 1.15, color: d.loaded ? Colors.white : Colors.white38)),
        const SizedBox(height: 2),
        Text(d.deck.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Colors.white54)),
        const Spacer(),
        if (d.deck.tag.isNotEmpty) ...[
          Text(d.deck.tag.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis, style: _label(kYellow, size: 8)),
          const SizedBox(height: 5),
        ],
        Row(children: [
          _readout('BPM', d.deck.bpm.isEmpty ? '--' : d.deck.bpm),
          const SizedBox(width: 6),
          _readout('KEY', d.deck.key.isEmpty ? '--' : d.deck.key),
          if (d.deck.speed.isNotEmpty) ...[const SizedBox(width: 6), _readout('SPEED', d.deck.speed)],
        ]),
        const SizedBox(height: 6),
        Container(
          height: 3,
          color: _line,
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(widthFactor: d.loaded ? share.clamp(0.0, 1.0) : 0, child: Container(color: d.color)),
        ),
      ]),
    );
  }

  Widget _readout(String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(border: Border.all(color: _line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: _label(Colors.white38, size: 7)),
          Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
        ]),
      );

  Widget _portrait(BoxConstraints box) {
    final decks = _decks;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _top(),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _waves(zoomHeight: 64, overviewHeight: 26)),
      const SizedBox(height: 8),
      if (decks.length == 2)
        SizedBox(
          height: 150,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              Expanded(child: _deckCard(decks[0])),
              const SizedBox(width: 8),
              Expanded(child: _deckCard(decks[1])),
            ]),
          ),
        ),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Container(height: s.mashups ? 300 : 210, color: kPanel, padding: const EdgeInsets.all(6), child: _mixerPanel()),
      ),
      const SizedBox(height: 8),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _pads()),
      const SizedBox(height: 6),
      Expanded(child: _partList()),
      _transport(),
    ]);
  }

  /// Every mashup or song in the set; tap one to jump to it.
  Widget _partList() {
    final now = s.parts.isEmpty ? -1 : s.partAt(_position);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: s.parts.length,
      itemBuilder: (context, i) {
        final p = s.parts[i];
        final main = p.song ?? p.vocal ?? p.beat!;
        final sub = s.mashups ? 'over ${p.beat?.title ?? ''}' : main.artist;
        final on = i == now;
        final c = s.mashups ? kPink : kYellow;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _seek(p.start),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
            decoration: BoxDecoration(
              color: on ? c.withValues(alpha: 0.10) : null,
              border: const Border(bottom: BorderSide(color: _line)),
            ),
            child: Row(children: [
              SizedBox(width: 26, child: Text('${i + 1}', style: _label(on ? c : Colors.white38, size: 11))),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.vocal == null && s.mashups ? 'Beat break' : main.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: on ? Colors.white : Colors.white70)),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: Colors.white38)),
                ]),
              ),
              Text(_clock(p.start), style: const TextStyle(fontSize: 11, color: Colors.white38, fontFeatures: [FontFeature.tabularFigures()])),
            ]),
          ),
        );
      },
    );
  }

  Widget _landscape(BoxConstraints box) {
    final decks = _decks;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _top(),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _waves(zoomHeight: 48, overviewHeight: 20)),
      const SizedBox(height: 6),
      Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: Column(children: [if (decks.isNotEmpty) Expanded(child: _deckCard(decks[0])), const SizedBox(height: 6), _halfPads(0)])),
            const SizedBox(width: 8),
            SizedBox(width: 260, child: Container(color: kPanel, padding: const EdgeInsets.all(4), child: _mixerPanel())),
            const SizedBox(width: 8),
            Expanded(child: Column(children: [if (decks.length > 1) Expanded(child: _deckCard(decks[1])), const SizedBox(height: 6), _halfPads(4)])),
          ]),
        ),
      ),
      _transport(),
    ]);
  }

  /// Four of the eight FX pads (landscape: four under each deck).
  Widget _halfPads(int from) => SizedBox(
        height: 40,
        child: Row(children: [
          for (var i = from; i < from + 4; i++) ...[
            if (i > from) const SizedBox(width: 5),
            Expanded(child: _Pad(fx: _fx, index: i, onChanged: () => setState(() {}))),
          ],
        ]),
      );
}

class _DeckNow {
  final String role;
  final PhoneDeck deck;
  final Color color;
  final double from, to;
  final bool loaded;
  const _DeckNow(this.role, this.deck, this.color, this.from, this.to, {this.loaded = true});
}

/// One Beat FX pad: hold for while held, tap to keep it on.
class _Pad extends StatelessWidget {
  final FxSettings fx;
  final int index;
  final VoidCallback onChanged;
  const _Pad({required this.fx, required this.index, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final (kind, color) = QuickPads.pads[index];
    final lit = fx.on && fx.beatFx == kind;
    return GestureDetector(
      onTapDown: (_) {
        fx.press(kind);
        onChanged();
      },
      onTapUp: (_) {
        fx.release(kind);
        onChanged();
      },
      onTapCancel: () {
        fx.release(kind);
        onChanged();
      },
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: lit ? color.withValues(alpha: 0.3) : const Color(0xFF15151C),
          border: Border.all(color: lit ? color : color.withValues(alpha: 0.5), width: 1.2),
          boxShadow: lit ? [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 10)] : null,
        ),
        child: Text(kind.label.toUpperCase(), maxLines: 1, style: _label(lit ? Colors.white : color, size: 8)),
      ),
    );
  }
}

/// The set's waveform: [zoomed] scrolls past a fixed playhead in the middle
/// (about 16 seconds across); otherwise the whole set with the playhead on it.
/// Bass is teal (the beat), the highs pink, mids white.
class _WavePainter extends CustomPainter {
  final Float32List? wave;
  final double position, duration;
  final bool zoomed;
  final List<double> parts;
  _WavePainter(this.wave, this.position, {required this.zoomed, required this.duration, this.parts = const []});

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0E0E14));
    final w = wave;
    final mid = size.height / 2;
    final span = zoomed ? 16.0 : math.max(1.0, duration);
    final t0 = zoomed ? position - span / 2 : 0.0;
    if (w != null && w.isNotEmpty) {
      final n = w.length ~/ 4;
      const step = 2.0; // pixels per bar
      final low = Paint()..color = kTeal.withValues(alpha: 0.9);
      final mids = Paint()..color = Colors.white.withValues(alpha: 0.75);
      final high = Paint()..color = kPink.withValues(alpha: 0.9);
      for (var x = 0.0; x < size.width; x += step) {
        final a = ((t0 + x / size.width * span) * 100).floor();
        final b = ((t0 + (x + step) / size.width * span) * 100).floor();
        if (b <= 0 || a >= n) continue;
        var l = 0.0, m = 0.0, h = 0.0;
        for (var k = math.max(0, a); k < math.min(n, math.max(a + 1, b)); k++) {
          l = math.max(l, w[k * 4]);
          m = math.max(m, w[k * 4 + 1]);
          h = math.max(h, w[k * 4 + 2]);
        }
        double hgt(double v) => math.min(mid, math.sqrt(v) * mid * 1.6);
        final played = !zoomed && t0 + x / size.width * span < position;
        final dim = played ? 0.45 : 1.0;
        canvas.drawRect(Rect.fromLTRB(x, mid - hgt(l), x + step - 0.5, mid + hgt(l)), low..color = kTeal.withValues(alpha: 0.9 * dim));
        canvas.drawRect(Rect.fromLTRB(x, mid - hgt(m) * 0.8, x + step - 0.5, mid + hgt(m) * 0.8), mids..color = Colors.white.withValues(alpha: 0.7 * dim));
        canvas.drawRect(Rect.fromLTRB(x, mid - hgt(h) * 0.6, x + step - 0.5, mid + hgt(h) * 0.6), high..color = kPink.withValues(alpha: 0.9 * dim));
      }
    }
    if (!zoomed) {
      final tick = Paint()..color = kYellow.withValues(alpha: 0.7);
      for (final p in parts.skip(1)) {
        final x = p / span * size.width;
        canvas.drawRect(Rect.fromLTWH(x, 0, 1, 5), tick);
      }
    }
    final px = zoomed ? size.width / 2 : position / span * size.width;
    canvas.drawRect(Rect.fromLTWH(px - 1, 0, 2, size.height), Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.position != position || old.wave != wave || old.wave?.length != wave?.length;
}

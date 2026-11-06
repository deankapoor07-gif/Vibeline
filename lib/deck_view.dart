import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'fx_deck.dart';
import 'mixer.dart';
import 'sections.dart';

// The look: near-black, crisp white text, and a few loud colours that each
// mean something (pink = the singer, teal = the beat).
const kInk = Color(0xFF07070A);
const kPanel = Color(0xFF101016);
const kLine = Color(0xFF24242E);
const kPink = Color(0xFFFF3DBB);
const kTeal = Color(0xFF22E6C8);
const kYellow = Color(0xFFFFD23F);
const kCorner = 3.0;
const kSetColors = [kPink, kTeal, Color(0xFF8F5BFF), Color(0xFFFF8A1F), Color(0xFF3DA5FF), Color(0xFF7DFF5A), kYellow];

/// One deck on the Now Playing screen.
class DeckInfo {
  final String role; // VOCAL, BEAT, NOW, NEXT
  final String title;
  final String artist;
  final Color color;
  final List<(String, Color)> tags;
  final Widget? action; // e.g. its mute button, top right of the card
  final String bpm; // e.g. 124.0
  final String keyCode; // e.g. 8A
  final bool loaded; // false: nothing on this deck
  const DeckInfo(this.role, this.title, this.artist, this.color, this.tags, {this.action, this.bpm = '', this.keyCode = '', this.loaded = true});
}

/// The bass / mid / high loudness and peak of each rendered section, every
/// 10 ms, fetched from the native side once per file and layer choice (a
/// muted singer or beat drops out of the picture too).
class WaveCache {
  static const binsPerSecond = 100;
  final Mixer mixer;
  void Function()? onLoaded;
  WaveCache(this.mixer);

  final _data = <String, Float32List>{};
  final _pending = <String>{};

  Float32List? of(Section s, {bool vocal = true, bool beat = true}) {
    final p = s.path;
    if (p == null) return null;
    final paths = [if (beat) p, if (vocal) ?s.voxPath];
    final key = '$p|$vocal|$beat';
    final d = _data[key];
    if (d != null || !_pending.add(key)) return d;
    mixer.waveform(paths).then((v) {
      _pending.remove(key);
      if (_data.length > 80) _data.remove(_data.keys.first);
      _data[key] = v;
      onLoaded?.call();
    }, onError: (_) => _pending.remove(key));
    return null;
  }
}

/// Two spinning decks and the colour waveform scrolling past the playhead.
class NowPlayingView extends StatefulWidget {
  final List<DeckInfo> decks;
  final List<Section> sections;
  final WaveCache waves;
  final double position;
  final bool playing;
  final String heading;
  final String upNext;
  final List<double> beats; // mix time of every beat
  final Set<double> downbeats; // the ones that start a bar
  final bool vocalMuted, beatMuted;
  final Widget? trailing; // beside "up next" (the Scratch button)
  final Widget? top; // in place of the waveform when there's no set
  final Widget? overview; // the whole set, under the waveform
  /// The mixer between the decks; it's given how loud each layer is right now.
  final Widget Function(double Function(bool vocal) level)? mixer;

  const NowPlayingView({
    super.key,
    required this.decks,
    required this.sections,
    required this.waves,
    required this.position,
    required this.playing,
    required this.heading,
    required this.upNext,
    this.beats = const [],
    this.downbeats = const {},
    this.vocalMuted = false,
    this.beatMuted = false,
    this.trailing,
    this.top,
    this.overview,
    this.mixer,
  });

  @override
  State<NowPlayingView> createState() => _NowPlayingViewState();
}

class _NowPlayingViewState extends State<NowPlayingView> with SingleTickerProviderStateMixin {
  // The player reports its position every 200 ms; in between the screen
  // runs it on by the clock so the waveform and platters glide.
  late final Ticker _ticker;
  double _base = 0;
  DateTime _baseAt = DateTime.now();
  double _window = 4; // seconds each side of the playhead; scroll to zoom

  double get _pos {
    if (!widget.playing) return _base;
    final ran = DateTime.now().difference(_baseAt).inMicroseconds / 1e6;
    return _base + math.min(ran, 0.5);
  }

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => setState(() {}));
    _base = widget.position;
    if (widget.playing) _ticker.start();
  }

  @override
  void didUpdateWidget(NowPlayingView old) {
    super.didUpdateWidget(old);
    if (widget.position != old.position || widget.playing != old.playing) {
      _base = widget.position;
      _baseAt = DateTime.now();
    }
    if (widget.playing && !_ticker.isActive) _ticker.start();
    if (!widget.playing && _ticker.isActive) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pos = _pos;
    return LayoutBuilder(
      builder: (context, box) {
        // Songs first, as on a DJ deck: the waveform up top, then the decks.
        final topHeight = widget.top != null ? 92.0 : 62.0;
        final hasOverview = widget.overview != null && box.maxHeight >= topHeight + 56;
        final used = topHeight + (hasOverview ? 56 : 0) + 6;
        final deckHeight = box.maxHeight - used;
        return Column(
          children: [
            if (box.maxHeight >= topHeight) SizedBox(height: topHeight, child: widget.top ?? _wave(pos)),
            if (hasOverview) SizedBox(height: 56, child: widget.overview!),
            if (deckHeight >= 90) ...[
              const SizedBox(height: 6),
              SizedBox(
                height: deckHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < widget.decks.length; i++) ...[
                      if (i > 0) ...[
                        const SizedBox(width: 6),
                        if (widget.mixer != null && box.maxWidth >= 620) ...[widget.mixer!(_levelOf), const SizedBox(width: 6)],
                      ],
                      Expanded(child: _Deck(widget.decks[i], pos, mirrored: i == 1)),
                    ],
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  /// How loud one layer of the set is at this moment, from its waveform (0..1).
  double _levelOf(bool vocal) {
    if (!widget.playing) return 0;
    final t = _pos;
    for (final s in widget.sections) {
      if (t < s.start || t >= s.end) continue;
      if (vocal && s.voxPath == null) return 0;
      final d = widget.waves.of(s, vocal: vocal, beat: !vocal);
      if (d == null) return 0;
      final i = ((t - s.start) * WaveCache.binsPerSecond).floor() * 4;
      if (i < 0 || i + 3 >= d.length) return 0;
      return d[i + 3] * 1.05;
    }
    return 0;
  }

  Widget _wave(double pos) => Container(
        padding: const EdgeInsets.fromLTRB(10, 5, 10, 5),
        decoration: BoxDecoration(color: const Color(0xFF0C0C11), borderRadius: BorderRadius.circular(3)),
        child: Column(
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    widget.heading.toUpperCase(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 10, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: Colors.white54),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.upNext,
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11, color: Colors.white54),
                  ),
                ),
                if (widget.trailing != null) ...[const SizedBox(width: 10), widget.trailing!],
              ],
            ),
            const SizedBox(height: 3),
            Expanded(
              child: Tooltip(
                message: 'Scroll to zoom in and out',
                waitDuration: const Duration(seconds: 1),
                child: Listener(
                  onPointerSignal: (e) {
                    if (e is PointerScrollEvent) {
                      setState(() => _window = (_window * math.pow(1.0015, e.scrollDelta.dy)).clamp(2.0, 30.0));
                    }
                  },
                  child: SizedBox.expand(
                    child: CustomPaint(
                      painter: _WavePainter(widget.sections, widget.waves, pos, _window, widget.beats, widget.downbeats,
                          vocal: !widget.vocalMuted, beat: !widget.beatMuted),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}

/// A deck: the song across the top, then its numbers and a turntable. The
/// right-hand deck is a mirror image of the left, so the mixer sits between.
class _Deck extends StatelessWidget {
  final DeckInfo d;
  final double pos;
  final bool mirrored;
  const _Deck(this.d, this.pos, {this.mirrored = false});

  static const _numbersWidth = 150.0;

  /// A record only turns while it's the one playing.
  double get _spin => d.role == 'NEXT' || !d.loaded ? 0 : pos;

  Widget _numbers() => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: mirrored ? Alignment.topRight : Alignment.topLeft,
        child: SizedBox(
          width: _numbersWidth,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: mirrored ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Text(d.role, style: TextStyle(fontSize: 10, letterSpacing: 1.5, color: d.loaded ? d.color : Colors.white38, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(
                d.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: mirrored ? TextAlign.right : TextAlign.left,
                style: TextStyle(fontSize: 14, height: 1.15, fontWeight: FontWeight.w700, color: d.loaded ? Colors.white : Colors.white38),
              ),
              const SizedBox(height: 2),
              Text(
                d.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Colors.white60),
              ),
              const SizedBox(height: 10),
              Text(
                d.bpm.isEmpty ? '--' : d.bpm,
                style: const TextStyle(fontSize: 26, height: 1, fontWeight: FontWeight.w700, color: Colors.white, fontFeatures: [FontFeature.tabularFigures()]),
              ),
              const SizedBox(height: 2),
              const Text('BPM', style: TextStyle(fontSize: 9, letterSpacing: 1, color: Colors.white54)),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  border: Border.all(color: d.loaded ? d.color : Colors.white24),
                  borderRadius: BorderRadius.circular(kCorner),
                ),
                child: Text(d.keyCode.isEmpty ? '--' : d.keyCode, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: d.loaded ? d.color : Colors.white38)),
              ),
              const SizedBox(height: 2),
              const Text('KEY', style: TextStyle(fontSize: 9, letterSpacing: 1, color: Colors.white54)),
              for (final (label, c) in d.tags) ...[
                const SizedBox(height: 6),
                Text(
                  label.toUpperCase(),
                  textAlign: mirrored ? TextAlign.right : TextAlign.left,
                  style: TextStyle(fontSize: 9, letterSpacing: 0.5, fontWeight: FontWeight.w700, color: Color.lerp(c, Colors.white, 0.25)),
                ),
              ],
              if (d.action != null) ...[const SizedBox(height: 8), d.action!],
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: kPanel,
        border: Border(top: BorderSide(color: d.loaded ? d.color : Colors.white24, width: 2)),
      ),
      child: LayoutBuilder(
        builder: (context, box) {
          final side = math.min(box.maxHeight, box.maxWidth - _numbersWidth - 8);
          final numbers = SizedBox(width: math.min(_numbersWidth, box.maxWidth), height: box.maxHeight, child: _numbers());
          if (side < 50) return Align(alignment: mirrored ? Alignment.topRight : Alignment.topLeft, child: numbers);
          final table = Expanded(
            child: Center(
              child: SizedBox(
                width: side,
                height: side,
                child: CustomPaint(painter: _TurntablePainter(_spin, loaded: d.loaded)),
              ),
            ),
          );
          return Row(children: mirrored ? [table, const SizedBox(width: 8), numbers] : [numbers, const SizedBox(width: 8), table]);
        },
      ),
    );
  }
}

/// A record player seen from above: a metal platter with its strobe dots, a
/// grooved record, a plain grey label reading DJ, and the tonearm resting on the
/// record. The record turns at 33⅓ with the music, so it stops when the set does.
/// It looks the same loaded or empty, apart from the DJ lighting up: Dean wants
/// proper turntables, with the deck's colour kept to the details beside them.
class _TurntablePainter extends CustomPainter {
  final double pos;
  final bool loaded;
  _TurntablePainter(this.pos, {this.loaded = true});

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final r = side * 0.455;
    final c = Offset(size.width / 2 - side * 0.035, size.height / 2);
    final angle = pos * (100 / 3) / 60 * 2 * math.pi;

    // Metal platter edge, with strobe dots that travel round with it.
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF3A3A44));
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, side * 0.006)
        ..color = const Color(0xFF8A8A96),
    );
    final dots = Paint()..color = const Color(0xFFB8B8C4);
    final dotSize = math.max(0.6, side * 0.004);
    for (var i = 0; i < 72; i++) {
      final a = angle + i * 2 * math.pi / 72;
      canvas.drawCircle(c + Offset(math.cos(a), math.sin(a)) * (r * 0.965), dotSize, dots);
    }

    // The record.
    final vinyl = r * 0.92;
    canvas.drawCircle(c, vinyl, Paint()..color = const Color(0xFF09090B));
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = const Color(0xFF24242B);
    final step = math.max(2.2, r * 0.028);
    for (var g = r * 0.42; g < vinyl - 2; g += step) {
      canvas.drawCircle(c, g, groove);
    }
    // Light catching the vinyl: it stays still while the record turns under it.
    canvas.drawCircle(
      c,
      vinyl,
      Paint()
        ..shader = SweepGradient(
          center: Alignment.center,
          colors: const [Color(0x00FFFFFF), Color(0x24FFFFFF), Color(0x00FFFFFF), Color(0x00FFFFFF), Color(0x24FFFFFF), Color(0x00FFFFFF), Color(0x00FFFFFF)],
          stops: const [0.05, 0.12, 0.2, 0.55, 0.62, 0.7, 1],
        ).createShader(Rect.fromCircle(center: c, radius: vinyl)),
    );

    // The label, turning with the record so you can see it spin.
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(angle);
    final label = r * 0.38;
    canvas.drawCircle(Offset.zero, label, Paint()..color = const Color(0xFF3A3A44));
    canvas.drawCircle(
      Offset.zero,
      label * 0.9,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.6, label * 0.018)
        ..color = Colors.white.withValues(alpha: 0.18),
    );
    final dj = TextPainter(
      text: TextSpan(
        text: 'DJ',
        style: TextStyle(fontSize: label * 0.95, height: 1, fontWeight: FontWeight.w900, letterSpacing: -label * 0.02, color: loaded ? Colors.white : Colors.white38),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    dj.paint(canvas, Offset(-dj.width / 2, -dj.height / 2));
    canvas.restore();

    // The tonearm: base at the top right, its head resting on the record.
    final pivot = Offset(c.dx + r * 0.98, c.dy - r * 0.88);
    final elbow = Offset(c.dx + r * 0.86, c.dy + r * 0.12);
    final head = Offset(c.dx + r * 0.42, c.dy + r * 0.58);
    final armWidth = math.max(1.5, side * 0.014);
    final arm = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = armWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = const Color(0xFFD6D6DE);
    final shadow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = armWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.black.withValues(alpha: 0.5);
    Path armPath(Offset by) => Path()
      ..moveTo(pivot.dx + by.dx, pivot.dy + by.dy)
      ..lineTo(elbow.dx + by.dx, elbow.dy + by.dy)
      ..lineTo(head.dx + by.dx, head.dy + by.dy);
    canvas.drawPath(armPath(Offset(side * 0.008, side * 0.012)), shadow);
    canvas.drawPath(armPath(Offset.zero), arm);
    // Headshell.
    canvas.save();
    canvas.translate(head.dx, head.dy);
    canvas.rotate((head - elbow).direction);
    final shell = side * 0.055;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromCenter(center: Offset.zero, width: shell * 1.5, height: shell * 0.8), const Radius.circular(1)),
      Paint()..color = const Color(0xFFD6D6DE),
    );
    canvas.restore();
    // Base.
    canvas.drawCircle(pivot, side * 0.042, Paint()..color = const Color(0xFF55555F));
    canvas.drawCircle(pivot, side * 0.022, Paint()..color = const Color(0xFFD6D6DE));
  }

  @override
  bool shouldRepaint(_TurntablePainter old) => old.pos != pos || old.loaded != loaded;
}

/// The mix around the playhead, drawn the way DJ software does: the overall
/// peaks in grey, then the bass in red, the mids (most singing) in green and
/// the highs (hats, cymbals) in blue-white on top, each as tall as that part
/// is loud. Beat lines run behind it, brighter on the first beat of a bar;
/// ahead of the playhead it's dimmer.
class _WavePainter extends CustomPainter {
  final List<Section> sections;
  final WaveCache waves;
  final double pos;
  final double window; // seconds each side of the playhead
  final List<double> beats;
  final Set<double> downbeats;
  final bool vocal, beat;
  _WavePainter(this.sections, this.waves, this.pos, this.window, this.beats, this.downbeats,
      {required this.vocal, required this.beat});

  static const _layers = [
    (Color(0xFF8A8A99), 0.95), // peak
    (Color(0xFF3DDC6A), 3.4), // mid
    (Color(0xFFFF3B30), 2.6), // low
    (Color(0xFF7FD8FF), 5.0), // high
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final t0 = pos - window, span = 2 * window;
    double xOf(double t) => (t - t0) / span * size.width;

    // Beat lines.
    final tick = Paint()..strokeWidth = 1;
    for (final b in beats) {
      if (b < t0 || b > t0 + span) continue;
      final x = xOf(b);
      tick.color = Colors.white.withValues(alpha: downbeats.contains(b) ? 0.28 : 0.09);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), tick);
    }

    // One sample per pixel column: [low, mid, high, peak].
    final cols = size.width.floor();
    final vals = List<List<double>?>.filled(cols, null);
    for (var x = 0; x < cols; x++) {
      final t = t0 + x / size.width * span;
      Section? s;
      for (final q in sections) {
        if (t >= q.start && t < q.end) s = q;
      }
      if (s == null) continue;
      final d = waves.of(s, vocal: vocal, beat: beat);
      if (d == null) continue;
      final i = ((t - s.start) * WaveCache.binsPerSecond).floor() * 4;
      if (i < 0 || i + 3 >= d.length) continue;
      vals[x] = [d[i], d[i + 1], d[i + 2], d[i + 3]];
    }

    final half = size.width / 2;
    for (final (layer, (color, gain)) in [(3, _layers[0]), (1, _layers[1]), (0, _layers[2]), (2, _layers[3])]) {
      for (final ahead in [false, true]) {
        final path = Path();
        var open = false;
        final xs = <int>[];
        for (var x = ahead ? half.floor() : 0; x < (ahead ? cols : half.ceil()); x++) {
          final v = vals[x];
          if (v == null) {
            if (open) _close(path, xs, vals, layer, gain, mid);
            open = false;
            xs.clear();
            continue;
          }
          final h = (v[layer] * gain).clamp(0.0, 1.0) * mid;
          if (!open) {
            path.moveTo(x.toDouble(), mid - h);
            open = true;
          } else {
            path.lineTo(x.toDouble(), mid - h);
          }
          xs.add(x);
        }
        if (open) _close(path, xs, vals, layer, gain, mid);
        canvas.drawPath(path, Paint()..color = color.withValues(alpha: ahead ? 0.45 : 1.0));
      }
    }

    canvas.drawLine(
      Offset(half, 0),
      Offset(half, size.height),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2,
    );
  }

  /// Back along the bottom edge (the mirror image), closing the shape.
  void _close(Path path, List<int> xs, List<List<double>?> vals, int layer, double gain, double mid) {
    for (final x in xs.reversed) {
      final h = (vals[x]![layer] * gain).clamp(0.0, 1.0) * mid;
      path.lineTo(x.toDouble(), mid + h);
    }
    path.close();
  }

  @override
  bool shouldRepaint(_WavePainter old) => true;
}

/// Eight Beat FX pads that are always on screen, each with its number key.
class QuickPads extends StatelessWidget {
  static const pads = [
    (BeatFx.echo, kPink),
    (BeatFx.roll, Color(0xFFFF8A1F)),
    (BeatFx.spiral, kYellow),
    (BeatFx.reverb, Color(0xFF7DFF5A)),
    (BeatFx.flanger, kTeal),
    (BeatFx.filter, Color(0xFF3DA5FF)),
    (BeatFx.trans, Color(0xFF8F5BFF)),
    (BeatFx.vinylBrake, Color(0xFFFF4D4D)),
  ];

  final FxSettings fx;
  final void Function() onChanged;
  final bool oneRow;
  const QuickPads({super.key, required this.fx, required this.onChanged, this.oneRow = false});

  /// Two rows of four, so the XY pad fits beside them.
  @override
  Widget build(BuildContext context) {
    Widget row(int from) => Row(
      children: [
        for (var i = from; i < from + 4; i++) ...[if (i > from) const SizedBox(width: 6), Expanded(child: _pad(i))],
      ],
    );
    if (oneRow) {
      return Row(
        children: [
          for (var i = 0; i < pads.length; i++) ...[if (i > 0) const SizedBox(width: 4), Expanded(child: _pad(i))],
        ],
      );
    }
    return Column(children: [row(0), const SizedBox(height: 6), row(4)]);
  }

  Widget _pad(int i) {
    final (f, c) = pads[i];
    final lit = fx.on && fx.beatFx == f;
    return Tooltip(
      message: '${f.hint}. Tap to keep it on, hold for just while held · key ${i + 1}',
      waitDuration: const Duration(milliseconds: 600),
      child: Listener(
        onPointerDown: (_) {
          fx.press(f);
          onChanged();
        },
        onPointerUp: (_) {
          fx.release(f);
          onChanged();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          height: 42,
          decoration: BoxDecoration(
            color: lit ? c : const Color(0xFF17171F),
            borderRadius: BorderRadius.circular(3),
            border: Border(bottom: BorderSide(color: c, width: 3)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  (f == BeatFx.vinylBrake ? 'Brake' : f.label).toUpperCase(),
                  style: TextStyle(fontSize: 11, letterSpacing: 0.6, fontWeight: FontWeight.w800, color: lit ? kInk : Colors.white),
                ),
              ),
              const SizedBox(height: 2),
              Text('${i + 1}', style: TextStyle(fontSize: 9, color: lit ? kInk : Colors.white38)),
            ],
          ),
        ),
      ),
    );
  }
}

/// A block on the whole-set strip (a mashup or a song).
class OverviewItem {
  final double start, end;
  final String label;
  final Color color;
  const OverviewItem(this.start, this.end, this.label, this.color);
}

/// Something worth marking on the strip: an acapella drop, a beat bridge or
/// an Auto FX move.
enum MarkKind { drop, bridge, fx }

/// The whole set at a glance; click anywhere to jump there.
class SetOverview extends StatelessWidget {
  final List<OverviewItem> items;
  final List<(double, MarkKind)> marks;
  final double position;
  final double duration;
  final void Function(double t) onSeek;

  const SetOverview({
    super.key,
    required this.items,
    required this.marks,
    required this.position,
    required this.duration,
    required this.onSeek,
  });

  static const markColor = {MarkKind.drop: kPink, MarkKind.bridge: kYellow, MarkKind.fx: kTeal};

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Text('SET · CLICK TO JUMP', style: TextStyle(fontSize: 10, letterSpacing: 0.8, fontWeight: FontWeight.w700, color: Colors.white54)),
            const Spacer(),
            for (final (k, name) in const [
              (MarkKind.drop, 'acapella drop'),
              (MarkKind.bridge, 'beat bridge'),
              (MarkKind.fx, 'Auto FX'),
            ])
              if (marks.any((m) => m.$2 == k)) ...[
                const SizedBox(width: 12),
                Icon(k == MarkKind.fx ? Icons.change_history : Icons.circle, size: 9, color: markColor[k]),
                const SizedBox(width: 4),
                Text(name, style: const TextStyle(fontSize: 11, color: Colors.white54)),
              ],
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth;
            double x(double t) => duration <= 0 ? 0 : (t / duration).clamp(0.0, 1.0) * w;
            return MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (e) => onSeek((e.localPosition.dx / w).clamp(0.0, 1.0) * duration),
                child: SizedBox(
                  height: 34,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (final it in items)
                        Positioned(
                          left: x(it.start) + 1.5,
                          width: math.max(2, x(it.end) - x(it.start) - 3),
                          top: 3,
                          height: 28,
                          child: Container(
                            padding: const EdgeInsets.only(left: 5),
                            alignment: Alignment.centerLeft,
                            decoration: BoxDecoration(
                              color: it.color.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(3),
                              border: Border.all(color: it.color),
                            ),
                            child: Text(
                              it.label,
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                              style: TextStyle(fontSize: 10, color: it.color),
                            ),
                          ),
                        ),
                      for (final (t, k) in marks)
                        Positioned(
                          left: x(t) - 4.5,
                          top: k == MarkKind.fx ? 25 : 0,
                          child: Icon(
                            k == MarkKind.fx ? Icons.change_history : Icons.circle,
                            size: 9,
                            color: markColor[k],
                          ),
                        ),
                      Positioned(
                        left: x(position) - 1,
                        top: 0,
                        bottom: 0,
                        child: Container(width: 2, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// The XY pad: press and drag to play an effect. Left to right is its length
/// (snapped to the beat, 1/16 up to 16 beats), bottom to top how strong it
/// is. Let go and it stops; the pads' own settings come back.
class XYPad extends StatefulWidget {
  final FxSettings fx;
  final void Function() onChanged;
  final void Function() onMore;
  final bool moreOpen;
  const XYPad({super.key, required this.fx, required this.onChanged, required this.onMore, required this.moreOpen});

  @override
  State<XYPad> createState() => _XYPadState();
}

class _XYPadState extends State<XYPad> {
  int _pick = 0; // which of the eight pad effects the square plays
  Offset? _at; // 0..1 each way while held
  double _keepLength = 1, _keepDepth = 0.6;

  FxSettings get fx => widget.fx;
  (BeatFx, Color) get _effect => QuickPads.pads[_pick];

  void _apply(Offset p, Size size) {
    final x = (p.dx / size.width).clamp(0.0, 0.999), y = (p.dy / size.height).clamp(0.0, 1.0);
    final f = _effect.$1;
    fx.beatFx = f;
    fx.lengths[f] = kFxLengths[(x * kFxLengths.length).floor()];
    fx.depth = (1 - y).clamp(0.08, 1.0);
    fx.on = true;
    fx.sendBeat();
    setState(() => _at = Offset(x, y));
    widget.onChanged();
  }

  void _down(Offset p, Size size) {
    final f = _effect.$1;
    _keepLength = fx.lengths[f]!;
    _keepDepth = fx.depth;
    _apply(p, size);
  }

  void _up() {
    final f = _effect.$1;
    fx.on = false;
    fx.sendBeat();
    fx.lengths[f] = _keepLength;
    fx.depth = _keepDepth;
    setState(() => _at = null);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final (f, c) = _effect;
    final at = _at;
    return Column(
      children: [
        Row(
          children: [
            Tooltip(
              message: 'Click to choose which effect the square plays',
              child: InkWell(
                onTap: () => setState(() => _pick = (_pick + 1) % QuickPads.pads.length),
                borderRadius: BorderRadius.circular(3),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        (f == BeatFx.vinylBrake ? 'Brake' : f.label).toUpperCase(),
                        style: TextStyle(fontSize: 11, letterSpacing: 0.6, fontWeight: FontWeight.w800, color: c),
                      ),
                      Icon(Icons.unfold_more, size: 14, color: c),
                    ],
                  ),
                ),
              ),
            ),
            const Spacer(),
            if (at != null)
              Text(
                '${fxLengthLabel(fx.lengths[f]!)} beat · ${(fx.depth * 100).round()}%',
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
            if (at == null)
              InkWell(
                onTap: widget.onMore,
                borderRadius: BorderRadius.circular(3),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text(
                    'MORE FX',
                    style: TextStyle(fontSize: 10, letterSpacing: 0.6, fontWeight: FontWeight.w700, color: widget.moreOpen ? Colors.white : Colors.white54),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(
          child: LayoutBuilder(
            builder: (context, box) {
              final size = box.biggest;
              return Tooltip(
                message: 'Press and drag: left to right is the length, bottom to top how strong. Let go to stop.',
                waitDuration: const Duration(seconds: 1),
                child: Listener(
                  onPointerDown: (e) => _down(e.localPosition, size),
                  onPointerMove: (e) => _apply(e.localPosition, size),
                  onPointerUp: (_) => _up(),
                  onPointerCancel: (_) => _up(),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.precise,
                    child: Container(
                      decoration: BoxDecoration(
                        color: kPanel,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: at != null ? c : c.withValues(alpha: 0.35)),
                      ),
                      child: CustomPaint(painter: _XYPainter(c, at), size: size),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _XYPainter extends CustomPainter {
  final Color c;
  final Offset? at;
  _XYPainter(this.c, this.at);

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = c.withValues(alpha: 0.12)
      ..strokeWidth = 1;
    for (var i = 1; i < kFxLengths.length; i++) {
      final x = size.width * i / kFxLengths.length;
      canvas.drawLine(Offset(x, 4), Offset(x, size.height - 4), line);
    }
    void label(String s, Offset o) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: const TextStyle(fontSize: 10, color: Colors.white38),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, o);
    }

    label('short', Offset(6, size.height - 16));
    label('long', Offset(size.width - 28, size.height - 16));
    label('strong', const Offset(6, 4));
    final p = at;
    if (p == null) return;
    final o = Offset(p.dx * size.width, p.dy * size.height);
    canvas.drawLine(Offset(o.dx, 0), Offset(o.dx, size.height), Paint()..color = c.withValues(alpha: 0.35));
    canvas.drawLine(Offset(0, o.dy), Offset(size.width, o.dy), Paint()..color = c.withValues(alpha: 0.35));
    canvas.drawCircle(o, 16, Paint()..color = c.withValues(alpha: 0.25));
    canvas.drawCircle(o, 10, Paint()..color = c);
  }

  @override
  bool shouldRepaint(_XYPainter old) => old.at != at || old.c != c;
}

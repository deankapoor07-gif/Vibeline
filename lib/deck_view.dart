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
const kSetColors = [kPink, kTeal, Color(0xFF8F5BFF), Color(0xFFFF8A1F), Color(0xFF3DA5FF), Color(0xFF7DFF5A), kYellow];

/// One deck on the Now Playing screen.
class DeckInfo {
  final String role; // VOCAL, BEAT, NOW, NEXT
  final String title;
  final String artist;
  final Color color;
  final List<(String, Color)> tags;
  const DeckInfo(this.role, this.title, this.artist, this.color, this.tags);
}

/// The bass / mid / high loudness of each rendered section, fetched from the
/// native side once per file.
class WaveCache {
  final Mixer mixer;
  void Function()? onLoaded;
  WaveCache(this.mixer);

  final _data = <String, Float32List>{};
  final _pending = <String>{};

  Float32List? of(Section s) {
    final p = s.path;
    if (p == null) return null;
    final d = _data[p];
    if (d != null || !_pending.add(p)) return d;
    mixer.waveform([p, ?s.voxPath]).then((v) {
      _pending.remove(p);
      if (_data.length > 80) _data.remove(_data.keys.first);
      _data[p] = v;
      onLoaded?.call();
    }, onError: (_) => _pending.remove(p));
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

  const NowPlayingView({
    super.key,
    required this.decks,
    required this.sections,
    required this.waves,
    required this.position,
    required this.playing,
    required this.heading,
    required this.upNext,
  });

  @override
  State<NowPlayingView> createState() => _NowPlayingViewState();
}

class _NowPlayingViewState extends State<NowPlayingView> with SingleTickerProviderStateMixin {
  // The player reports its position every 200 ms; in between the screen
  // runs it on by the clock so the waveform and platters glide.
  late final Ticker _ticker = createTicker((_) => setState(() {}));
  double _base = 0;
  DateTime _baseAt = DateTime.now();
  double _window = 7; // seconds each side of the playhead; scroll to zoom

  double get _pos {
    if (!widget.playing) return _base;
    final ran = DateTime.now().difference(_baseAt).inMicroseconds / 1e6;
    return _base + math.min(ran, 0.5);
  }

  @override
  void initState() {
    super.initState();
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
    return Column(
      children: [
        Row(
          children: [
            for (var i = 0; i < widget.decks.length; i++) ...[
              if (i > 0) const SizedBox(width: 10),
              Expanded(child: _Deck(widget.decks[i], pos)),
            ],
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            decoration: BoxDecoration(color: const Color(0xFF0C0C11), borderRadius: BorderRadius.circular(12)),
            child: Column(
              children: [
                Row(
                  children: [
                    Text(widget.heading, style: const TextStyle(fontSize: 11, color: Colors.white54)),
                    const Spacer(),
                    Flexible(
                      child: Text(
                        widget.upNext,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11, color: Colors.white54),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
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
                        child: CustomPaint(painter: _WavePainter(widget.sections, widget.waves, pos, _window)),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Deck extends StatelessWidget {
  final DeckInfo d;
  final double pos;
  const _Deck(this.d, this.pos);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: d.color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          SizedBox(width: 76, height: 76, child: CustomPaint(painter: _PlatterPainter(d.color, pos))),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  d.role,
                  style: TextStyle(fontSize: 11, letterSpacing: 1.2, color: d.color, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  d.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                Text(
                  d.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final (label, c) in d.tags)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: c.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(label, style: TextStyle(fontSize: 11, color: Color.lerp(c, Colors.white, 0.35))),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A record turning at 33⅓ — it turns with the music, so it stops when the
/// set does.
class _PlatterPainter extends CustomPainter {
  final Color color;
  final double pos;
  _PlatterPainter(this.color, this.pos);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF0B0B0E));
    final groove = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = const Color(0xFF1C1C22);
    for (var g = r * 0.42; g < r - 2; g += 2.4) {
      canvas.drawCircle(c, g, groove);
    }
    canvas.drawCircle(
      c,
      r - 1,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color,
    );
    final angle = pos * (100 / 3) / 60 * 2 * math.pi;
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.rotate(angle);
    canvas.drawCircle(Offset.zero, r * 0.36, Paint()..color = color);
    // A mark on the label and a light catching the vinyl show it turning.
    canvas.drawRect(Rect.fromLTWH(-1.5, -r * 0.34, 3, r * 0.16), Paint()..color = kInk.withValues(alpha: 0.7));
    canvas.drawLine(
      Offset(0, -r * 0.46),
      Offset(0, -r * 0.9),
      Paint()
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round
        ..color = Colors.white.withValues(alpha: 0.18),
    );
    canvas.restore();
    canvas.drawCircle(c, 3, Paint()..color = kInk);
  }

  @override
  bool shouldRepaint(_PlatterPainter old) => old.pos != pos || old.color != color;
}

/// The mix around the playhead, coloured by what's sounding: red bass, green
/// mids (most singing), blue highs (hats, cymbals). Ahead of the playhead
/// it's dimmer.
class _WavePainter extends CustomPainter {
  final List<Section> sections;
  final WaveCache waves;
  final double pos;
  final double window; // seconds each side of the playhead
  _WavePainter(this.sections, this.waves, this.pos, this.window);

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final paint = Paint()..strokeWidth = 2;
    for (var x = 0.0; x < size.width; x += 2) {
      final t = pos + (x / size.width * 2 - 1) * window;
      Section? s;
      for (final q in sections) {
        if (t >= q.start && t < q.end) s = q;
      }
      if (s == null) continue;
      final d = waves.of(s);
      if (d == null) continue;
      final i = ((t - s.start) * 50).floor() * 3;
      if (i < 0 || i + 2 >= d.length) continue;
      final l = d[i] * 1.3, m = d[i + 1], h = d[i + 2] * 2.0;
      final sum = l + m + h;
      if (sum <= 1e-6) continue;
      final amp = (math.sqrt(d[i] * d[i] + d[i + 1] * d[i + 1] + d[i + 2] * d[i + 2]) * 3.4).clamp(0.02, 1.0);
      final a = x >= size.width / 2 ? 0.5 : 1.0;
      paint.color = Color.fromRGBO(
        (40 + 215 * (l / sum) * 1.5).clamp(0, 255).round(),
        (40 + 215 * (m / sum) * 1.5).clamp(0, 255).round(),
        (60 + 195 * (h / sum) * 1.8).clamp(0, 255).round(),
        a,
      );
      final hgt = amp * mid;
      canvas.drawLine(Offset(x, mid - hgt), Offset(x, mid + hgt), paint);
    }
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2,
    );
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
  final void Function() onMore;
  final bool moreOpen;
  const QuickPads({super.key, required this.fx, required this.onChanged, required this.onMore, required this.moreOpen});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < pads.length; i++) ...[if (i > 0) const SizedBox(width: 6), Expanded(child: _pad(i))],
        const SizedBox(width: 6),
        Tooltip(
          message: 'All 13 effects, lengths and the Colour FX knobs',
          child: InkWell(
            onTap: onMore,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: moreOpen ? Colors.white : kPanel,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white24),
              ),
              child: Text('More FX', style: TextStyle(fontSize: 12, color: moreOpen ? kInk : Colors.white70)),
            ),
          ),
        ),
      ],
    );
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
          height: 52,
          decoration: BoxDecoration(
            color: lit ? c : kPanel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: lit ? c : c.withValues(alpha: 0.45)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  f == BeatFx.vinylBrake ? 'Brake' : f.label,
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: lit ? kInk : c),
                ),
              ),
              const SizedBox(height: 3),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: lit ? kInk.withValues(alpha: 0.4) : Colors.white24),
                ),
                child: Text('${i + 1}', style: TextStyle(fontSize: 10, color: lit ? kInk : Colors.white54)),
              ),
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
            const Text('Whole set · click to jump', style: TextStyle(fontSize: 11, color: Colors.white54)),
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
                              borderRadius: BorderRadius.circular(4),
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

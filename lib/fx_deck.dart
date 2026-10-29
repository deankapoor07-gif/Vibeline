import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'mixer.dart';

/// Colour FX: one effect type, a knob on each layer (centre = off).
enum ColourFx {
  filter('Filter', 'Left: low-pass · Right: high-pass'),
  crush('Crush', 'Bit-crusher, filtered to the side you turn'),
  noise('Noise', 'White noise swept by a filter: great for build-ups'),
  gateComp('Gate / Comp', 'Left: gate (chops the sound) · Right: compressor (hits harder)');

  final String label, hint;
  const ColourFx(this.label, this.hint);
}

/// Beat FX, in the native engine's order. [beats] is each one's starting
/// length; [timed] is false where the length doesn't matter.
enum BeatFx {
  echo('Echo', 1, 'Repeats that keep ringing after you let go'),
  delay('Delay', 1, 'Repeats that stop when you let go'),
  pingPong('Ping Pong', 0.5, 'Repeats bouncing left and right'),
  spiral('Spiral', 1, 'Echoes that climb in pitch'),
  reverb('Reverb', 1, 'Big room around the sound', timed: false),
  shimmer('Shimmer', 1, 'Reverb with a sparkly octave on top', timed: false),
  flanger('Flanger', 16, 'Jet-plane sweep (one sweep per length)'),
  phaser('Phaser', 16, 'Swirling sweep (one sweep per length)'),
  filter('Filter', 16, 'Resonant filter sweeping in time'),
  trans('Trans', 0.25, 'Chops the sound on and off on the beat'),
  roll('Roll', 0.25, 'Loops the last bit while held'),
  pitchRoll('Pitch Roll', 0.25, 'Loops while held, pitch sliding down'),
  vinylBrake('Vinyl Brake', 2, 'The record slows to a stop');

  final String label, hint;
  final double beats;
  final bool timed;
  const BeatFx(this.label, this.beats, this.hint, {this.timed = true});
}

const _lengths = [1 / 16, 1 / 8, 1 / 4, 1 / 2, 3 / 4, 1.0, 2.0, 4.0, 8.0, 16.0];

String _lengthLabel(double b) {
  if (b >= 1) return '${b.round()}';
  if (b == 0.75) return '3/4';
  return '1/${(1 / b).round()}';
}

/// What the FX controls are set to. Lives with the screen, so closing and
/// reopening the panel doesn't lose anything mid-set.
class FxSettings {
  final Mixer mixer;
  FxSettings(this.mixer);

  ColourFx colour = ColourFx.filter;
  double beatKnob = 0, vocalKnob = 0;

  BeatFx beatFx = BeatFx.echo;
  bool on = false;
  double depth = 0.6;
  final Map<BeatFx, double> lengths = {for (final f in BeatFx.values) f: f.beats};

  double get length => lengths[beatFx]!;

  void sendColour() => mixer.setColourFx(colour.index, beatKnob, vocalKnob);
  void sendBeat() => mixer.setBeatFx(beatFx.index, on, length, depth);

  /// Everything back to centre / off.
  void reset() {
    beatKnob = 0;
    vocalKnob = 0;
    on = false;
    sendColour();
    sendBeat();
  }
}

/// The FX panel: Colour FX knobs on the left, Beat FX pads on the right.
class FxDeck extends StatefulWidget {
  final FxSettings fx;
  final bool hasVocal; // mashup sets have a separate vocal layer
  final double? bpm;
  final Color accent;

  const FxDeck({super.key, required this.fx, required this.hasVocal, required this.bpm, required this.accent});

  @override
  State<FxDeck> createState() => _FxDeckState();
}

class _FxDeckState extends State<FxDeck> {
  FxSettings get fx => widget.fx;
  DateTime? _downAt;
  bool _wasOn = false;

  // Tap a pad: it stays on until tapped again. Hold it: it's on only while
  // held. Pressing another pad switches to that one.
  void _padDown(BeatFx f) {
    setState(() {
      _wasOn = fx.on && fx.beatFx == f;
      fx.beatFx = f;
      fx.on = !_wasOn;
      _downAt = DateTime.now();
    });
    fx.sendBeat();
  }

  void _padUp(BeatFx f) {
    final held = _downAt != null && DateTime.now().difference(_downAt!).inMilliseconds > 300;
    _downAt = null;
    if (held && !_wasOn && fx.beatFx == f && fx.on) {
      setState(() => fx.on = false);
      fx.sendBeat();
    }
  }

  void _step(int d) {
    var i = _lengths.indexWhere((x) => (x - fx.length).abs() < 1e-6);
    if (i < 0) i = 5;
    setState(() => fx.lengths[fx.beatFx] = _lengths[(i + d).clamp(0, _lengths.length - 1)]);
    fx.sendBeat();
  }

  @override
  Widget build(BuildContext context) {
    final accent = widget.accent;
    return Container(
      height: 168,
      color: const Color(0xFF121218),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // COLOUR FX
          SizedBox(
            width: 330,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const _Title('COLOUR FX'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final c in ColourFx.values)
                      Tooltip(
                        message: c.hint,
                        child: _Chip(
                          label: c.label,
                          selected: fx.colour == c,
                          accent: accent,
                          onTap: () {
                            setState(() => fx.colour = c);
                            fx.sendColour();
                          },
                        ),
                      ),
                  ],
                ),
                const Spacer(),
                Row(
                  children: [
                    Knob(
                      label: 'BEAT',
                      value: fx.beatKnob,
                      bipolar: true,
                      accent: accent,
                      onChanged: (v) {
                        setState(() => fx.beatKnob = v);
                        fx.sendColour();
                      },
                    ),
                    const SizedBox(width: 18),
                    Opacity(
                      opacity: widget.hasVocal ? 1 : 0.35,
                      child: Knob(
                        label: 'VOCAL',
                        value: fx.vocalKnob,
                        bipolar: true,
                        accent: accent,
                        onChanged: widget.hasVocal
                            ? (v) {
                                setState(() => fx.vocalKnob = v);
                                fx.sendColour();
                              }
                            : null,
                      ),
                    ),
                    const SizedBox(width: 14),
                    const Expanded(
                      child: Text('Drag up / down or scroll.\nDouble-click to centre (off).',
                          style: TextStyle(fontSize: 10, color: Colors.white38)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const VerticalDivider(color: Colors.white12, width: 28),
          // BEAT FX
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const _Title('BEAT FX'),
                    const SizedBox(width: 12),
                    Text(widget.bpm == null ? '— BPM' : '${widget.bpm!.toStringAsFixed(1)} BPM',
                        style: const TextStyle(fontSize: 11, color: Colors.white60, fontFeatures: [FontFeature.tabularFigures()])),
                    const SizedBox(width: 16),
                    Opacity(
                      opacity: fx.beatFx.timed ? 1 : 0.35,
                      child: Row(children: [
                        _SmallButton(icon: Icons.chevron_left, onTap: fx.beatFx.timed ? () => _step(-1) : null),
                        SizedBox(
                          width: 64,
                          child: Text('${_lengthLabel(fx.length)} beat${fx.length > 1 ? 's' : ''}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                        ),
                        _SmallButton(icon: Icons.chevron_right, onTap: fx.beatFx.timed ? () => _step(1) : null),
                      ]),
                    ),
                    const Spacer(),
                    Text('Tap: on/off · Hold: while held', style: const TextStyle(fontSize: 10, color: Colors.white38)),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: LayoutBuilder(builder: (context, c) {
                    const perRow = 7, gap = 6.0;
                    final w = (c.maxWidth - gap * (perRow - 1)) / perRow;
                    final h = (c.maxHeight - gap) / 2;
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final f in BeatFx.values)
                          Tooltip(
                            message: f.hint,
                            waitDuration: const Duration(milliseconds: 600),
                            child: _Pad(
                              width: w,
                              height: h,
                              label: f.label,
                              selected: fx.beatFx == f,
                              lit: fx.on && fx.beatFx == f,
                              accent: accent,
                              onDown: () => _padDown(f),
                              onUp: () => _padUp(f),
                            ),
                          ),
                      ],
                    );
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Padding(
            padding: const EdgeInsets.only(top: 34),
            child: Knob(
              label: 'LEVEL',
              value: fx.depth,
              bipolar: false,
              accent: accent,
              onChanged: (v) {
                setState(() => fx.depth = v);
                fx.sendBeat();
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _Title extends StatelessWidget {
  final String text;
  const _Title(this.text);
  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, letterSpacing: 1.5, color: Colors.white70));
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.accent, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? accent.withValues(alpha: 0.25) : Colors.white.withValues(alpha: 0.05),
            border: Border.all(color: selected ? accent : Colors.white24),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label, style: TextStyle(fontSize: 12, color: selected ? Colors.white : Colors.white70)),
        ),
      );
}

class _SmallButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _SmallButton({required this.icon, this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(padding: const EdgeInsets.all(2), child: Icon(icon, size: 18, color: Colors.white70)),
      );
}

/// A Beat FX pad: lights up while its effect is on.
class _Pad extends StatelessWidget {
  final double width, height;
  final String label;
  final bool selected, lit;
  final Color accent;
  final VoidCallback onDown, onUp;

  const _Pad({
    required this.width,
    required this.height,
    required this.label,
    required this.selected,
    required this.lit,
    required this.accent,
    required this.onDown,
    required this.onUp,
  });

  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => onDown(),
        onPointerUp: (_) => onUp(),
        onPointerCancel: (_) => onUp(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 60),
          width: width,
          height: height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: lit ? accent.withValues(alpha: 0.85) : Colors.white.withValues(alpha: selected ? 0.10 : 0.05),
            border: Border.all(color: selected ? accent : Colors.white12, width: selected ? 1.5 : 1),
            borderRadius: BorderRadius.circular(8),
            boxShadow: lit ? [BoxShadow(color: accent.withValues(alpha: 0.6), blurRadius: 12)] : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4),
          // Long names shrink to fit rather than breaking mid-word.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(label,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: lit ? Colors.black : Colors.white)),
          ),
        ),
      );
}

/// A rotary knob. Bipolar: -1…1 with off in the middle; otherwise 0…1.
/// Drag up/down or scroll to turn; double-click to reset.
class Knob extends StatelessWidget {
  final String label;
  final double value;
  final bool bipolar;
  final Color accent;
  final ValueChanged<double>? onChanged;

  const Knob({super.key, required this.label, required this.value, required this.bipolar, required this.accent, this.onChanged});

  double get _min => bipolar ? -1 : 0;

  void _nudge(double d) {
    final v = (value + d * (bipolar ? 2 : 1)).clamp(_min, 1.0);
    // A little detent at the centre so "off" is easy to find.
    onChanged?.call(bipolar && v.abs() < 0.03 ? 0 : v);
  }

  @override
  Widget build(BuildContext context) => Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) _nudge(-e.scrollDelta.dy / 600);
        },
        child: GestureDetector(
          onVerticalDragUpdate: onChanged == null ? null : (d) => _nudge(-d.delta.dy / 160),
          onDoubleTap: onChanged == null ? null : () => onChanged!(bipolar ? 0 : 0.6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 54, height: 54, child: CustomPaint(painter: _KnobPainter(value, bipolar, accent))),
              const SizedBox(height: 4),
              Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white60)),
            ],
          ),
        ),
      );
}

class _KnobPainter extends CustomPainter {
  final double value;
  final bool bipolar;
  final Color accent;
  _KnobPainter(this.value, this.bipolar, this.accent);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2 - 4;
    const start = math.pi * 0.75, sweep = math.pi * 1.5;
    final rect = Rect.fromCircle(center: c, radius: r);
    final track = Paint()
      ..color = Colors.white12
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, start, sweep, false, track);
    final f = bipolar ? (value + 1) / 2 : value; // 0..1 around the dial
    final arc = Paint()
      ..color = accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    if (bipolar) {
      final mid = start + sweep / 2;
      canvas.drawArc(rect, mid, (f - 0.5) * sweep, false, arc);
    } else {
      canvas.drawArc(rect, start, f * sweep, false, arc);
    }
    canvas.drawCircle(c, r - 7, Paint()..color = const Color(0xFF26262E));
    final a = start + f * sweep;
    canvas.drawLine(c + Offset(math.cos(a), math.sin(a)) * (r - 16), c + Offset(math.cos(a), math.sin(a)) * (r - 8),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(_KnobPainter old) => old.value != value || old.accent != accent;
}

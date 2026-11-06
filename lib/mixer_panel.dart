import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'deck_view.dart';
import 'fx_deck.dart';
import 'rig.dart';

/// Where a channel fader sits when nothing has been changed.
const kFaderHome = 0.8;

/// A fader position (0..1) as a level: home is 0 dB, the top +6, the bottom off.
double faderDb(double v) {
  if (v <= 0.01) return -60;
  if (v >= kFaderHome) return (v - kFaderHome) / (1 - kFaderHome) * 6;
  return (v - kFaderHome) / kFaderHome * 40;
}

/// The master knob (-1..1) as a level: the middle is 0 dB, full right +6, full
/// left off. It only changes what you hear, never the saved mix.
double masterDb(double v) {
  if (v <= -0.99) return -60;
  return v >= 0 ? v * 6 : v * 40;
}

/// What the crossfader takes off each layer: full left is only the vocal, full
/// right only the beat, and the middle leaves both alone.
(double vocalDb, double beatDb) crossfadeDb(double x) {
  double cut(double amount) => amount >= 0.999 ? -60 : 20 * math.log(1 - amount) / math.ln10;
  return (x > 0 ? cut(x) : 0, x < 0 ? cut(-x) : 0);
}

/// The mixer between the decks. Everything on it changes the sound live.
class MixerPanel extends StatelessWidget {
  final bool hasVocal;
  final double vocalFader, beatFader, crossfader, master;
  final bool muteVocal, muteBeat;
  final FxSettings fx;
  final double meterVocal, meterBeat;
  final void Function(double) onVocalFader, onBeatFader, onCrossfader, onMaster;
  final VoidCallback onMuteVocal, onMuteBeat, onKnob;

  const MixerPanel({
    super.key,
    required this.hasVocal,
    required this.vocalFader,
    required this.beatFader,
    required this.crossfader,
    required this.master,
    required this.muteVocal,
    required this.muteBeat,
    required this.fx,
    required this.meterVocal,
    required this.meterBeat,
    required this.onVocalFader,
    required this.onBeatFader,
    required this.onCrossfader,
    required this.onMaster,
    required this.onMuteVocal,
    required this.onMuteBeat,
    required this.onKnob,
  });

  static const _width = 236.0, _minHeight = 262.0;

  Widget _channel(String name, Color c, double value, void Function(double) on, double meter, {required bool meterFirst}) {
    final m = _Meter(meter);
    final f = Expanded(
      child: Tooltip(
        message: '$name level. Double-click to put it back.',
        waitDuration: const Duration(seconds: 1),
        child: RigFader(value: value, color: c, onChanged: on, home: kFaderHome),
      ),
    );
    return Expanded(child: Row(children: meterFirst ? [m, const SizedBox(width: 6), f] : [f, const SizedBox(width: 6), m]));
  }

  Widget _master() => Tooltip(
        message: 'Master: the overall volume. Double-click to put it back. Saved mixes are not affected.',
        waitDuration: const Duration(seconds: 1),
        child: Knob(label: 'MASTER\nLEVEL', value: master, bipolar: true, accent: kRigAmber, onChanged: onMaster),
      );

  Widget _body() {
    final title = fx.colour.label.toUpperCase();
    if (!hasVocal) {
      return Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          Knob(
            label: '$title\nBEAT',
            value: fx.beatKnob,
            bipolar: true,
            accent: kTeal,
            onChanged: (v) {
              fx.beatKnob = v;
              fx.sendColour();
              onKnob();
            },
          ),
          _master(),
        ]),
        const SizedBox(height: 10),
        Expanded(child: _Meter(meterBeat, wide: true)),
      ]);
    }
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
        Knob(
          label: '$title\nVOCAL',
          value: fx.vocalKnob,
          bipolar: true,
          accent: kPink,
          onChanged: (v) {
            fx.vocalKnob = v;
            fx.sendColour();
            onKnob();
          },
        ),
        _master(),
        Knob(
          label: '$title\nBEAT',
          value: fx.beatKnob,
          bipolar: true,
          accent: kTeal,
          onChanged: (v) {
            fx.beatKnob = v;
            fx.sendColour();
            onKnob();
          },
        ),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: Center(child: RigToggle(label: 'Mute', on: muteVocal, color: kPink, tooltip: 'Cut the singer out for an instrumental moment', onChanged: (_) => onMuteVocal()))),
        const SizedBox(width: 8),
        Expanded(child: Center(child: RigToggle(label: 'Mute', on: muteBeat, color: kTeal, tooltip: 'Cut the beat out for an acapella moment', onChanged: (_) => onMuteBeat()))),
      ]),
      const SizedBox(height: 8),
      Expanded(
        child: Row(children: [
          _channel('Vocal', kPink, vocalFader, onVocalFader, muteVocal ? 0 : meterVocal, meterFirst: false),
          const SizedBox(width: 10),
          _channel('Beat', kTeal, beatFader, onBeatFader, muteBeat ? 0 : meterBeat, meterFirst: true),
        ]),
      ),
      const SizedBox(height: 8),
      Row(children: [
        const Text('VOCAL', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: kPink)),
        const SizedBox(width: 6),
        Expanded(
          child: Tooltip(
            message: 'Crossfader: slide left for only the vocal, right for only the beat. Double-click to centre.',
            waitDuration: const Duration(seconds: 1),
            child: RigCrossfader(value: crossfader, onChanged: onCrossfader),
          ),
        ),
        const SizedBox(width: 6),
        const Text('BEAT', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: kTeal)),
      ]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: _width,
      decoration: const BoxDecoration(gradient: kRigPanelFace),
      foregroundDecoration: BoxDecoration(border: Border.all(color: kLine)),
      child: LayoutBuilder(
        builder: (context, box) => FittedBox(
          fit: BoxFit.scaleDown,
          child: SizedBox(
            width: _width,
            height: math.max(_minHeight, box.maxHeight),
            child: Padding(padding: const EdgeInsets.all(10), child: _body()),
          ),
        ),
      ),
    );
  }
}

/// A level meter fed by the sound of the set. [level] is 0..1.
class _Meter extends StatelessWidget {
  final double level;
  final bool wide;
  const _Meter(this.level, {this.wide = false});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: wide ? 18 : 8,
        child: CustomPaint(painter: _MeterPainter(level.clamp(0.0, 1.0)), size: Size.infinite),
      );
}

class _MeterPainter extends CustomPainter {
  final double level;
  _MeterPainter(this.level);

  @override
  void paint(Canvas canvas, Size size) {
    const segments = 22;
    final h = size.height / segments;
    for (var i = 0; i < segments; i++) {
      final at = i / segments;
      final lit = at < level;
      final c = at > 0.86 ? const Color(0xFFFF3B30) : (at > 0.68 ? kRigAmber : kRigGreen);
      canvas.drawRect(
        Rect.fromLTWH(0, size.height - (i + 1) * h + 1, size.width, math.max(1, h - 2)),
        Paint()..color = lit ? c : c.withValues(alpha: 0.1),
      );
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) => old.level != level;
}

/// A channel fader. Drag it, scroll isn't needed; double-click returns it home.
class RigFader extends StatelessWidget {
  final double value, home;
  final Color color;
  final void Function(double) onChanged;
  const RigFader({super.key, required this.value, required this.color, required this.onChanged, required this.home});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, box) {
          void at(Offset p) => onChanged((1 - p.dy / math.max(1, box.maxHeight)).clamp(0.0, 1.0));
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragStart: (d) => at(d.localPosition),
            onVerticalDragUpdate: (d) => at(d.localPosition),
            onDoubleTap: () => onChanged(home),
            child: CustomPaint(painter: _FaderPainter(value, color, home), size: Size.infinite),
          );
        },
      );
}

class _FaderPainter extends CustomPainter {
  final double value, home;
  final Color color;
  _FaderPainter(this.value, this.color, this.home);

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    final tick = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    for (var i = 0; i <= 10; i++) {
      final y = 6 + (size.height - 12) * i / 10;
      canvas.drawLine(Offset(x - 13, y), Offset(x - 7, y), tick);
      canvas.drawLine(Offset(x + 7, y), Offset(x + 13, y), tick);
    }
    canvas.drawRect(Rect.fromCenter(center: Offset(x, size.height / 2), width: 3, height: size.height - 8), Paint()..color = Colors.black);
    final y = 6 + (size.height - 12) * (1 - value);
    final cap = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, y), width: 28, height: 16), const Radius.circular(2));
    canvas.drawRRect(cap, Paint()..color = const Color(0xFF8C8C98));
    canvas.drawLine(Offset(x - 13, y), Offset(x + 13, y), Paint()
      ..color = color
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_FaderPainter old) => old.value != value || old.color != color;
}

/// The crossfader: -1 (left) to 1 (right), with a little notch in the middle.
class RigCrossfader extends StatelessWidget {
  final double value;
  final void Function(double) onChanged;
  const RigCrossfader({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 26,
        child: LayoutBuilder(
          builder: (context, box) {
            void at(Offset p) {
              final v = (p.dx / math.max(1, box.maxWidth) * 2 - 1).clamp(-1.0, 1.0);
              onChanged(v.abs() < 0.04 ? 0 : v);
            }

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (d) => at(d.localPosition),
              onHorizontalDragUpdate: (d) => at(d.localPosition),
              onDoubleTap: () => onChanged(0),
              child: CustomPaint(painter: _CrossPainter(value), size: Size.infinite),
            );
          },
        ),
      );
}

class _CrossPainter extends CustomPainter {
  final double value;
  _CrossPainter(this.value);

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final tick = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;
    for (var i = 0; i <= 8; i++) {
      final x = 6 + (size.width - 12) * i / 8;
      canvas.drawLine(Offset(x, 2), Offset(x, 6), tick);
      canvas.drawLine(Offset(x, size.height - 6), Offset(x, size.height - 2), tick);
    }
    canvas.drawRect(Rect.fromCenter(center: Offset(size.width / 2, y), width: size.width - 8, height: 3), Paint()..color = Colors.black);
    final x = 8 + (size.width - 16) * (value + 1) / 2;
    final cap = RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(x, y), width: 14, height: size.height - 4), const Radius.circular(2));
    canvas.drawRRect(cap, Paint()..color = const Color(0xFF8C8C98));
    canvas.drawLine(Offset(x, 3), Offset(x, size.height - 3), Paint()
      ..color = Colors.white
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_CrossPainter old) => old.value != value;
}

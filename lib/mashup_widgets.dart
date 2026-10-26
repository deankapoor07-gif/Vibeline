import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'mashup.dart';
import 'models.dart';
import 'planner.dart' show shiftCamelot;
import 'tuning.dart';

const kMashupAccent = Colors.purpleAccent;

// ---------------------------------------------------------
// MASHUP & SAMPLE LANE (the acapellas placed across the set)
// ---------------------------------------------------------
class MashupLaneHeader extends StatelessWidget {
  final AnchorBeat? anchor;
  const MashupLaneHeader({super.key, this.anchor});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      height: anchor != null ? 84 : 54,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF221A30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kMashupAccent.withValues(alpha: 0.5), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text("MASHUP & SAMPLE LANE", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: kMashupAccent)),
          SizedBox(height: 2),
          const Text("AI acapellas + your sounds, loops & acapellas", style: TextStyle(fontSize: 9, color: Colors.white38)),
          if (anchor != null) ...[
            const SizedBox(height: 4),
            Text('⚓ Anchor: ${anchor!.track.title}',
                style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.amberAccent),
                overflow: TextOverflow.ellipsis),
            Text('${anchor!.tempo.toStringAsFixed(1)} BPM · key ${anchor!.camelot}',
                style: const TextStyle(fontSize: 9, color: Colors.white38)),
          ],
        ],
      ),
    );
  }
}

/// The acapella block that sits above each mashup card.
class AcapellaBlock extends StatelessWidget {
  final Mashup mashup;
  final bool live;
  const AcapellaBlock({super.key, required this.mashup, required this.live});

  @override
  Widget build(BuildContext context) {
    final vocalLane = mashup.lanes.first;
    final audible = mashup.laneAudible(vocalLane);
    return Container(
      width: 320,
      height: 54,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: kMashupAccent.withValues(alpha: audible ? (live ? 0.4 : 0.22) : 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: audible ? kMashupAccent : Colors.white24),
      ),
      child: Row(
        children: [
          Text('🎤', style: TextStyle(fontSize: 18, color: Colors.white.withValues(alpha: audible ? 1 : 0.3))),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Acapella: ${mashup.vocal.title}',
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${mashup.vocalBars} bars'
                  '${mashup.vocalShift != 0 ? ' · ${mashup.vocalShift > 0 ? '+' : ''}${mashup.vocalShift} semitone' : ''}'
                  ' · ${((mashup.vocalRate - 1) * 100).toStringAsFixed(1)}% speed',
                  style: const TextStyle(fontSize: 9, color: Colors.white54),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------
// MASHUP CARD WITH EXPANDABLE STEM LANES
// ---------------------------------------------------------
class TrackStemLaneWidget extends StatelessWidget {
  final Mashup mashup;
  final bool expanded;
  final bool isCurrent;
  final bool busy;
  final double position;
  final VoidCallback onToggleStems;
  final VoidCallback onTap;
  final VoidCallback onSwap;
  final VoidCallback onShuffle;
  final void Function(StemLane lane) onToggleMute;
  final void Function(StemLane lane) onToggleSolo;
  final void Function(int delta) onShift;
  final void Function(double cents) onFine;
  final VoidCallback onResetPitch;
  final void Function(double db) onVocalDb;
  final void Function(double db) onBeatDb;
  final void Function(double scale) onTempo;
  final void Function(LibraryTrack song, bool asVocal) onDrop;
  final bool anchorMode;

  const TrackStemLaneWidget({
    super.key,
    required this.mashup,
    required this.expanded,
    required this.isCurrent,
    required this.busy,
    required this.position,
    required this.onToggleStems,
    required this.onTap,
    required this.onSwap,
    required this.onShuffle,
    required this.onToggleMute,
    required this.onToggleSolo,
    required this.onShift,
    required this.onFine,
    required this.onResetPitch,
    required this.onVocalDb,
    required this.onBeatDb,
    required this.onTempo,
    required this.onDrop,
    this.anchorMode = false,
  });

  @override
  Widget build(BuildContext context) {
    final m = mashup;
    final span = m.end - m.start;
    final played = span > 0 ? ((position - m.start) / span).clamp(0.0, 1.0) : 0.0;
    final beatLanes = m.lanes.where((l) => !l.fromVocalSong).toList();
    final vocalLanes = m.lanes.where((l) => l.fromVocalSong).toList();
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 320,
      decoration: BoxDecoration(
        color: isCurrent ? const Color(0xFF262233) : const Color(0xFF1E1E28),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCurrent || expanded ? kMashupAccent : Colors.white24,
          width: isCurrent ? 2.5 : 1.5,
        ),
        boxShadow: isCurrent ? [BoxShadow(color: kMashupAccent.withValues(alpha: 0.3), blurRadius: 18)] : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Main header: which vocal over which beat
          InkWell(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
              decoration: BoxDecoration(
                color: Colors.purple.shade900.withValues(alpha: 0.3),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _dropZone(
                          true,
                          m.beatOnly
                              ? const Text('BEAT BREAK  ·  drop a song here to add a vocal',
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: kMashupAccent))
                              : _songLine('🎤', m.vocal.title, m.vocal.artist, Colors.pinkAccent),
                        ),
                        const SizedBox(height: 4),
                        _dropZone(false, _songLine('🥁', m.beat.title, m.beat.artist, Colors.greenAccent)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(expanded ? Icons.expand_less : Icons.expand_more, color: kMashupAccent),
                    onPressed: onToggleStems,
                    tooltip: "Show stem lanes",
                  ),
                ],
              ),
            ),
          ),

          // Style + key/tempo line
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Text(m.styleLine, style: const TextStyle(fontSize: 11, color: Colors.white70), overflow: TextOverflow.ellipsis),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
            child: Text(
              '${shiftCamelot(m.beatGrid.camelot, m.beatShift)} · ${m.playedBpm.toStringAsFixed(1)} BPM · keys ${m.keyMatch}${Tuning.use432 ? ' · 432 Hz' : ''}',
              style: const TextStyle(fontSize: 10, color: Colors.white38),
            ),
          ),

          // Master waveform: the beat, with the stretch where the vocal sings
          Container(
            height: 48,
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            decoration: BoxDecoration(color: Colors.black45, borderRadius: BorderRadius.circular(6)),
            child: CustomPaint(
              size: Size.infinite,
              painter: _MashupWavePainter(
                beat: m.beatGrid.waveform,
                vocalFrom: span > 0 ? ((m.vocalIn - m.start) / span).clamp(0.0, 1.0) : 0.0,
                vocalTo: span > 0 ? ((m.vocalOut - m.start) / span).clamp(0.0, 1.0) : 0.0,
                played: isCurrent || played >= 1 ? played : 0,
                vocalOn: m.laneAudible(m.lanes.first),
              ),
            ),
          ),

          // Vocal pitch: semitones (key) and fine cents (by ear)
          if (!m.beatOnly) _pitchRow(),
          // Live volume faders
          if (!m.beatOnly) _faderRow('🎤 Vocal', m.vocalDb, Colors.pinkAccent, onVocalDb),
          _faderRow('🥁 Beat', m.beatDb, Colors.greenAccent, onBeatDb),
          if (anchorMode)
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 2, 12, 4),
              child: Text('⚓ Tempo and key follow the anchor beat', style: TextStyle(fontSize: 9, color: Colors.amberAccent)),
            )
          else
            _tempoRow(),

          // Swap / shuffle
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
            child: Row(
              children: [
                TextButton.icon(
                  onPressed: busy ? null : onSwap,
                  icon: const Icon(Icons.swap_vert, size: 16),
                  label: const Text('Swap vocal ↔ beat', style: TextStyle(fontSize: 11)),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: busy ? null : onShuffle,
                  icon: const Icon(Icons.shuffle, size: 16),
                  label: const Text('Shuffle', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ),

          // EXPANDED STEM SUB-LANES
          if (expanded) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12.0),
              child: Text("ISOLATED STEM LANES", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: kMashupAccent)),
            ),
            _groupLabel('From ${m.beat.title} (beat)'),
            for (final lane in beatLanes) _laneRow(lane),
            _groupLabel('From ${m.vocal.title} (vocal)'),
            for (final lane in vocalLanes) _laneRow(lane),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  Widget _pitchRow() {
    final m = mashup;
    final st = m.vocalShift;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 2, 8, 0),
      child: Row(
        children: [
          const Text('Vocal pitch', style: TextStyle(fontSize: 10, color: Colors.white54)),
          const SizedBox(width: 4),
          _round(Icons.remove, busy ? null : () => onShift(-1), 'Down a semitone'),
          SizedBox(
            width: 34,
            child: Text(st == 0 ? '0 st' : '${st > 0 ? '+' : ''}$st st',
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.pinkAccent)),
          ),
          _round(Icons.add, busy ? null : () => onShift(1), 'Up a semitone'),
          Expanded(
            child: Tooltip(
              message: 'Fine-tune by ear (cents). Tuning is already matched automatically'
                  '${m.autoTuneCents.abs() >= 1 ? ' (${m.autoTuneCents > 0 ? '+' : ''}${m.autoTuneCents.round()}¢)' : ''}.',
              child: SliderTheme(
                data: SliderThemeData(trackHeight: 2, overlayShape: SliderComponentShape.noOverlay,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
                child: _FineSlider(value: m.fineCents, enabled: !busy, onChanged: onFine),
              ),
            ),
          ),
          SizedBox(
            width: 30,
            child: Text('${m.fineCents >= 0 ? '+' : ''}${m.fineCents.round()}¢', style: const TextStyle(fontSize: 10, color: Colors.white54)),
          ),
          _round(Icons.restart_alt, busy ? null : onResetPitch, 'Back to automatic'),
        ],
      ),
    );
  }

  Widget _tempoRow() {
    final m = mashup;
    final bpm = m.beatGrid.steadyBpm * m.tempoScale;
    final natural = !m.beatOnly && (m.tempoScale - m.vocalNaturalScale).abs() < 0.002;
    void set(double scale) => onTempo((scale * 1000).round() / 1000);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
      child: Column(
        children: [
          Row(
            children: [
              const SizedBox(width: 62, child: Text('⏱ Tempo', style: TextStyle(fontSize: 10, color: Colors.white54))),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(trackHeight: 2, overlayShape: SliderComponentShape.noOverlay,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
                  child: _ReleaseSlider(
                    value: m.tempoScale,
                    min: 0.85,
                    max: 1.15,
                    color: Colors.amberAccent,
                    label: (v) => '${(m.beatGrid.steadyBpm * v).toStringAsFixed(1)} BPM',
                    onChanged: busy ? null : set,
                  ),
                ),
              ),
              SizedBox(
                width: 56,
                child: Text('${bpm.toStringAsFixed(1)} BPM', style: const TextStyle(fontSize: 10, color: Colors.white70)),
              ),
              _round(Icons.restart_alt, busy ? null : () => set(1.0), "Beat's own speed"),
            ],
          ),
          Row(
            children: [
              const SizedBox(width: 62),
              _round(Icons.remove, busy ? null : () => set((bpm - 0.5) / m.beatGrid.steadyBpm), 'Half a BPM slower'),
              _round(Icons.add, busy ? null : () => set((bpm + 0.5) / m.beatGrid.steadyBpm), 'Half a BPM faster'),
              const SizedBox(width: 6),
              if (!m.beatOnly)
                Text(
                  natural ? 'vocal at its natural speed' : 'vocal at ${(m.vocalSpeed * 100).toStringAsFixed(0)}% speed',
                  style: TextStyle(fontSize: 9, color: natural ? Colors.greenAccent : Colors.white38),
                ),
              const Spacer(),
              if (!m.beatOnly && !natural)
                InkWell(
                  onTap: busy ? null : () => set(m.vocalNaturalScale),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text('Match vocal', style: TextStyle(fontSize: 10, color: Colors.amberAccent, fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _faderRow(String label, double db, Color color, void Function(double) onChanged) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
        child: Row(
          children: [
            SizedBox(width: 62, child: Text(label, style: const TextStyle(fontSize: 10, color: Colors.white54))),
            Expanded(
              child: SliderTheme(
                data: SliderThemeData(trackHeight: 2, overlayShape: SliderComponentShape.noOverlay,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6)),
                child: _LiveSlider(value: db, min: -12, max: 12, color: color, onChanged: onChanged),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text('${db >= 0 ? '+' : ''}${db.toStringAsFixed(1)} dB', style: const TextStyle(fontSize: 10, color: Colors.white54)),
            ),
            InkWell(
              onTap: () => onChanged(0),
              customBorder: const CircleBorder(),
              child: const Padding(padding: EdgeInsets.all(3), child: Icon(Icons.restart_alt, size: 15, color: Colors.white38)),
            ),
          ],
        ),
      );

  Widget _round(IconData icon, VoidCallback? onTap, String tip) => Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Padding(padding: const EdgeInsets.all(3), child: Icon(icon, size: 15, color: Colors.white70)),
        ),
      );

  /// A song line that accepts a song dragged from the library.
  Widget _dropZone(bool asVocal, Widget child) => DragTarget<LibraryTrack>(
        onWillAcceptWithDetails: (_) => !busy,
        onAcceptWithDetails: (d) => onDrop(d.data, asVocal),
        builder: (context, candidates, _) {
          final hover = candidates.isNotEmpty;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: hover ? (asVocal ? Colors.pinkAccent : Colors.greenAccent).withValues(alpha: 0.2) : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: hover ? (asVocal ? Colors.pinkAccent : Colors.greenAccent) : Colors.transparent),
            ),
            child: hover
                ? Text(asVocal ? 'Drop to use as the vocal' : 'Drop to use as the beat',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: asVocal ? Colors.pinkAccent : Colors.greenAccent))
                : child,
          );
        },
      );

  Widget _songLine(String icon, String title, String artist, Color color) => Row(
        children: [
          Text(icon, style: const TextStyle(fontSize: 13)),
          const SizedBox(width: 6),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: title, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: color)),
                TextSpan(text: '  $artist', style: const TextStyle(color: Colors.white54, fontSize: 11)),
              ]),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );

  Widget _groupLabel(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
        child: Text(text, style: const TextStyle(fontSize: 9, color: Colors.white38), overflow: TextOverflow.ellipsis),
      );

  Widget _laneRow(StemLane stem) {
    final audible = mashup.laneAudible(stem);
    return Container(
      height: 34,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: stem.color.withValues(alpha: audible ? 0.12 : 0.03),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: stem.color.withValues(alpha: audible ? 0.35 : 0.1)),
      ),
      child: Row(
        children: [
          Icon(Icons.graphic_eq, size: 14, color: stem.color.withValues(alpha: audible ? 1 : 0.3)),
          const SizedBox(width: 8),
          Text(stem.label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: stem.color.withValues(alpha: audible ? 1 : 0.35))),
          const Spacer(),
          _pill('M', stem.muted, Colors.red, busy ? null : () => onToggleMute(stem), 'Mute'),
          const SizedBox(width: 4),
          _pill('S', stem.solo, Colors.amber, busy ? null : () => onToggleSolo(stem), 'Solo'),
        ],
      ),
    );
  }

  Widget _pill(String label, bool on, Color color, VoidCallback? onTap, String tip) => Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            width: 22,
            padding: const EdgeInsets.symmetric(vertical: 2),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? color.withValues(alpha: 0.3) : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: on ? color : Colors.white24),
            ),
            child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: on ? color : Colors.white70)),
          ),
        ),
      );
}

class _MashupWavePainter extends CustomPainter {
  final List<double> beat;
  final double vocalFrom, vocalTo, played;
  final bool vocalOn;
  _MashupWavePainter({required this.beat, required this.vocalFrom, required this.vocalTo, required this.played, required this.vocalOn});

  @override
  void paint(Canvas canvas, Size size) {
    // Vocal span highlight
    if (vocalOn) {
      final r = Rect.fromLTRB(size.width * vocalFrom, 2, size.width * vocalTo, size.height - 2);
      canvas.drawRRect(RRect.fromRectAndRadius(r, const Radius.circular(4)), Paint()..color = Colors.pinkAccent.withValues(alpha: 0.18));
    }
    if (beat.isEmpty) return;
    final n = 90;
    final w = size.width / n;
    final mid = size.height / 2;
    final p = Paint()..strokeWidth = math.max(1, w * 0.6);
    for (var i = 0; i < n; i++) {
      final f = (i + 0.5) / n;
      final v = beat[(f * beat.length).floor().clamp(0, beat.length - 1)];
      p.color = f <= played ? kMashupAccent : Colors.greenAccent.withValues(alpha: 0.4);
      final h = math.max(1.0, v * (size.height / 2 - 6));
      canvas.drawLine(Offset(i * w + w / 2, mid - h), Offset(i * w + w / 2, mid + h), p);
    }
  }

  @override
  bool shouldRepaint(_MashupWavePainter o) => o.played != played || o.vocalOn != vocalOn || o.beat != beat;
}

/// A slider that applies when you let go (for changes that re-mix).
class _ReleaseSlider extends StatefulWidget {
  final double value, min, max;
  final Color color;
  final String Function(double) label;
  final void Function(double)? onChanged;
  const _ReleaseSlider(
      {required this.value, required this.min, required this.max, required this.color, required this.label, this.onChanged});

  @override
  State<_ReleaseSlider> createState() => _ReleaseSliderState();
}

class _ReleaseSliderState extends State<_ReleaseSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) => Slider(
        value: (_drag ?? widget.value).clamp(widget.min, widget.max),
        min: widget.min,
        max: widget.max,
        divisions: 120,
        label: widget.label(_drag ?? widget.value),
        activeColor: widget.color,
        onChanged: widget.onChanged == null ? null : (v) => setState(() => _drag = v),
        onChangeEnd: (v) {
          setState(() => _drag = null);
          widget.onChanged?.call(v);
        },
      );
}

/// A fader that changes the sound live while you drag it.
class _LiveSlider extends StatefulWidget {
  final double value, min, max;
  final Color color;
  final void Function(double) onChanged;
  const _LiveSlider({required this.value, required this.min, required this.max, required this.color, required this.onChanged});

  @override
  State<_LiveSlider> createState() => _LiveSliderState();
}

class _LiveSliderState extends State<_LiveSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) => Slider(
        value: (_drag ?? widget.value).clamp(widget.min, widget.max),
        min: widget.min,
        max: widget.max,
        divisions: ((widget.max - widget.min) * 2).round(),
        activeColor: widget.color,
        onChanged: (v) {
          setState(() => _drag = v);
          widget.onChanged(v);
        },
        onChangeEnd: (v) => setState(() => _drag = null),
      );
}

/// Fine-tune slider (applied live while dragging).
class _FineSlider extends StatefulWidget {
  final double value;
  final bool enabled;
  final void Function(double) onChanged;
  const _FineSlider({required this.value, required this.enabled, required this.onChanged});

  @override
  State<_FineSlider> createState() => _FineSliderState();
}

class _FineSliderState extends State<_FineSlider> {
  double? _drag;

  @override
  Widget build(BuildContext context) => Slider(
        value: (_drag ?? widget.value).clamp(-50, 50),
        min: -50,
        max: 50,
        divisions: 50,
        activeColor: Colors.pinkAccent,
        // Live: the pitch follows the slider as you drag, like a hardware knob.
        onChanged: widget.enabled
            ? (v) {
                setState(() => _drag = v);
                widget.onChanged(v);
              }
            : null,
        onChangeEnd: (v) => setState(() => _drag = null),
      );
}

class MashupBridge extends StatelessWidget {
  final VoidCallback onAdd;
  const MashupBridge({super.key, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      height: 190,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(height: 2, color: kMashupAccent.withValues(alpha: 0.7)),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.purple.shade900.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: kMashupAccent.withValues(alpha: 0.7)),
            ),
            child: const Text("BLEND", style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: kMashupAccent)),
          ),
          const SizedBox(height: 4),
          const Text('8 bars', style: TextStyle(fontSize: 9, color: Colors.white54)),
          const SizedBox(height: 6),
          Tooltip(
            message: 'Add a beat from any song here',
            child: InkWell(
              onTap: onAdd,
              customBorder: const CircleBorder(),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: kMashupAccent)),
                child: const Icon(Icons.add, size: 16, color: kMashupAccent),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Container(height: 2, color: kMashupAccent.withValues(alpha: 0.7)),
        ],
      ),
    );
  }
}

/// Search the library for a song and drop its beat into the set.
class InsertBeatDialog extends StatefulWidget {
  final List<LibraryTrack> tracks;
  const InsertBeatDialog({super.key, required this.tracks});

  @override
  State<InsertBeatDialog> createState() => _InsertBeatDialogState();
}

class _InsertBeatDialogState extends State<InsertBeatDialog> {
  String _q = '';
  LibraryTrack? _picked;

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final hits = widget.tracks
        .where((t) => q.isEmpty || t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q))
        .take(60)
        .toList();
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E28),
      title: const Text('Add a beat'),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Search your songs…', prefixIcon: Icon(Icons.search)),
              onChanged: (v) => setState(() => _q = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: hits.length,
                itemBuilder: (_, i) {
                  final t = hits[i];
                  return ListTile(
                    dense: true,
                    selected: identical(t, _picked),
                    selectedTileColor: kMashupAccent.withValues(alpha: 0.15),
                    title: Text(t.title, overflow: TextOverflow.ellipsis),
                    subtitle: Text([t.artist, if (t.genre.isNotEmpty) t.genre, if (t.year > 0) '${t.year}'].join(' · '),
                        overflow: TextOverflow.ellipsis),
                    trailing: t.shazam ? const Text('SHAZAM', style: TextStyle(fontSize: 9, color: Colors.lightBlueAccent)) : null,
                    onTap: () => setState(() => _picked = t),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        TextButton(
          onPressed: _picked == null ? null : () => Navigator.pop(context, (_picked!, false)),
          child: const Text('Beat only'),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: kMashupAccent, foregroundColor: Colors.white),
          onPressed: _picked == null ? null : () => Navigator.pop(context, (_picked!, true)),
          child: const Text('Beat + AI vocal'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------
// SAMPLE LANE STRIP (sounds, loops and acapellas over a mashup)
// ---------------------------------------------------------
class SampleStrip extends StatelessWidget {
  final Mashup mashup;
  final List<SamplePlacement> samples;
  final bool busy;
  final void Function(LibraryTrack track) onDrop;
  final VoidCallback onAdd;
  final void Function(SamplePlacement s, void Function() change) onChange;
  final void Function(SamplePlacement s) onRemove;
  final void Function(SamplePlacement s) onToggleVocal;
  final void Function(SamplePlacement s) onToggleMelody;

  const SampleStrip({
    super.key,
    required this.mashup,
    required this.samples,
    required this.busy,
    required this.onDrop,
    required this.onAdd,
    required this.onChange,
    required this.onRemove,
    required this.onToggleVocal,
    required this.onToggleMelody,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<LibraryTrack>(
      onWillAcceptWithDetails: (_) => !busy,
      onAcceptWithDetails: (d) => onDrop(d.data),
      builder: (context, candidates, _) {
        final hover = candidates.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 320,
          margin: const EdgeInsets.only(top: 6),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: hover ? kMashupAccent.withValues(alpha: 0.18) : Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: hover ? kMashupAccent : Colors.white12, style: hover ? BorderStyle.solid : BorderStyle.solid),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final s in samples) _chip(s),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      hover ? 'Drop to add it over this mashup' : (samples.isEmpty ? 'Sample lane: drop a sound, loop or song here' : ''),
                      style: TextStyle(fontSize: 10, color: hover ? kMashupAccent : Colors.white38),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: busy ? null : onAdd,
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 6)),
                    icon: const Icon(Icons.add, size: 14),
                    label: const Text('Add sound', style: TextStyle(fontSize: 10)),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _chip(SamplePlacement s) {
    final m = mashup;
    final where = s.bar == 0
        ? 'from the start'
        : s.bar >= Mashup.introBars + m.vocalBars
            ? 'in the outro (bar ${s.bar + 1})'
            : s.bar >= Mashup.introBars
                ? 'under the vocal (bar ${s.bar + 1})'
                : 'bar ${s.bar + 1}';
    Widget btn(IconData icon, String tip, VoidCallback? onTap) => Tooltip(
          message: tip,
          child: InkWell(
            onTap: busy ? null : onTap,
            customBorder: const CircleBorder(),
            child: Padding(padding: const EdgeInsets.all(2), child: Icon(icon, size: 14, color: Colors.white70)),
          ),
        );
    Widget toggle(String label, bool on, String tip, VoidCallback? onTap) => Tooltip(
          message: tip,
          child: InkWell(
            onTap: busy ? null : onTap,
            borderRadius: BorderRadius.circular(4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: on ? kMashupAccent.withValues(alpha: 0.3) : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: on ? kMashupAccent : Colors.white24),
              ),
              child: Text(label, style: TextStyle(fontSize: 9, color: onTap == null ? Colors.white24 : (on ? Colors.white : Colors.white60))),
            ),
          ),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        color: kMashupAccent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: kMashupAccent.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(s.vocalOnly ? '🎤 ' : (s.melodyOnly ? '🎹 ' : '🎛 '), style: const TextStyle(fontSize: 11)),
              Expanded(
                child: Text(s.track.title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
              ),
              btn(Icons.close, 'Remove', () => onRemove(s)),
            ],
          ),
          Row(
            children: [
              btn(Icons.chevron_left, '4 bars earlier', s.bar >= 4 ? () => onChange(s, () => s.bar -= 4) : null),
              Text(where, style: const TextStyle(fontSize: 9, color: Colors.white60)),
              btn(Icons.chevron_right, '4 bars later', () => onChange(s, () => s.bar += 4)),
              const SizedBox(width: 6),
              btn(Icons.remove, 'Shorter', s.bars > 4 ? () => onChange(s, () => s.bars -= 4) : null),
              Text('${s.bars} bars', style: const TextStyle(fontSize: 9, color: Colors.white60)),
              btn(Icons.add, 'Longer', () => onChange(s, () => s.bars += 4)),
            ],
          ),
          Row(
            children: [
              toggle('🎤 Vocal only', s.vocalOnly, 'Play just the singing (an acapella). First time splits stems.', () => onToggleVocal(s)),
              const SizedBox(width: 4),
              toggle('🎹 Melody', s.melodyOnly,
                  'Play just the instruments — no drums, bass or vocals (e.g. an orchestra over a dance beat). First time splits stems.',
                  () => onToggleMelody(s)),
              const SizedBox(width: 4),
              toggle('Sync', s.sync, 'Lock its beat to the mashup (songs with a beat)',
                  s.canSync ? () => onChange(s, () => s.sync = !s.sync) : null),
              const SizedBox(width: 4),
              toggle(s.keyMatch && s.keyShift != 0 ? 'Key ${s.keyShift > 0 ? '+' : ''}${s.keyShift}' : 'Key',
                  s.keyMatch, 'Shift it into the key of the mashup',
                  s.canKeyMatch ? () => onChange(s, () => s.keyMatch = !s.keyMatch) : null),
            ],
          ),
          Row(
            children: [
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(trackHeight: 2, overlayShape: SliderComponentShape.noOverlay,
                      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5)),
                  child: _ReleaseSlider(
                    value: s.db,
                    min: -18,
                    max: 12,
                    color: kMashupAccent,
                    label: (v) => '${v >= 0 ? '+' : ''}${v.toStringAsFixed(0)} dB',
                    onChanged: busy ? null : (v) => onChange(s, () => s.db = v),
                  ),
                ),
              ),
              Text('${s.db >= 0 ? '+' : ''}${s.db.toStringAsFixed(0)} dB', style: const TextStyle(fontSize: 9, color: Colors.white54)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Search for a sound or song to put on the sample lane.
class AddSoundDialog extends StatefulWidget {
  final List<LibraryTrack> tracks;
  const AddSoundDialog({super.key, required this.tracks});

  @override
  State<AddSoundDialog> createState() => _AddSoundDialogState();
}

class _AddSoundDialogState extends State<AddSoundDialog> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final q = _q.toLowerCase();
    final hits = widget.tracks
        .where((t) => q.isEmpty || t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q))
        .take(80)
        .toList();
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E28),
      title: const Text('Add to the sample lane'),
      content: SizedBox(
        width: 460,
        height: 420,
        child: Column(
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Search sounds and songs (try "rain" or "fire")…', prefixIcon: Icon(Icons.search)),
              onChanged: (v) => setState(() => _q = v),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: hits.length,
                itemBuilder: (_, i) {
                  final t = hits[i];
                  return ListTile(
                    dense: true,
                    title: Text(t.title, overflow: TextOverflow.ellipsis),
                    subtitle: Text([t.artist, if (t.genre.isNotEmpty) t.genre].where((x) => x.isNotEmpty).join(' · '),
                        overflow: TextOverflow.ellipsis),
                    onTap: () => Navigator.pop(context, t),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))],
    );
  }
}

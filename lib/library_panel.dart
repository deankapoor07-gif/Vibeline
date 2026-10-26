import 'package:flutter/material.dart';

import 'mashup.dart';
import 'mashup_widgets.dart';
import 'models.dart';

/// Your songs, ready to drop into a mashup as its vocal or its beat. Songs are
/// ranked by how well they'd fit the mashup you're working on.
class LibraryPanel extends StatefulWidget {
  final List<LibraryTrack> tracks;
  final List<Mashup> mashups;
  final MashupMaker? maker;
  final int target;
  final bool asVocal;
  final bool busy;
  final String? analyseStatus;
  final void Function(int index) onTarget;
  final void Function(bool asVocal) onRole;
  final void Function(LibraryTrack song, bool asVocal) onUse;
  final VoidCallback onAnalyseAll;
  final VoidCallback onClose;
  final void Function(LibraryTrack song)? onAnchor;
  final void Function(LibraryTrack song)? onMixAround;

  const LibraryPanel({
    super.key,
    required this.tracks,
    required this.mashups,
    required this.maker,
    required this.target,
    required this.asVocal,
    required this.busy,
    required this.analyseStatus,
    required this.onTarget,
    required this.onRole,
    required this.onUse,
    required this.onAnalyseAll,
    required this.onClose,
    this.onAnchor,
    this.onMixAround,
  });

  @override
  State<LibraryPanel> createState() => _LibraryPanelState();
}

class _Fit {
  final double score;
  final String keyLabel;
  final Color keyColor;
  final double stretch;
  const _Fit(this.score, this.keyLabel, this.keyColor, this.stretch);
}

class _LibraryPanelState extends State<LibraryPanel> {
  String _q = '';
  bool _shazamOnly = false;
  bool _bestFit = true;
  // Fit scores are worked out once per (mashup, role, analysed-song count).
  Object? _fitKey;
  Map<String, _Fit?> _fits = {};

  Mashup? get _m => widget.target >= 0 && widget.target < widget.mashups.length ? widget.mashups[widget.target] : null;

  Map<String, _Fit?> _computeFits() {
    final m = _m, maker = widget.maker;
    final analysed = widget.tracks.where((t) => t.analysis != null).length;
    final key = (m, widget.asVocal, analysed);
    if (key == _fitKey) return _fits;
    _fitKey = key;
    final out = <String, _Fit?>{};
    if (m != null && maker != null) {
      for (final t in widget.tracks) {
        if (t.analysis == null) continue;
        final f = widget.asVocal
            ? maker.fit(t, m.beat, nearTempo: m.tempo)
            : (m.beatOnly ? maker.fit(t, t) : maker.fit(m.vocal, t));
        if (f == null) {
          out[t.path] = null;
          continue;
        }
        final (label, color) = f.key >= 0.99
            ? ('perfect', Colors.greenAccent)
            : f.key >= 0.8
                ? ('compatible', Colors.greenAccent)
                : f.key >= 0.45
                    ? ('loose', Colors.amber)
                    : ('clash', Colors.redAccent);
        final score = 1.5 * f.key - 5 * f.stretch.abs() - 0.1 * f.shift.abs() + (t.shazam ? 0.3 : 0);
        out[t.path] = _Fit(score, label, color, f.stretch);
      }
    }
    return _fits = out;
  }

  @override
  Widget build(BuildContext context) {
    final fits = _computeFits();
    final q = _q.toLowerCase();
    final m = _m;
    var rows = widget.tracks.where((t) {
      if (_shazamOnly && !t.shazam) return false;
      if (m != null && (identical(t, m.vocal) || identical(t, m.beat))) return false;
      return q.isEmpty || t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q) || t.genre.toLowerCase().contains(q);
    }).toList();
    if (_bestFit) {
      double rank(LibraryTrack t) => fits.containsKey(t.path) ? (fits[t.path]?.score ?? -50) : -100;
      rows.sort((a, b) => rank(b).compareTo(rank(a)));
    } else {
      rows.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    }
    final analysed = widget.tracks.where((t) => t.analysis != null).length;

    return Container(
      width: 340,
      decoration: const BoxDecoration(
        color: Color(0xFF16161D),
        border: Border(left: BorderSide(color: Colors.white12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
            child: Row(
              children: [
                const Icon(Icons.library_music, size: 18, color: kMashupAccent),
                const SizedBox(width: 8),
                Text('Your songs (${widget.tracks.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                IconButton(icon: const Icon(Icons.close, size: 18), onPressed: widget.onClose, tooltip: 'Close'),
              ],
            ),
          ),

          // Which mashup, vocal or beat
          if (widget.mashups.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  const Text('Swap into', style: TextStyle(fontSize: 11, color: Colors.white54)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButton<int>(
                      isExpanded: true,
                      isDense: true,
                      value: widget.target.clamp(0, widget.mashups.length - 1),
                      underline: const SizedBox.shrink(),
                      style: const TextStyle(fontSize: 11, color: Colors.white),
                      items: [
                        for (var i = 0; i < widget.mashups.length; i++)
                          DropdownMenuItem(
                            value: i,
                            child: Text(
                              '${i + 1}. ${widget.mashups[i].beatOnly ? 'Beat break' : widget.mashups[i].vocal.title} / ${widget.mashups[i].beat.title}',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) => v == null ? null : widget.onTarget(v),
                    ),
                  ),
                ],
              ),
            ),
          if (widget.mashups.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: SegmentedButton<bool>(
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const [
                  ButtonSegment(value: true, label: Text('🎤 Replace vocal', style: TextStyle(fontSize: 11))),
                  ButtonSegment(value: false, label: Text('🥁 Replace beat', style: TextStyle(fontSize: 11))),
                ],
                selected: {widget.asVocal},
                onSelectionChanged: (s) => widget.onRole(s.first),
              ),
            ),

          // Search + filters
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search title, artist or genre…',
                prefixIcon: Icon(Icons.search, size: 18),
                isDense: true,
              ),
              style: const TextStyle(fontSize: 12),
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Wrap(
              spacing: 6,
              children: [
                FilterChip(
                  label: const Text('Best fit first', style: TextStyle(fontSize: 10)),
                  selected: _bestFit,
                  onSelected: (v) => setState(() => _bestFit = v),
                  visualDensity: VisualDensity.compact,
                ),
                FilterChip(
                  label: const Text('My Shazams', style: TextStyle(fontSize: 10)),
                  selected: _shazamOnly,
                  onSelected: (v) => setState(() => _shazamOnly = v),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.analyseStatus ??
                        (analysed < widget.tracks.length
                            ? '$analysed of ${widget.tracks.length} songs analysed — fit is shown for those.'
                            : 'All songs analysed.'),
                    style: const TextStyle(fontSize: 9, color: Colors.white38),
                  ),
                ),
                if (widget.analyseStatus == null && analysed < widget.tracks.length)
                  TextButton(
                    onPressed: widget.onAnalyseAll,
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                    child: const Text('Analyse all', style: TextStyle(fontSize: 10)),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white12),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 4, 12, 2),
            child: Text('Drag a song onto a card\'s 🎤 or 🥁 line, or use the buttons.',
                style: TextStyle(fontSize: 9, color: Colors.white38)),
          ),

          // Songs
          Expanded(
            child: ListView.builder(
              itemCount: rows.length,
              itemBuilder: (_, i) => _row(rows[i], fits),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(LibraryTrack t, Map<String, _Fit?> fits) {
    final a = t.analysis;
    final fit = fits[t.path];
    final known = fits.containsKey(t.path);
    final details = [
      t.artist,
      if (t.genre.isNotEmpty) t.genre,
      if (t.year > 0) '${t.year}',
      if (a != null) '${a.steadyBpm.toStringAsFixed(0)} BPM · ${a.camelot}',
    ].join(' · ');
    final tile = Container(
      padding: const EdgeInsets.fromLTRB(12, 5, 4, 5),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Colors.white10))),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Flexible(child: Text(t.title, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
                  if (t.shazam)
                    const Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Text('SHAZAM', style: TextStyle(fontSize: 8, color: Colors.lightBlueAccent)),
                    ),
                ]),
                Text(details, style: const TextStyle(fontSize: 10, color: Colors.white54), overflow: TextOverflow.ellipsis),
                if (_m != null)
                  Text(
                    !known
                        ? (a == null ? 'not analysed yet (takes a moment when used)' : '')
                        : fit == null
                            ? 'tempo too far off'
                            : 'keys ${fit.keyLabel} · ${widget.asVocal ? 'vocal' : 'vocal on it'} '
                                '${fit.stretch >= 0 ? 'sped up' : 'slowed'} ${(fit.stretch.abs() * 100).toStringAsFixed(0)}%',
                    style: TextStyle(fontSize: 9, color: fit?.keyColor ?? Colors.white30),
                  ),
              ],
            ),
          ),
          if (widget.onMixAround != null) _use('✨', 'Build a new mix around this song (finds its best beat)', () => widget.onMixAround!(t)),
          if (_m != null) ...[
            _use('🎤', 'Use as the vocal of this mashup', () => widget.onUse(t, true)),
            _use('🥁', 'Use as the beat of this mashup', () => widget.onUse(t, false)),
            if (widget.onAnchor != null) _use('⚓', 'Make this the anchor beat', () => widget.onAnchor!(t)),
          ],
        ],
      ),
    );
    return Draggable<LibraryTrack>(
      data: t,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: kMashupAccent.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(6)),
          child: Text(t.title, style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold)),
        ),
      ),
      child: tile,
    );
  }

  Widget _use(String icon, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: InkWell(
          onTap: widget.busy ? null : onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(padding: const EdgeInsets.all(5), child: Text(icon, style: const TextStyle(fontSize: 15))),
        ),
      );
}

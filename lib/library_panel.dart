import 'package:flutter/material.dart';

import 'mashup.dart';
import 'mashup_widgets.dart';
import 'models.dart';

enum SongSort { bestFit, bpm, key, title, artist, genre, time }

/// Songs in order of a sort; songs not analysed yet go last.
void sortSongs(List<LibraryTrack> rows, SongSort sort, {double Function(LibraryTrack)? fit}) {
  // Quote marks and the like don't count, so "Hello" files under H.
  String plain(String t) => t.toLowerCase().replaceFirst(RegExp(r'^[^a-z0-9]+'), '');
  int title(LibraryTrack a, LibraryTrack b) => plain(a.title).compareTo(plain(b.title));
  int byNumber(LibraryTrack a, LibraryTrack b, double? Function(LibraryTrack) of) {
    final x = of(a), y = of(b);
    if (x == null || y == null) return x == y ? title(a, b) : (x == null ? 1 : -1);
    return x == y ? title(a, b) : x.compareTo(y);
  }

  switch (sort) {
    case SongSort.bestFit:
      rows.sort((a, b) => fit!(b).compareTo(fit(a)));
    case SongSort.bpm:
      rows.sort((a, b) => byNumber(a, b, (t) => t.analysis?.steadyBpm));
    case SongSort.key:
      rows.sort((a, b) => byNumber(a, b, (t) => camelotOrder(t.analysis?.camelot)));
    case SongSort.title:
      rows.sort(title);
    case SongSort.artist:
      rows.sort((a, b) {
        final c = a.artist.toLowerCase().compareTo(b.artist.toLowerCase());
        return c != 0 ? c : title(a, b);
      });
    case SongSort.genre:
      rows.sort((a, b) {
        if (a.genre.isEmpty != b.genre.isEmpty) return a.genre.isEmpty ? 1 : -1;
        final c = a.genre.toLowerCase().compareTo(b.genre.toLowerCase());
        return c != 0 ? c : title(a, b);
      });
    case SongSort.time:
      rows.sort((a, b) => byNumber(a, b, (t) => t.duration));
  }
}

/// 1A, 1B, 2A… so songs that mix well sit together; null if there's no key.
double? camelotOrder(String? camelot) {
  final m = RegExp(r'^(\d+)([AB])$').firstMatch(camelot ?? '');
  if (m == null) return null;
  return int.parse(m[1]!) + (m[2] == 'B' ? 0.5 : 0);
}

/// Your songs, ready to drop into a mashup as its vocal or its beat. Songs are
/// ranked by how well they'd fit the mashup you're working on.
/// The note about songs left out because they're only in iCloud.
String iCloudNote(int n) => n == 1
    ? "1 song is only in iCloud, so it's left out of your sets. Download it in Finder to use it."
    : "$n songs are only in iCloud, so they're left out of your sets. Download them in Finder to use them.";

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
  final bool wide; // across the bottom, as a table

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
    this.wide = false,
  });

  @override
  State<LibraryPanel> createState() => _LibraryPanelState();
}

const kTealText = Color(0xFF7FE3D4);
const kRigAmberText = Color(0xFFFF9F1C);

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
  SongSort? _chosenSort; // nothing chosen: best fit if there's a mashup, else A-Z
  SongSort get _sort => _chosenSort ?? (_m != null ? SongSort.bestFit : SongSort.title);
  set _sort(SongSort s) => _chosenSort = s;
  // Sorted once per change, so a big library stays smooth while music plays.
  Object? _rowsKey;
  List<LibraryTrack> _rows = const [];
  // Fit scores are worked out once per (mashup, role, analysed-song count).
  Object? _fitKey;
  Map<String, _Fit?> _fits = {};

  int _unreadable = 0;
  String _unreadableNote() => _unreadable == 0 ? '' : ' ($_unreadable couldn\'t be read)';

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
    final known = widget.tracks.where((t) => t.analysis != null).length;
    final rowsKey = Object.hashAll([q, _shazamOnly, _sort, m, _fitKey, widget.tracks.length, known]);
    if (rowsKey != _rowsKey) {
      _rowsKey = rowsKey;
      _rows = widget.tracks.where((t) {
        if (_shazamOnly && !t.shazam) return false;
        if (m != null && (identical(t, m.vocal) || identical(t, m.beat))) return false;
        return q.isEmpty || t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q) || t.genre.toLowerCase().contains(q);
      }).toList();
      double rank(LibraryTrack t) => fits.containsKey(t.path) ? (fits[t.path]?.score ?? -50) : -100;
      sortSongs(_rows, _sort, fit: rank);
    }
    final rows = _rows;
    // Songs that couldn't be read (damaged or odd files) count as done: the
    // analyser has tried them and there's nothing more Analyse all can do.
    final unreadable = widget.tracks.where((t) => t.analysis == null && t.analysisTried && !t.inCloud).length;
    final analysed = widget.tracks.where((t) => t.analysis != null).length + unreadable;
    final inCloud = widget.tracks.where((t) => t.inCloud).length;
    final usable = widget.tracks.length - inCloud;
    _unreadable = unreadable;
    if (widget.wide) return _table(rows, fits, analysed, inCloud, usable);

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
                  ButtonSegment(value: true, icon: Icon(Icons.mic, size: 14), label: Text('Replace vocal', style: TextStyle(fontSize: 11))),
                  ButtonSegment(value: false, icon: Icon(Icons.graphic_eq, size: 14), label: Text('Replace beat', style: TextStyle(fontSize: 11))),
                ],
                selected: {widget.asVocal},
                onSelectionChanged: (s) => widget.onRole(s.first),
              ),
            ),

          // Search + filters
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: TextField(
              onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
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
                for (final (sort, label) in const [
                  (SongSort.bestFit, 'Best fit'),
                  (SongSort.bpm, 'BPM'),
                  (SongSort.key, 'Key'),
                  (SongSort.title, 'A–Z'),
                ])
                  ChoiceChip(
                    label: Text(label, style: const TextStyle(fontSize: 10)),
                    selected: _sort == sort,
                    onSelected: (_) => setState(() => _sort = sort),
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
                        (analysed < usable
                            ? '$analysed of $usable songs analysed — fit is shown for those.'
                            : 'All songs analysed.${_unreadableNote()}'),
                    style: const TextStyle(fontSize: 9, color: Colors.white38),
                  ),
                ),
                if (widget.analyseStatus == null && analysed < usable)
                  TextButton(
                    onPressed: widget.onAnalyseAll,
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                    child: const Text('Analyse all', style: TextStyle(fontSize: 10)),
                  ),
              ],
            ),
          ),
          if (inCloud > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
              child: Tooltip(
                message: 'In Finder, click the cloud icon next to a song to download it, then reopen this app.\n'
                    'Downloaded songs take up space on your Mac.',
                child: Text(
                  iCloudNote(inCloud),
                  style: const TextStyle(fontSize: 11, color: Colors.white70),
                ),
              ),
            ),
          const Divider(height: 1, color: Colors.white12),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 4, 12, 2),
            child: Text('Drag a song onto a card\'s vocal or beat line, or use the buttons.',
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

  // ------------------------------------------- Across the bottom, as a table

  static const _time = 54.0, _bpm = 50.0, _key = 44.0;

  Widget _side(String label, IconData icon, bool on, VoidCallback onTap) => InkWell(
        onTap: onTap,
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          color: on ? const Color(0xFF2A2A34) : null,
          child: Row(children: [
            Icon(icon, size: 14, color: Colors.white70),
            const SizedBox(width: 8),
            Text(label, style: const TextStyle(fontSize: 12, color: Colors.white)),
          ]),
        ),
      );

  Widget _head(String label, SongSort sort, {double? width, int flex = 0, bool right = false}) {
    final on = _sort == sort;
    final cell = InkWell(
      onTap: () => setState(() => _sort = sort),
      child: Row(
        mainAxisAlignment: right ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(
            child: Text(
              label.toUpperCase(),
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, letterSpacing: 0.7, fontWeight: FontWeight.w700, color: on ? Colors.white : Colors.white54),
            ),
          ),
          if (on) const Icon(Icons.arrow_drop_down, size: 14, color: Colors.white),
        ],
      ),
    );
    return width != null ? SizedBox(width: width, child: cell) : Expanded(flex: flex, child: cell);
  }

  static String _clock(double s) {
    final t = s.round();
    return '${t ~/ 60}:${(t % 60).toString().padLeft(2, '0')}';
  }

  Widget _tableRow(LibraryTrack t, Map<String, _Fit?> fits, bool odd) {
    final a = t.analysis;
    final fit = fits[t.path];
    final dim = t.inCloud;
    final main = TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: dim ? Colors.white38 : Colors.white);
    final soft = TextStyle(fontSize: 12, color: dim ? Colors.white30 : Colors.white70);
    final row = Container(
      height: 30,
      color: odd ? const Color(0xFF131319) : null,
      padding: const EdgeInsets.only(left: 10, right: 4),
      child: Row(children: [
        Expanded(
          flex: 5,
          child: Row(children: [
            if (dim)
              const Tooltip(
                message: 'Only in iCloud. Download it in Finder, then reopen this app.',
                child: Padding(padding: EdgeInsets.only(right: 6), child: Icon(Icons.cloud_outlined, size: 14, color: Colors.white38)),
              ),
            Flexible(child: Text(t.title, overflow: TextOverflow.ellipsis, maxLines: 1, style: main)),
            if (t.shazam)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Text('SHAZAM', style: TextStyle(fontSize: 8, color: Colors.lightBlueAccent)),
              ),
          ]),
        ),
        const SizedBox(width: 8),
        Expanded(flex: 3, child: Text(t.artist, overflow: TextOverflow.ellipsis, maxLines: 1, style: soft)),
        const SizedBox(width: 8),
        Expanded(flex: 2, child: Text(t.genre, overflow: TextOverflow.ellipsis, maxLines: 1, style: soft)),
        SizedBox(width: _time, child: Text(t.duration > 0 ? _clock(t.duration) : '', textAlign: TextAlign.right, style: soft)),
        SizedBox(width: _bpm, child: Text(a == null ? '' : a.steadyBpm.toStringAsFixed(0), textAlign: TextAlign.right, style: soft)),
        SizedBox(
          width: _key,
          child: Text(a?.camelot ?? '', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fit?.keyColor ?? kTealText)),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 104,
          child: t.inCloud
              ? null
              : Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if (_m != null) ...[
                    _use(Icons.mic, 'Use as the vocal of this mashup', () => widget.onUse(t, true)),
                    _use(Icons.graphic_eq, 'Use as the beat of this mashup', () => widget.onUse(t, false)),
                    if (widget.onAnchor != null) _use(Icons.anchor, 'Make this the anchor beat', () => widget.onAnchor!(t)),
                  ],
                  if (widget.onMixAround != null) _use(Icons.queue_music, 'Build a new mix around this song (finds its best beat)', () => widget.onMixAround!(t)),
                ]),
        ),
      ]),
    );
    return row;
  }

  Widget _table(List<LibraryTrack> rows, Map<String, _Fit?> fits, int analysed, int inCloud, int usable) {
    final status = widget.analyseStatus ?? (analysed < usable ? '$analysed of $usable songs analysed' : 'All songs analysed${_unreadableNote()}');
    return Container(
      decoration: const BoxDecoration(color: Color(0xFF0E0E13), border: Border(top: BorderSide(color: Colors.white12))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Left: which songs
          Container(
            width: 190,
            decoration: const BoxDecoration(border: Border(right: BorderSide(color: Colors.white12))),
            child: ListView(padding: const EdgeInsets.all(6), children: [
              _side('All songs', Icons.library_music, !_shazamOnly, () => setState(() => _shazamOnly = false)),
              _side('My Shazams', Icons.bolt, _shazamOnly, () => setState(() => _shazamOnly = true)),
              const SizedBox(height: 8),
              if (_m != null) ...[
                InkWell(
                  onTap: () => setState(() => _sort = SongSort.bestFit),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Text('BEST FIT FIRST', style: TextStyle(fontSize: 10, letterSpacing: 0.7, fontWeight: FontWeight.w700, color: _sort == SongSort.bestFit ? kRigAmberText : Colors.white54)),
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(status, style: const TextStyle(fontSize: 10, color: Colors.white54)),
              ),
              if (widget.analyseStatus == null && analysed < usable)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(onPressed: widget.onAnalyseAll, child: const Text('Analyse all', style: TextStyle(fontSize: 11))),
                ),
              if (inCloud > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
                  child: Text(iCloudNote(inCloud), style: const TextStyle(fontSize: 10, color: Colors.white54)),
                ),
            ]),
          ),
          // Right: the songs
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(children: [
                    Text('${rows.length} SONGS', style: const TextStyle(fontSize: 11, letterSpacing: 0.7, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: TextField(
                        onTapOutside: (_) => FocusManager.instance.primaryFocus?.unfocus(),
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          hintText: 'Search title, artist or genre…',
                          hintStyle: TextStyle(fontSize: 12, color: Colors.white54),
                          prefixIcon: Icon(Icons.search, size: 15),
                          prefixIconConstraints: BoxConstraints(minWidth: 24),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() => _q = v),
                      ),
                    ),
                  ]),
                ),
                Container(
                  height: 22,
                  padding: const EdgeInsets.only(left: 10, right: 4),
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: Colors.white12), bottom: BorderSide(color: Colors.white12))),
                  child: Row(children: [
                    _head('Title', SongSort.title, flex: 5),
                    const SizedBox(width: 8),
                    _head('Artist', SongSort.artist, flex: 3),
                    const SizedBox(width: 8),
                    _head('Genre', SongSort.genre, flex: 2),
                    _head('Time', SongSort.time, width: _time, right: true),
                    _head('BPM', SongSort.bpm, width: _bpm, right: true),
                    _head('Key', SongSort.key, width: _key, right: true),
                    const SizedBox(width: 112),
                  ]),
                ),
                Expanded(
                  child: ListView.builder(
                    itemExtent: 30,
                    itemCount: rows.length,
                    itemBuilder: (_, i) => _tableRow(rows[i], fits, i.isOdd),
                  ),
                ),
              ],
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
                if (t.inCloud)
                  const Text('In iCloud: download it in Finder to use it',
                      style: TextStyle(fontSize: 10, color: Colors.white54)),
                if (a != null)
                  Text('${a.steadyBpm.toStringAsFixed(0)} BPM · ${a.key}${a.camelot.isEmpty ? '' : ' · ${a.camelot}'}',
                      style: const TextStyle(fontSize: 10, color: kTealText)),
                if (_m != null && !t.inCloud)
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
          if (widget.onMixAround != null && !t.inCloud) _use(Icons.queue_music, 'Build a new mix around this song (finds its best beat)', () => widget.onMixAround!(t)),
          if (_m != null && !t.inCloud) ...[
            _use(Icons.mic, 'Use as the vocal of this mashup', () => widget.onUse(t, true)),
            _use(Icons.graphic_eq, 'Use as the beat of this mashup', () => widget.onUse(t, false)),
            if (widget.onAnchor != null) _use(Icons.anchor, 'Make this the anchor beat', () => widget.onAnchor!(t)),
          ],
        ],
      ),
    );
    if (t.inCloud) return tile;
    return Draggable<LibraryTrack>(
      data: t,
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: kMashupAccent.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(3)),
          child: Text(t.title, style: const TextStyle(fontSize: 12, color: Colors.white, fontWeight: FontWeight.bold)),
        ),
      ),
      child: tile,
    );
  }

  Widget _use(IconData icon, String tip, VoidCallback onTap) => Tooltip(
        message: tip,
        child: InkWell(
          onTap: widget.busy ? null : onTap,
          borderRadius: BorderRadius.circular(3),
          child: Padding(padding: const EdgeInsets.all(5), child: Icon(icon, size: 16, color: Colors.white70)),
        ),
      );
}

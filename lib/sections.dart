import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'library.dart';
import 'mixer.dart';

/// A stretch of the set rendered as its own file. Cuts sit where a blend has
/// just finished, so neighbouring sections render identically around the cut
/// and join seamlessly.
class Section {
  final double start;
  final double end; // includes the short crossfade tail
  final Map<String, dynamic> json;
  final String hash;
  String? path;
  String? voxPath; // the vocal layer, when the section has featured vocals
  Section(this.start, this.end, this.json, this.hash);

  void found(String file) {
    path = file;
    final vox = File('$file.vox.m4a');
    voxPath = vox.existsSync() ? vox.path : null;
  }
}

/// Splits a set into sections, renders only the ones that changed (nearest
/// the playhead first) and keeps the player's timeline up to date. This is
/// what makes edits quick and lets a set run for hours.
class SectionEngine {
  static const crossfade = 0.02;
  final Mixer mixer;
  final double Function() playhead;
  void Function()? onChanged;

  List<Section> sections = [];
  bool _working = false;
  int _version = 0;
  Section? _rendering;
  final Map<String, int> _failures = {};

  SectionEngine(this.mixer, this.playhead);

  static String get dir => '${MusicLibrary.home}/Library/Caches/Vibeline/sections';

  int get ready => sections.where((s) => s.path != null).length;
  bool get allReady => sections.isNotEmpty && ready == sections.length;

  /// Seconds of audio ready from the playhead onwards without a gap.
  double get readyAhead {
    final p = playhead();
    var t = p;
    for (final s in sections) {
      if (s.end <= p) continue;
      if (s.path == null) break;
      t = s.end;
    }
    return t - p;
  }

  /// Clean out old renders (call once at startup).
  static void prune() {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return;
      final cutoff = DateTime.now().subtract(const Duration(days: 10));
      for (final f in d.listSync().whereType<File>()) {
        if (f.lastModifiedSync().isBefore(cutoff) || f.path.endsWith('.part.m4a')) f.deleteSync();
      }
    } catch (_) {}
  }

  /// Takes a whole-set render plan plus cut times and brings the sections up
  /// to date. Unchanged sections are reused straight from disk.
  Future<void> setPlan(Map<String, dynamic> plan, List<double> cuts, {List<List<double>>? remap}) async {
    _version++;
    await Directory(dir).create(recursive: true);
    final duration = (plan['duration'] as num).toDouble();
    final clips = (plan['clips'] as List).cast<Map<String, dynamic>>();
    final bounds = [0.0, ...cuts.where((c) => c > 0.5 && c < duration - 0.5), duration];
    final out = <Section>[];
    for (var k = 0; k + 1 < bounds.length; k++) {
      final t0 = bounds[k], t1 = bounds[k + 1];
      final last = k + 2 == bounds.length;
      final end = last ? t1 : t1 + crossfade;
      final preRoll = k == 0 ? 0.0 : _preRoll(clips, t0);
      final window = {
        'start': t0,
        'end': end,
        'preRoll': preRoll,
        'fadeIn': k == 0 ? 0.0 : crossfade,
        'fadeOut': last ? 0.0 : crossfade,
      };
      final used = clips.where((c) {
        final s = (c['outStart'] as num).toDouble();
        return s < end && _clipEnd(c) + 4 > t0 - preRoll;
      }).toList();
      final json = <String, dynamic>{
        'format': 'alac1', // bump to re-render every section after an engine change
        'duration': end,
        'clips': used,
        if (plan['warmth'] != null) 'warmth': plan['warmth'],
        'window': window,
      };
      final canonical = jsonEncode(_round(json));
      final hash = _fnv(canonical);
      final s = Section(t0, end, json, hash);
      final f = File('$dir/$hash.m4a');
      if (f.existsSync()) s.found(f.path);
      out.add(s);
    }
    sections = out;
    await _pushTimeline(remap: remap);
    onChanged?.call();
    // If a render is busy with something no longer most urgent (e.g. a section
    // far ahead, while you just edited the one playing), drop it.
    final busy = _rendering;
    if (busy != null) {
      final next = _nextTodo();
      if (next != null && next.hash != busy.hash) mixer.cancel(out: '$dir/${busy.hash}.m4a');
    }
    _pump();
  }

  /// The unrendered section that matters most: the one under the playhead,
  /// then the ones coming up, then anything already played.
  Section? _nextTodo() {
    final p = playhead();
    final todo = sections.where((s) => s.path == null && (_failures[s.hash] ?? 0) < 3).toList();
    if (todo.isEmpty) return null;
    double rank(Section s) => s.end < p ? 1e9 + (p - s.end) : math.max(0, s.start - p);
    todo.sort((a, b) => rank(a).compareTo(rank(b)));
    return todo.first;
  }

  /// Warm-up needed before a cut: back to the start of every clip still
  /// playing there, so they render from their true beginning.
  double _preRoll(List<Map<String, dynamic>> clips, double cut) {
    var earliest = cut - 2;
    for (final c in clips) {
      final s = (c['outStart'] as num).toDouble();
      if (s < cut && _clipEnd(c) > cut + 0.2) earliest = math.min(earliest, s);
    }
    return (cut - earliest + 1.5).clamp(2.0, 90.0);
  }

  static double _clipEnd(Map<String, dynamic> c) {
    final warp = c['warp'] as List?;
    final srcStart = (c['srcStart'] as num).toDouble(), srcEnd = (c['srcEnd'] as num).toDouble();
    if (warp != null && warp.length >= 2) {
      final a = (warp[warp.length - 2] as List).cast<num>(), b = (warp.last as List).cast<num>();
      final slope = (b[1] - a[1]) / math.max(1e-6, (b[0] - a[0]).toDouble());
      return b[0] + (srcEnd - b[1]) / math.max(1e-6, slope);
    }
    return (c['outStart'] as num).toDouble() + (srcEnd - srcStart) / (c['rate'] as num).toDouble();
  }

  List<Map<String, dynamic>> get _rows => [
        for (final s in sections) {'path': s.path, 'voxPath': s.voxPath, 'start': s.start, 'end': s.end}
      ];

  Future<void> _pushTimeline({List<List<double>>? remap}) => mixer.setTimeline(_rows, remap: remap);

  /// Renders missing sections one at a time, closest to the playhead first.
  Future<void> _pump() async {
    if (_working) return;
    _working = true;
    try {
      while (true) {
        final s = _nextTodo();
        if (s == null) break;
        final version = _version;
        final file = '$dir/${s.hash}.m4a';
        _rendering = s;
        try {
          await mixer.render(s.json, out: file, reportProgress: false);
        } catch (_) {
          // Cancelled for something more urgent, or the plan changed: next pass.
          _rendering = null;
          if (version == _version && sections.contains(s)) {
            // Not cancelled for something newer: count it as a failure.
            _failures[s.hash] = (_failures[s.hash] ?? 0) + 1;
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
          continue;
        }
        _rendering = null;
        // The plan may have changed while rendering; any section with the same
        // content can still use the file.
        for (final x in sections) {
          if (x.hash == s.hash) x.found(file);
        }
        await _pushTimeline();
        onChanged?.call();
      }
    } finally {
      _working = false;
    }
  }

  /// Joins every section into one file (for saving).
  Future<void> export(String out, Map<String, dynamic> live) => mixer.exportTimeline(_rows, live, out);

  static dynamic _round(dynamic v) {
    if (v is double) return (v * 1e6).round() / 1e6;
    if (v is List) return v.map(_round).toList();
    if (v is Map) return v.map((k, x) => MapEntry(k, _round(x)));
    return v;
  }

  static String _fnv(String s) {
    // 64-bit FNV-1a, enough to tell section contents apart.
    var h1 = 0x811c9dc5, h2 = 0x01000193 ^ 0x5bd1e995;
    for (final c in utf8.encode(s)) {
      h1 = ((h1 ^ c) * 0x01000193) & 0xffffffff;
      h2 = ((h2 ^ c) * 0x01000193 + (h1 >> 7)) & 0xffffffff;
    }
    return '${h1.toRadixString(16).padLeft(8, '0')}${h2.toRadixString(16).padLeft(8, '0')}';
  }
}

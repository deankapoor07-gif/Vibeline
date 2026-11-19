// What the last few sets used, so the next one sounds different: the same
// vocal over the same beat is avoided most, then songs heard recently.
import 'dart:convert';
import 'dart:io';

import 'library.dart';
import 'models.dart';

class RecentSets {
  static const keep = 6;
  static List<List<List<String>>> _sets = []; // newest first; each: [[vocal, beat], ...]
  static String? _dir;

  static File get _file => File('${_dir ?? MusicLibrary.supportDir}/recent_sets.json');

  static void load({String? dir}) {
    _dir = dir;
    try {
      final j = jsonDecode(_file.readAsStringSync()) as List;
      _sets = [
        for (final s in j) [for (final p in s as List) (p as List).cast<String>()]
      ];
    } catch (_) {
      _sets = [];
    }
  }

  static void record(Iterable<(LibraryTrack, LibraryTrack)> pairs) {
    final set = [for (final (v, b) in pairs) [v.path, b.path]];
    if (set.isEmpty) return;
    _sets = [set, ..._sets].take(keep).toList();
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode(_sets));
    } catch (_) {}
  }

  /// How much to hold a pairing back: up to 2.5 for the exact pairing from the
  /// last set, less for songs heard recently, fading over [keep] sets.
  static double penalty(LibraryTrack vocal, LibraryTrack beat) {
    var p = 0.0;
    for (var k = 0; k < _sets.length; k++) {
      final fade = 1 - k / keep;
      for (final pair in _sets[k]) {
        if (pair[0] == vocal.path && pair[1] == beat.path) p += 2.5 * fade;
        if (pair[0] == vocal.path || pair[1] == vocal.path) p += 0.7 * fade;
        if (pair[0] == beat.path || pair[1] == beat.path) p += 0.5 * fade;
      }
    }
    return p;
  }

  static void clearForTest() => _sets = [];
}

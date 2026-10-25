import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;

import 'models.dart';

/// Finds songs, works out which ones Dean Shazamed, and runs the Python
/// analyser (tempo, beats, key, energy) on the ones a mix needs.
class MusicLibrary {
  static final String home = Platform.environment['HOME'] ?? '';
  static final String supportDir = '$home/Library/Application Support/Vibeline';
  static final String python = '$supportDir/venv/bin/python';
  static final String defaultFolder = '$home/Desktop/Test Music';

  /// Your own files in the Music app (bought or added songs and sounds;
  /// streamed Apple Music songs are copy-protected and live elsewhere).
  static final String musicAppFolder = '$home/Music/Music/Media.localized/Music';

  final List<LibraryTrack> tracks = [];
  String folder = defaultFolder;
  bool useMusicApp = true; // also scan the Music app's own files
  int shazamMatches = 0;
  String? _script;

  Future<void> loadSettings() async {
    try {
      final f = File('$supportDir/settings.json');
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        folder = (j['folder'] as String?) ?? folder;
        useMusicApp = (j['useMusicApp'] as bool?) ?? useMusicApp;
      }
    } catch (_) {}
  }

  Future<void> saveSettings() async {
    await Directory(supportDir).create(recursive: true);
    await File('$supportDir/settings.json').writeAsString(jsonEncode({'folder': folder, 'useMusicApp': useMusicApp}));
  }

  /// Problems that stop Vibeline from mixing, in plain words, or null if ready.
  Future<String?> checkSetup() async {
    if (!await File(python).exists()) {
      return 'The music analyser isn\'t installed (expected at $python).';
    }
    if (!await Directory(folder).exists()) {
      return 'Can\'t find your music folder: $folder';
    }
    return null;
  }

  Future<String> _scriptPath() async {
    if (_script != null) return _script!;
    await Directory(supportDir).create(recursive: true);
    final path = '$supportDir/vibeline_ai.py';
    await File(path).writeAsString(await rootBundle.loadString('assets/vibeline_ai.py'));
    return _script = path;
  }

  Stream<Map<String, dynamic>> _run(List<String> args) async* {
    final script = await _scriptPath();
    // The helper watches this app's process id and quits if the app closes.
    final proc = await Process.start(python, ['-I', script, ...args],
        environment: {'VIBELINE_APP_PID': '$pid'});
    proc.stderr.drain<void>();
    await for (final line in proc.stdout.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.trim().isEmpty) continue;
      try {
        yield jsonDecode(line) as Map<String, dynamic>;
      } catch (_) {}
    }
    await proc.exitCode;
  }

  Future<void> scan() async {
    final previous = {for (final t in tracks) t.path: t.analysis};
    tracks.clear();
    final folders = [
      folder,
      if (useMusicApp && musicAppFolder != folder && Directory(musicAppFolder).existsSync()) musicAppFolder,
    ];
    await for (final row in _run(['tags', ...folders])) {
      if (row['type'] != 'tags') continue;
      final t = LibraryTrack.fromJson(row);
      t.analysis = previous[t.path];
      tracks.add(t);
    }
    await _markShazam();
  }

  /// Analyses any of [wanted] not yet analysed. Cached on disk by the script,
  /// so songs only take time the first time they're used.
  Future<void> analyze(List<LibraryTrack> wanted, void Function(int done, int total) onProgress) async {
    final todo = wanted.where((t) => t.analysis == null && !t.analysisTried).toList();
    if (todo.isEmpty) return;
    final byPath = {for (final t in todo) t.path: t};
    var done = 0;
    onProgress(0, todo.length);
    await for (final row in _run(['analyze', ...byPath.keys])) {
      if (row['type'] != 'analysis') continue;
      done++;
      final t = byPath[row['path']];
      if (t != null) {
        t.analysisTried = true;
        t.level = (row['loudnessDb'] as num?)?.toDouble();
        t.tuningHz = (row['tuning'] as num?)?.toDouble();
        t.waveform = ((row['waveform'] as List?) ?? const []).map((e) => (e as num).toDouble()).toList();
        if (row['ok'] == true) {
          try {
            t.analysis = Analysis.fromJson(row)..gridOffset = t.stems?.gridOffset ?? 0;
          } catch (_) {}
        }
      }
      onProgress(done, todo.length);
    }
  }

  /// Splits songs into stems (about 25 s a song the first time; cached after).
  Future<void> separate(List<LibraryTrack> wanted, void Function(int done, int total, LibraryTrack? current) onProgress) async {
    final todo = wanted.where((t) => t.stems == null).toList();
    if (todo.isEmpty) return;
    final byPath = {for (final t in todo) t.path: t};
    var done = 0;
    onProgress(0, todo.length, todo.first);
    await for (final row in _run(['separate', ...byPath.keys])) {
      if (row['type'] != 'stems') continue;
      done++;
      final t = byPath[row['path']];
      if (t != null && row['ok'] == true) {
        final s = StemSet.fromJson(row);
        if (s.complete) {
          t.stems = s;
          t.analysis?.gridOffset = s.gridOffset;
        }
      }
      onProgress(done, todo.length, done < todo.length ? todo[done] : null);
    }
  }

  // ------------------------------------------------------- Shazam

  static String norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '')
      .replaceAll(RegExp(r'\b(feat|ft)\..*'), '')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');

  static String _firstArtist(String s) =>
      norm(s.toLowerCase().split(RegExp(r',|&| x | and |feat|ft\.|with')).first);

  Future<List<List<String>>> _shazamSongs() async {
    final cache = File('$supportDir/shazam.json');
    List<List<String>> fromCache() {
      try {
        return (jsonDecode(cache.readAsStringSync()) as List)
            .map((e) => (e as List).map((x) => x.toString()).toList())
            .toList();
      } catch (_) {
        return [];
      }
    }

    final fresh = cache.existsSync() &&
        DateTime.now().difference(cache.lastModifiedSync()) < const Duration(hours: 12);
    if (fresh) return fromCache();

    const script = '''
tell application "Music"
  set out to ""
  repeat with pl in (every playlist whose name contains "Shazam")
    set ns to name of every track of pl
    set ars to artist of every track of pl
    repeat with i from 1 to count of ns
      set out to out & (item i of ns) & tab & (item i of ars) & linefeed
    end repeat
  end repeat
  return out
end tell''';
    try {
      final r = await Process.run('osascript', ['-e', script]).timeout(const Duration(seconds: 60));
      if (r.exitCode == 0) {
        final rows = (r.stdout as String)
            .split('\n')
            .map((l) => l.split('\t'))
            .where((p) => p.length >= 2 && p[0].isNotEmpty)
            .map((p) => [p[0], p[1]])
            .toList();
        if (rows.isNotEmpty) {
          await Directory(supportDir).create(recursive: true);
          await cache.writeAsString(jsonEncode(rows));
          return rows;
        }
      }
    } catch (_) {}
    return fromCache();
  }

  Future<void> _markShazam() async {
    final songs = await _shazamSongs();
    final byTitle = <String, List<String>>{};
    for (final s in songs) {
      byTitle.putIfAbsent(norm(s[0]), () => []).add(_firstArtist(s[1]));
    }
    shazamMatches = 0;
    for (final t in tracks) {
      final artists = byTitle[norm(t.title)];
      if (artists == null) continue;
      final a = _firstArtist(t.artist);
      t.shazam = artists.any((x) => x.isEmpty || a.isEmpty || x.contains(a) || a.contains(x));
      if (t.shazam) shazamMatches++;
    }
  }
}

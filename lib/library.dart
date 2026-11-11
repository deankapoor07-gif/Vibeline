import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart' show rootBundle;

import 'models.dart';

/// Estimates the time left from how fast songs are finishing. Songs analysed
/// before finish almost instantly, so those don't count towards the pace.
class ProgressClock {
  ProgressClock({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final List<int> _gapsMs = [];
  DateTime? _last;
  bool _working = false;

  /// Call as each song finishes; returns e.g. " · about 12 min left", or an
  /// empty string until there's enough to go on.
  String tick(int done, int total) {
    final now = _now();
    if (_last != null) {
      final gap = now.difference(_last!).inMilliseconds;
      // Songs already known rush past at the start and say nothing about speed.
      // After that, songs finishing together still count, or the wait reads long.
      if (gap >= 50) _working = true;
      if (_working) {
        _gapsMs.add(gap);
        if (_gapsMs.length > 30) _gapsMs.removeAt(0);
      }
    }
    _last = now;
    if (_gapsMs.length < 8 || done >= total) return '';
    final perSong = _gapsMs.reduce((a, b) => a + b) / _gapsMs.length;
    final minutes = ((total - done) * perSong / 60000).ceil();
    if (minutes <= 1) return ' · under a minute left';
    if (minutes < 60) return ' · about $minutes min left';
    final mins = minutes % 60;
    return ' · about ${minutes ~/ 60} hr${mins == 0 ? '' : ' $mins min'} left';
  }
}

/// Finds songs, works out which ones Dean Shazamed, and runs the Python
/// analyser (tempo, beats, key, energy) on the ones a mix needs.
class MusicLibrary {
  static final String home = Platform.environment['HOME'] ?? '';
  static final String supportDir = '$home/Library/Application Support/Vibeline';
  /// The analyser's Python: the copy inside the app (Contents/Resources/helper,
  /// added by tool/bundle_helper.sh), or, in a development build, the venv
  /// set up by hand on Dean's Mac.
  static final String python = () {
    final contents = File(Platform.resolvedExecutable).parent.parent.path;
    final bundled = '$contents/Resources/helper/python/bin/python3';
    return File(bundled).existsSync() ? bundled : '$supportDir/venv/bin/python';
  }();
  static final String defaultFolder = '$home/Desktop/Test Music';

  /// Your own files in the Music app (bought or added songs and sounds;
  /// streamed Apple Music songs are copy-protected and live elsewhere).
  static final String musicAppFolder = '$home/Music/Music/Media.localized/Music';

  final List<LibraryTrack> tracks = [];
  String folder = defaultFolder;
  bool useMusicApp = true; // also scan the Music app's own files
  /// Look for music everywhere in your home folder and on plugged-in drives,
  /// instead of one folder.
  bool wholeMac = true;
  int shazamMatches = 0;
  String? _script;

  Future<void> loadSettings() async {
    try {
      final f = File('$supportDir/settings.json');
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        folder = (j['folder'] as String?) ?? folder;
        useMusicApp = (j['useMusicApp'] as bool?) ?? useMusicApp;
        wholeMac = (j['wholeMac'] as bool?) ?? wholeMac;
      }
    } catch (_) {}
  }

  Future<void> saveSettings() async {
    await Directory(supportDir).create(recursive: true);
    await File('$supportDir/settings.json').writeAsString(jsonEncode({'folder': folder, 'useMusicApp': useMusicApp, 'wholeMac': wholeMac}));
  }

  /// Problems that stop Vibeline from mixing, in plain words, or null if ready.
  Future<String?> checkSetup() async {
    if (!await File(python).exists()) {
      return 'The music analyser isn\'t installed (expected at $python).';
    }
    if (!wholeMac && !await Directory(folder).exists()) {
      return 'Can\'t find your music folder: $folder';
    }
    return null;
  }

  /// Downloads the AI models the analyser needs if this Mac doesn't have them
  /// yet (about 1 GB, first run only). [progress] gets a status line and a
  /// 0–1 fraction. Returns a problem in plain words, or null when ready.
  Future<String?> ensureModels(void Function(String status, double? fraction) progress) async {
    var missing = 0;
    await for (final row in _run(['models'])) {
      if (row['type'] == 'models') missing = (row['mb'] as num?)?.toInt() ?? 0;
    }
    if (missing == 0) return null;
    var done = 0;
    String? problem = 'The AI models didn\'t finish downloading. Check the internet connection and try again.';
    progress('Getting the AI ready, first time only · downloading about $missing MB…', 0);
    await for (final row in _run(['getmodels'])) {
      if (row['type'] == 'model' && row['state'] == 'done') {
        done += (row['mb'] as num?)?.toInt() ?? 0;
        progress('Getting the AI ready, first time only · $done of $missing MB downloaded…', done / missing);
      } else if (row['type'] == 'error') {
        problem = 'Couldn\'t download the AI models (${row['message']}). Check the internet connection and try again.';
      } else if (row['type'] == 'done') {
        problem = null;
      }
    }
    return problem;
  }

  Future<String> _scriptPath() async {
    if (_script != null) return _script!;
    await Directory(supportDir).create(recursive: true);
    final path = '$supportDir/vibeline_ai.py';
    await File(path).writeAsString(await rootBundle.loadString('assets/vibeline_ai.py'));
    return _script = path;
  }

  /// Runs Rubber Band jobs (see prestretch.dart); one row per job.
  Stream<Map<String, dynamic>> prestretch(List<String> jobFiles) => _run(['prestretch', ...jobFiles]);

  /// Longest song list sent on the command line; longer ones go in a file.
  /// macOS allows about 1 MB, shared with everything else the app passes along.
  static int maxArgBytes = 100 * 1024;

  /// The most songs one set will listen to. A big drive can hold 20,000, and
  /// each new song takes seconds to analyse.
  static const maxPoolSongs = 2000;

  /// Cuts a very large pool down to a size a set can get through: your
  /// Shazamed songs and the songs on this Mac come first, then the best-ranked
  /// songs from plugged-in drives. Keeps the pool's order within each group.
  static List<LibraryTrack> limitPool(List<LibraryTrack> pool) {
    bool first(LibraryTrack t) => t.shazam || !t.path.startsWith('/Volumes/');
    final preferred = pool.where(first).toList();
    final limit = math.min(maxPoolSongs, math.max(400, preferred.length + 100));
    if (pool.length <= limit) return pool;
    return [...preferred, ...pool.where((t) => !first(t))].take(limit).toList();
  }

  /// What to analyse before a set can start, given what's already known:
  /// enough songs that suit the request ([matches]), then enough overall. The
  /// rest can wait for the background. Keeps the pool's order.
  static List<LibraryTrack> songsToAnalyseFirst(
    List<LibraryTrack> pool, {
    required int minReady,
    int matchMin = 0,
    bool Function(LibraryTrack)? matches,
  }) {
    bool waiting(LibraryTrack t) => t.analysis == null && !t.analysisTried && !t.inCloud;
    final first = <LibraryTrack>[];
    if (matches != null) {
      final have = pool.where((t) => t.analysis != null && matches(t)).length;
      first.addAll(pool.where((t) => waiting(t) && matches(t)).take(math.max(0, matchMin - have)));
    }
    final ready = pool.where((t) => t.analysis != null).length;
    final chosen = first.toSet();
    first.addAll(pool.where((t) => waiting(t) && !chosen.contains(t)).take(math.max(0, minReady - ready - first.length)));
    return first;
  }

  Stream<Map<String, dynamic>> _run(List<String> args, {bool gentle = false}) async* {
    final script = await _scriptPath();
    Directory? listDir;
    Process? running;
    Future<void> Function()? stopReading;
    try {
      var sent = args;
      final bytes = args.fold<int>(0, (n, a) => n + utf8.encode(a).length + 1);
      if (args.length > 2 && bytes > maxArgBytes) {
        listDir = await Directory.systemTemp.createTemp('noodles-list-');
        final list = File('${listDir.path}/songs.json');
        await list.writeAsString(jsonEncode(args.sublist(1)));
        sent = [args.first, '@${list.path}'];
      }
      // The helper watches this app's process id and quits if the app closes.
      // At lower priority, so playback and the screen stay smooth while it
      // works flat out (splitting stems takes ~20 s a song).
      final proc = await Process.start('/usr/bin/nice', ['-n', '10', python, '-I', '-B', script, ...sent],
          environment: {'VIBELINE_APP_PID': '$pid', if (gentle) 'VIBELINE_WORKERS': '2'});
      running = proc;
      proc.stderr.drain<void>();
      // Reading stops when the helper exits, even if a leftover process of its
      // is still holding the line open after a crash, so nothing waits forever.
      final lines = StreamController<String>();
      final reading = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(lines.add, onDone: lines.close);
      stopReading = reading.cancel;
      unawaited(proc.exitCode.then((_) async {
        await Future<void>.delayed(const Duration(seconds: 1));
        await reading.cancel();
        if (!lines.isClosed) await lines.close();
      }));
      await for (final line in lines.stream) {
        if (line.trim().isEmpty) continue;
        try {
          yield jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {}
      }
    } finally {
      await stopReading?.call();
      running?.kill(); // if whoever was listening stopped early
      try {
        await listDir?.delete(recursive: true);
      } catch (_) {}
    }
  }

  bool _knownLoaded = false;

  /// Songs left out because they're only in iCloud.
  int get inCloudCount => tracks.where((t) => t.inCloud).length;

  /// Loads the results for every song analysed on an earlier day (quick: no
  /// audio is opened). Only does the work once per search for songs.
  Future<void> loadKnown() async {
    if (_knownLoaded) return;
    final todo = {for (final t in tracks) if (t.analysis == null) t.path: t};
    if (todo.isNotEmpty) {
      await for (final row in _run(['known', ...todo.keys])) {
        final t = todo[row['path']];
        if (t == null) continue;
        if (row['type'] == 'in_icloud') t.inCloud = true;
        if (row['type'] == 'analysis') _applyAnalysis(t, row);
      }
    }
    _knownLoaded = true;
  }

  void _applyAnalysis(LibraryTrack t, Map<String, dynamic> row) {
    t.analysisTried = true;
    t.level = (row['loudnessDb'] as num?)?.toDouble();
    t.tuningHz = (row['tuning'] as num?)?.toDouble();
    t.waveform = ((row['waveform'] as List?) ?? const []).map((e) => (e as num).toDouble()).toList();
    if (row['ok'] == true) {
      try {
        t.analysis = Analysis.fromJson(row)..pinTo(t.stems);
      } catch (_) {}
    }
  }

  Future<void> scan() async {
    _knownLoaded = false;
    final previous = {for (final t in tracks) t.path: t.analysis};
    tracks.clear();
    final folders = wholeMac
        ? [home, ...externalDrives()]
        : [
            folder,
            if (useMusicApp && musicAppFolder != folder && Directory(musicAppFolder).existsSync()) musicAppFolder,
          ];
    await for (final row in _run(['tags', ...folders])) {
      if (row['type'] != 'tags') continue;
      final t = LibraryTrack.fromJson(row);
      // Searching everywhere turns up alert sounds and short clips: songs only.
      if (wholeMac && t.duration > 0 && t.duration < 60) continue;
      t.analysis = previous[t.path];
      tracks.add(t);
    }
    await _markShazam();
  }

  /// Plugged-in drives (not the Mac's own disk, and not Time Machine).
  static List<String> externalDrives() {
    final out = <String>[];
    try {
      for (final e in Directory('/Volumes').listSync(followLinks: false)) {
        if (e is! Directory || e.path.split('/').last.startsWith('.')) continue;
        if (Directory('${e.path}/Backups.backupdb').existsSync() || File('${e.path}/.com.apple.timemachine.supported').existsSync()) {
          continue;
        }
        out.add(e.path);
      }
    } catch (_) {}
    return out;
  }

  /// Analyses any of [wanted] not yet analysed. Cached on disk by the script,
  /// so songs only take time the first time they're used. [gentle] leaves more
  /// of the Mac free; [stop] is checked as each song finishes.
  Future<void> analyze(List<LibraryTrack> wanted, void Function(int done, int total) onProgress,
      {bool gentle = false, bool Function()? stop}) async {
    final todo = wanted.where((t) => t.analysis == null && !t.analysisTried && !t.inCloud).toList();
    if (todo.isEmpty) return;
    final byPath = {for (final t in todo) t.path: t};
    var done = 0;
    onProgress(0, todo.length);
    await for (final row in _run(['analyze', ...byPath.keys], gentle: gentle)) {
      if (row['type'] != 'analysis') continue;
      done++;
      final t = byPath[row['path']];
      if (t != null) _applyAnalysis(t, row);
      onProgress(done, todo.length);
      if (stop?.call() ?? false) break;
    }
  }

  /// Measures beats to a bar for any of [wanted] not yet known (a few seconds a
  /// song the first time; remembered on disk after).
  Future<void> meter(List<LibraryTrack> wanted) async {
    final byPath = {for (final t in wanted) if (t.barBeats == null) t.path: t};
    if (byPath.isEmpty) return;
    await for (final row in _run(['meter', ...byPath.keys])) {
      if (row['type'] == 'meter') byPath[row['path']]?.barBeats = (row['beats'] as num?)?.toInt();
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
          t.analysis?.pinTo(s);
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

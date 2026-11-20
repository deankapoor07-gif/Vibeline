// The 7-day trial and the licence key bought through Creem.
//
// Keys are checked through our licence server (a small Cloudflare Worker that
// holds the Creem API key, which must never ship inside the app). Once a Mac
// is activated it keeps working offline; it rechecks now and then when online,
// and only locks if the server says the key was refunded, disabled or is gone.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'library.dart';

/// Our licence server, e.g. `https://djn-licence.<account>.workers.dev`. It
/// only accepts keys for the D-Jay Noodles product. Set this before a release;
/// the release test fails while it's null.
const String? kLicenceServer = null;

const kBuyUrl = 'https://d-jaynoodles.com/#buy';
const kTrialDays = 7;
const _recheckEvery = Duration(days: 14);

enum LicenceState { trial, expired, licensed }

class ActivationResult {
  final bool ok;
  final String message;
  const ActivationResult(this.ok, this.message);
}

/// One HTTP POST to the licence server: JSON fields in, JSON out.
typedef LicencePost = Future<(int, Map<String, dynamic>)> Function(String action, Map<String, String> fields);

class Licence extends ChangeNotifier {
  Licence({String? dir, LicencePost? post, DateTime Function()? now, TrialStore? trialStore})
      : _dir = dir ?? MusicLibrary.supportDir,
        _post = post ?? _httpPost,
        _now = now ?? DateTime.now,
        _trialStore = trialStore ?? KeychainTrialStore();

  static final Licence instance = Licence();

  final String _dir;
  final LicencePost _post;
  final DateTime Function() _now;
  final TrialStore _trialStore;

  String? key;
  String? instanceId;
  DateTime? lastChecked;
  DateTime? trialStart;
  DateTime? _lastSeen;
  bool loaded = false;

  File get _file => File('$_dir/licence.json');

  bool get licensed => key != null && instanceId != null;

  /// Today, but never earlier than the last time the app ran, so winding the
  /// clock back doesn't add trial days.
  DateTime get _today {
    final n = _now();
    final seen = _lastSeen;
    return seen != null && n.isBefore(seen) ? seen : n;
  }

  int get trialDaysLeft {
    final start = trialStart ?? _today;
    final used = _today.difference(start).inHours / 24;
    return (kTrialDays - used).ceil().clamp(0, kTrialDays);
  }

  LicenceState get state => licensed ? LicenceState.licensed : trialDaysLeft > 0 ? LicenceState.trial : LicenceState.expired;

  /// The key with all but the last block hidden, for the licence window.
  String get maskedKey {
    final k = key ?? '';
    final parts = k.split('-');
    if (parts.length < 2) return k.length <= 4 ? k : '••••${k.substring(k.length - 4)}';
    return [...parts.take(parts.length - 1).map((p) => '•' * p.length), parts.last].join('-');
  }

  Future<void> load() async {
    Map<String, dynamic> j = {};
    try {
      if (_file.existsSync()) j = jsonDecode(await _file.readAsString()) as Map<String, dynamic>;
    } catch (_) {}
    key = j['key'] as String?;
    instanceId = j['instance'] as String?;
    lastChecked = DateTime.tryParse(j['checked'] as String? ?? '');
    _lastSeen = DateTime.tryParse(j['seen'] as String? ?? '');
    // The trial start lives in two places; the earlier one wins, so deleting
    // one of them doesn't restart the trial.
    final starts = [DateTime.tryParse(j['trial'] as String? ?? ''), await _trialStore.read()].whereType<DateTime>().toList()..sort();
    trialStart = starts.isEmpty ? _now() : starts.first;
    if (starts.isEmpty || await _trialStore.read() == null) await _trialStore.write(trialStart!);
    loaded = true;
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    final n = _now();
    if (_lastSeen == null || n.isAfter(_lastSeen!)) _lastSeen = n;
    try {
      await Directory(_dir).create(recursive: true);
      await _file.writeAsString(jsonEncode({
        'trial': trialStart?.toIso8601String(),
        'seen': _lastSeen?.toIso8601String(),
        if (key != null) 'key': key,
        if (instanceId != null) 'instance': instanceId,
        if (lastChecked != null) 'checked': lastChecked!.toIso8601String(),
      }));
    } catch (_) {}
  }

  /// Plain words for a reason code from the licence server.
  static String _friendly(String? reason) {
    switch (reason) {
      case 'limit':
        return 'This key is already in use on 3 Macs. Open D-Jay Noodles on one you no longer use and choose "Move licence off this Mac", then try again.';
      case 'not_found':
      case 'missing':
        return "That key wasn't recognised. Check it matches the one in your receipt email.";
      case 'disabled':
      case 'expired':
        return "That key is no longer active. If you think that's wrong, email hello@d-jaynoodles.com.";
      case 'wrong_product':
        return 'That key is for something else, not D-Jay Noodles.';
      case 'unavailable':
        return "The licence server didn't answer. Try again in a few minutes.";
    }
    return "That key couldn't be activated.";
  }

  /// Reasons that mean the key really is no good any more (not just a hiccup).
  static const _revoked = {'not_found', 'disabled', 'expired', 'wrong_product'};

  Future<ActivationResult> activate(String typed) async {
    final k = typed.trim();
    if (k.isEmpty) return const ActivationResult(false, 'Paste your licence key first.');
    final (int code, Map<String, dynamic> j) res;
    try {
      res = await _post('activate', {'key': k, 'name': await _macName()});
    } catch (_) {
      return const ActivationResult(false, "Couldn't reach the licence server. Check you're online and try again.");
    }
    final j = res.$2;
    final id = j['instance'];
    if (j['ok'] != true || id is! String || id.isEmpty) return ActivationResult(false, _friendly(j['reason'] as String?));
    key = k;
    instanceId = id;
    lastChecked = _now();
    await _save();
    notifyListeners();
    return const ActivationResult(true, 'Thanks! D-Jay Noodles is activated on this Mac.');
  }

  /// Frees this Mac's slot so the key can go on another Mac.
  Future<ActivationResult> deactivate() async {
    if (!licensed) return const ActivationResult(true, '');
    try {
      final (_, j) = await _post('deactivate', {'key': key!, 'instance': instanceId!});
      if (j['ok'] != true) return ActivationResult(false, _friendly(j['reason'] as String?));
    } catch (_) {
      return const ActivationResult(false, "Couldn't reach the licence server. Check you're online and try again.");
    }
    key = null;
    instanceId = null;
    lastChecked = null;
    await _save();
    notifyListeners();
    return const ActivationResult(true, 'This Mac is no longer using your licence.');
  }

  /// Every couple of weeks, when online: is the key still good? Offline or a
  /// server hiccup changes nothing; only a clear "refunded / disabled / gone"
  /// does.
  Future<void> recheck() async {
    if (!licensed) return;
    final last = lastChecked;
    if (last != null && _now().difference(last) < _recheckEvery) return;
    try {
      final (_, j) = await _post('validate', {'key': key!, 'instance': instanceId!});
      if (j['valid'] == true) {
        lastChecked = _now();
      } else if (_revoked.contains(j['reason'])) {
        key = null;
        instanceId = null;
        lastChecked = null;
      }
      await _save();
      notifyListeners();
    } catch (_) {}
  }

  static Future<String> _macName() async {
    try {
      final r = await Process.run('sysctl', ['-n', 'hw.model']);
      final m = '${r.stdout}'.trim();
      if (m.isNotEmpty) return 'Mac ($m)';
    } catch (_) {}
    return 'Mac';
  }

  static Future<(int, Map<String, dynamic>)> _httpPost(String action, Map<String, String> fields) async {
    final server = kLicenceServer;
    if (server == null) throw const SocketException('No licence server in this build');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(Uri.parse('$server/$action'));
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(fields));
      final res = await req.close().timeout(const Duration(seconds: 20));
      final body = await res.transform(utf8.decoder).join();
      final j = body.isEmpty ? <String, dynamic>{} : jsonDecode(body);
      return (res.statusCode, j is Map<String, dynamic> ? j : <String, dynamic>{});
    } finally {
      client.close(force: true);
    }
  }

  /// Opens the shop in the browser.
  static Future<void> openShop() async {
    try {
      await Process.run('open', [kBuyUrl]);
    } catch (_) {}
  }
}

/// The second copy of the trial start date.
abstract class TrialStore {
  Future<DateTime?> read();
  Future<void> write(DateTime start);
}

/// Keeps the trial start in the login keychain, so it survives the app's
/// folders being cleared.
class KeychainTrialStore implements TrialStore {
  static const _service = 'D-Jay Noodles trial';

  @override
  Future<DateTime?> read() async {
    try {
      final r = await Process.run('security', ['find-generic-password', '-s', _service, '-a', 'start', '-w']);
      if (r.exitCode != 0) return null;
      return DateTime.tryParse('${r.stdout}'.trim());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(DateTime start) async {
    try {
      await Process.run('security', ['add-generic-password', '-U', '-s', _service, '-a', 'start', '-w', start.toIso8601String()]);
    } catch (_) {}
  }
}

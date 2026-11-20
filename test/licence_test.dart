import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/licence.dart';

class MemTrial implements TrialStore {
  DateTime? v;
  MemTrial([this.v]);
  @override
  Future<DateTime?> read() async => v;
  @override
  Future<void> write(DateTime start) async => v = start;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('licence_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  final day0 = DateTime(2026, 11, 20, 10);

  Licence make({required DateTime Function() now, MemTrial? store, LicencePost? post}) =>
      Licence(dir: dir.path, now: now, trialStore: store ?? MemTrial(), post: post ?? (a, f) async => (500, <String, dynamic>{}));

  test('trial counts down 7 days, then ends', () async {
    var now = day0;
    final store = MemTrial();
    final l = make(now: () => now, store: store);
    await l.load();
    expect(l.state, LicenceState.trial);
    expect(l.trialDaysLeft, 7);
    expect(store.v, day0);
    now = day0.add(const Duration(days: 2, hours: 1));
    expect(l.trialDaysLeft, 5);
    now = day0.add(const Duration(days: 6, hours: 23));
    expect(l.trialDaysLeft, 1);
    now = day0.add(const Duration(days: 7));
    expect(l.state, LicenceState.expired);
  });

  test('deleting the licence file does not restart the trial', () async {
    var now = day0;
    final store = MemTrial();
    await make(now: () => now, store: store).load();
    File('${dir.path}/licence.json').deleteSync();
    now = day0.add(const Duration(days: 8));
    final again = make(now: () => now, store: store);
    await again.load();
    expect(again.state, LicenceState.expired);
  });

  test('clearing the keychain copy does not restart it either', () async {
    var now = day0;
    await make(now: () => now, store: MemTrial()).load();
    now = day0.add(const Duration(days: 8));
    final again = make(now: () => now, store: MemTrial());
    await again.load();
    expect(again.state, LicenceState.expired);
  });

  test('winding the clock back does not add days', () async {
    var now = day0;
    final store = MemTrial();
    await make(now: () => now, store: store).load();
    now = day0.add(const Duration(days: 6));
    await make(now: () => now, store: store).load();
    now = day0;
    final again = make(now: () => now, store: store);
    await again.load();
    expect(again.trialDaysLeft, 1);
  });

  test('a good key activates, survives restart, and works offline', () async {
    var now = day0.add(const Duration(days: 30));
    final calls = <String>[];
    final l = make(
        now: () => now,
        store: MemTrial(day0),
        post: (a, f) async {
          calls.add(a);
          expect(f['key'], 'ABCD-1234-EFGH-5678');
          return (200, <String, dynamic>{'ok': true, 'instance': 'inst-1'});
        });
    await l.load();
    expect(l.state, LicenceState.expired);
    final r = await l.activate('  ABCD-1234-EFGH-5678 ');
    expect(r.ok, isTrue);
    expect(l.state, LicenceState.licensed);
    expect(l.maskedKey, '••••-••••-••••-5678');

    // Restart with no network at all, long after the last check.
    now = now.add(const Duration(days: 90));
    final offline = make(now: () => now, post: (a, f) async => throw const SocketException('offline'));
    await offline.load();
    await offline.recheck();
    expect(offline.state, LicenceState.licensed);
  });

  test('a refunded key stops working on the next check', () async {
    var now = day0;
    final l = make(
        now: () => now,
        post: (a, f) async => a == 'activate'
            ? (200, <String, dynamic>{'ok': true, 'instance': 'i'})
            : (200, <String, dynamic>{'valid': false, 'reason': 'disabled'}));
    await l.load();
    await l.activate('KEY-1');
    now = now.add(const Duration(days: 15));
    await l.recheck();
    expect(l.licensed, isFalse);
  });

  test('a recheck too soon makes no call', () async {
    var calls = 0;
    final l = make(
        now: () => day0,
        post: (a, f) async {
          calls++;
          return (200, <String, dynamic>{'ok': true, 'instance': 'i'});
        });
    await l.load();
    await l.activate('KEY-1');
    await l.recheck();
    expect(calls, 1);
  });

  test('plain-English errors', () async {
    final l = make(
        now: () => day0,
        post: (a, f) async => f['key'] == 'FULL'
            ? (200, <String, dynamic>{'ok': false, 'reason': 'limit'})
            : f['key'] == 'OTHER'
                ? (200, <String, dynamic>{'ok': false, 'reason': 'wrong_product'})
                : (400, <String, dynamic>{'ok': false, 'reason': 'not_found'}));
    await l.load();
    expect((await l.activate('')).message, contains('Paste'));
    expect((await l.activate('FULL')).message, contains('3 Macs'));
    expect((await l.activate('NOPE')).message, contains("wasn't recognised"));
    expect((await l.activate('OTHER')).message, contains('not D-Jay Noodles'));
    expect(l.licensed, isFalse);
    final offline = make(now: () => day0, post: (a, f) async => throw const SocketException('x'));
    await offline.load();
    expect((await offline.activate('K')).message, contains('online'));
  });

  test('moving the licence off this Mac', () async {
    final seen = <String>[];
    final l = make(
        now: () => day0,
        post: (a, f) async {
          seen.add(a);
          return a == 'activate'
              ? (200, <String, dynamic>{'ok': true, 'instance': 'i'})
              : (200, <String, dynamic>{'ok': true});
        });
    await l.load();
    await l.activate('KEY-1');
    expect((await l.deactivate()).ok, isTrue);
    expect(l.licensed, isFalse);
    expect(seen, ['activate', 'deactivate']);
  });

  test('a licence server hiccup on recheck keeps the licence', () async {
    var now = day0;
    final l = make(
        now: () => now,
        post: (a, f) async => a == 'activate'
            ? (200, <String, dynamic>{'ok': true, 'instance': 'i'})
            : (503, <String, dynamic>{'valid': false, 'reason': 'unavailable'}));
    await l.load();
    await l.activate('KEY-1');
    now = now.add(const Duration(days: 15));
    await l.recheck();
    expect(l.licensed, isTrue);
  });

  test('validate and deactivate send the key and this Mac\'s instance', () async {
    final sent = <String, Map<String, String>>{};
    var now = day0;
    final l = make(
        now: () => now,
        post: (a, f) async {
          sent[a] = f;
          return switch (a) {
            'activate' => (200, <String, dynamic>{'ok': true, 'instance': 'ins_9'}),
            'validate' => (200, <String, dynamic>{'valid': true}),
            _ => (200, <String, dynamic>{'ok': true}),
          };
        });
    await l.load();
    await l.activate('KEY-9');
    now = now.add(const Duration(days: 15));
    await l.recheck();
    await l.deactivate();
    expect(sent['activate']!['key'], 'KEY-9');
    expect(sent['activate']!['name'], startsWith('Mac'));
    expect(sent['validate'], {'key': 'KEY-9', 'instance': 'ins_9'});
    expect(sent['deactivate'], {'key': 'KEY-9', 'instance': 'ins_9'});
  });

  test('release: our licence server is set', () {
    expect(kLicenceServer, isNotNull, reason: 'Set kLicenceServer in lib/licence.dart');
    expect(kLicenceServer, startsWith('https://'));
  }, skip: Platform.environment['VIBELINE_RELEASE'] != '1');
}

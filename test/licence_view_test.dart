import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/licence.dart';
import 'package:vibeline/licence_view.dart';

import 'licence_test.dart' show MemTrial;

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('licence_view'));
  tearDown(() => dir.deleteSync(recursive: true));

  Licence make(DateTime start, DateTime now) => Licence(
        dir: dir.path,
        now: () => now,
        trialStore: MemTrial(start),
        post: (a, f) async => (200, <String, dynamic>{'activated': true, 'instance': {'id': 'i'}, 'meta': {'store_id': kLemonStoreId ?? 1, 'product_id': kLemonProductId ?? 2}}),
      );

  testWidgets('trial ended: the screen shows, a key unlocks the app', (t) async {
    await t.binding.setSurfaceSize(const Size(900, 600));
    final l = make(DateTime(2026, 1, 1), DateTime(2026, 2, 1));
    await t.runAsync(l.load);
    await t.pumpWidget(MaterialApp(home: LicenceGate(licence: l, child: const Text('THE APP'))));
    await t.pumpAndSettle();
    expect(find.text('YOUR FREE TRIAL HAS ENDED'), findsOneWidget);
    expect(find.text('THE APP'), findsNothing);
    await t.enterText(find.byType(TextField), 'KEY-1');
    await t.runAsync(() async {
      await t.tap(find.text('Activate'));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await t.pumpAndSettle();
    expect(find.text('THE APP'), findsOneWidget);
  });

  testWidgets('during the trial the app shows straight away', (t) async {
    final l = make(DateTime(2026, 1, 1), DateTime(2026, 1, 3));
    await t.runAsync(l.load);
    await t.pumpWidget(MaterialApp(home: LicenceGate(licence: l, child: const Text('THE APP'))));
    await t.pumpAndSettle();
    expect(find.text('THE APP'), findsOneWidget);
  });

  testWidgets('licence window: trial, then activated', (t) async {
    await t.binding.setSurfaceSize(const Size(900, 600));
    final l = make(DateTime(2026, 1, 1), DateTime(2026, 1, 3));
    await t.runAsync(l.load);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: (c) => TextButton(onPressed: () => showLicenceWindow(c, licence: l), child: const Text('open'))))));
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    expect(find.text('Free trial: 5 days left'), findsOneWidget);
    await t.runAsync(() => l.activate('ABCD-1234'));
    await t.pumpAndSettle();
    expect(find.text('Activated on this Mac'), findsOneWidget);
    expect(find.text('Move licence off this Mac'), findsOneWidget);
  });
}

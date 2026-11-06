import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/empty_screen.dart';
import 'package:vibeline/library.dart';
import 'package:vibeline/library_panel.dart';
import 'package:vibeline/models.dart';
import 'package:vibeline/rig.dart';
import 'package:vibeline/theme_picker.dart';
import 'package:vibeline/vibe.dart';

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  test('every theme button is a theme the app understands', () {
    for (final t in themeChoices) {
      expect(parseTheme('', t).themed, isTrue, reason: t);
    }
  });

  testWidgets('shortcuts leave the keys alone while you type in a box', (t) async {
    final box = FocusNode(), button = FocusNode();
    await t.pumpWidget(_app(Column(children: [
      TextField(focusNode: box),
      Focus(focusNode: button, child: const Text('not a box')),
    ])));
    box.requestFocus();
    await t.pump();
    expect(typingIn(FocusManager.instance.primaryFocus?.context), isTrue);
    button.requestFocus();
    await t.pump();
    expect(typingIn(FocusManager.instance.primaryFocus?.context), isFalse);
    expect(typingIn(null), isFalse);
  });

  testWidgets('the theme list fills in the theme, and No theme clears it', (t) async {
    final c = TextEditingController();
    await t.pumpWidget(_app(StatefulBuilder(
      builder: (_, set) => ThemePicker(controller: c, locked: false, onChanged: () => set(() {})),
    )));
    expect(find.text('NONE'), findsOneWidget);
    await t.tap(find.byType(ThemePicker));
    await t.pumpAndSettle();
    await t.tap(find.text('Punk'));
    await t.pumpAndSettle();
    expect(c.text, 'Punk');
    expect(find.text('PUNK'), findsOneWidget);
    await t.tap(find.byType(ThemePicker));
    await t.pumpAndSettle();
    await t.tap(find.text('No theme'));
    await t.pumpAndSettle();
    expect(c.text, '');
  });

  testWidgets('you can type your own theme', (t) async {
    final c = TextEditingController();
    await t.pumpWidget(_app(StatefulBuilder(
      builder: (_, set) => ThemePicker(controller: c, locked: false, onChanged: () => set(() {})),
    )));
    await t.tap(find.byType(ThemePicker));
    await t.pumpAndSettle();
    await t.tap(find.text('Type your own…'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'soundtrack');
    await t.tap(find.text('Use theme'));
    await t.pumpAndSettle();
    expect(c.text, 'soundtrack');
  });

  testWidgets('the theme stays locked while a set is being made', (t) async {
    final c = TextEditingController(text: '80s');
    await t.pumpWidget(_app(ThemePicker(controller: c, locked: true, onChanged: () {})));
    await t.tap(find.byType(ThemePicker));
    await t.pumpAndSettle();
    expect(find.text('Punk'), findsNothing);
  });

  testWidgets('a lit button shows its state and stays put when locked', (t) async {
    final pressed = <bool>[];
    await t.pumpWidget(_app(RigToggle(label: 'Mashups', on: true, onChanged: pressed.add)));
    expect(find.text('MASHUPS'), findsOneWidget);
    await t.tap(find.text('MASHUPS'));
    expect(pressed, [false]);
    await t.pumpWidget(_app(RigToggle(label: 'Mashups', on: true, locked: true, onChanged: pressed.add)));
    await t.pumpAndSettle();
    await t.tap(find.text('MASHUPS'));
    expect(pressed, [false]);
  });

  Widget empty({bool busy = false, bool scanned = true, bool problem = false, int songs = 10, void Function(String)? ex, VoidCallback? folder}) => _app(EmptyScreen(
        busy: busy,
        mashup: true,
        scanned: scanned,
        problem: problem,
        songCount: songs,
        goLabel: 'Make my set',
        accent: Colors.pink,
        onExample: ex ?? (_) {},
        onChooseFolder: folder ?? () {},
        onWholeMac: () {},
      ));

  testWidgets('the empty screen says the next step, and examples fill the box', (t) async {
    String? picked;
    await t.pumpWidget(empty(ex: (e) => picked = e));
    expect(find.text('NO SET LOADED'), findsOneWidget);
    expect(find.textContaining('stems'), findsNothing);
    await t.tap(find.text(mashupExamples[1]));
    expect(picked, mashupExamples[1]);
  });

  testWidgets('no songs found offers a way to find them', (t) async {
    var chose = false;
    await t.pumpWidget(empty(songs: 0, folder: () => chose = true));
    expect(find.text('NO SONGS FOUND'), findsOneWidget);
    await t.tap(find.text('Choose a folder'));
    expect(chose, isTrue);
  });

  testWidgets('while working or looking, no examples get in the way', (t) async {
    await t.pumpWidget(empty(busy: true));
    expect(find.text('BUILDING YOUR SET…'), findsOneWidget);
    expect(find.text(mashupExamples[0]), findsNothing);
    await t.pumpWidget(empty(scanned: false, songs: 0));
    expect(find.text('LOOKING FOR YOUR MUSIC…'), findsOneWidget);
    await t.pumpWidget(empty(scanned: false, songs: 0, problem: true));
    expect(find.text('ONE THING TO FIX FIRST'), findsOneWidget);
  });

  test('iCloud-only songs are never waited for', () {
    LibraryTrack song(String p, {bool cloud = false}) =>
        LibraryTrack(path: p, title: p, artist: 'a', genre: '', year: 2000, duration: 200)..inCloud = cloud;
    final first = MusicLibrary.songsToAnalyseFirst([song('cloud', cloud: true), song('here')], minReady: 2);
    expect(first.map((t) => t.path), ['here']);
    expect(iCloudNote(1), contains('1 song is'));
    expect(iCloudNote(250), contains('250 songs are'));
  });
}

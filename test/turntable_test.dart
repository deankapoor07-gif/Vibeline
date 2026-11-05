import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/deck_view.dart';
import 'package:vibeline/fx_deck.dart';
import 'package:vibeline/mixer.dart';
import 'package:vibeline/mixer_panel.dart';

void main() {
  const decks = [
    DeckInfo('VOCAL', 'A very long song title that will not fit on one line at all', 'Some Artist', kPink, [('102% speed', kPink), ('Acapella drop', kYellow)], bpm: '124.0', keyCode: '8A'),
    DeckInfo('BEAT', 'Beat Song', 'Other Artist', kTeal, [('Keys match', kTeal)], bpm: '124.0', keyCode: '8A'),
  ];

  // Every window shape, with the Songs panel and FX panel open or shut.
  for (final hasVocal in const [true, false])
  for (final size in const [Size(1280, 420), Size(1280, 190), Size(900, 300), Size(460, 500), Size(460, 200), Size(460, 90), Size(320, 40), Size(320, 10)]) {
    testWidgets('decks fit at ${size.width} x ${size.height}, vocal layer $hasVocal', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox.fromSize(
              size: size,
              child: NowPlayingView(
                decks: decks,
                sections: const [],
                waves: WaveCache(Mixer()),
                position: 12,
                playing: false,
                heading: 'Now playing · mashup 1 of 5',
                upNext: 'Up next in 2:15 · Another song',
                overview: const SizedBox.expand(),
                mixer: (level) => MixerPanel(
                  hasVocal: hasVocal,
                  vocalFader: kFaderHome,
                  beatFader: kFaderHome,
                  crossfader: 0,
                  muteVocal: false,
                  muteBeat: false,
                  fx: FxSettings(Mixer()),
                  meterVocal: level(true),
                  meterBeat: level(false),
                  onVocalFader: (_) {},
                  onBeatFader: (_) {},
                  onCrossfader: (_) {},
                  onMuteVocal: () {},
                  onMuteBeat: () {},
                  onKnob: () {},
                ),
              ),
            ),
          ),
        ),
      ));
      expect(t.takeException(), isNull);
    });
  }

  test('faders: home leaves the level alone, the bottom is silent', () {
    expect(faderDb(kFaderHome), 0);
    expect(faderDb(1), closeTo(6, 0.001));
    expect(faderDb(0), -60);
  });

  test('crossfader: the middle changes nothing, the ends cut one layer', () {
    expect(crossfadeDb(0), (0.0, 0.0));
    expect(crossfadeDb(1).$1, -60);
    expect(crossfadeDb(1).$2, 0);
    expect(crossfadeDb(-1).$2, -60);
    expect(crossfadeDb(0.5).$1, closeTo(-6.02, 0.01));
  });
}

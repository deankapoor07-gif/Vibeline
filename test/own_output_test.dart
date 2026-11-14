import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/library.dart';

void main() {
  test('saved mixes and iPhone sets are kept out of the song library', () {
    for (final p in [
      '/Users/x/Desktop/D-Jay Noodles Mix – Party, mix genres, my Shazams – 2026-11-08 18.39.m4a',
      '/Users/x/Music/Music/Media.localized/Music/Unknown Artist/Unknown Album/Vibeline Mashups – Kiwi – 2026-10-27 22.33.m4a',
      '/Volumes/SPARE DRIVE/D-Jay Noodles archive/Saved mixes/D-Jay Noodles Mashups – Feel It – 2026-10-29 20.27 (2).m4a',
      '/Volumes/PortableSSD/D-Jay Noodles archive/Old mix parts/2026-11/7496e3e35e4dc670.m4a',
      '/Volumes/SPARE DRIVE/D-Jay Noodles archive/old mix parts/2ff1272aeca9a867.m4a.vox.m4a',
      '/Users/x/Library/Mobile Documents/com~apple~CloudDocs/D-Jay Noodles/Sets/Party – 2026-11-01 10.00/s003.vox.m4a',
    ]) {
      expect(MusicLibrary.isOwnOutput(p), isTrue, reason: p);
    }
    for (final p in [
      '/Users/x/Music/01 Fantasy (R3HAB Remix).mp3',
      '/Users/x/Music/Noodles/Mix Tape.mp3',
      '/Users/x/Music/Vibeline Mixdown.m4a',
    ]) {
      expect(MusicLibrary.isOwnOutput(p), isFalse, reason: p);
    }
  });
}

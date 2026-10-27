import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/models.dart';
import 'package:vibeline/prompt_song.dart';

void main() {
  LibraryTrack t(String title, String artist) =>
      LibraryTrack(path: '/$title', title: title, artist: artist, genre: '', year: 0, duration: 200);
  final lib = [
    t('Slice of Heaven', 'Dave Dobbyn'),
    t("Wanna Be Startin' Somethin' (Single Version)", 'Michael Jackson'),
    t('Dance of the Sugar Plum Fairy', 'Tchaikovsky'),
    t('Thriller - 2003 Edit', 'Michael Jackson'),
    t('Party Rock Anthem (feat. Lauren Bennett)', 'LMFAO'),
    t('Heaven', 'Bryan Adams'),
  ];
  String? title(String prompt) => songFromPrompt(prompt, lib)?.track?.title;

  test('finds the song however it is asked for', () {
    expect(title('Slice of Heaven'), 'Slice of Heaven');
    expect(title('slice of heaven'), 'Slice of Heaven');
    expect(title('sugar plum fairy'), 'Dance of the Sugar Plum Fairy');
    expect(title('Heaven'), 'Heaven');
    expect(title('mix Slice of Heaven'), 'Slice of Heaven');
    expect(title('Start with slice of heaven, party'), 'Slice of Heaven');
    expect(title('build a mix around Slice of Heaven'), 'Slice of Heaven');
    expect(title('start the mix with Slice of Heaven'), 'Slice of Heaven');
    expect(title('mix wanna be starting something'), "Wanna Be Startin' Somethin' (Single Version)");
    expect(title('Wanna Be Startin Somethin'), "Wanna Be Startin' Somethin' (Single Version)");
    expect(title('start with thriller by michael jackson'), 'Thriller - 2003 Edit');
    expect(title('mix party rock anthem'), 'Party Rock Anthem (feat. Lauren Bennett)');
    expect(title('mix sugar plum fairy'), 'Dance of the Sugar Plum Fairy');
    expect(title('mix plum fairy'), null); // too small a piece of the title
    expect(songFromPrompt('mix Heaven', lib)?.track?.title, 'Heaven');
  });

  test('vibes stay vibes', () {
    expect(songFromPrompt('Party, mix genres, my Shazams', lib), isNull);
    expect(songFromPrompt('mix genres, party', lib), isNull);
    expect(songFromPrompt('chill sunset vibes', lib), isNull);
    expect(songFromPrompt('Party, mix genres', [...lib, t('Party', 'Beyoncé')]), isNull);
    expect(songFromPrompt('party anthems, loud', lib), isNull);
    expect(songFromPrompt('mashup 80s and hip hop', lib), isNull);
  });

  test('says when a requested song is missing', () {
    final p = songFromPrompt('start with Bohemian Rhapsody, rock', lib)!;
    expect(p.track, isNull);
    expect(p.query, 'Bohemian Rhapsody');
    expect(p.rest, 'rock');
  });
}

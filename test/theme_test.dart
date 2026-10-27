import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/models.dart';
import 'package:vibeline/vibe.dart';

void main() {
  LibraryTrack t(String title, String artist, String genre, int year) =>
      LibraryTrack(path: '/$title', title: title, artist: artist, genre: genre, year: year, duration: 200);
  final hellsBells = t('Hells Bells', 'AC/DC', 'Hard Rock', 1980);
  final ghostbusters = t('Ghostbusters (from "Ghostbusters")', 'Ray Parker Jr.', 'Pop', 1984);
  final rebelYell = t('Rebel Yell', 'Billy Idol', 'Rock', 1983);
  final rockAround = t('Rock Around the Clock', 'Bill Haley', 'Rock & Roll', 2011);
  final elvis = t("Can't Help Falling In Love", 'Elvis Presley', 'Pop', 1961);
  final drake = t("God's Plan", 'Drake', 'Hip-Hop/Rap', 2018);
  final dancing = t('Dancing Queen', 'ABBA', 'Pop', 1976);
  final boodUp = t("Boo'd Up", 'Ella Mai', 'R&B/Soul', 2017);
  final hellaGood = t('Hella Good', 'No Doubt', 'Rock', 2001);
  final all = [hellsBells, ghostbusters, rebelYell, rockAround, elvis, drake, dancing, boodUp, hellaGood];
  List<String> pick(String prompt) => [for (final x in all) if (parseVibe(prompt).fits(x)) x.title];

  test('theme nights keep only songs that fit', () {
    expect(pick('80s night'), ['Hells Bells', 'Ghostbusters (from "Ghostbusters")', 'Rebel Yell']);
    expect(pick("80’s party"), ['Hells Bells', 'Ghostbusters (from "Ghostbusters")', 'Rebel Yell']);
    expect(pick('eighties rock'), ['Hells Bells', 'Rebel Yell']);
    expect(pick('rap'), ["God's Plan"]);
    expect(pick('punk'), ['Rebel Yell']);
    expect(pick('Rockin Roll'), ['Rock Around the Clock', "Can't Help Falling In Love"]);
    expect(pick("rock 'n' roll party"), ['Rock Around the Clock', "Can't Help Falling In Love"]);
    expect(pick('Horror night'), ['Hells Bells', 'Ghostbusters (from "Ghostbusters")']);
    expect(pick('Halloween'), ['Hells Bells', 'Ghostbusters (from "Ghostbusters")']);
  });

  test('theme box: any genre tag, and 20+ minutes or what the songs allow', () {
    final soundtrack = t('Ghostbusters', 'Ray Parker Jr.', 'Soundtrack', 1984);
    final v = parseTheme('party', 'soundtrack');
    expect(v.fits(soundtrack), isTrue);
    expect(v.fits(drake), isFalse);
    final big = parseTheme('party', '80s');
    expect(fitThemeLength(big, 300), isNull);
    expect(big.minutes, 20);
    final asked = parseTheme('party, 1 hour', '80s');
    expect(fitThemeLength(asked, 300), isNull);
    expect(asked.minutes, 60);
    final small = parseTheme('', 'punk');
    expect(fitThemeLength(small, 11), contains('about 11 min'));
    expect(small.minutes, 11);
    expect(fitThemeLength(parseTheme('chill', ''), 5), isNull); // not a theme night
  });

  test('ordinary vibes are not theme nights', () {
    for (final p in ['Party, mix genres, my Shazams', 'chill sunset', 'top 40 hits', 'club bangers', 'throwback party']) {
      expect(parseVibe(p).themed, isFalse, reason: p);
    }
  });

  // VIBELINE_TAGS=<tags jsonl>: how many of a real library fit each theme.
  final tags = Platform.environment['VIBELINE_TAGS'];
  test('real library counts', () {
    final lib = [
      for (final l in File(tags!).readAsLinesSync())
        if (l.trim().isNotEmpty && (jsonDecode(l) as Map)['type'] == 'tags') LibraryTrack.fromJson(jsonDecode(l) as Map<String, dynamic>)
    ];
    for (final p in ['80s', 'punk', 'Rockin Roll', 'rap', 'rock', '80s rock', 'Halloween', 'horror night', '90s', 'country']) {
      final v = parseVibe(p);
      final fit = lib.where(v.fits).toList();
      print('$p → ${fit.length} songs · mashups ~${v.minutesAvailable(lib, mashups: true).round()} min · blend ~${v.minutesAvailable(lib, mashups: false).round()} min${p.contains('allow') || p.contains('orror') ? ': ${fit.map((x) => x.title).join(' | ')}' : ''}');
    }
  }, skip: tags == null);
}

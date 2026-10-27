import 'dart:math' as math;

import 'models.dart';

/// What a typed vibe ("Aussie rock crowd, high energy, smooth transitions")
/// means musically.
class VibeProfile {
  double targetBpm = 120;
  double startEnergy = 0.5;
  double peakEnergy = 0.9;
  double endEnergy = 0.75;
  int trackCount = 10;
  double minutes = 11; // how long the set should run
  bool smooth = true; // long blends vs. punchy cuts
  bool mixGenres = false; // reward genre contrast between songs
  bool shazamOnly = false;
  bool aussie = false;
  int? yearFrom;
  int? yearTo;
  final Set<String> genres = {}; // genre families wanted
  // A theme night: only songs that fit are used (see [fits]). Genres you name
  // outright, a decade, or one of [_themes].
  final Set<String> themeGenres = {};
  String? theme; // 'punk', 'rocknroll', 'halloween', or a key of [cultureThemes]
  bool strictEra = false;
  String? genreText; // a theme typed that isn't one of the above: matched against genre tags ("soundtrack", "k-pop")
  bool lengthSet = false; // the prompt said how long ("1 hour", "20 songs")
  bool bpmSet = false; // the prompt named a tempo ("100 bpm")
  String? vocalFamily; // "country vocals over hip hop" -> country
  String? beatFamily; //                                 -> hiphop
  // Master "analog warmth" (tape saturation + vinyl crackle), set by the vibe.
  double drive = 1.2;
  double crackle = 0.3;
  final List<String> description = [];

  /// Energy the set should have at position p (0 = first song, 1 = last).
  double energyAt(double p) {
    if (p < 0.7) return startEnergy + (peakEnergy - startEnergy) * (p / 0.7);
    return peakEnergy + (endEnergy - peakEnergy) * ((p - 0.7) / 0.3);
  }

  String get summary => description.isEmpty ? 'All-rounder mix' : description.join(' · ');

  bool get themed => themeGenres.isNotEmpty || theme != null || strictEra || genreText != null;

  /// Whether a song belongs in this theme night (always true without one).
  bool fits(LibraryTrack t) {
    if (strictEra && (t.year <= 0 || (yearFrom != null && t.year < yearFrom!) || (yearTo != null && t.year > yearTo!))) {
      return false;
    }
    final g = t.genre.toLowerCase(), a = t.artist.toLowerCase(), title = t.title.toLowerCase();
    switch (theme) {
      case 'punk':
        if (!g.contains('punk') && !_punkArtists.any(a.contains)) return false;
      case 'rocknroll':
        final classic = RegExp(r"rock\s*(&|and|'?n'?)\s*roll|rockabilly|doo.?wop").hasMatch(g) || _rockNRollArtists.any(a.contains);
        final era = t.year >= 1950 && t.year < 1966 && const {'rock', 'pop', 'rnb', 'country'}.contains(genreFamily(t.genre));
        if (!classic && !era) return false;
      case 'halloween':
        if (!isSpooky(title, a)) return false;
      case final String k when cultureThemes.containsKey(k):
        if (!cultureThemes[k]!.fits(t)) return false;
    }
    if (themeGenres.isNotEmpty && !themeGenres.contains(genreFamily(t.genre))) return false;
    if (genreText != null && !g.contains(genreText!) && !a.contains(genreText!)) return false;
    return true;
  }

  /// Roughly how many minutes of mix the songs that fit can make: a mashup
  /// (~2.1 min) uses two songs; a blend mix plays ~2.3 min of each.
  double minutesAvailable(List<LibraryTrack> tracks, {required bool mashups}) {
    final n = tracks.where((t) => fits(t) && t.duration >= 100).length;
    return mashups ? n / 2 * 2.1 : n * 2.3;
  }
}

/// Music from a country or culture: by artist (files don't say where a
/// singer is from) or by a genre tag that does.
class CultureTheme {
  final String name;
  final List<String> words; // what you'd type
  final RegExp? genre;
  final List<String> artists;
  const CultureTheme(this.name, this.words, this.genre, this.artists);

  bool fits(LibraryTrack t) {
    if (genre != null && genre!.hasMatch(t.genre.toLowerCase())) return true;
    final a = t.artist.toLowerCase();
    // Whole names only: "zed" isn't Zedd, "kings" isn't Kings of Leon.
    return artists.any((x) => RegExp('(?<![a-z0-9])${RegExp.escape(x)}(?![a-z0-9])').hasMatch(a));
  }
}

final cultureThemes = {
  'kiwi': CultureTheme('Kiwi', ['kiwi', 'kiwis', 'new zealand', 'nz', 'aotearoa', 'kiwiana'], null, [
    'crowded house', 'neil finn', 'tim finn', 'split enz', 'drax project', 'sons of zion', 'nesian mystik',
    'dave dobbyn', 'dragon', 'stan walker', 'six60', 'lorde', 'benee', 'brooke fraser', 'herbs', 'katchafire',
    'foley', 'bic runga', 'kimbra', "fat freddy's drop", 'gin wigmore', 'tiki taane', 'che fu', 'prince tui teka',
    'the exponents', 'hollie smith', 'marlon williams', 'broods', 'the naked and famous', 'shihad', 'opshop',
    'supergroove', 'dei hamo', 'scribe', 'aaradhna', 'j williams', 'mitch james', 'jordan rakei', 'alien weaponry',
    'omc', 'stellar', 'elemeno p', 'goldenhorse', 'the mutton birds', 'hayley westenra', 'kiri te kanawa',
    'avalanche city', 'house of shem', 'tomorrow people', 'l.a.b', 'lab', 'lomez', 'corrella', 'teeks',
    'jamie mcdell', 'ria hall', 'rob ruha', 'annah mac', 'the feelers', 'mi-sex', "th' dudes", 'tami neilson',
    'smashproof', 'david dallas', 'p-money', 'ladi6', 'bailey wiley', 'montell2099', 'the beths', 'yumi zouma',
    'salmonella dub', 'trinity roots', 'shapeshifter', 'ladyhawke', 'concord dawn', 'upper hutt posse',
    'the chills', 'the clean', 'jon toogood', 'chelsea jade', 'the black seeds', 'kora', 'savage & aaradhna',
  ]),
  'pacific': CultureTheme('Pacific', ['pacific', 'polynesian', 'pasifika', 'islander', 'islanders', 'samoan', 'tongan', 'hawaiian', 'fijian'],
      null, [
    'sons of zion', 'common kings', 'katchafire', 'te vaka', 'lomez', 'corrella', 'tomorrow people', 'l.a.b',
    'house of shem', 'j boog', 'spawnbreezie', 'rebel souljahz', 'kolohe kai', "israel kamakawiwo'ole",
    'jawsh 685', 'three houses down', 'nesian mystik', 'aaradhna', 'fiji', 'stan walker', 'jamestown story',
  ]),
  'reggae': CultureTheme('Reggae', ['reggae', 'dancehall', 'caribbean', 'jamaican', 'jamaica', 'ska', 'roots'],
      RegExp(r'reggae|dancehall|\bska\b|\bdub\b'), [
    'bob marley', 'ub40', 'jimmy cliff', 'peter tosh', 'toots', 'shaggy', 'sean paul', 'damian marley',
    'ziggy marley', 'inner circle', 'chronixx', 'koffee', 'beenie man', 'buju banton', 'popcaan', 'burning spear',
    'steel pulse', 'third world', 'maxi priest', 'katchafire', 'the black seeds', 'j boog', 'protoje',
  ]),
  'latin': CultureTheme('Latin', ['latin', 'latino', 'latina', 'reggaeton', 'spanish', 'salsa', 'bachata', 'cumbia'],
      RegExp(r'latin|urbano|reggaeton|spanish|salsa|bachata|cumbia'), [
    'shakira', 'j balvin', 'bad bunny', 'daddy yankee', 'luis fonsi', 'enrique iglesias', 'ricky martin', 'maluma',
    'ozuna', 'karol g', 'rosalía', 'rosalia', 'becky g', 'becky g.', 'nicky jam', 'marc anthony', 'gloria estefan',
    'pitbull', 'camila cabello', 'santana', 'juanes', 'don omar', 'romeo santos', 'prince royce', 'anitta',
    'sebastián yatra', 'sebastian yatra', 'manu chao', 'los del rio', 'gipsy kings', 'selena', 'celia cruz',
    'mc fioti', 'anuel aa', 'rauw alejandro', 'tainy', 'jennifer lopez', 'juan magán', 'farruko', 'sech',
  ]),
  'afrobeats': CultureTheme('Afrobeats', ['afrobeat', 'afrobeats', 'afro', 'african', 'amapiano', 'naija'],
      RegExp(r'afro|african|amapiano'), [
    'burna boy', 'wizkid', 'davido', 'tems', 'rema', 'ckay', 'fireboy dml', 'tiwa savage', 'yemi alade', 'mr eazi',
    'tekno', 'kizz daniel', 'master kg', 'black coffee', 'sauti sol', 'diamond platnumz', 'fela kuti',
    'angelique kidjo', 'asake', 'ayra starr', 'omah lay', 'joeboy', 'patoranking', 'tyla',
  ]),
};

/// Spooky by its title (or a classic Halloween song).
bool isSpooky(String title, String artist) {
  final t = title.toLowerCase();
  if (_halloweenSongs.any(t.contains)) return true;
  return RegExp(
          r"\b(ghosts?|ghostbusters|monsters?|zombies?|witch(es|y)?|devils?|hells?|haunted|haunting|vampires?|halloween|spooky|scary|skeletons?|graveyard|grave|thriller|frankenstein|dracula|werewol(f|ves)|nightmare|psycho|demons?|voodoo|black magic|superstition|exorcist|horror|creep|reaper|coffin|cemetery|wicked|bury a friend|somebody'?s watching)\b")
      .hasMatch(t.replaceAll('’', "'"));
}

const _halloweenSongs = [
  'monster mash', 'time warp', 'this is halloween', 'bad moon rising', 'highway to hell', 'disturbia',
  'psycho killer', "dead man's party", 'black magic woman', 'i put a spell on you', 'witchy woman',
  'sympathy for the devil', 'enter sandman', "don't fear the reaper", 'people are strange', 'tubular bells',
  'hall of the mountain king', 'danse macabre', 'addams family', 'purple people eater', 'ghost town',
  'season of the witch', 'heads will roll', 'spooky, scary', 'rave in the grave', 'i was made for lovin',
  'hungry like the wolf', 'killer queen', 'super freak', 'zombie', 'thriller', 'ghostbusters',
];

const _punkArtists = [
  'ramones', 'sex pistols', 'the clash', 'green day', 'blink-182', 'blink 182', 'the offspring', 'sum 41',
  'bad religion', 'rancid', 'misfits', 'dead kennedys', 'buzzcocks', 'the damned', 'nofx', 'pennywise',
  'social distortion', 'bad brains', 'the stooges', 'iggy pop', 'billy idol', 'generation x', 'the jam',
  'my chemical romance', 'paramore', 'good charlotte', 'simple plan', 'fall out boy', 'all time low',
  'yellowcard', 'new found glory', 'the living end', 'the saints', 'radio birdman', 'the hives',
  'jimmy eat world', 'avril lavigne', 'machine gun kelly', 'the distillers', 'x-ray spex', 'siouxsie',
];

const _rockNRollArtists = [
  'elvis', 'chuck berry', 'little richard', 'buddy holly', 'jerry lee lewis', 'bill haley', 'everly brothers',
  'eddie cochran', 'fats domino', 'ritchie valens', 'roy orbison', 'gene vincent', 'carl perkins',
  "johnny o'keefe", 'stray cats', 'shakin\' stevens', 'showaddywaddy', 'brian setzer', 'the big bopper',
  'del shannon', 'the crickets', 'wanda jackson', 'sha na na', 'the beach boys',
];

/// Broad genre families, from the genre tag in each file.
String genreFamily(String genre) {
  final g = genre.toLowerCase();
  if (g.contains('hip') || g.contains('rap') || g.contains('trap')) return 'hiphop';
  if (g.contains('r&b') || g.contains('soul') || g.contains('funk')) return 'rnb';
  if (g.contains('house') || g.contains('dance') || g.contains('electr') || g.contains('techno') || g.contains('edm')) {
    return 'dance';
  }
  if (g.contains('rock') || g.contains('alternative') || g.contains('metal') || g.contains('punk') || g.contains('indie')) {
    return 'rock';
  }
  if (g.contains('country')) return 'country';
  if (g.contains('reggae') || g.contains('dancehall') || g.contains('afro')) return 'reggae';
  if (g.contains('jazz') || g.contains('blues')) return 'jazz';
  if (g.contains('latin') || g.contains('reggaeton')) return 'latin';
  if (g.contains('pop') || g.contains('singer')) return 'pop';
  return 'other';
}

const _aussieArtists = [
  'men at work', 'inxs', 'ac/dc', 'acdc', 'midnight oil', 'cold chisel', 'jimmy barnes', 'kylie',
  'savage garden', 'crowded house', 'the veronicas', 'sia', 'vance joy', 'tones and i', 'dean lewis',
  '5 seconds of summer', 'gotye', 'jet', 'silverchair', 'powderfinger', 'hilltop hoods', 'flume',
  'peking duk', 'rufus', 'rüfüs', 'keith urban', 'natalie imbruglia', 'icehouse', 'hunters & collectors',
  'the living end', 'wolfmother', 'john farnham', 'kasey chambers', 'daryl braithwaite', 'missy higgins',
  'jessica mauboy', 'guy sebastian', 'delta goodrem', 'the presets', 'cut copy', 'empire of the sun',
  'tame impala', 'the temper trap', 'angus & julia stone', 'king gizzard', 'g flip', 'the kid laroi',
  'troye sivan', 'iggy azalea', 'vera blue', 'ruel', 'masked wolf', 'pnau', 'the avalanches',
  'bee gees', 'little river band', 'air supply', 'australian crawl', 'divinyls', 'mental as anything',
  'hoodoo gurus', 'the church', 'the angels', 'rose tattoo', 'skyhooks', 'the easybeats', 'birds of tokyo',
  'grinspoon', 'spiderbait', 'shannon noll', 'amy shark', 'courtney barnett', 'meg mac', 'paul kelly',
  'thelma plum', 'baker boy', 'alison wonderland', 'what so not', 'hayden james', 'dom dolla', 'fisher',
  'confidence man', 'lime cordiale', 'spacey jane', 'ocean alley', 'sheppard', 'timmy trumpet',
];

bool isAussie(String artist) {
  final a = artist.toLowerCase();
  return _aussieArtists.any((x) => a.contains(x));
}

VibeProfile parseVibe(String text) {
  final v = VibeProfile();
  final t = text.toLowerCase();
  // Whole words only, so 'run' doesn't match 'brunch'.
  bool has(List<String> words) =>
      words.any((w) => RegExp('(?<![a-z0-9])${RegExp.escape(w)}(?![a-z0-9])').hasMatch(t));

  // Energy / tempo.
  if (has(['rave', 'techno', 'edm', 'club', 'banger', 'hype', 'festival', 'peak time'])) {
    v
      ..targetBpm = 127
      ..startEnergy = 0.7
      ..peakEnergy = 1.0
      ..endEnergy = 0.9
      ..smooth = false;
    v.genres.addAll(['dance', 'pop']);
    v.description.add('Club energy');
  } else if (has(['gym', 'workout', 'run', 'training'])) {
    v
      ..targetBpm = 126
      ..startEnergy = 0.75
      ..peakEnergy = 1.0
      ..endEnergy = 0.95
      ..smooth = false;
    v.description.add('Workout pace');
  } else if (has(['chill', 'cafe', 'café', 'lounge', 'relax', 'dinner', 'sunset', 'background', 'study', 'coffee'])) {
    v
      ..targetBpm = 100
      ..startEnergy = 0.3
      ..peakEnergy = 0.55
      ..endEnergy = 0.35
      ..smooth = true;
    v.description.add('Laid-back');
  } else if (has(['party', 'high energy', 'dance floor', 'dancefloor', 'pumping', 'wedding', 'birthday'])) {
    v
      ..targetBpm = 122
      ..startEnergy = 0.6
      ..peakEnergy = 1.0
      ..endEnergy = 0.85;
    v.description.add('Party energy');
  }

  // Themes.
  final rockNRoll = RegExp(r"\brock(in['’]?g?\s*|\s*(&|and|['’]?n['’]?)\s*)roll|rockabilly|\b50['’]?s\b|fifties").hasMatch(t);
  if (rockNRoll) {
    v.theme = 'rocknroll';
    v.description.add("Rock 'n' roll");
  } else if (has(['punk', 'pop punk', 'pop-punk'])) {
    v.theme = 'punk';
    v.description.add('Punk');
  } else if (has(['halloween', 'horror', 'spooky', 'scary', 'creepy', 'haunted', 'zombie', 'trick or treat', 'monster mash', 'fright night'])) {
    v.theme = 'halloween';
    v.description.add('Halloween');
  } else {
    for (final e in cultureThemes.entries) {
      if (has(e.value.words)) {
        v.theme = e.key;
        v.description.add(e.value.name);
        break;
      }
    }
  }

  // Genres. Named outright, they make a theme night (only those genres).
  final before = {...v.genres};
  if (has(['hip hop', 'hip-hop', 'hiphop', 'rap', 'trap'])) {
    v.genres.add('hiphop');
    if (!has(['rave', 'club', 'techno'])) v.targetBpm = 96;
  }
  if (has(['r&b', 'rnb', 'soul', 'funk'])) v.genres.add('rnb');
  if (!rockNRoll && has(['rock', 'guitar', 'pub'])) v.genres.add('rock');
  if (has(['country', 'cowboy', 'boots'])) v.genres.add('country');
  if (has(['reggae', 'dancehall', 'island', 'afrobeat'])) v.genres.add('reggae');
  if (has(['house', 'dance music', 'electronic'])) v.genres.add('dance');
  if (has(['pop', 'top 40', 'hits', 'chart'])) v.genres.add('pop');
  final named = v.genres.difference(before);
  if (has(['jazz', 'blues'])) v.genres.add('jazz');
  if (has(['latin', 'reggaeton'])) v.genres.add('latin');
  if (v.genres.isNotEmpty) v.description.add(v.genres.map(_familyName).join(' + '));
  v.themeGenres.addAll(named.where((g) => g != 'pop' || has(['pop'])));
  if (v.theme == 'punk') v.themeGenres.remove('rock'); // "punk rock": the punk list decides
  // "reggae" / "latin" / "afrobeat" also name genre families; the theme's own
  // artist list and tags decide (Shakira is tagged Pop).
  if (cultureThemes.containsKey(v.theme)) v.themeGenres.removeAll(['reggae', 'latin']);

  // "country vocals over hip hop beats"
  final over = RegExp(r"([a-z&/ -]+?)\s+(?:vocals?|acapellas?|singing|singers?)\s+(?:over|on|with)\s+(?:a\s+|an\s+)?([a-z&/ -]+?)(?:\s+(?:beats?|instrumentals?|music|grooves?))?(?:$|[,.!])")
      .firstMatch(t);
  if (over != null) {
    String? fam(String words) {
      final f = genreFamily(words);
      return f == 'other' ? null : f;
    }
    final vocalWords = over.group(1)!.split(RegExp(r'[, ]+')).where((w) => w.isNotEmpty).toList();
    v.vocalFamily = fam(vocalWords.skip(math.max(0, vocalWords.length - 2)).join(' '));
    v.beatFamily = fam(over.group(2)!);
    if (v.vocalFamily != null && v.beatFamily != null) {
      v.description.add('${_familyName(v.vocalFamily!)} vocals over ${_familyName(v.beatFamily!)} beats');
    }
  }

  if (has(['aussie', 'australia', 'straya', 'oz rock', 'down under'])) {
    v.aussie = true;
    v.description.add('Aussie flavour');
  }

  // Eras.
  const decadeWords = {'fifties': '50', 'sixties': '60', 'seventies': '70', 'eighties': '80', 'nineties': '90'};
  final word = decadeWords.keys.where((w) => has([w])).firstOrNull;
  final decade = RegExp(r"\b(19)?([5-9]0)['’]?s\b").firstMatch(t);
  final dd = word != null ? decadeWords[word] : decade?.group(2);
  if (dd != null && !(rockNRoll && dd == '50')) {
    final d = 1900 + int.parse(dd);
    v
      ..yearFrom = d
      ..yearTo = d + 9
      ..strictEra = true;
    v.description.add('${dd}s');
  } else if (has(['2000s', 'noughties'])) {
    v
      ..yearFrom = 2000
      ..yearTo = 2009
      ..strictEra = true;
    v.description.add('2000s');
  } else if (has(['throwback', 'old school', 'retro', 'classic'])) {
    v.yearTo = 2005;
    v.description.add('Throwbacks');
  } else if (has(['modern', 'new', 'today', 'latest', 'current', 'fresh', 'recent'])) {
    v.yearFrom = 2018;
    v.description.add('Modern');
  }

  // Shape of the mix.
  if (has(['mashup', 'mash-up', 'mix genres', 'all genres', 'different genres', 'eclectic', 'all over', 'mixed bag', 'variety'])) {
    v.mixGenres = true;
    v.description.add('Genre-hopping');
  }
  if (has(['shazam', 'my favourites', 'my favorites', 'songs i like', 'my songs'])) {
    v.shazamOnly = true;
    v.description.add('Your Shazams');
  }
  if (has(['smooth', 'seamless', 'long blends', 'silky'])) v.smooth = true;
  if (has(['punchy', 'quick cuts', 'fast cuts', 'chop', 'hard'])) v.smooth = false;
  // Set length: "short", "long", "4 hours", "4hrs", "90 minutes", "20 songs".
  final defaultMinutes = v.minutes;
  if (has(['short', 'quick set', 'quick mix'])) v.minutes = 7;
  if (has(['long', 'hour', 'marathon'])) v.minutes = 60;
  if (has(['all night', 'all-nighter'])) v.minutes = 240;
  final hours = RegExp(r'\b(\d+(?:\.\d+)?)\s*(?:h|hr|hrs|hour|hours)\b').firstMatch(t);
  if (hours != null) v.minutes = double.parse(hours.group(1)!) * 60;
  final mins = RegExp(r'\b(\d{1,3})\s*(?:min|mins|minutes)\b').firstMatch(t);
  if (mins != null) v.minutes = double.parse(mins.group(1)!);
  final n = RegExp(r'\b(\d{1,3})\s*(?:songs|tracks|tunes|mashups)\b').firstMatch(t);
  if (n != null) v.minutes = int.parse(n.group(1)!) * 2.2;
  v.lengthSet = v.minutes != defaultMinutes;
  v.minutes = v.minutes.clamp(4, 360);
  v.trackCount = (v.minutes / 2.3).round().clamp(2, 160);
  if (v.minutes >= 60) {
    final h = v.minutes / 60;
    v.description.add('${h == h.roundToDouble() ? h.round() : h.toStringAsFixed(1)}h set');
  }

  final bpm = RegExp(r'\b(\d{2,3})\s*bpm\b').firstMatch(t);
  if (bpm != null) {
    v.targetBpm = int.parse(bpm.group(1)!).toDouble().clamp(70, 180);
    v.bpmSet = true;
  }

  // Warmth character per vibe (Dean's profiles). Drive is applied at half
  // strength above clean, since the mix already runs close to full scale.
  double half(double d) => 1 + (d - 1) * 0.5;
  if (has(['cafe', 'café', 'chill', 'lounge', 'ambient', 'relax', 'background', 'coffee', 'study'])) {
    v
      ..drive = half(1.2)
      ..crackle = 0.7;
  } else if (has(['rave', 'festival', 'techno', 'edm', 'hard', 'pounding'])) {
    v
      ..drive = half(2.2)
      ..crackle = 0.1;
  } else if (v.genres.contains('hiphop') || v.genres.contains('rnb') || has(['urban', 'bounce', 'groove'])) {
    v
      ..drive = half(1.6)
      ..crackle = 0.3;
  } else if (v.genres.contains('rock') || has(['band'])) {
    v
      ..drive = half(1.8)
      ..crackle = 0.5;
  } else {
    v
      ..drive = half(1.4)
      ..crackle = 0.3;
  }

  v.description.add(v.smooth ? 'Smooth blends' : 'Punchy cuts');
  return v;
}

/// The vibe box plus the theme box ("80s", "punk", "Halloween", or any genre
/// tag in your library like "soundtrack").
VibeProfile parseTheme(String vibe, String theme) {
  final th = theme.trim();
  final v = parseVibe(th.isEmpty ? vibe : '$vibe, $th');
  if (th.isNotEmpty && !parseVibe(th).themed) {
    v.genreText = th.toLowerCase();
    v.description.insert(0, th);
  }
  return v;
}

/// Sets the length of a theme night: at least 20 minutes unless you asked
/// for a length, but never more than the songs that fit can fill. Returns a
/// note when the theme is short of songs.
String? fitThemeLength(VibeProfile v, double available) {
  if (!v.themed) return null;
  if (!v.lengthSet) v.minutes = math.max(20, v.minutes);
  String? note;
  if (available < v.minutes) {
    note = available < 4
        ? 'Hardly any of your songs fit this theme — add some to your music folder.'
        : 'Your library has about ${available.round()} min of music for this theme, so the mix is ${available.round()} min. Add more songs to make it longer.';
    v.minutes = math.max(4, available);
  }
  v.trackCount = (v.minutes / 2.3).round().clamp(2, 160);
  return note;
}

/// A theme night plays at the tempo most of its songs sit at, not the
/// preset for "party" (122 BPM would leave out most Kiwi songs, which sit
/// around 80–100). Songs count at half or double time too. Call once the
/// pool is analysed.
void fitThemeTempo(VibeProfile v, List<LibraryTrack> pool) {
  if (!v.themed || v.bpmSet) return;
  final bpms = [for (final t in pool) if (t.analysis != null) t.analysis!.steadyBpm];
  if (bpms.length < 4) return;
  var best = v.targetBpm, bestScore = -1e9;
  for (var t = 76.0; t <= 136; t += 1) {
    var n = 0.0;
    for (final b in bpms) {
      final off = [0.5, 1.0, 2.0].map((f) => (math.log(t / (b * f))).abs()).reduce(math.min);
      if (off < 0.06) n += 1 - off / 0.06; // closer counts for more (less stretching)
    }
    n -= (math.log(t / v.targetBpm)).abs(); // ties: stay near the vibe's tempo
    if (n > bestScore) {
      bestScore = n;
      best = t;
    }
  }
  v.targetBpm = best;
}

String _familyName(String f) => switch (f) {
      'hiphop' => 'Hip-hop',
      'rnb' => 'R&B',
      'dance' => 'Dance',
      'rock' => 'Rock',
      'country' => 'Country',
      'reggae' => 'Reggae',
      'jazz' => 'Jazz',
      'latin' => 'Latin',
      'pop' => 'Pop',
      _ => f,
    };

/// How well a song fits the vibe, from its tags alone (before analysis).
double tagScore(LibraryTrack t, VibeProfile v, math.Random rng) {
  var s = rng.nextDouble() * 0.6; // freshness: every Re-Mix is a little different
  if (t.shazam) s += v.shazamOnly ? 3 : 0.9;
  final fam = genreFamily(t.genre);
  if (v.genres.isNotEmpty) s += v.genres.contains(fam) ? 1.2 : -0.6;
  if (v.aussie && isAussie(t.artist)) s += 2.0;
  if (t.year > 0) {
    if (v.yearFrom != null && t.year < v.yearFrom!) s -= 1.0 + (v.yearFrom! - t.year) / 10;
    if (v.yearTo != null && t.year > v.yearTo!) s -= 1.0 + (t.year - v.yearTo!) / 10;
  }
  if (fam == 'other' && t.genre.toLowerCase().contains('christmas')) s -= 3;
  if (t.duration < 100 || t.duration > 600) s -= 2;
  return s;
}

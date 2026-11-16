import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibeline/stem_cache.dart';

void main() {
  test('sha1 matches the analyser (Python hashlib)', () {
    expect(StemCache.sha1Hex(utf8.encode('')), 'da39a3ee5e6b4b0d3255bfef95601890afd80709');
    expect(StemCache.sha1Hex(utf8.encode('abc')), 'a9993e364706816aba3e25717850c26c9cd0d89d');
    // Longer than one block, with non-ASCII (song paths often have both).
    final s = '/Volumes/Spare Drive/Music/Beyoncé – Déjà Vu (feat. Jay-Z).m4a|8123456|1700000000|stems1';
    expect(StemCache.sha1Hex(utf8.encode(s)), '0c9c4a7d3d18e3b63a2cf09e3f7951125b5a4a45');
  });
}

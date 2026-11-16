import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'models.dart';

/// Whether a song has been split into stems before, without loading them:
/// the analyser keeps each song's stems in a folder named by a SHA-1 of its
/// path, size and modified time (vibeline_ai.py `_stem_dir`, STEM_VERSION 1).
class StemCache {
  static final String dir = '${Platform.environment['HOME'] ?? ''}/Library/Caches/Vibeline/stems';
  static const _version = 1;
  static final Map<String, bool> _known = {};

  /// Split already: stems loaded, or waiting on disk (loading those is instant).
  static bool isSplit(LibraryTrack t) {
    if (t.stems != null) return true;
    return _known.putIfAbsent(t.path, () {
      try {
        final st = File(t.path).statSync();
        if (st.type == FileSystemEntityType.notFound) return false;
        final mtime = st.modified.millisecondsSinceEpoch ~/ 1000;
        final h = sha1Hex(utf8.encode('${t.path}|${st.size}|$mtime|stems$_version'));
        return File('$dir/$h/stems.json').existsSync();
      } catch (_) {
        return false;
      }
    });
  }

  /// For tests.
  static void forget() => _known.clear();

  static String sha1Hex(List<int> message) {
    var h0 = 0x67452301, h1 = 0xEFCDAB89, h2 = 0x98BADCFE, h3 = 0x10325476, h4 = 0xC3D2E1F0;
    final ml = message.length * 8;
    final padded = BytesBuilder()
      ..add(message)
      ..addByte(0x80);
    while ((padded.length % 64) != 56) {
      padded.addByte(0);
    }
    final len = ByteData(8)..setUint64(0, ml);
    padded.add(len.buffer.asUint8List());
    final bytes = ByteData.sublistView(padded.toBytes());
    int rotl(int x, int n) => ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF;
    final w = List<int>.filled(80, 0);
    for (var off = 0; off < bytes.lengthInBytes; off += 64) {
      for (var i = 0; i < 16; i++) {
        w[i] = bytes.getUint32(off + i * 4);
      }
      for (var i = 16; i < 80; i++) {
        w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
      }
      var a = h0, b = h1, c = h2, d = h3, e = h4;
      for (var i = 0; i < 80; i++) {
        int f, k;
        if (i < 20) {
          f = (b & c) | ((~b) & d);
          k = 0x5A827999;
        } else if (i < 40) {
          f = b ^ c ^ d;
          k = 0x6ED9EBA1;
        } else if (i < 60) {
          f = (b & c) | (b & d) | (c & d);
          k = 0x8F1BBCDC;
        } else {
          f = b ^ c ^ d;
          k = 0xCA62C1D6;
        }
        final temp = (rotl(a, 5) + (f & 0xFFFFFFFF) + e + k + w[i]) & 0xFFFFFFFF;
        e = d;
        d = c;
        c = rotl(b, 30);
        b = a;
        a = temp;
      }
      h0 = (h0 + a) & 0xFFFFFFFF;
      h1 = (h1 + b) & 0xFFFFFFFF;
      h2 = (h2 + c) & 0xFFFFFFFF;
      h3 = (h3 + d) & 0xFFFFFFFF;
      h4 = (h4 + e) & 0xFFFFFFFF;
    }
    return [h0, h1, h2, h3, h4].map((x) => x.toRadixString(16).padLeft(8, '0')).join();
  }
}

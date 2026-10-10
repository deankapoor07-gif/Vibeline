import 'dart:convert';

import 'package:flutter/services.dart';

/// Talks to the native mixer (macos/Runner/MainFlutterWindow.swift): renders
/// sections offline and plays a timeline of them back to back.
class Mixer {
  static const _channel = MethodChannel('vibeline/mixer');
  void Function(double progress)? onProgress;

  Mixer() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'progress') onProgress?.call((call.arguments as num).toDouble());
    });
  }

  /// Renders a render-plan (optionally a window of it) to [out].
  Future<String> render(Map<String, dynamic> plan, {required String out, bool reportProgress = true}) async {
    final path = await _channel.invokeMethod<String>('render', {
      'plan': jsonEncode(plan),
      'out': out,
      'reportProgress': reportProgress,
    });
    return path ?? out;
  }

  Future<void> cancel({String? out}) => _channel.invokeMethod('cancel', {if (out != null) 'out': out});

  /// [remap]: when an edit moved the music under the playhead in time, pairs
  /// of [old mix time, new mix time] so the player can switch seamlessly.
  Future<void> setTimeline(List<Map<String, dynamic>> segments, {List<List<double>>? remap}) =>
      _channel.invokeMethod('timeline', {'segments': segments, if (remap != null) 'remap': remap});

  Future<void> play({double? from}) => _channel.invokeMethod('play', {if (from != null) 'from': from});
  Future<void> pause() => _channel.invokeMethod('pause');
  Future<void> seek(double seconds) => _channel.invokeMethod('seek', {'seconds': seconds});

  /// Live adjustments, applied instantly by the player:
  /// {vocal: [{start, end, cents, db}], beat: [{start, end, db}]}.
  Future<void> setLiveMap(Map<String, dynamic> live) => _channel.invokeMethod('liveMap', live);

  Future<void> exportTimeline(List<Map<String, dynamic>> segments, Map<String, dynamic> live, String out) =>
      _channel.invokeMethod('export', {'segments': segments, 'live': live, 'out': out});

  /// (position, playing, waiting-for-a-section-to-render)
  Future<(double, bool, bool)> position() async {
    final m = await _channel.invokeMapMethod<String, dynamic>('position');
    return (
      ((m?['position'] as num?) ?? 0).toDouble(),
      (m?['playing'] as bool?) ?? false,
      (m?['waiting'] as bool?) ?? false,
    );
  }
}

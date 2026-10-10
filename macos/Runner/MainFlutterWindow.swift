import AVFoundation
import Accelerate
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    MixerChannel.shared.attach(to: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

// MARK: - Flutter bridge

/// "vibeline/mixer": renders sections of a mix offline, and plays a timeline
/// of rendered sections back to back without gaps.
final class MixerChannel {
  static let shared = MixerChannel()

  private var channel: FlutterMethodChannel?
  private let renderQueue = DispatchQueue(label: "vibeline.render", qos: .userInitiated)
  private var cancelRequested = false
  private var currentOut: String?
  private let player = TimelinePlayer()

  func attach(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "vibeline/mixer", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "render":
      guard let planJson = args["plan"] as? String, let out = args["out"] as? String else {
        result(FlutterError(code: "args", message: "plan and out are required", details: nil))
        return
      }
      let report = args["reportProgress"] as? Bool ?? true
      renderQueue.async { [weak self] in
        guard let self else { return }
        DispatchQueue.main.sync {
          self.cancelRequested = false
          self.currentOut = out
        }
        do {
          let plan = try JSONDecoder().decode(MixPlan.self, from: Data(planJson.utf8))
          // Two layers: everything else, and the featured vocals (bus 1), which
          // the player runs through a live pitch control.
          let layers: [(MixPlan, String)] = [(plan.layer(vocal: false), out), (plan.layer(vocal: true), out + ".vox.m4a")]
          // Both layers render at once, on two cores.
          var failure: Error?
          let lock = NSLock()
          var progress = [0.0, 0.0]
          DispatchQueue.concurrentPerform(iterations: layers.count) { k in
            let (layer, path) = layers[k]
            if k == 1 && layer.clips.isEmpty {
              try? FileManager.default.removeItem(atPath: path)
              return
            }
            do {
              let tmp = URL(fileURLWithPath: path + ".part.m4a")
              try MixRenderer(plan: layer).render(
                to: tmp,
                progress: { p in
                  guard report else { return }
                  lock.lock(); progress[k] = p; let total = (progress[0] + progress[1]) / 2; lock.unlock()
                  DispatchQueue.main.async { self.channel?.invokeMethod("progress", arguments: total) }
                },
                isCancelled: { self.cancelRequested })
              try? FileManager.default.removeItem(atPath: path)
              try FileManager.default.moveItem(at: tmp, to: URL(fileURLWithPath: path))
            } catch {
              lock.lock(); failure = error; lock.unlock()
            }
          }
          if let failure { throw failure }
          DispatchQueue.main.async { result(out) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "render", message: "\(error)", details: nil))
          }
        }
      }
    case "cancel":
      // Only cancel the render it names (a newer one may have started).
      if let out = args["out"] as? String { if out == currentOut { cancelRequested = true } } else { cancelRequested = true }
      result(nil)
    case "timeline":
      let rows = args["segments"] as? [[String: Any]] ?? []
      let remap = (args["remap"] as? [[Double]])?.filter { $0.count == 2 }
      player.update(rows.map(TimelinePlayer.Segment.init(row:)), remap: remap)
      result(nil)
    case "liveMap":
      player.live = TimelinePlayer.LiveMap(args)
      result(nil)
    case "play":
      player.play(from: args["from"] as? Double)
      result(nil)
    case "pause":
      player.pause()
      result(nil)
    case "seek":
      player.seek(to: (args["seconds"] as? Double) ?? 0)
      result(nil)
    case "position":
      result(["position": player.position, "playing": player.isPlaying, "waiting": player.isWaiting])
    case "export":
      guard let out = args["out"] as? String, let rows = args["segments"] as? [[String: Any]] else {
        result(FlutterError(code: "args", message: "segments and out are required", details: nil))
        return
      }
      let segs = rows.map(TimelinePlayer.Segment.init(row:))
      let live = TimelinePlayer.LiveMap(args["live"] as? [String: Any] ?? [:])
      renderQueue.async {
        do {
          try TimelinePlayer.export(segs, live: live, to: URL(fileURLWithPath: out))
          DispatchQueue.main.async { result(out) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "export", message: "\(error)", details: nil)) }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

// MARK: - Plan (decoded from the Dart planner's JSON)

struct Keyframe: Decodable {
  let t: Double      // seconds in the mix
  let gain: Double   // 0...1
  let low: Double    // dB
  let mid: Double    // dB
  let high: Double   // dB
  let hpf: Double    // Hz (<= 25 = off)
  let lpf: Double    // Hz (>= 19000 = off)
  let echo: Double   // 0...1 wet

  static func lerp(_ a: Keyframe, _ b: Keyframe, _ x: Double) -> Keyframe {
    func l(_ p: Double, _ q: Double) -> Double { p + (q - p) * x }
    // Filters sweep musically on a log scale.
    func lf(_ p: Double, _ q: Double) -> Double { exp(log(p) + (log(q) - log(p)) * x) }
    return Keyframe(
      t: l(a.t, b.t), gain: l(a.gain, b.gain), low: l(a.low, b.low), mid: l(a.mid, b.mid),
      high: l(a.high, b.high), hpf: lf(a.hpf, b.hpf), lpf: lf(a.lpf, b.lpf), echo: l(a.echo, b.echo))
  }
}

struct Clip: Decodable {
  let path: String
  let srcStart: Double
  let srcEnd: Double
  let outStart: Double
  let rate: Double
  let pitchCents: Double
  let gainDb: Double
  let deck: Int
  let echoTime: Double
  let keys: [Keyframe]
  /// Optional beat map [[mixTime, songTime], ...]: the song's speed follows it
  /// so every beat lands where the map says (vocals riding a live recording).
  let warp: [[Double]]?
  /// 1 = featured vocal layer (gets live pitch control); otherwise the main layer.
  let bus: Int?
  /// More stems summed with `path` before stretching (e.g. a beat's melody,
  /// bass and drums): one time-stretch instead of several.
  let mix: [String]?

  /// Where in the song (seconds) playback should be at mix time t.
  func sourceTime(at t: Double) -> Double {
    guard let w = warp, w.count >= 2 else { return srcStart + (t - outStart) * rate }
    var i = 1
    while i < w.count - 1 && w[i][0] < t { i += 1 }
    let a = w[i - 1], b = w[i]
    let slope = (b[1] - a[1]) / max(1e-6, b[0] - a[0])
    return a[1] + (t - a[0]) * slope
  }

  /// Mix time when the clip has played to srcEnd.
  var outEnd: Double {
    guard let w = warp, w.count >= 2 else { return outStart + (srcEnd - srcStart) / rate }
    let a = w[w.count - 2], b = w[w.count - 1]
    let slope = (b[1] - a[1]) / max(1e-6, b[0] - a[0])
    return b[0] + (srcEnd - b[1]) / max(1e-6, slope)
  }

  func automation(at t: Double) -> Keyframe {
    guard let first = keys.first else {
      return Keyframe(t: t, gain: 1, low: 0, mid: 0, high: 0, hpf: 20, lpf: 20000, echo: 0)
    }
    if t <= first.t { return first }
    for i in 1..<keys.count where t < keys[i].t {
      let a = keys[i - 1], b = keys[i]
      let span = b.t - a.t
      return Keyframe.lerp(a, b, span > 0 ? (t - a.t) / span : 1)
    }
    return keys[keys.count - 1]
  }
}

/// Part of the mix to render. Times are mix seconds; the file starts at
/// `start`. Rendering begins `preRoll` earlier so effects are warmed up, and
/// the edges can fade so neighbouring sections crossfade seamlessly.
struct RenderWindow: Decodable {
  let start: Double
  let end: Double
  let preRoll: Double
  let fadeIn: Double
  let fadeOut: Double
}

struct MixPlan: Decodable {
  let duration: Double
  let clips: [Clip]
  let warmth: Warmth?
  let window: RenderWindow?

  /// Just the vocal layer or just the rest. Crackle only goes on the main layer.
  func layer(vocal: Bool) -> MixPlan {
    MixPlan(
      duration: duration, clips: clips.filter { ($0.bus == 1) == vocal },
      warmth: warmth.map { vocal ? Warmth(drive: $0.drive, crackle: 0) : $0 }, window: window)
  }
}

/// Master "analog warmth": tape-style soft saturation plus vinyl crackle.
struct Warmth: Decodable {
  let drive: Double    // 1 = clean; 1.5 = warm
  let crackle: Double  // 0...1
}

/// Applied to the finished mix, block by block.
final class AnalogWarmth {
  private let drive: Float
  private let norm: Float
  private let crackle: Float
  private var pop: Float = 0      // current click level, decays quickly
  private var popSign: Float = 1
  private var hiss: Float = 0     // one-pole filtered noise bed
  private var noiseBuf = [Float](repeating: 0, count: 4096)

  init(_ w: Warmth) {
    drive = Float(max(1, w.drive))
    norm = tanh(drive)
    crackle = Float(min(1, max(0, w.crackle)))
  }

  /// Seed from the block's position in the mix (not from the render), so
  /// sections rendered separately get exactly the same crackle.
  private static func seed(_ frame: Int64) -> UInt64 {
    var x = UInt64(bitPattern: frame) &* 0x9E37_79B9_7F4A_7C15
    x ^= x >> 30; x = x &* 0xBF58_476D_1CE4_E5B9
    x ^= x >> 27; x = x &* 0x94D0_49BB_1331_11EB
    return (x ^ (x >> 31)) | 1
  }

  func process(_ buffer: AVAudioPCMBuffer, at startFrame: AVAudioFramePosition) {
    guard let data = buffer.floatChannelData else { return }
    let channels = Int(buffer.format.channelCount)
    let n = Int(buffer.frameLength)
    if crackle > 0 {
      if noiseBuf.count < n { noiseBuf = [Float](repeating: 0, count: n) }
      // A few soft pops a second at crackle 0.4, like a well-loved record.
      var x = Self.seed(startFrame)
      let popChance = UInt64(Double(crackle) * 0.00025 * Double(UInt64.max >> 11))
      @inline(__always) func next() -> UInt64 {
        x ^= x << 13; x ^= x >> 7; x ^= x << 17
        return x >> 11
      }
      let unit = 1.0 / Float(1 << 53)
      for i in 0..<n {
        if next() < popChance {
          pop = (0.015 + 0.045 * Float(next()) * unit) * crackle * 2
          popSign = next() & 1 == 0 ? 1 : -1
        }
        hiss = 0.995 * hiss + 0.005 * (Float(next()) * unit * 2 - 1)
        // Each pop is a tiny burst of noise that dies away in about a millisecond.
        noiseBuf[i] = pop * popSign * (0.3 + 0.7 * Float(next()) * unit) + hiss * 0.004 * crackle
        pop *= 0.93
        if next() & 1 == 0 { popSign = -popSign }
      }
      for c in 0..<channels { vDSP_vadd(data[c], 1, noiseBuf, 1, data[c], 1, vDSP_Length(n)) }
    }
    if drive > 1.001 {
      // Tape-style soft saturation, vectorised: tanh(x·drive) / tanh(drive).
      var d = drive, k = 1 / norm
      var count = Int32(n)
      for c in 0..<channels {
        vDSP_vsmul(data[c], 1, &d, data[c], 1, vDSP_Length(n))
        vvtanhf(data[c], data[c], &count)
        vDSP_vsmul(data[c], 1, &k, data[c], 1, vDSP_Length(n))
      }
    }
  }
}

// MARK: - Offline renderer

private final class Deck {
  let player = AVAudioPlayerNode()
  let timePitch = AVAudioUnitTimePitch()
  let eq = AVAudioUnitEQ(numberOfBands: 5)
  let delay = AVAudioUnitDelay()
  var clip: Clip?

  // AVAudioUnitTimePitch only plays at rates that are whole steps of 1/512
  // (asking for 0.977 gives 0.9765625), which drifts ~0.4 ms per second. So
  // each block we pick the step that keeps the song exactly where it should
  // be, which also lets a song follow a beat map (warp).
  private var playedFrames = 0.0
  private var srcBase = 0.0
  private var appliedRate: Float = 1

  init() {
    let b = eq.bands
    b[0].filterType = .lowShelf; b[0].frequency = 110; b[0].gain = 0; b[0].bypass = false
    b[1].filterType = .parametric; b[1].frequency = 1000; b[1].bandwidth = 1.5; b[1].gain = 0
    b[1].bypass = false
    b[2].filterType = .highShelf; b[2].frequency = 6500; b[2].gain = 0; b[2].bypass = false
    b[3].filterType = .highPass; b[3].frequency = 20; b[3].bypass = true
    b[4].filterType = .lowPass; b[4].frequency = 20000; b[4].bypass = true
    delay.wetDryMix = 0
    delay.feedback = 45
    delay.lowPassCutoff = 5000
  }

  func resetRate(srcBase: Double) {
    playedFrames = 0
    self.srcBase = srcBase
    appliedRate = -1
  }

  /// Picks the rate for the next [frames] of output starting at mix time t.
  func setRate(at t: Double, frames: Int, sampleRate: Double) {
    guard let c = clip, frames > 0 else { return }
    let target = (c.sourceTime(at: t + Double(frames) / sampleRate) - srcBase) * sampleRate
    let need = (target - playedFrames) / Double(frames)
    let rate = min(2, max(0.5, (need * 512).rounded() / 512))
    playedFrames += rate * Double(frames)
    if Float(rate) != appliedRate {
      appliedRate = Float(rate)
      timePitch.rate = appliedRate
    }
  }

  func apply(_ k: Keyframe) {
    player.volume = Float(min(1, max(0, k.gain)))
    let b = eq.bands
    b[0].gain = Float(k.low)
    b[1].gain = Float(k.mid)
    b[2].gain = Float(k.high)
    b[3].bypass = k.hpf <= 25
    b[3].frequency = Float(max(20, min(18000, k.hpf)))
    b[4].bypass = k.lpf >= 19000
    b[4].frequency = Float(max(40, min(20000, k.lpf)))
    delay.wetDryMix = Float(min(100, max(0, k.echo * 100)))
  }
}

enum RenderError: Error { case cancelled, badFile(String) }

final class MixRenderer {
  private let plan: MixPlan
  private let sampleRate: Double = 44100
  private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

  init(plan: MixPlan) { self.plan = plan }

  func render(
    to url: URL, progress: @escaping (Double) -> Void, isCancelled: @escaping () -> Bool
  ) throws {
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)

    let bus = AVAudioMixerNode()
    let limiter = AVAudioUnitEffect(
      audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0,
        componentFlagsMask: 0))
    engine.attach(bus)
    engine.attach(limiter)
    engine.connect(bus, to: limiter, format: format)
    engine.connect(limiter, to: engine.mainMixerNode, format: format)
    AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.004, 0)
    AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.08, 0)
    AudioUnitSetParameter(limiter.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 0, 0)
    try engine.start()

    try? FileManager.default.removeItem(at: url)
    // Sections are working files: Apple Lossless saves several times faster
    // than AAC (which was most of the render time) and loses nothing. The
    // final export is still AAC.
    let out = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2, AVEncoderBitDepthHintKey: 16,
      ], commonFormat: .pcmFormatFloat32, interleaved: false)

    let win = plan.window ?? RenderWindow(start: 0, end: plan.duration, preRoll: 0, fadeIn: 0, fadeOut: 0)
    let warmth = plan.warmth.map(AnalogWarmth.init)
    // The time-stretch unit's internal processing grid is counted from when the
    // engine starts, so every render starts on the same 8192-frame grid in mix
    // time: a clip then comes out identical whichever section renders it.
    let grid: AVAudioFramePosition = 8192
    let rawStart = AVAudioFramePosition(((win.start - win.preRoll) * sampleRate).rounded(.down))
    let startFrame = Int64((Double(rawStart) / Double(grid)).rounded(.down)) * grid
    let writeFrame = AVAudioFramePosition(win.start * sampleRate)
    let endFrame = AVAudioFramePosition(win.end * sampleRate)
    // Clips that finish before the window are skipped; ones already playing
    // when it opens start part-way through.
    let clips = plan.clips.filter { $0.outEnd + 3 > Double(startFrame) / sampleRate }
      .sorted { $0.outStart < $1.outStart }
    let buffer = AVAudioPCMBuffer(
      pcmFormat: engine.manualRenderingFormat,
      frameCapacity: engine.manualRenderingMaximumFrameCount)!
    // Automation is updated every block; 256 frames (~6 ms) keeps sweeps smooth.
    let block: AVAudioFramePosition = 256
    var frame = startFrame
    var next = 0
    var lastReported = -1.0

    // Every clip gets a fresh deck (player → time-stretch → EQ → echo), removed
    // when it's done: no effect state carries over from an earlier song, so
    // separately rendered sections match exactly.
    var decks: [Deck] = []
    func open(_ clip: Clip, at t: Double) throws {
      let d = Deck()
      [d.player, d.timePitch, d.eq, d.delay].forEach { engine.attach($0) }
      engine.connect(d.player, to: d.timePitch, format: format)
      engine.connect(d.timePitch, to: d.eq, format: format)
      engine.connect(d.eq, to: d.delay, format: format)
      engine.connect(d.delay, to: bus, format: format)
      try start(clip, on: d, at: t)
      decks.append(d)
    }

    while next < clips.count, AVAudioFramePosition(clips[next].outStart * sampleRate) <= frame {
      try open(clips[next], at: Double(frame) / sampleRate)
      next += 1
    }

    while frame < endFrame {
      if isCancelled() { throw RenderError.cancelled }

      // Start every clip that begins exactly now. Blocks are cut so a clip
      // start always lands on a block boundary — sample-accurate entries.
      while next < clips.count, AVAudioFramePosition(clips[next].outStart * sampleRate) <= frame {
        try open(clips[next], at: clips[next].outStart)
        next += 1
      }
      // Let go of decks whose clip (and echo tail) has finished.
      let now = Double(frame) / sampleRate
      decks.removeAll { d in
        guard let c = d.clip, now > c.outEnd + 4 else { return false }
        d.player.stop()
        [d.player, d.timePitch, d.eq, d.delay].forEach { engine.detach($0) }
        return true
      }

      // Blocks follow a fixed grid in mix time (plus clip starts), so any two
      // renders of the same moment make identical decisions and match exactly.
      var n = min(block - ((frame % block) + block) % block, endFrame - frame)
      if next < clips.count {
        let s = AVAudioFramePosition(clips[next].outStart * sampleRate)
        if s > frame { n = min(n, s - frame) }
      }

      let t = Double(frame) / sampleRate
      for d in decks {
        if let c = d.clip {
          d.apply(c.automation(at: t))
          d.setRate(at: t, frames: Int(n), sampleRate: sampleRate)
        }
      }
      let status = try engine.renderOffline(AVAudioFrameCount(n), to: buffer)
      if frame + n > writeFrame && (status == .success || status == .insufficientDataFromInputNode) {
        warmth?.process(buffer, at: frame)
        // Whole blocks are always rendered (so decisions match other renders);
        // only the part from the section start is kept.
        var from = frame
        if frame < writeFrame {
          let skip = Int(writeFrame - frame)
          let keep = Int(buffer.frameLength) - skip
          for c in 0..<Int(buffer.format.channelCount) {
            memmove(buffer.floatChannelData![c], buffer.floatChannelData![c] + skip, keep * MemoryLayout<Float>.size)
          }
          buffer.frameLength = AVAudioFrameCount(keep)
          from = writeFrame
        }
        applyFades(buffer, from: from, win: win)
        try out.write(from: buffer)
      }
      frame += n

      let p = Double(frame - startFrame) / Double(max(1, endFrame - startFrame))
      if p - lastReported >= 0.01 {
        lastReported = p
        progress(p)
      }
    }
    engine.stop()
    progress(1)
  }

  private func applyFades(_ buffer: AVAudioPCMBuffer, from frame: AVAudioFramePosition, win: RenderWindow) {
    guard win.fadeIn > 0 || win.fadeOut > 0, let data = buffer.floatChannelData else { return }
    for i in 0..<Int(buffer.frameLength) {
      let t = Double(frame + AVAudioFramePosition(i)) / sampleRate
      // Sections are cut where both renders are identical, so a short linear
      // crossfade joins them seamlessly.
      var g = 1.0
      if win.fadeIn > 0 && t < win.start + win.fadeIn { g = max(0, (t - win.start) / win.fadeIn) }
      if win.fadeOut > 0 && t > win.end - win.fadeOut { g = min(g, max(0, (win.end - t) / win.fadeOut)) }
      if g < 1 {
        for c in 0..<Int(buffer.format.channelCount) { data[c][i] *= Float(g) }
      }
    }
  }

  private func start(_ clip: Clip, on deck: Deck, at t: Double) throws {
    deck.player.stop()
    deck.timePitch.reset()
    deck.delay.reset()
    deck.timePitch.rate = Float((clip.rate * 512).rounded() / 512)
    deck.timePitch.pitch = Float(clip.pitchCents)
    deck.eq.globalGain = Float(max(-24, min(24, clip.gainDb)))
    deck.delay.delayTime = max(0.05, min(2, clip.echoTime))
    deck.clip = clip
    let from = max(clip.srcStart, clip.sourceTime(at: t))
    deck.resetRate(srcBase: from)
    deck.apply(clip.automation(at: t))
    guard from < clip.srcEnd - 0.01 else { deck.clip = nil; return }
    let segment = try loadSegment(clip, from: from)
    deck.player.scheduleBuffer(segment, at: nil, options: [], completionHandler: nil)
    deck.player.play()
  }

  /// Reads [from, srcEnd) of the clip's file(s) as 44.1 kHz stereo float,
  /// summing any extra stems in.
  private func loadSegment(_ clip: Clip, from: Double) throws -> AVAudioPCMBuffer {
    let main = try loadFile(clip.path, from: from, to: clip.srcEnd)
    for extra in clip.mix ?? [] {
      let b = try loadFile(extra, from: from, to: clip.srcEnd)
      let n = Int(min(main.frameLength, b.frameLength))
      for c in 0..<2 {
        let d = main.floatChannelData![c], e = b.floatChannelData![c]
        for i in 0..<n { d[i] += e[i] }
      }
    }
    return main
  }

  private func loadFile(_ path: String, from: Double, to srcEnd: Double) throws -> AVAudioPCMBuffer {
    let clip = (path: path, srcEnd: srcEnd)
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: clip.path))
    let src = file.processingFormat
    let a = max(0, AVAudioFramePosition(from * src.sampleRate))
    let b = min(file.length, AVAudioFramePosition(clip.srcEnd * src.sampleRate))
    guard b > a else { throw RenderError.badFile(clip.path) }
    file.framePosition = a
    let count = AVAudioFrameCount(b - a)
    guard let raw = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: count) else {
      throw RenderError.badFile(clip.path)
    }
    try file.read(into: raw, frameCount: count)
    return try convert(raw, to: format, path: clip.path)
  }
}

func convert(_ raw: AVAudioPCMBuffer, to format: AVAudioFormat, path: String) throws -> AVAudioPCMBuffer {
  let src = raw.format
  if src.sampleRate == format.sampleRate && src.channelCount == format.channelCount
    && src.commonFormat == format.commonFormat && src.isInterleaved == format.isInterleaved
  {
    return raw
  }
  guard let converter = AVAudioConverter(from: src, to: format) else { throw RenderError.badFile(path) }
  if src.channelCount == 1 { converter.channelMap = [0, 0] }
  let capacity = AVAudioFrameCount(Double(raw.frameLength) * format.sampleRate / src.sampleRate) + 4096
  guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
    throw RenderError.badFile(path)
  }
  var fed = false
  var convError: NSError?
  converter.convert(to: converted, error: &convError) { _, status in
    if fed {
      status.pointee = .endOfStream
      return nil
    }
    fed = true
    status.pointee = .haveData
    return raw
  }
  if let convError { throw convError }
  return converted
}

// MARK: - Live timeline player

/// Plays rendered sections back to back on the engine's sample clock, so a
/// 4-hour set never drifts. Each section has a main layer and a vocal layer;
/// the vocal layer runs through a live pitch control, so pitch moves are
/// instant (like the key knob on DJ hardware), with no re-rendering.
final class TimelinePlayer {
  struct Segment: Equatable {
    let path: String?
    let voxPath: String?
    let start: Double  // mix time the files start at
    let end: Double    // mix time they end (including the fade-out tail)

    init(path: String?, voxPath: String?, start: Double, end: Double) {
      self.path = path
      self.voxPath = voxPath
      self.start = start
      self.end = end
    }

    init(row: [String: Any]) {
      self.init(
        path: row["path"] as? String, voxPath: row["voxPath"] as? String,
        start: (row["start"] as? Double) ?? 0, end: (row["end"] as? Double) ?? 0)
    }
  }

  /// Your live adjustments over a stretch of the mix: vocal pitch (cents)
  /// and volume (dB) for the vocal layer or the main (beat) layer.
  struct LiveRegion {
    let start: Double
    let end: Double
    let cents: Double
    let db: Double

    init(row: [String: Any]) {
      start = (row["start"] as? Double) ?? 0
      end = (row["end"] as? Double) ?? 0
      cents = (row["cents"] as? Double) ?? 0
      db = (row["db"] as? Double) ?? 0
    }
  }

  struct LiveMap {
    var vocal: [LiveRegion] = []
    var beat: [LiveRegion] = []

    init() {}
    init(_ args: [String: Any]) {
      vocal = (args["vocal"] as? [[String: Any]] ?? []).map(LiveRegion.init(row:))
      beat = (args["beat"] as? [[String: Any]] ?? []).map(LiveRegion.init(row:))
    }

    /// (vocal cents, vocal dB, beat dB) at mix time t.
    func at(_ t: Double) -> (Float, Float, Float) {
      let v = vocal.first(where: { t >= $0.start && t < $0.end })
      let b = beat.first(where: { t >= $0.start && t < $0.end })
      return (Float(v?.cents ?? 0), Float(v?.db ?? 0), Float(b?.db ?? 0))
    }
  }

  /// Smooths volume moves (≈80 ms) so faders never click.
  struct Smoothed {
    var value: Float = 0
    mutating func toward(_ target: Float, _ k: Float) -> Float {
      value += (target - value) * k
      if abs(target - value) < 0.01 { value = target }
      return value
    }
  }

  private struct Active {
    let beat: AVAudioPlayerNode
    let vox: AVAudioPlayerNode?
    let beatBuf: AVAudioPCMBuffer
    let voxBuf: AVAudioPCMBuffer?
    let path: String
    let bufferStart: Double  // mix time of buffer frame 0
  }

  private let sr = 44100.0
  private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
  private let engine = AVAudioEngine()
  private let beatBus = AVAudioMixerNode()
  private let voxBus = AVAudioMixerNode()
  private let voxPitch = AVAudioUnitTimePitch()
  private let voxGain = AVAudioUnitEQ(numberOfBands: 1)
  private let beatGain = AVAudioUnitEQ(numberOfBands: 1)
  private let master = AVAudioMixerNode()
  private let limiter = TimelinePlayer.makeLimiter()
  private var voxDb = Smoothed()
  private var beatDb = Smoothed()

  private var segments: [Segment] = []
  private var active: [Int: Active] = [:]
  private var loading: Set<Int> = []
  private var swapping: [Int: String] = [:]
  private var beatPool: [AVAudioPlayerNode] = []
  private var voxPool: [AVAudioPlayerNode] = []
  private var timer: Timer?
  private var pitchTimer: Timer?
  private let loadQueue = DispatchQueue(label: "vibeline.load", qos: .userInitiated)

  var live = LiveMap() {
    didSet { applyLive() }
  }

  private(set) var isPlaying = false
  private var anchorSample: AVAudioFramePosition = 0  // engine sample time of anchorPos
  private var anchorPos = 0.0
  private var pausedPos = 0.0
  private var generation = 0  // bumps on every restart so stale loads are dropped

  init() {
    Self.wire(engine, beatBus: beatBus, beatGain: beatGain, voxBus: voxBus, voxPitch: voxPitch, voxGain: voxGain,
      master: master, limiter: limiter, format: format)
    // All player nodes are created up front: attaching nodes to a running
    // engine stalls audio (and, on this app's shared thread, the screen).
    for _ in 0..<16 {
      for vocal in [false, true] {
        let n = AVAudioPlayerNode()
        engine.attach(n)
        engine.connect(n, to: vocal ? voxBus : beatBus, format: format)
        if vocal { voxPool.append(n) } else { beatPool.append(n) }
      }
    }
    engine.prepare()
    // Live controls follow the playhead closely (vocals never overlap between
    // mashups, so switching value between them is seamless).
    pitchTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in self?.applyLive() }
  }

  /// main layer → gain ─┐
  /// vocal layer → pitch → gain ─┴→ master → limiter → out
  static func wire(
    _ engine: AVAudioEngine, beatBus: AVAudioMixerNode, beatGain: AVAudioUnitEQ, voxBus: AVAudioMixerNode,
    voxPitch: AVAudioUnitTimePitch, voxGain: AVAudioUnitEQ, master: AVAudioMixerNode, limiter: AVAudioUnitEffect,
    format: AVAudioFormat
  ) {
    for g in [voxGain, beatGain] { g.bands[0].bypass = true }
    [beatBus, beatGain, voxBus, voxPitch, voxGain, master, limiter].forEach { engine.attach($0) }
    engine.connect(beatBus, to: beatGain, format: format)
    engine.connect(beatGain, to: master, format: format)
    engine.connect(voxBus, to: voxPitch, format: format)
    engine.connect(voxPitch, to: voxGain, format: format)
    engine.connect(voxGain, to: master, format: format)
    engine.connect(master, to: limiter, format: format)
    engine.connect(limiter, to: engine.mainMixerNode, format: format)
  }

  static func makeLimiter() -> AVAudioUnitEffect {
    let l = AVAudioUnitEffect(
      audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    AudioUnitSetParameter(l.audioUnit, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.004, 0)
    AudioUnitSetParameter(l.audioUnit, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.08, 0)
    AudioUnitSetParameter(l.audioUnit, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, 4.0, 0)
    return l
  }

  private func applyLive() {
    let (cents, vdb, bdb) = live.at(position)
    if voxPitch.pitch != cents { voxPitch.pitch = cents }
    voxGain.globalGain = voxDb.toward(vdb, 0.25)
    beatGain.globalGain = beatDb.toward(bdb, 0.25)
  }

  private var nowSample: AVAudioFramePosition? {
    guard let t = engine.mainMixerNode.lastRenderTime, t.isSampleTimeValid else { return nil }
    return t.sampleTime
  }

  /// Position on the timeline actually playing right now.
  private var rawPosition: Double {
    guard isPlaying, let now = nowSample else { return pausedPos }
    return max(anchorPos, anchorPos + Double(now - anchorSample) / sr)
  }

  /// Position in the current (latest) timeline. While an edit that moved
  /// the music in time is being swapped in, the old position is mapped over.
  var position: Double {
    let p = rawPosition
    return remap.map { Self.mapped(p, $0) } ?? p
  }

  // An edit moved the music under the playhead in time (e.g. a tempo change):
  // pairs of [old mix time, new mix time]. The old audio keeps playing until
  // the new section is ready, then it crossfades at the same musical moment.
  private var remap: [[Double]]?
  private var retiring: [Active] = []
  private var switching = false

  static func mapped(_ t: Double, _ map: [[Double]]) -> Double {
    guard let first = map.first, let last = map.last else { return t }
    if t <= first[0] { return t + (first[1] - first[0]) }
    if t >= last[0] { return t + (last[1] - last[0]) }
    var i = 1
    while i < map.count - 1 && map[i][0] < t { i += 1 }
    let a = map[i - 1], b = map[i]
    let f = (t - a[0]) / max(1e-9, b[0] - a[0])
    return a[1] + f * (b[1] - a[1])
  }

  /// True while playing but the section under the playhead isn't rendered yet.
  var isWaiting: Bool {
    guard isPlaying else { return false }
    let p = position
    guard let i = segments.firstIndex(where: { p >= $0.start && p < $0.end }) else { return false }
    return active[i] == nil
  }

  func update(_ new: [Segment], remap newRemap: [[Double]]? = nil) {
    if let newRemap, !isPlaying, !newRemap.isEmpty {
      // Edited while paused: resume at the same musical moment.
      pausedPos = Self.mapped(pausedPos, newRemap)
    }
    if let newRemap, isPlaying, !newRemap.isEmpty {
      // Keep everything that's playing going; switch over once ready.
      if remap == nil {
        retiring.append(contentsOf: active.values)
        active.removeAll()
        remap = newRemap
      } else {
        // A second edit before the first landed: compose the maps.
        remap = remap!.map { [$0[0], Self.mapped($0[1], newRemap)] }
      }
      segments = new
      loading.removeAll()
      swapping.removeAll()
      tick()
      return
    }
    let p = position
    for (i, a) in active {
      let sameStart = i < new.count && i < segments.count && abs(new[i].start - segments[i].start) < 1e-3
      let changed = !sameStart || new[i].path != a.path
      guard changed else { continue }
      let audible = i < segments.count && p >= segments[i].start - 0.3 && p < segments[i].end
      if audible && isPlaying && sameStart {
        // The part playing right now was edited. Never go silent: keep the old
        // audio until the new version is rendered and loaded, then crossfade.
        if let newPath = new[i].path, swapping[i] != newPath {
          swapping[i] = newPath
          crossfade(i, to: new[i])
        }
        continue
      }
      if audible && isPlaying {
        fadeOut(a, at: p + 0.1)
        let nodes = (a.beat, a.vox)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.recycle(nodes.0, nodes.1) }
      } else {
        recycle(a.beat, a.vox)
      }
      active[i] = nil
      swapping[i] = nil
    }
    segments = new
    loading.removeAll()
    tick()
  }

  func play(from pos: Double? = nil) {
    if let pos { pausedPos = pos }
    if !engine.isRunning { try? engine.start() }
    stopAll()
    guard let now = nowSample else {
      // Engine needs a render cycle before it has a clock; try again shortly.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.play(from: pos) }
      return
    }
    anchorSample = now + AVAudioFramePosition(0.12 * sr)
    anchorPos = pausedPos
    isPlaying = true
    generation += 1
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    tick()
  }

  func pause() {
    pausedPos = rawPosition
    isPlaying = false
    timer?.invalidate()
    stopAll()
  }

  /// Jumps while playing without a gap: the new spot is loaded first, then
  /// crossfaded in over 60 ms (sample-accurate, on the engine clock).
  func seek(to pos: Double) {
    guard isPlaying, remap == nil, !seeking else {
      if isPlaying { play(from: pos) } else { pausedPos = pos }
      return
    }
    guard let j = segments.firstIndex(where: { pos >= $0.start && pos < $0.end }), let path = segments[j].path
    else { play(from: pos); return }
    seeking = true
    let s = segments[j]
    let gen = generation
    // Pick the switch moment now (old timeline) and load the new spot in the
    // background ready to go: the main thread then only schedules it.
    let tOld = rawPosition + 0.35
    let switchSample = anchorSample + AVAudioFramePosition(((tOld - anchorPos) * sr).rounded())
    loadQueue.async { [weak self] in
      guard let self else { return }
      let beat = try? Self.read(path, from: pos - s.start, format: self.format, fadeIn: 0.06)
      let vox = s.voxPath.flatMap { try? Self.read($0, from: pos - s.start, format: self.format, fadeIn: 0.06) }
      DispatchQueue.main.async {
        self.seeking = false
        guard gen == self.generation, self.isPlaying, let beat else { self.play(from: pos); return }
        guard self.rawPosition < tOld - 0.02 else { self.play(from: pos); return }  // loading was too slow
        let old = Array(self.active.values)
        for a in old { self.fadeOut(a, at: tOld, over: 0.06) }
        self.active.removeAll()
        self.loading.removeAll()
        self.swapping.removeAll()
        self.generation += 1  // drop loads that were for the old spot
        self.anchorSample = switchSample
        self.anchorPos = pos
        self.start(j, beat: beat, vox: vox, path: path, at: pos)
        DispatchQueue.main.asyncAfter(deadline: .now() + (tOld - self.rawPosition) + 0.4) {
          for a in old { self.recycle(a.beat, a.vox) }
        }
        self.tick()
      }
    }
  }
  private var seeking = false

  private func stopAll() {
    for (_, a) in active { recycle(a.beat, a.vox) }
    for a in retiring { recycle(a.beat, a.vox) }
    retiring.removeAll()
    if let r = remap { pausedPos = Self.mapped(pausedPos, r) }
    remap = nil
    switching = false
    active.removeAll()
    loading.removeAll()
    swapping.removeAll()
  }

  private func recycle(_ beat: AVAudioPlayerNode, _ vox: AVAudioPlayerNode?) {
    beat.stop()
    if !beatPool.contains(beat) { beatPool.append(beat) }
    if let vox {
      vox.stop()
      if !voxPool.contains(vox) { voxPool.append(vox) }
    }
  }

  private func freshNode(vocal: Bool) -> AVAudioPlayerNode {
    if vocal, let n = voxPool.popLast() { return n }
    if !vocal, let n = beatPool.popLast() { return n }
    let n = AVAudioPlayerNode()
    engine.attach(n)
    engine.connect(n, to: vocal ? voxBus : beatBus, format: format)
    return n
  }

  private func when(_ t: Double) -> AVAudioTime {
    AVAudioTime(sampleTime: anchorSample + AVAudioFramePosition(((t - anchorPos) * sr).rounded()), atRate: sr)
  }

  /// Keeps the next few seconds scheduled and lets go of finished sections.
  private func tick() {
    guard isPlaying else { return }
    if remap != nil {
      trySwitch()
      return
    }
    let p = position
    for (i, a) in active where i >= segments.count || segments[i].end < p - 0.5 {
      recycle(a.beat, a.vox)
      active[i] = nil
    }
    for (i, s) in segments.enumerated() where s.end > p && s.start < p + 10 {
      guard active[i] == nil, !loading.contains(i), let path = s.path else { continue }
      schedule(i, s, path: path, playhead: p)
    }
  }

  private func schedule(_ i: Int, _ s: Segment, path: String, playhead p: Double) {
    loading.insert(i)
    let gen = generation
    // Joining late (seek / restart): start a moment ahead with a fade-in.
    let late = p + 0.3 > s.start
    let from = late ? max(s.start, p + 0.3) : s.start
    loadQueue.async { [weak self] in
      guard let self else { return }
      // The fade-in for a late join is done here in the background.
      let beat = try? Self.read(path, from: from - s.start, format: self.format, fadeIn: late ? 0.03 : 0)
      let vox = s.voxPath.flatMap { try? Self.read($0, from: from - s.start, format: self.format, fadeIn: late ? 0.03 : 0) }
      DispatchQueue.main.async {
        self.loading.remove(i)
        guard let beat, gen == self.generation, self.isPlaying, i < self.segments.count,
          self.segments[i].path == path, self.active[i] == nil
        else { return }
        // Normally the section is ready well ahead and is used as loaded; only
        // if loading took too long is it trimmed so it still starts in the future.
        let start = max(from, self.position + 0.05)
        let trim = start - from > 0.001
        let b = trim ? Self.slice(beat, from: start - from, fadeIn: 0.03) : beat
        let v = trim ? vox.map { Self.slice($0, from: start - from, fadeIn: 0.03) } : vox
        self.start(i, beat: b, vox: v, path: path, at: start)
      }
    }
  }

  private func start(_ i: Int, beat: AVAudioPCMBuffer, vox: AVAudioPCMBuffer?, path: String, at t: Double) {
    let bn = freshNode(vocal: false)
    bn.scheduleBuffer(beat, at: nil, options: [], completionHandler: nil)
    var vn: AVAudioPlayerNode?
    if let vox {
      let n = freshNode(vocal: true)
      n.scheduleBuffer(vox, at: nil, options: [], completionHandler: nil)
      vn = n
    }
    let w = when(t)
    bn.play(at: w)
    vn?.play(at: w)
    active[i] = Active(beat: bn, vox: vn, beatBuf: beat, voxBuf: vox, path: path, bufferStart: t)
  }

  /// Swaps from the old timeline to the new one at the same musical moment,
  /// once the new section under the playhead is rendered and loaded.
  private func trySwitch() {
    guard let map = remap, !switching else { return }
    let ahead = Self.mapped(rawPosition + 0.7, map)
    guard let j = segments.firstIndex(where: { ahead >= $0.start && ahead < $0.end }),
      let path = segments[j].path
    else { return }
    switching = true
    let s = segments[j]
    let gen = generation
    let from = ahead
    loadQueue.async { [weak self] in
      guard let self else { return }
      let beat = try? Self.read(path, from: from - s.start, format: self.format)
      let vox = s.voxPath.flatMap { try? Self.read($0, from: from - s.start, format: self.format) }
      DispatchQueue.main.async {
        self.switching = false
        guard gen == self.generation, self.isPlaying, let map = self.remap, let beat,
          j < self.segments.count, self.segments[j].path == path
        else { return }
        // Switch where the new audio begins (it was loaded a little ahead), or,
        // if loading was slow, a moment from now at the matching point.
        let raw = self.rawPosition
        let inverse = map.map { [$0[1], $0[0]] }
        var tOld = Self.mapped(from, inverse)
        if tOld < raw + 0.05 { tOld = raw + 0.08 }
        let tNew = max(from, Self.mapped(tOld, map))
        let b = Self.slice(beat, from: tNew - from, fadeIn: 0.08)
        let v = vox.map { Self.slice($0, from: tNew - from, fadeIn: 0.08) }
        let switchSample = self.anchorSample + AVAudioFramePosition(((tOld - self.anchorPos) * self.sr).rounded())
        let old = self.retiring
        for a in old { self.fadeOut(a, at: tOld, over: 0.08) }
        self.retiring.removeAll()
        self.remap = nil
        self.anchorSample = switchSample
        self.anchorPos = tNew
        self.start(j, beat: b, vox: v, path: path, at: tNew)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
          for a in old { self.recycle(a.beat, a.vox) }
        }
        self.tick()
      }
    }
  }

  /// Replaces the section playing now with its newly rendered version: loads
  /// it fully first, then crossfades over 80 ms a moment later. No gap.
  private func crossfade(_ i: Int, to s: Segment) {
    guard let path = s.path else { return }
    let gen = generation
    let t = position + 0.45
    loadQueue.async { [weak self] in
      guard let self else { return }
      guard let beat = try? Self.read(path, from: t - s.start, format: self.format, fadeIn: 0.08) else { return }
      let vox = s.voxPath.flatMap { try? Self.read($0, from: t - s.start, format: self.format, fadeIn: 0.08) }
      DispatchQueue.main.async {
        guard gen == self.generation, self.isPlaying, self.swapping[i] == path, i < self.segments.count,
          self.segments[i].path == path, let old = self.active[i]
        else { return }
        self.swapping[i] = nil
        if self.rawPosition > t - 0.02 {
          // Loading was too slow for the chosen moment: try again shortly.
          self.swapping[i] = path
          self.crossfade(i, to: s)
          return
        }
        self.fadeOut(old, at: t, over: 0.08)
        self.active[i] = nil
        self.start(i, beat: beat, vox: vox, path: path, at: t)
        DispatchQueue.main.asyncAfter(deadline: .now() + (t - self.rawPosition) + 0.4) {
          self.recycle(old.beat, old.vox)
        }
      }
    }
  }

  static func read(_ path: String, from offset: Double, format: AVAudioFormat, fadeIn: Double = 0) throws
    -> AVAudioPCMBuffer
  {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let a = AVAudioFramePosition(max(0, offset) * file.processingFormat.sampleRate)
    guard a < file.length else { throw RenderError.badFile(path) }
    file.framePosition = a
    let count = AVAudioFrameCount(file.length - a)
    guard let raw = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
      throw RenderError.badFile(path)
    }
    try file.read(into: raw, frameCount: count)
    let buf = try convert(raw, to: format, path: path)
    let n = min(Int(buf.frameLength), Int(fadeIn * format.sampleRate))
    if n > 0, let d = buf.floatChannelData {
      for i in 0..<n {
        let g = Float(i) / Float(n)
        for c in 0..<Int(format.channelCount) { d[c][i] *= g }
      }
    }
    return buf
  }

  /// A copy of [buf] from [offset] seconds on, with an optional fade-in.
  static func slice(_ buf: AVAudioPCMBuffer, from offset: Double, fadeIn: Double) -> AVAudioPCMBuffer {
    let sr = buf.format.sampleRate
    let skip = min(Int(buf.frameLength), max(0, Int((offset * sr).rounded())))
    let keep = Int(buf.frameLength) - skip
    let out = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: AVAudioFrameCount(max(1, keep)))!
    out.frameLength = AVAudioFrameCount(keep)
    let ch = Int(buf.format.channelCount)
    for c in 0..<ch {
      memcpy(out.floatChannelData![c], buf.floatChannelData![c] + skip, keep * MemoryLayout<Float>.size)
    }
    let n = min(keep, Int(fadeIn * sr))
    if n > 0 {
      for i in 0..<n {
        let g = Float(i) / Float(n)
        for c in 0..<ch { out.floatChannelData![c][i] *= g }
      }
    }
    return out
  }

  /// Fades a scheduled section out from mix time t (it keeps playing silence).
  private func fadeOut(_ a: Active, at t: Double, over fade: Double = 0.05) {
    for buf in [a.beatBuf, a.voxBuf].compactMap({ $0 }) {
      guard let d = buf.floatChannelData else { continue }
      let start = max(0, Int((t - a.bufferStart) * sr))
      let len = Int(buf.frameLength)
      guard start < len else { continue }
      let n = max(1, Int(fade * sr))
      let fadeEnd = min(len, start + n)
      // Only a second of silence after the fade: the node is stopped well
      // before that runs out, so there's no need to wipe the whole buffer
      // (which on the shared main thread could hitch the screen).
      let silentEnd = min(len, fadeEnd + Int(sr))
      for c in 0..<2 {
        for i in start..<fadeEnd { d[c][i] *= 1 - Float(i - start) / Float(n) }
        if fadeEnd < silentEnd { memset(d[c] + fadeEnd, 0, (silentEnd - fadeEnd) * MemoryLayout<Float>.size) }
      }
    }
  }

  /// Renders the whole set to one file the same way the player plays it:
  /// sections back to back, the vocal layer through the pitch control
  /// (following the pitch map), and the master limiter.
  static func export(_ segs: [Segment], live: LiveMap, to url: URL) throws {
    let sr = 44100.0
    let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
    let engine = AVAudioEngine()
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
    let beatBus = AVAudioMixerNode(), voxBus = AVAudioMixerNode(), master = AVAudioMixerNode()
    let voxPitch = AVAudioUnitTimePitch()
    let voxGain = AVAudioUnitEQ(numberOfBands: 1), beatGain = AVAudioUnitEQ(numberOfBands: 1)
    let limiter = makeLimiter()
    wire(engine, beatBus: beatBus, beatGain: beatGain, voxBus: voxBus, voxPitch: voxPitch, voxGain: voxGain,
      master: master, limiter: limiter, format: format)
    var voxDb = Smoothed(), beatDb = Smoothed()
    try engine.start()

    try? FileManager.default.removeItem(at: url)
    let out = try AVAudioFile(
      forWriting: url,
      settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sr, AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 256_000,
      ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
    let total = AVAudioFramePosition(((segs.last?.end ?? 0) * sr).rounded())
    var frame: AVAudioFramePosition = 0
    var next = 0
    var playing: [(nodes: [AVAudioPlayerNode], endFrame: AVAudioFramePosition)] = []

    while frame < total {
      // Start sections exactly on their first sample.
      while next < segs.count, AVAudioFramePosition((segs[next].start * sr).rounded()) <= frame {
        let s = segs[next]
        guard let path = s.path else { throw RenderError.badFile("section \(next) not ready") }
        var nodes: [AVAudioPlayerNode] = []
        for (file, bus) in [(path, beatBus), (s.voxPath, voxBus)] {
          guard let file else { continue }
          let buf = try read(file, from: 0, format: format)
          let n = AVAudioPlayerNode()
          engine.attach(n)
          engine.connect(n, to: bus, format: format)
          n.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
          n.play()
          nodes.append(n)
        }
        playing.append((nodes, AVAudioFramePosition((s.end * sr).rounded()) + 4096))
        next += 1
      }
      var n = min(AVAudioFramePosition(512), total - frame)
      if next < segs.count {
        let s = AVAudioFramePosition((segs[next].start * sr).rounded())
        if s > frame { n = min(n, s - frame) }
      }
      let (cents, vdb, bdb) = live.at(Double(frame) / sr)
      voxPitch.pitch = cents
      voxGain.globalGain = voxDb.toward(vdb, 0.12)
      beatGain.globalGain = beatDb.toward(bdb, 0.12)
      let status = try engine.renderOffline(AVAudioFrameCount(n), to: buffer)
      if status == .success || status == .insufficientDataFromInputNode { try out.write(from: buffer) }
      frame += n
      playing.removeAll { p in
        guard frame > p.endFrame else { return false }
        p.nodes.forEach { $0.stop(); engine.detach($0) }
        return true
      }
    }
    engine.stop()
  }
}

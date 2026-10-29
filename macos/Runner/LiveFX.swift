import AVFoundation

// Live performance effects for the player, like a DJ mixer's:
//   Colour FX: one knob per channel (beat layer, vocal layer). Centre is off;
//     turn left or right for the two flavours of the chosen effect.
//   Beat FX: on the master, timed to the beat under the playhead. Pads switch
//     them on (tap = stays on, hold = only while held).
// Each runs inside an in-process audio unit, so it sits in the player's
// AVAudioEngine chain like Apple's own effects.

// MARK: - Building blocks

/// Two-pole filter (RBJ cookbook), transposed direct form II.
struct Biquad {
  var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
  var z1: Float = 0, z2: Float = 0

  mutating func set(_ kind: Int, _ f: Float, _ q: Float, _ sr: Float) {
    let w = 2 * Float.pi * min(max(f, 10), sr * 0.45) / sr
    let c = cos(w), alpha = sin(w) / (2 * q)
    let a0 = 1 + alpha
    switch kind {
    case 0:  // low-pass
      b0 = (1 - c) / 2 / a0; b1 = (1 - c) / a0; b2 = b0
    case 1:  // high-pass
      b0 = (1 + c) / 2 / a0; b1 = -(1 + c) / a0; b2 = b0
    default:  // band-pass, 0 dB peak
      b0 = alpha / a0; b1 = 0; b2 = -alpha / a0
    }
    a1 = -2 * c / a0
    a2 = (1 - alpha) / a0
  }

  @inline(__always) mutating func run(_ x: Float) -> Float {
    let y = b0 * x + z1
    z1 = b1 * x - a1 * y + z2
    z2 = b2 * x - a2 * y
    return y
  }

  mutating func reset() { z1 = 0; z2 = 0 }
}

/// A stereo delay line read at any (fractional) distance behind the write head.
final class DelayLine {
  let size: Int
  let l: UnsafeMutablePointer<Float>
  let r: UnsafeMutablePointer<Float>
  var w = 0

  init(seconds: Double, sr: Double) {
    size = Int(seconds * sr)
    l = .allocate(capacity: size); l.initialize(repeating: 0, count: size)
    r = .allocate(capacity: size); r.initialize(repeating: 0, count: size)
  }
  deinit { l.deallocate(); r.deallocate() }

  @inline(__always) func write(_ a: Float, _ b: Float) {
    l[w] = a; r[w] = b
    w += 1
    if w == size { w = 0 }
  }

  /// [d] samples behind the most recent write (d ≥ 1).
  @inline(__always) func read(_ d: Float) -> (Float, Float) {
    var p = Float(w) - d
    while p < 0 { p += Float(size) }
    let i = Int(p) % size, j = (i + 1) % size, f = p - Float(Int(p))
    return (l[i] + (l[j] - l[i]) * f, r[i] + (r[j] - r[i]) * f)
  }

  /// At absolute position [p] (wraps).
  @inline(__always) func at(_ p: Double) -> (Float, Float) {
    var q = p.truncatingRemainder(dividingBy: Double(size))
    if q < 0 { q += Double(size) }
    let i = Int(q), j = (i + 1) % size, f = Float(q - Double(i))
    return (l[i] + (l[j] - l[i]) * f, r[i] + (r[j] - r[i]) * f)
  }

  func clear() {
    l.update(repeating: 0, count: size)
    r.update(repeating: 0, count: size)
  }
}

/// Pitch shifter: two read heads sweeping through a short delay line,
/// crossfaded so their sum stays level. Used inside feedback loops, where
/// its slight graininess is part of the sound.
final class PitchShifter {
  private let line: DelayLine
  private let window: Float
  private var phase: Float = 0
  var ratio: Float = 1

  init(sr: Double) {
    line = DelayLine(seconds: 0.2, sr: sr)
    window = Float(0.07 * sr)
  }

  @inline(__always) func run(_ a: Float, _ b: Float) -> (Float, Float) {
    line.write(a, b)
    phase += (1 - ratio) / window
    phase -= floor(phase)
    let p2 = (phase + 0.5) - floor(phase + 0.5)
    let g1 = sin(Float.pi * phase), g2 = sin(Float.pi * p2)
    let x = line.read(1 + phase * window), y = line.read(1 + p2 * window)
    return (x.0 * g1 * g1 + y.0 * g2 * g2, x.1 * g1 * g1 + y.1 * g2 * g2)
  }
}

/// Freeverb (Jezar's public-domain design): 8 damped combs + 4 allpasses
/// per side.
final class Reverb {
  private final class Comb {
    let buf: UnsafeMutablePointer<Float>; let n: Int; var i = 0; var store: Float = 0
    init(_ n: Int) { self.n = n; buf = .allocate(capacity: n); buf.initialize(repeating: 0, count: n) }
    deinit { buf.deallocate() }
    @inline(__always) func run(_ x: Float, _ fb: Float, _ damp: Float) -> Float {
      let y = buf[i]
      store = y * (1 - damp) + store * damp
      buf[i] = x + store * fb
      i += 1; if i == n { i = 0 }
      return y
    }
  }
  private final class Allpass {
    let buf: UnsafeMutablePointer<Float>; let n: Int; var i = 0
    init(_ n: Int) { self.n = n; buf = .allocate(capacity: n); buf.initialize(repeating: 0, count: n) }
    deinit { buf.deallocate() }
    @inline(__always) func run(_ x: Float) -> Float {
      let b = buf[i]
      buf[i] = x + b * 0.5
      i += 1; if i == n { i = 0 }
      return b - x
    }
  }

  private let combs: [[Comb]]
  private let alls: [[Allpass]]
  var feedback: Float = 0.84
  var damp: Float = 0.25

  init(sr: Double) {
    let k = sr / 44100
    let c = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617], a = [556, 441, 341, 225]
    combs = [0, 23].map { s in c.map { Comb(Int(Double($0 + s) * k)) } }
    alls = [0, 23].map { s in a.map { Allpass(Int(Double($0 + s) * k)) } }
  }

  @inline(__always) func run(_ inL: Float, _ inR: Float) -> (Float, Float) {
    let x = (inL + inR) * 0.015
    var out: (Float, Float) = (0, 0)
    for side in 0..<2 {
      var s: Float = 0
      for c in combs[side] { s += c.run(x, feedback, damp) }
      for a in alls[side] { s = a.run(s) }
      if side == 0 { out.0 = s * 3 } else { out.1 = s * 3 }
    }
    return out
  }
}

// MARK: - Colour FX

/// One channel's Colour FX. [knob] runs -1…1; 0 (the centre) is off.
final class ColourFX {
  enum Kind: Int { case filter = 0, crush, noise, gateComp }

  var kind = Kind.filter
  var knob: Float = 0  // set from the main thread
  private var k: Float = 0  // smoothed
  private var lastKind = Kind.filter
  private let sr: Float
  private var low = [Biquad(), Biquad()]
  private var high = [Biquad(), Biquad()]
  private var held: (Float, Float) = (0, 0)
  private var holdCount = 0
  private var env: Float = 0
  private var gain: Float = 1
  private var seed: UInt32 = 0x1234_5678

  init(sr: Double) { self.sr = Float(sr) }

  @inline(__always) private func noise() -> Float {
    seed = seed &* 1_664_525 &+ 1_013_904_223
    return Float(Int32(bitPattern: seed)) / Float(Int32.max)
  }

  private func setFilters(_ lpFrom: Float, _ lpTo: Float, _ hpTo: Float, _ a: Float, q: Float) {
    let f = k < 0 ? lpFrom * pow(lpTo / lpFrom, a) : 20 * pow(hpTo / 20, a)
    for c in 0..<2 {
      if k < 0 { low[c].set(0, f, q, sr) } else { high[c].set(1, f, q, sr) }
    }
  }

  @inline(__always) private func filtered(_ x: Float, _ c: Int) -> Float {
    k < 0 ? low[c].run(x) : high[c].run(x)
  }

  func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
    // ~40 ms glide so a knob turn never clicks.
    k += (knob - k) * min(1, Float(n) / (0.04 * sr))
    if kind != lastKind || abs(k) < 0.004 {
      lastKind = kind
      for c in 0..<2 { low[c].reset(); high[c].reset() }
      env = 0; gain = 1; holdCount = 0
      if abs(k) < 0.004 { return }
    }
    let a = abs(k)
    switch kind {
    case .filter:
      // Left: low-pass closing from 20 kHz to 150 Hz. Right: high-pass
      // opening from 20 Hz to 6 kHz. A little resonance as it goes.
      setFilters(20000, 150, 6000, a, q: 0.8 + 0.9 * a)
      for i in 0..<n { l[i] = filtered(l[i], 0); r[i] = filtered(r[i], 1) }

    case .crush:
      // Fewer bits and a lower sample rate, plus a filter on the knob's side.
      let levels = pow(2, 16 - 13.5 * a)
      let hold = 1 + Int(a * a * 30)
      setFilters(20000, 1200, 1500, a * 0.8, q: 0.707)
      for i in 0..<n {
        if holdCount <= 0 {
          held = ((l[i] * levels).rounded() / levels, (r[i] * levels).rounded() / levels)
          holdCount = hold
        }
        holdCount -= 1
        l[i] = filtered(held.0, 0); r[i] = filtered(held.1, 1)
      }

    case .noise:
      // White noise mixed in, the whole lot through the knob's filter.
      setFilters(20000, 300, 5000, a, q: 1.0)
      let level = 0.3 * a
      for i in 0..<n {
        let z = noise() * level
        l[i] = filtered(l[i] + z, 0); r[i] = filtered(r[i] + z, 1)
      }

    case .gateComp:
      if k < 0 {
        // Gate: everything under the threshold drops out, chopping the sound.
        let th = pow(10, (-40 + 40 * a) / 20)
        let att: Float = 1 - exp(-1 / (0.001 * sr)), rel: Float = 1 - exp(-1 / (0.02 * sr))
        let gOpen: Float = 1 - exp(-1 / (0.001 * sr)), gClose: Float = 1 - exp(-1 / (0.02 * sr))
        for i in 0..<n {
          let x = max(abs(l[i]), abs(r[i]))
          env += (x - env) * (x > env ? att : rel)
          let target: Float = env > th ? 1 : 0
          gain += (target - gain) * (target > gain ? gOpen : gClose)
          l[i] *= gain; r[i] *= gain
        }
      } else {
        // Compressor: squashes the peaks and brings the level back up, so
        // it hits harder and sounds louder.
        let thDb = -6 - 24 * a, ratio = 1 + 7 * a
        let makeup = pow(10, (-thDb * (1 - 1 / ratio) * 0.9) / 20)
        let att: Float = 1 - exp(-1 / (0.005 * sr)), rel: Float = 1 - exp(-1 / (0.12 * sr))
        for i in 0..<n {
          let x = max(abs(l[i]), abs(r[i]))
          env += (x - env) * (x > env ? att : rel)
          let lvl = 20 * log10(max(env, 1e-6))
          let over = max(0, lvl - thDb)
          let g = pow(10, -over * (1 - 1 / ratio) / 20) * makeup
          l[i] *= g; r[i] *= g
        }
      }
    }
  }
}

// MARK: - Beat FX

final class BeatFX {
  enum Kind: Int {
    case echo = 0, delay, pingPong, spiral, reverb, shimmer, flanger, phaser, filter, trans, roll, pitchRoll, vinylBrake
  }

  // Set from the main thread.
  var kind = Kind.echo
  var on = false
  var beats: Double = 1  // the effect's length in beats (1/16 … 16)
  var depth: Float = 0.6  // level / depth, 0…1
  private var syncPhase: Double = 0
  private var syncLen: Double = 0.5
  private var syncSerial = 0

  /// Where the playhead is on the beat grid (beats since the start) and how
  /// long a beat lasts there (seconds).
  func sync(phase: Double, beatLen: Double) {
    syncPhase = phase
    syncLen = beatLen
    syncSerial &+= 1
  }

  private let sr: Double
  private var phase: Double = 0  // beats
  private var beatLen: Double = 0.5
  private var seenSerial = 0

  // Shared state.
  private let history: DelayLine  // the last few seconds of dry sound (roll, brake)
  private let echoLine: DelayLine
  private let reverb: Reverb
  private let shifter: PitchShifter
  private let shimmerShifter: PitchShifter
  private let shortLine: DelayLine  // flanger
  private var echoDelay: Float = 22050  // samples, glides to its target
  private var send: Float = 0  // into the echo / reverb (follows `on`)
  private var wet: Float = 0  // insert effects' mix (follows `on`)
  private var echoTone: (Float, Float) = (0, 0)
  private var lastFb: (Float, Float) = (0, 0)
  private var shimmerFb: (Float, Float) = (0, 0)
  private var fbAp = [[Float]](repeating: [Float](repeating: 0, count: 12), count: 2)
  private var phaserFb: (Float, Float) = (0, 0)
  private var flangeFb: (Float, Float) = (0, 0)
  private var sweep = [Biquad(), Biquad()]
  private var transGain: Float = 1

  // Roll / brake.
  private var wasOn = false
  private var loopStart = 0.0  // history position the loop starts at
  private var loopLen = 0.0
  private var loopPos = 0.0
  private var rollRate = 1.0
  private var heldFor = 0.0  // seconds since the pad went down
  private var brakePos = 0.0
  private var brakeSpeed = 1.0
  private var takeover: Float = 0  // roll / brake vs the live sound

  init(sr: Double) {
    self.sr = sr
    history = DelayLine(seconds: 12, sr: sr)
    echoLine = DelayLine(seconds: 9, sr: sr)
    reverb = Reverb(sr: sr)
    shifter = PitchShifter(sr: sr)
    shimmerShifter = PitchShifter(sr: sr)
    shortLine = DelayLine(seconds: 0.05, sr: sr)
  }

  func process(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, _ n: Int) {
    if seenSerial != syncSerial {
      seenSerial = syncSerial
      phase = syncPhase
      beatLen = max(0.2, min(2, syncLen))
    }
    let kind = self.kind, on = self.on, depth = self.depth
    let length = max(1.0 / 16, beats) * beatLen  // seconds
    let spb = beatLen * sr  // samples per beat
    let fast: Float = Float(1 - exp(-1 / (0.004 * sr)))  // ~4 ms glides

    // Echo family: delay time locked to the beat.
    let echoTarget = Float(min(8.5, max(0.02, length)) * sr)
    let feedback: Float
    switch kind {
    case .delay: feedback = 0.3
    case .pingPong: feedback = 0.62
    case .spiral: feedback = 0.8
    default: feedback = 0.6
    }
    shifter.ratio = pow(2, 1.0 / 12)  // spiral: each repeat a semitone higher
    shimmerShifter.ratio = 2  // shimmer: an octave up
    reverb.feedback = 0.84

    // Roll / brake start the moment the pad goes down.
    let grabs = kind == .roll || kind == .pitchRoll || kind == .vinylBrake
    let tails = !grabs && kind.rawValue <= Kind.shimmer.rawValue
    let inserts = kind == .flanger || kind == .phaser || kind == .filter || kind == .trans
    if on && !wasOn && grabs {
      loopStart = Double(history.w)
      loopLen = max(0.03 * sr, min(4 * sr, length * sr))
      loopPos = 0
      rollRate = 1
      heldFor = 0
      brakePos = Double(history.w) - 1
      brakeSpeed = 1
    }
    wasOn = on

    for i in 0..<n {
      let x = l[i], y = r[i]
      history.write(x, y)
      var oL = x, oR = y

      // --- tails: echo / delay / ping pong / spiral, reverb / shimmer.
      let sendTarget: Float = on && tails ? 1 : 0
      send += (sendTarget - send) * fast
      echoDelay += (echoTarget - echoDelay) * 0.0005
      let (eL, eR) = echoLine.read(echoDelay)
      var inL: Float = 0, inR: Float = 0
      switch kind {
      case .echo, .delay:
        // Feedback darkened a little each time round, like tape.
        echoTone.0 += (eL - echoTone.0) * 0.35
        echoTone.1 += (eR - echoTone.1) * 0.35
        inL = x * send + echoTone.0 * feedback
        inR = y * send + echoTone.1 * feedback
      case .pingPong:
        // Mono in on the left; each side feeds the other, so repeats bounce.
        inL = (x + y) * 0.5 * send + eR * feedback
        inR = eL * feedback
      case .spiral:
        let (pL, pR) = shifter.run(eL * feedback, eR * feedback)
        echoTone.0 += (pL - echoTone.0) * 0.5
        echoTone.1 += (pR - echoTone.1) * 0.5
        inL = x * send + echoTone.0
        inR = y * send + echoTone.1
      default:
        // Not an echo pad: let any echo still ringing die away.
        inL = eL * 0.55
        inR = eR * 0.55
      }
      echoLine.write(inL, inR)
      // Delay stops when the pad lets go; the others ring out.
      let echoOut: Float = kind == .delay ? send : 1
      oL += eL * depth * echoOut
      oR += eR * depth * echoOut

      let revIn: (Float, Float)
      if kind == .reverb || kind == .shimmer {
        var a = x * send, b = y * send
        if kind == .shimmer {
          // Soft-limited, so the octave feedback can't build up forever.
          a += tanh(shimmerFb.0 * 0.12); b += tanh(shimmerFb.1 * 0.12)
        }
        revIn = (a, b)
      } else {
        revIn = (0, 0)
      }
      let (vL, vR) = reverb.run(revIn.0, revIn.1)
      if kind == .shimmer {
        shimmerFb = shimmerShifter.run(vL, vR)
      } else {
        shimmerFb = (0, 0)
      }
      oL += vL * depth * 0.6
      oR += vR * depth * 0.6

      // --- insert effects: flanger, phaser, filter, trans.
      let wetTarget: Float = on && inserts ? 1 : 0
      wet += (wetTarget - wet) * fast
      if wet > 0.0001 {
        let lfo = Float(0.5 - 0.5 * cos(2 * Double.pi * (phase / max(1.0 / 16, beats))))
        var pL = oL, pR = oR
        switch kind {
        case .flanger:
          shortLine.write(oL + flangeFb.0 * 0.6, oR + flangeFb.1 * 0.6)
          let d = Float(sr) * (0.0008 + 0.0065 * lfo)
          let (fL, fR) = shortLine.read(d)
          flangeFb = (fL, fR)
          pL = (oL + fL) * 0.7; pR = (oR + fR) * 0.7
        case .phaser:
          // Six all-pass stages swept between ~250 Hz and ~2.5 kHz.
          let f = 250 * pow(10, lfo)
          let t = tan(Float.pi * f / Float(sr))
          let c = (t - 1) / (t + 1)
          for side in 0..<2 {
            var s = (side == 0 ? oL : oR) + (side == 0 ? phaserFb.0 : phaserFb.1) * 0.55
            for st in 0..<6 {
              let x1 = fbAp[side][st * 2], y1 = fbAp[side][st * 2 + 1]
              let out = c * s + x1 - c * y1
              fbAp[side][st * 2] = s
              fbAp[side][st * 2 + 1] = out
              s = out
            }
            if side == 0 { phaserFb.0 = s; pL = (oL + s) * 0.7 } else { phaserFb.1 = s; pR = (oR + s) * 0.7 }
          }
        case .filter:
          if i % 16 == 0 {
            let f = 200 * pow(40, lfo)
            sweep[0].set(0, f, 3, Float(sr)); sweep[1].set(0, f, 3, Float(sr))
          }
          pL = sweep[0].run(oL); pR = sweep[1].run(oR)
        case .trans:
          // Cut on and off on every division of the beat.
          let frac = (phase / max(1.0 / 16, beats)).truncatingRemainder(dividingBy: 1)
          let g: Float = frac < 0.5 ? 1 : 0
          transGain += (g - transGain) * 0.02
          pL = oL * transGain; pR = oR * transGain
        default:
          break
        }
        let mix = wet * depth
        oL = oL * (1 - mix) + pL * mix
        oR = oR * (1 - mix) + pR * mix
      }

      // --- roll, pitch roll, vinyl brake: replace the live sound while held.
      let takeTarget: Float = on && grabs ? 1 : 0
      takeover += (takeTarget - takeover) * Float(1 - exp(-1 / (0.006 * sr)))
      if takeover > 0.0001 {
        var gL: Float = 0, gR: Float = 0
        if kind == .vinylBrake {
          if brakeSpeed > 0 {
            (gL, gR) = history.at(brakePos)
            let fade = Float(min(1, brakeSpeed * 3))
            gL *= fade; gR *= fade
            brakePos += brakeSpeed
            brakeSpeed -= 1 / (max(0.25, min(8, length)) * sr)
          }
        } else if kind == .roll || kind == .pitchRoll {
          (gL, gR) = history.at(loopStart + loopPos)
          // A tiny fade at the loop's seam so it doesn't click.
          let edge = min(loopPos, loopLen - loopPos) / (0.003 * sr)
          let g = Float(min(1, edge))
          gL *= g; gR *= g
          loopPos += rollRate
          if loopPos >= loopLen { loopPos -= loopLen }
          if kind == .pitchRoll {
            // Pitch slides down while held (as far as an octave at full depth).
            heldFor += 1 / sr
            rollRate = 1 - Double(depth) * 0.5 * min(1, heldFor / (4 * beatLen))
          }
        }
        let mix = takeover * (kind == .vinylBrake ? 1 : max(depth, 0.5))
        oL = oL * (1 - mix) + gL * mix
        oR = oR * (1 - mix) + gR * mix
      }

      l[i] = oL
      r[i] = oR
      phase += 1 / spb
    }
  }
}

// MARK: - Audio units

/// Hosts a block of DSP as an effect in an AVAudioEngine chain.
final class FXUnit: AUAudioUnit {
  static let colourDesc = AudioComponentDescription(
    componentType: kAudioUnitType_Effect, componentSubType: 0x636F_6C66,  // 'colf'
    componentManufacturer: 0x4E6F_6F64, componentFlags: 0, componentFlagsMask: 0)  // 'Nood'
  static let beatDesc = AudioComponentDescription(
    componentType: kAudioUnitType_Effect, componentSubType: 0x6265_6166,  // 'beaf'
    componentManufacturer: 0x4E6F_6F64, componentFlags: 0, componentFlagsMask: 0)

  static let registered: Void = {
    AUAudioUnit.registerSubclass(FXUnit.self, as: colourDesc, name: "Noodles: Colour FX", version: 1)
    AUAudioUnit.registerSubclass(FXUnit.self, as: beatDesc, name: "Noodles: Beat FX", version: 1)
  }()

  /// Makes an effect node running [process] (called on the audio thread with
  /// the left and right channels and the frame count).
  static func make(_ desc: AudioComponentDescription, _ process: @escaping (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Void)
    -> AVAudioUnitEffect
  {
    _ = registered
    let node = AVAudioUnitEffect(audioComponentDescription: desc)
    (node.auAudioUnit as? FXUnit)?.process = process
    return node
  }

  var process: ((UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int) -> Void)?
  private var inputs: AUAudioUnitBusArray!
  private var outputs: AUAudioUnitBusArray!
  private static let maxFrames = 8192
  // The input is pulled into these (one buffer per channel).
  private let inL = UnsafeMutablePointer<Float>.allocate(capacity: FXUnit.maxFrames)
  private let inR = UnsafeMutablePointer<Float>.allocate(capacity: FXUnit.maxFrames)
  private let inList = AudioBufferList.allocate(maximumBuffers: 2)

  override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = [])
    throws
  {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    try super.init(componentDescription: componentDescription, options: options)
    inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: format)])
    outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
    maximumFramesToRender = AUAudioFrameCount(Self.maxFrames)
  }

  deinit {
    inL.deallocate()
    inR.deallocate()
    free(inList.unsafeMutablePointer)
  }

  override var inputBusses: AUAudioUnitBusArray { inputs }
  override var outputBusses: AUAudioUnitBusArray { outputs }

  override var internalRenderBlock: AUInternalRenderBlock {
    let inL = self.inL, inR = self.inR, inList = self.inList
    return { [weak self] _, timestamp, frames, _, output, _, pullInput in
      guard let pullInput else { return kAudioUnitErr_NoConnection }
      guard Int(frames) <= FXUnit.maxFrames else { return kAudioUnitErr_TooManyFramesToProcess }
      let bytes = frames * 4
      inList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(inL))
      inList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(inR))
      var pullFlags = AudioUnitRenderActionFlags()
      let status = pullInput(&pullFlags, timestamp, frames, 0, inList.unsafeMutablePointer)
      guard status == noErr else { return status }
      let out = UnsafeMutableAudioBufferListPointer(output)
      for b in 0..<min(out.count, 2) {
        let src = inList[b].mData!
        if out[b].mData == nil {
          out[b].mData = src
        } else if out[b].mData != src {
          memcpy(out[b].mData, src, Int(bytes))
        }
        out[b].mDataByteSize = bytes
      }
      if out.count >= 2, let process = self?.process,
        let l = out[0].mData?.assumingMemoryBound(to: Float.self),
        let r = out[1].mData?.assumingMemoryBound(to: Float.self)
      {
        process(l, r, Int(frames))
      }
      return noErr
    }
  }
}

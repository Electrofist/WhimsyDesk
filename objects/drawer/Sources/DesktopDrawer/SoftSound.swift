import AppKit
import AVFoundation

/// All of the app's sound, synthesized; there are no audio assets.
///
/// - `play(_:volume:)`: muted wooden knocks, rendered once into in-memory WAVs.
/// - `slide`: a quiet wood-on-wood rumble whose loudness follows the drawer's speed. The audio engine
///   runs only while the drawer is moving and is stopped shortly after it comes to rest.
enum SoftSound {
    enum Kind { case close, open }

    private static var knocks: [Kind: NSSound] = [:]

    static func play(_ kind: Kind, volume: Float) {
        if knocks[kind] == nil { knocks[kind] = NSSound(data: makeWAV(kind)) }
        guard let sound = knocks[kind] else { return }
        sound.stop()
        sound.volume = volume
        sound.play()
    }

    // MARK: Sliding

    /// Shared with the render callback. Plain stores of a Float from the main thread are fine here:
    /// a torn read could only produce one odd sample of a noise signal.
    private final class SlideState {
        var target: Float = 0
        var level: Float = 0
        var seed: UInt32 = 0x2545_F491
        var rumble: Float = 0
        var scrape: Float = 0
        var catchEnv: Float = 0
        var wobble: Float = 0
    }

    private static let state = SlideState()
    private static var engine: AVAudioEngine?
    private static var pendingStop: DispatchWorkItem?

    static func beginSlide() {
        pendingStop?.cancel()
        pendingStop = nil
        if engine == nil { engine = makeEngine() }
        guard let e = engine, !e.isRunning else { return }
        try? e.start()
    }

    static func slide(speed: CGFloat) {
        state.target = Float(min(1, speed * 0.5)) * 0.22
    }

    static func endSlide() {
        state.target = 0
        pendingStop?.cancel()
        let work = DispatchWorkItem { engine?.stop() }          // releases the audio hardware entirely
        pendingStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private static func makeEngine() -> AVAudioEngine {
        let e = AVAudioEngine()
        let s = state
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let node = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            for f in 0..<Int(frameCount) {
                s.level += (s.target - s.level) * 0.0012           // ~20 ms glide, no zipper noise
                s.seed = s.seed &* 1_664_525 &+ 1_013_904_223
                let white = Float(Int32(bitPattern: s.seed)) / Float(Int32.max)
                s.rumble += 0.03 * (white - s.rumble)                // low body of the runners
                s.scrape += 0.22 * (white - s.scrape)                // fine grain dragging over wood
                s.wobble += 0.0004 * (white - s.wobble)              // slow unevenness in the rubbing
                if white > 0.99975 { s.catchEnv = 1 }                // the odd tiny catch in the grain
                s.catchEnv *= 0.9965
                let texture = 1 + s.wobble * 40
                let sample = (s.rumble * 2.4 * texture + (s.scrape - s.rumble) * 0.16 + s.catchEnv * s.scrape * 0.6) * s.level
                for b in buffers { b.mData?.assumingMemoryBound(to: Float.self)[f] = sample }
            }
            return noErr
        }
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: format)
        return e
    }

    // MARK: Knocks

    /// Wood-body modes (frequency, decay/s, amplitude) excited by a short, felt-softened impact.
    private static func makeWAV(_ kind: Kind) -> Data {
        let rate = 44_100
        let duration = kind == .close ? 0.26 : 0.16
        let count = Int(duration * Double(rate))
        let modes: [(Float, Float, Float)] = kind == .close
            ? [(98, 20, 1.0), (214, 30, 0.42), (377, 48, 0.22), (611, 75, 0.10)]     // panel against the carcass
            : [(176, 38, 0.7), (402, 60, 0.35), (835, 95, 0.16)]                   // box against the stop block
        // The close has a second, smaller bump: the drawer settling back off the bumpers.
        let hits: [(Float, Float)] = kind == .close ? [(0, 1), (0.062, 0.22)] : [(0, 1)]

        var pcm = [Int16]()
        pcm.reserveCapacity(count)
        var seed: UInt32 = 12_345
        var soft: Float = 0
        for i in 0..<count {
            let t = Float(i) / Float(rate)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max)
            soft += 0.12 * (noise - soft)
            var sample: Float = 0
            for (start, gain) in hits where t >= start {
                let u = t - start
                let attack = min(1, u / 0.0018)                                  // felt: no hard click
                var body: Float = 0
                for (freq, decay, amp) in modes { body += sin(2 * .pi * freq * u) * exp(-u * decay) * amp }
                let impact = soft * exp(-u * 160) * (kind == .close ? 0.5 : 0.7)
                sample += (body * 0.55 + impact) * attack * gain
            }
            pcm.append(Int16(max(-1, min(1, sample)) * 24_000))
        }

        var data = Data()
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put32(UInt32(36 + count * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16); put16(1); put16(1)
        put32(UInt32(rate)); put32(UInt32(rate * 2)); put16(2); put16(16)
        data.append(contentsOf: Array("data".utf8)); put32(UInt32(count * 2))
        pcm.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}

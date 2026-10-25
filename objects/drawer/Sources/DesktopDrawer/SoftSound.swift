import AppKit

/// The only sound in the app: one short, soft thump. Synthesized once into an in-memory WAV,
/// so there is no asset to ship and no audio engine running between plays.
enum SoftSound {
    private static var cached: NSSound?

    static func play(volume: Float) {
        if cached == nil { cached = NSSound(data: makeWAV()) }
        guard let sound = cached else { return }
        sound.stop()
        sound.volume = volume
        sound.play()
    }

    private static func makeWAV() -> Data {
        let rate = 44_100
        let count = Int(0.16 * Double(rate))
        var pcm = [Int16]()
        pcm.reserveCapacity(count)

        var seed: UInt32 = 12_345
        var lowpass: Float = 0
        for i in 0..<count {
            let t = Float(i) / Float(rate)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Float(Int32(bitPattern: seed)) / Float(Int32.max)
            lowpass += 0.06 * (noise - lowpass)                                   // felt-like, dull noise
            let thump = sin(2 * Float.pi * (95 - 220 * t) * t) * exp(-t * 30)    // short falling low tone
            let felt = lowpass * 2.2 * exp(-t * 55)
            let attack = min(1, t / 0.003)                                        // no click at the start
            let sample = (thump * 0.8 + felt * 0.5) * attack
            pcm.append(Int16(max(-1, min(1, sample)) * 22_000))
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

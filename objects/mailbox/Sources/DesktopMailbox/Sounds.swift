import AppKit

/// The mailbox's sounds. A recording in Resources/Sounds/<name>.wav is used if it exists;
/// otherwise the sound is made in code, modelled on the real thing (sheet metal ringing, a hinge
/// squeaking, paper crackling). Built once on first use. Nothing loops and nothing is scheduled.
enum Sounds {
    enum Name: String { case clunk, thud, creak, arrive, rustle, drop, seal }

    static var enabled: Bool {
        get { !UserDefaults.standard.bool(forKey: "soundOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "soundOff") }
    }

    private static var cache: [Name: NSSound] = [:]

    static func play(_ name: Name, volume: Float = 1) {
        guard enabled else { return }
        if cache[name] == nil {
            if let url = Bundle.main.url(forResource: name.rawValue, withExtension: "wav") {
                cache[name] = NSSound(contentsOf: url, byReference: false)
            } else {
                cache[name] = NSSound(data: wav(make(name)))
            }
        }
        guard let sound = cache[name] else { return }
        sound.stop()
        sound.volume = volume
        sound.play()
    }

    // MARK: Building blocks

    private static let rate = 44_100.0

    /// A two-pole resonator: rings at `freq` when hit, like one mode of a metal panel.
    private struct Resonator {
        var a1 = 0.0, a2 = 0.0, gain = 0.0, y1 = 0.0, y2 = 0.0
        init(_ freq: Double, bandwidth: Double) {
            let r = exp(-Double.pi * bandwidth / Sounds.rate)
            a1 = 2 * r * cos(2 * Double.pi * freq / Sounds.rate)
            a2 = -r * r
            gain = 1 - r
        }
        mutating func run(_ x: Double) -> Double {
            let y = gain * x + a1 * y1 + a2 * y2
            y2 = y1; y1 = y
            return y
        }
    }

    /// A bank of resonators, for sheet metal.
    private struct Panel {
        var modes: [(Resonator, Double)]
        init(_ spec: [(freq: Double, bandwidth: Double, amp: Double)]) {
            modes = spec.map { (Resonator($0.freq, bandwidth: $0.bandwidth), $0.amp) }
        }
        mutating func run(_ x: Double) -> Double {
            var sum = 0.0
            for i in modes.indices { sum += modes[i].0.run(x) * modes[i].1 }
            return sum
        }
    }

    private struct Noise {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
        mutating func next() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 20_001) / 10_000 - 1
        }
    }

    /// Thin painted steel: a crowd of slightly out-of-tune modes, the lower ones ringing longer.
    private static let steel: [(freq: Double, bandwidth: Double, amp: Double)] = [
        (118, 9, 1.0), (187, 12, 0.8), (263, 16, 0.7), (341, 20, 0.6), (452, 26, 0.5),
        (587, 34, 0.45), (733, 42, 0.4), (921, 55, 0.3), (1187, 70, 0.25), (1530, 95, 0.2), (2210, 140, 0.12),
    ]

    private static func render(_ seconds: Double, _ f: (Double, Int) -> Double) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var peak = 0.0
        var raw = [Double](repeating: 0, count: n)
        for i in 0..<n {
            raw[i] = f(Double(i) / rate, i)
            peak = max(peak, abs(raw[i]))
        }
        let scale = peak > 0 ? 0.9 / peak : 0
        for i in 0..<n {
            let fade = min(1, Double(n - i) / (rate * 0.02))
            out[i] = Float(raw[i] * scale * fade)
        }
        return out
    }

    // MARK: The sounds

    private static func make(_ name: Name) -> [Float] {
        var noise = Noise(UInt64(name.rawValue.utf8.reduce(7) { $0 &* 31 &+ UInt64($1) }))
        switch name {
        case .clunk:
            // The door slapping shut against the frame, then the latch catching a moment later.
            var panel = Panel(steel)
            var body = Resonator(85, bandwidth: 30)
            var latch = Panel([(2900, 260, 1), (4300, 400, 0.6)])
            return render(0.55) { t, _ in
                let hit = t < 0.004 ? noise.next() * (1 - t / 0.004) : 0
                let click = (t > 0.032 && t < 0.035) ? noise.next() : 0
                return panel.run(hit) * 1.4 + body.run(hit) * 5 + latch.run(click + hit * 0.3) * 0.8
            }
        case .thud:
            // The open door dropping onto its stop and rattling once.
            var panel = Panel(steel.map { ($0.freq * 0.92, $0.bandwidth * 1.6, $0.amp) })
            var body = Resonator(70, bandwidth: 40)
            return render(0.5) { t, _ in
                var hit = t < 0.006 ? noise.next() * (1 - t / 0.006) : 0
                if t > 0.085 && t < 0.089 { hit += noise.next() * 0.35 }
                if t > 0.15 && t < 0.152 { hit += noise.next() * 0.12 }
                return panel.run(hit) + body.run(hit) * 4
            }
        case .creak:
            // A dry hinge: stick-slip. Each slip is a tiny tick; the ticks speed up and slow down
            // with the swing, and ring the door panel.
            var panel = Panel([(980, 120, 1), (1640, 160, 0.7), (2450, 220, 0.4), (620, 90, 0.5)])
            var next = 0.0
            return render(0.6) { t, _ in
                let swing = sin(Double.pi * t / 0.6)
                let pitch = 140 + 230 * swing + 40 * sin(2 * .pi * 4.3 * t)
                var x = noise.next() * 0.02
                if t >= next {
                    x += (0.6 + 0.4 * noise.next()) * swing
                    next = t + 1 / pitch * (1 + 0.15 * noise.next())
                }
                return panel.run(x)
            }
        case .arrive:
            // A letter pushed through the slot: paper sliding on metal, then the hood flap clacking back.
            var slide = Resonator(2600, bandwidth: 2600)
            var flap = Panel([(1250, 70, 1), (2050, 110, 0.6), (3300, 180, 0.3), (640, 50, 0.5)])
            var body = Panel(steel.map { ($0.freq, $0.bandwidth * 2, $0.amp * 0.4) })
            return render(0.75) { t, _ in
                let swish = t < 0.32 ? sin(Double.pi * t / 0.32) : 0
                let hit = (t > 0.34 && t < 0.343) ? noise.next() : 0
                let land = (t > 0.36 && t < 0.37) ? noise.next() * 0.5 : 0
                return slide.run(noise.next() * swish) * 0.5 + flap.run(hit) * 1.3 + body.run(land)
            }
        case .rustle:
            // Paper unfolding: sparse crackles over a soft hiss, in two or three gestures.
            var crisp = Panel([(3200, 2200, 1), (6100, 3500, 0.7)])
            var hiss = Resonator(2400, bandwidth: 3000)
            return render(0.55) { t, _ in
                let gesture = max(0, sin(2 * .pi * 2.6 * t + 0.4)) * sin(Double.pi * t / 0.55)
                var x = noise.next() * 0.25 * gesture
                if abs(noise.next()) > 0.985 - 0.04 * gesture { x += noise.next() * 3 * gesture }
                return crisp.run(x) + hiss.run(noise.next() * gesture) * 0.4
            }
        case .drop:
            // A letter landing on the metal floor: a soft paper slap and a faint ring.
            var panel = Panel(steel.map { ($0.freq, $0.bandwidth * 2.5, $0.amp * 0.5) })
            var slap = Resonator(900, bandwidth: 1400)
            return render(0.35) { t, _ in
                let hit = t < 0.012 ? noise.next() * (1 - t / 0.012) : 0
                return slap.run(hit) * 2 + panel.run(hit * 0.25)
            }
        case .seal:
            // Wax cracking: a few dry snaps close together.
            var snap = Panel([(1800, 900, 1), (3400, 1400, 0.7), (900, 500, 0.4)])
            let snaps: [Double] = [0, 0.018, 0.031, 0.06]
            return render(0.2) { t, _ in
                var x = 0.0
                for (i, s) in snaps.enumerated() where t >= s && t < s + 0.0025 { x += noise.next() * (1 - Double(i) * 0.2) }
                return snap.run(x)
            }
        }
    }

    /// 16-bit mono WAV.
    private static func wav(_ samples: [Float]) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32_000))) }
        return data
    }

    #if DEBUG
    /// Writes every sound to a folder so they can be listened to side by side.
    static func export(to folder: URL) {
        for name in [Name.clunk, .thud, .creak, .arrive, .rustle, .drop, .seal] {
            try? wav(make(name)).write(to: folder.appendingPathComponent("\(name.rawValue).wav"))
        }
    }
    #endif
}

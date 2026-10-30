import AppKit

/// The machine's sounds. A recording in Resources/Sounds/<name>.wav is used if it exists;
/// otherwise the sound is made in code, modelled on the real thing (a geared motor, a knock on a
/// steel tray, a plastic flap). Built once on first use. Nothing loops and nothing is scheduled.
enum Sounds {
    enum Name: String, CaseIterable { case click, beep, error, motor, motorShort, thunk, flap, rattle }

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

    /// A two-pole resonator: rings at `freq` when hit, like one mode of a panel.
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

    /// A bank of resonators, for a panel with several modes.
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

    /// A one-pole low-pass, for things heard through the cabinet.
    private struct LowPass {
        var a = 0.0, y = 0.0
        init(_ cutoff: Double) { a = 1 - exp(-2 * Double.pi * cutoff / Sounds.rate) }
        mutating func run(_ x: Double) -> Double { y += a * (x - y); return y }
    }

    private struct Noise {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
        mutating func next() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 20_001) / 10_000 - 1
        }
    }

    /// The steel pickup tray: heavy, well damped modes.
    private static let tray: [(freq: Double, bandwidth: Double, amp: Double)] = [
        (165, 30, 1.0), (241, 38, 0.7), (352, 50, 0.55), (498, 70, 0.4), (687, 95, 0.3), (942, 130, 0.2), (1310, 190, 0.12),
    ]

    private static func render(_ seconds: Double, peak target: Double = 0.9, _ f: (Double, Int) -> Double) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var peak = 0.0
        var raw = [Double](repeating: 0, count: n)
        for i in 0..<n {
            raw[i] = f(Double(i) / rate, i)
            peak = max(peak, abs(raw[i]))
        }
        let scale = peak > 0 ? target / peak : 0
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
        case .click:
            // A plastic key bottoming out: a dry tick and a little hollow knock behind it.
            var tick = Panel([(3300, 900, 1), (5400, 1500, 0.6)])
            var body = Resonator(430, bandwidth: 160)
            return render(0.07) { t, _ in
                let hit = t < 0.0015 ? noise.next() : 0
                let back = (t > 0.006 && t < 0.0075) ? noise.next() * 0.5 : 0
                return tick.run(hit + back) + body.run(hit) * 3
            }
        case .beep:
            // The piezo beeper on the panel: a bright square-ish tone.
            return render(0.12, peak: 0.5) { t, _ in
                let env = min(1, t / 0.003) * min(1, (0.12 - t) / 0.012)
                let w = 2 * Double.pi * 2700 * t
                return (sin(w) + sin(3 * w) / 3 + sin(5 * w) / 5) * env
            }
        case .error:
            // Two low buzzes: nothing there.
            return render(0.24, peak: 0.5) { t, _ in
                let on = t < 0.08 || (t > 0.13 && t < 0.21)
                let local = t < 0.08 ? t : t - 0.13
                let env = on ? min(1, local / 0.004) * min(1, (0.08 - local) / 0.01) : 0
                let w = 2 * Double.pi * 520 * t
                return (sin(w) + sin(3 * w) / 3 + sin(5 * w) / 5 + sin(7 * w) / 7) * env
            }
        case .motor:
            return motor(seconds: 0.95, noise: &noise)
        case .motorShort:
            return motor(seconds: 0.5, noise: &noise)
        case .thunk:
            // A file landing in the steel tray: a muffled knock, the tray ringing briefly under it.
            var panel = Panel(tray)
            var body = Resonator(110, bandwidth: 45)
            var soft = LowPass(900)
            return render(0.45) { t, _ in
                let hit = t < 0.007 ? soft.run(noise.next()) * (1 - t / 0.007) * 6 : soft.run(0)
                return panel.run(hit) * 1.2 + body.run(hit) * 5
            }
        case .flap:
            // The plastic flap swinging back and tapping its frame.
            var shell = Panel([(880, 170, 1), (1540, 240, 0.7), (2650, 380, 0.4)])
            var hollow = Resonator(300, bandwidth: 90)
            return render(0.22) { t, _ in
                let hit = t < 0.002 ? noise.next() : 0
                return shell.run(hit) + hollow.run(hit) * 2
            }
        case .rattle:
            // The glass shivering in its frame: a few quick taps, each softer.
            var glass = Panel([(1850, 60, 1), (2630, 80, 0.8), (4120, 120, 0.5), (980, 50, 0.4)])
            let taps: [Double] = [0, 0.045, 0.085, 0.13, 0.17]
            return render(0.5) { t, _ in
                var x = 0.0
                for (i, s) in taps.enumerated() where t >= s && t < s + 0.0015 { x += noise.next() * (1 - Double(i) * 0.18) }
                return glass.run(x)
            }
        }
    }

    /// A small geared motor turning a coil, heard through the cabinet: a hum that spins up and down,
    /// a gear whine above it, brush hiss, a slight wobble as the spring loads, and the switch
    /// clicking at each end.
    private static func motor(seconds d: Double, noise: inout Noise) -> [Float] {
        var phase = 0.0
        var brush = Resonator(3100, bandwidth: 2200)
        var cabinet = LowPass(1800)
        var relay = Panel([(2400, 500, 1), (4100, 800, 0.5)])
        return render(d, peak: 0.6) { t, _ in
            let spin = min(1, t / 0.08) * min(1, max(0, d - t) / 0.1)
            let wobble = 1 + 0.05 * sin(2 * Double.pi * 5.2 * t)
            let f0 = (70 + 40 * spin) * wobble
            phase += 2 * Double.pi * f0 / rate
            var hum = 0.0
            for h in 1...6 { hum += sin(phase * Double(h)) / Double(h) }
            let whine = sin(phase * 7.5 + 0.3 * sin(2 * Double.pi * 3 * t)) * 0.22
            let hiss = brush.run(noise.next()) * 0.6
            let click = (t < 0.002 || (t > d - 0.03 && t < d - 0.028)) ? noise.next() : 0
            let body = cabinet.run((hum * 0.55 + whine) * spin * (0.9 + 0.1 * wobble) + hiss * spin)
            return body + relay.run(click) * 0.9
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
        for name in Name.allCases {
            try? wav(make(name)).write(to: folder.appendingPathComponent("\(name.rawValue).wav"))
        }
    }
    #endif
}

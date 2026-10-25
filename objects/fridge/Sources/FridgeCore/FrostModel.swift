import Foundation

/// How frosted and freezer-burnt a stored item looks. Computed from elapsed time only,
/// once, when the door opens. There is no background timer anywhere.
public struct FrostState: Equatable {
    /// 0...1 amount of rime on the item.
    public var frost: Double
    /// 0...1 light freezer burn: slight desaturation and a thin icy edge.
    public var burn: Double
    /// Quantized key so a baked image is only rebuilt when the look actually changes.
    public var bucket: Int

    public init(frost: Double, burn: Double) {
        self.frost = frost
        self.burn = burn
        let f = Int((frost * 8).rounded())
        let b = Int((burn * 8).rounded())
        self.bucket = f * 16 + b
    }
}

public enum FrostModel {
    public static let day: TimeInterval = 86_400

    /// Frost builds quickly at first and levels off: about 39% after a day, 78% after three.
    public static let frostTimeConstant: TimeInterval = 2 * day
    /// Freezer burn starts after two days and reaches its (light) cap at three weeks.
    public static let burnStart: TimeInterval = 2 * day
    public static let burnFull: TimeInterval = 21 * day
    public static let burnCap = 0.55

    public static func state(forElapsed seconds: TimeInterval) -> FrostState {
        let t = max(seconds, 0)
        let frost = 1.0 - exp(-t / frostTimeConstant)
        let u = min(max((t - burnStart) / (burnFull - burnStart), 0), 1)
        let smooth = u * u * (3 - 2 * u)
        return FrostState(frost: frost, burn: smooth * burnCap)
    }

    public static func state(placedAt: Date, now: Date, timeScale: Double = 1) -> FrostState {
        return state(forElapsed: now.timeIntervalSince(placedAt) * max(timeScale, 0))
    }
}

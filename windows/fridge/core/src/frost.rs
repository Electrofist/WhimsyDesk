//! How frosted and freezer-burnt a stored item looks. Computed from elapsed time only, once,
//! when a door opens. No background timer anywhere. Port of `FrostModel.swift`.

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FrostState {
    /// 0...1 amount of rime on the item.
    pub frost: f64,
    /// 0...0.55 light freezer burn: slight desaturation and a thin icy edge.
    pub burn: f64,
    /// Quantized key, so a baked image is only rebuilt when the look changes.
    pub bucket: i32,
}

impl FrostState {
    pub fn new(frost: f64, burn: f64) -> Self {
        // Swift's `rounded()` rounds half away from zero, like Rust's `round()`.
        let f = (frost * 8.0).round() as i32;
        let b = (burn * 8.0).round() as i32;
        Self { frost, burn, bucket: f * 16 + b }
    }
}

pub struct FrostModel;

impl FrostModel {
    pub const DAY: f64 = 86_400.0;
    /// About 39% after a day, 78% after three.
    pub const FROST_TIME_CONSTANT: f64 = 2.0 * Self::DAY;
    /// Burn starts after two days and reaches its light cap at three weeks.
    pub const BURN_START: f64 = 2.0 * Self::DAY;
    pub const BURN_FULL: f64 = 21.0 * Self::DAY;
    pub const BURN_CAP: f64 = 0.55;

    pub fn state_for_elapsed(seconds: f64) -> FrostState {
        let t = seconds.max(0.0);
        let frost = 1.0 - (-t / Self::FROST_TIME_CONSTANT).exp();
        let u = ((t - Self::BURN_START) / (Self::BURN_FULL - Self::BURN_START)).clamp(0.0, 1.0);
        let smooth = u * u * (3.0 - 2.0 * u);
        FrostState::new(frost, smooth * Self::BURN_CAP)
    }

    /// `placed_at` and `now` in seconds since the Unix epoch.
    pub fn state(placed_at: f64, now: f64, time_scale: f64) -> FrostState {
        Self::state_for_elapsed((now - placed_at) * time_scale.max(0.0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const DAY: f64 = FrostModel::DAY;

    #[test]
    fn nothing_at_first() {
        let s = FrostModel::state_for_elapsed(0.0);
        assert_eq!(s.frost, 0.0);
        assert_eq!(s.burn, 0.0);
    }

    #[test]
    fn frost_grows_and_levels_off() {
        let mut last = -1.0;
        let mut t = 0.0;
        while t <= 30.0 * DAY {
            let f = FrostModel::state_for_elapsed(t).frost;
            assert!(f >= last && f <= 1.0);
            last = f;
            t += 0.25 * DAY;
        }
        assert!(last > 0.99);
    }

    #[test]
    fn burn_starts_late_and_caps() {
        assert_eq!(FrostModel::state_for_elapsed(1.9 * DAY).burn, 0.0);
        assert!(FrostModel::state_for_elapsed(10.0 * DAY).burn > 0.1);
        assert!((FrostModel::state_for_elapsed(400.0 * DAY).burn - 0.55).abs() < 1e-12);
    }

    #[test]
    fn bucket_only_changes_with_the_look() {
        let a = FrostModel::state_for_elapsed(3.0 * 3600.0);
        let b = FrostModel::state_for_elapsed(3.0 * 3600.0 + 60.0);
        let c = FrostModel::state_for_elapsed(10.0 * DAY);
        assert_eq!(a.bucket, b.bucket);
        assert_ne!(a.bucket, c.bucket);
    }

    #[test]
    fn time_scale_speeds_it_up() {
        let now = 1_000_000.0;
        let placed = now - 3600.0;
        assert!(FrostModel::state(placed, now, 100.0).frost > FrostModel::state(placed, now, 1.0).frost);
    }
}

//! Small one-shot animations, advanced by the frame loop. Core Animation timing curves, so the
//! motion matches the Mac app.

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Curve {
    Linear,
    /// kCAMediaTimingFunctionEaseOut (0, 0, 0.58, 1).
    EaseOut,
    /// kCAMediaTimingFunctionEaseIn (0.42, 0, 1, 1).
    EaseIn,
    /// kCAMediaTimingFunctionDefault (0.25, 0.1, 0.25, 1), used by implicit transactions.
    Default,
}

impl Curve {
    pub fn apply(self, t: f64) -> f64 {
        let t = t.clamp(0.0, 1.0);
        match self {
            Curve::Linear => t,
            Curve::EaseOut => bezier(0.0, 0.0, 0.58, 1.0, t),
            Curve::EaseIn => bezier(0.42, 0.0, 1.0, 1.0, t),
            Curve::Default => bezier(0.25, 0.1, 0.25, 1.0, t),
        }
    }
}

/// CSS-style cubic Bézier timing function through (0,0), (x1,y1), (x2,y2), (1,1).
fn bezier(x1: f64, y1: f64, x2: f64, y2: f64, x: f64) -> f64 {
    let coord = |a: f64, b: f64, t: f64| {
        let u = 1.0 - t;
        3.0 * u * u * t * a + 3.0 * u * t * t * b + t * t * t
    };
    // x(t) is monotonic for these curves: bisection is plenty.
    let (mut lo, mut hi) = (0.0, 1.0);
    for _ in 0..40 {
        let mid = (lo + hi) / 2.0;
        if coord(x1, x2, mid) < x {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    coord(y1, y2, (lo + hi) / 2.0)
}

/// A value moving from `from` to `to` over `duration` seconds.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Tween {
    pub from: f64,
    pub to: f64,
    pub elapsed: f64,
    pub duration: f64,
    pub curve: Curve,
}

impl Tween {
    pub fn new(from: f64, to: f64, duration: f64, curve: Curve) -> Self {
        Self { from, to, elapsed: 0.0, duration, curve }
    }

    /// Already finished at `value`.
    pub fn at(value: f64) -> Self {
        Self { from: value, to: value, elapsed: 0.0, duration: 0.0, curve: Curve::Linear }
    }

    pub fn progress(&self) -> f64 {
        if self.duration <= 0.0 {
            1.0
        } else {
            (self.elapsed / self.duration).clamp(0.0, 1.0)
        }
    }

    pub fn value(&self) -> f64 {
        self.from + (self.to - self.from) * self.curve.apply(self.progress())
    }

    pub fn done(&self) -> bool {
        self.progress() >= 1.0
    }

    pub fn advance(&mut self, dt: f64) {
        self.elapsed += dt;
    }

    /// Head somewhere else from wherever it is now (like an interrupted implicit animation).
    pub fn retarget(&mut self, to: f64, duration: f64, curve: Curve) {
        if (self.to - to).abs() < 1e-12 && !self.done() {
            return;
        }
        if (self.value() - to).abs() < 1e-12 {
            *self = Tween::at(to);
            return;
        }
        *self = Tween::new(self.value(), to, duration, curve);
    }
}

/// Pop-in of a new note: scale 0.6 → 1.08 at 60 % → 1 over 0.22 s, eased out as a whole.
pub fn pop_scale(elapsed: f64) -> f64 {
    let t = Curve::EaseOut.apply(elapsed / 0.22);
    if t < 0.6 {
        0.6 + (1.08 - 0.6) * (t / 0.6)
    } else {
        1.08 + (1.0 - 1.08) * ((t - 0.6) / 0.4)
    }
}

pub const POP_DURATION: f64 = 0.22;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn curves_hit_their_ends() {
        for c in [Curve::Linear, Curve::EaseOut, Curve::EaseIn, Curve::Default] {
            assert!(c.apply(0.0).abs() < 1e-6);
            assert!((c.apply(1.0) - 1.0).abs() < 1e-6);
        }
        assert!(Curve::EaseOut.apply(0.5) > 0.5);
        assert!(Curve::EaseIn.apply(0.5) < 0.5);
    }

    #[test]
    fn tween_runs_and_retargets() {
        let mut t = Tween::new(0.0, 1.0, 0.15, Curve::Default);
        t.advance(0.075);
        let mid = t.value();
        assert!(mid > 0.0 && mid < 1.0);
        t.retarget(0.0, 0.15, Curve::Default);
        assert!((t.value() - mid).abs() < 1e-9);
        t.advance(1.0);
        assert!(t.done() && t.value().abs() < 1e-9);
    }

    #[test]
    fn pop_overshoots_then_settles() {
        assert!((pop_scale(0.0) - 0.6).abs() < 1e-6);
        let peak = (0..=220).map(|i| pop_scale(i as f64 / 1000.0)).fold(0.0, f64::max);
        assert!((peak - 1.08).abs() < 0.01);
        assert!((pop_scale(POP_DURATION) - 1.0).abs() < 1e-6);
    }
}

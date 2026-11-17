//! The small deterministic random generator from `Material.swift` (`RNG`), so every texture comes
//! out identical on every launch. This is xorshift64, NOT the SplitMix used by the fridge.

#[derive(Clone, Debug)]
pub struct SeededRandom {
    state: u64,
}

impl SeededRandom {
    pub fn new(seed: u64) -> Self {
        Self {
            state: seed.wrapping_add(1).wrapping_mul(0x9E37_79B9_7F4A_7C15),
        }
    }

    /// Next value in `[0, 1)` with 53 bits of precision.
    pub fn next_unit(&mut self) -> f64 {
        self.state ^= self.state << 13;
        self.state ^= self.state >> 7;
        self.state ^= self.state << 17;
        (self.state >> 11) as f64 / (1u64 << 53) as f64
    }

    pub fn range(&mut self, a: f64, b: f64) -> f64 {
        a + (b - a) * self.next_unit()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_seed_same_sequence() {
        let mut a = SeededRandom::new(42);
        let mut b = SeededRandom::new(42);
        for _ in 0..100 {
            assert_eq!(a.next_unit(), b.next_unit());
        }
    }

    #[test]
    fn stays_in_range() {
        let mut r = SeededRandom::new(7);
        for _ in 0..10_000 {
            let v = r.next_unit();
            assert!((0.0..1.0).contains(&v));
            let w = r.range(-3.0, 5.0);
            assert!((-3.0..5.0).contains(&w));
        }
    }

    #[test]
    fn first_value_matches_the_swift_algorithm() {
        // Worked by hand from Material.swift: s = (0 + 1) * 0x9E3779B97F4A7C15, then xorshift 13/7/17.
        let mut s: u64 = 0x9E37_79B9_7F4A_7C15;
        s ^= s << 13;
        s ^= s >> 7;
        s ^= s << 17;
        let expected = (s >> 11) as f64 / (1u64 << 53) as f64;
        assert_eq!(SeededRandom::new(0).next_unit(), expected);
    }
}

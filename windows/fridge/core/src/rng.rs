//! Small deterministic random numbers (splitmix64), identical to `SeededRandom` in `Art.swift`,
//! so frost specks, interior frost and item jitter come out the same as on the Mac.

#[derive(Clone, Debug)]
pub struct SeededRandom {
    state: u64,
}

impl SeededRandom {
    const GOLDEN: u64 = 0x9E37_79B9_7F4A_7C15;

    pub fn new(seed: u64) -> Self {
        Self { state: seed.wrapping_add(Self::GOLDEN) }
    }

    pub fn next_u64(&mut self) -> u64 {
        self.state = self.state.wrapping_add(Self::GOLDEN);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    pub fn unit(&mut self) -> f64 {
        (self.next_u64() >> 11) as f64 / (1u64 << 53) as f64
    }

    /// Uniform in [a, b).
    pub fn range(&mut self, a: f64, b: f64) -> f64 {
        a + (b - a) * self.unit()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn same_seed_same_sequence() {
        let mut a = SeededRandom::new(42);
        let mut b = SeededRandom::new(42);
        for _ in 0..10 {
            assert_eq!(a.next_u64(), b.next_u64());
        }
    }

    #[test]
    fn unit_is_in_range() {
        let mut r = SeededRandom::new(0xF205_7ED);
        for _ in 0..1000 {
            let u = r.unit();
            assert!((0.0..1.0).contains(&u));
        }
    }
}

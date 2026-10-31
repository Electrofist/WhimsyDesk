//! ISO 8601 dates in UTC with whole seconds ("2026-10-31T12:00:00Z"), the format the Mac app
//! writes. Times are seconds since the Unix epoch. Small on purpose: no date library needed.

use std::time::{SystemTime, UNIX_EPOCH};

pub fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

pub fn from_system_time(t: SystemTime) -> f64 {
    match t.duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_secs_f64(),
        Err(e) => -e.duration().as_secs_f64(),
    }
}

/// Days since 1970-01-01 to (year, month, day). Howard Hinnant's civil_from_days.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let m = m as i64;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

pub fn format(seconds: f64) -> String {
    let s = seconds.floor() as i64;
    let days = s.div_euclid(86_400);
    let rem = s.rem_euclid(86_400);
    let (y, mo, d) = civil_from_days(days);
    format!("{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z", y, mo, d, rem / 3600, rem % 3600 / 60, rem % 60)
}

/// Parses "YYYY-MM-DDTHH:MM:SS" followed by "Z" or "+HH:MM"/"-HH:MM". Fractions are ignored.
pub fn parse(text: &str) -> Option<f64> {
    let t = text.trim();
    if t.len() < 19 {
        return None;
    }
    let num = |a: usize, b: usize| t.get(a..b)?.parse::<i64>().ok();
    let (y, mo, d) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (h, mi, s) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) {
        return None;
    }
    let mut rest = &t[19..];
    if let Some(r) = rest.strip_prefix('.') {
        rest = r.trim_start_matches(|c: char| c.is_ascii_digit());
    }
    let offset = match rest {
        "Z" | "" => 0,
        _ => {
            let sign = if rest.starts_with('-') { -1 } else { 1 };
            let oh = rest.get(1..3)?.parse::<i64>().ok()?;
            let om = rest.get(4..6)?.parse::<i64>().ok()?;
            sign * (oh * 3600 + om * 60)
        }
    };
    let days = days_from_civil(y, mo as u32, d as u32);
    Some((days * 86_400 + h * 3600 + mi * 60 + s - offset) as f64)
}

/// serde helpers so dates read and write as ISO strings.
pub mod serde_iso {
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(v: &f64, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&super::format(*v))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<f64, D::Error> {
        let text = String::deserialize(d)?;
        super::parse(&text).ok_or_else(|| serde::de::Error::custom(format!("bad date {text}")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        for t in [0.0, 1_793_440_000.0, 951_782_400.0, 4_102_444_800.0] {
            assert_eq!(parse(&format(t)), Some(t));
        }
    }

    #[test]
    fn known_dates() {
        assert_eq!(format(0.0), "1970-01-01T00:00:00Z");
        assert_eq!(parse("2000-02-29T12:00:00Z"), Some(951_825_600.0));
        assert_eq!(parse("2000-02-29T17:30:00+05:30"), Some(951_825_600.0));
    }
}

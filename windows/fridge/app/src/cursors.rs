//! Open and closed hand cursors, drawn here as small pixel maps (Windows has no grab cursors).
//! `#` outline, `.` fill, space transparent.

const OPEN: [&str; 16] = [
    "      ##        ",
    "  ## #..###     ",
    " #..##..#..#    ",
    " #..##..#..# #  ",
    "  #..#..#..##.# ",
    "  #..#..#..#..# ",
    "##.#.......#..# ",
    "#..##.........# ",
    "#...#.........# ",
    " #............# ",
    "  #...........# ",
    "  #..........#  ",
    "   #.........#  ",
    "    #.......#   ",
    "     #......#   ",
    "     #......#   ",
];

const CLOSED: [&str; 16] = [
    "                ",
    "                ",
    "                ",
    "    ## ## ##    ",
    "   #..#..#..##  ",
    "   #.........#.#",
    "    #..........#",
    "   ##..........#",
    "  #.#..........#",
    "  #............#",
    "   #..........# ",
    "   #..........# ",
    "    #........#  ",
    "     #.......#  ",
    "     #.......#  ",
    "                ",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Hand {
    Open,
    Closed,
}

/// A cursor bitmap: `size x size` BGRA (straight alpha), top row first, plus the hot spot.
pub struct CursorImage {
    pub size: u32,
    pub bgra: Vec<u8>,
    pub hotspot: (u32, u32),
}

/// Draws a hand at a whole-number pixel size per map cell (1 at 100 %, 2 at 200 %).
pub fn hand(kind: Hand, dpi_scale: f64) -> CursorImage {
    let map = match kind {
        Hand::Open => &OPEN,
        Hand::Closed => &CLOSED,
    };
    let cell = (dpi_scale.round() as u32).clamp(1, 4);
    let size = 32 * cell;
    let offset = 8 * cell;
    let mut bgra = vec![0u8; (size * size * 4) as usize];
    for (row, line) in map.iter().enumerate() {
        for (col, ch) in line.chars().enumerate() {
            let v = match ch {
                '#' => 0u8,
                '.' => 255u8,
                _ => continue,
            };
            for dy in 0..cell {
                for dx in 0..cell {
                    let x = offset + col as u32 * cell + dx;
                    let y = offset + row as u32 * cell + dy;
                    let o = ((y * size + x) * 4) as usize;
                    bgra[o..o + 4].copy_from_slice(&[v, v, v, 255]);
                }
            }
        }
    }
    CursorImage { size, bgra, hotspot: (offset + 8 * cell, offset + 8 * cell) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_are_square() {
        for line in OPEN.iter().chain(CLOSED.iter()) {
            assert_eq!(line.chars().count(), 16, "{line:?}");
        }
    }

    #[test]
    fn scales_by_whole_cells() {
        let c = hand(Hand::Closed, 2.0);
        assert_eq!(c.size, 64);
        assert_eq!(c.bgra.len(), 64 * 64 * 4);
        assert_eq!(c.hotspot, (32, 32));
        assert!(c.bgra.chunks(4).any(|p| p[3] == 255));
    }
}

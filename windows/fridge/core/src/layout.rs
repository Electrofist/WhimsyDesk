//! Shelf slots and the interior perspective. Port of `ShelfLayout.swift`.

use std::collections::HashSet;

pub struct ShelfLayout;

impl ShelfLayout {
    pub const SHELF_COUNT: usize = 3;
    pub const ROW_COUNT: usize = 2;
    pub const COLUMN_COUNT: usize = 4;
    pub const SLOTS_PER_SHELF: usize = Self::ROW_COUNT * Self::COLUMN_COUNT;
    pub const CAPACITY: usize = Self::SHELF_COUNT * Self::SLOTS_PER_SHELF;

    /// Local slot to (row, column). Row 0 is the front and fills first.
    pub fn row_and_column(slot: usize) -> (usize, usize) {
        let s = slot.min(Self::SLOTS_PER_SHELF - 1);
        (s / Self::COLUMN_COUNT, s % Self::COLUMN_COUNT)
    }

    /// First free slot, starting on the preferred shelf and fanning outward.
    /// `occupied` holds global indexes (shelf * slots_per_shelf + slot).
    pub fn first_free_slot(occupied: &HashSet<usize>, preferred_shelf: i64) -> Option<(usize, usize)> {
        let start = preferred_shelf.clamp(0, Self::SHELF_COUNT as i64 - 1);
        let mut order = vec![start];
        let mut distance = 1;
        while order.len() < Self::SHELF_COUNT {
            if start - distance >= 0 {
                order.push(start - distance);
            }
            if start + distance < Self::SHELF_COUNT as i64 {
                order.push(start + distance);
            }
            distance += 1;
        }
        for shelf in order {
            let shelf = shelf as usize;
            for slot in 0..Self::SLOTS_PER_SHELF {
                if !occupied.contains(&(shelf * Self::SLOTS_PER_SHELF + slot)) {
                    return Some((shelf, slot));
                }
            }
        }
        None
    }

    /// Which shelf a drop at `y` (opening coordinates, origin bottom) is closest to.
    pub fn shelf_nearest(y: f64) -> usize {
        let mut best = 0;
        let mut best_distance = f64::MAX;
        for (index, front) in InteriorGeometry::SHELF_FRONT_Y.iter().enumerate() {
            let middle = InteriorGeometry::project(InteriorGeometry::OPENING_WIDTH / 2.0, *front, 0.5).1;
            let d = (y - middle).abs();
            if d < best_distance {
                best_distance = d;
                best = index;
            }
        }
        best
    }
}

/// The interior is a box seen from slightly above, sharing one eye with the doors.
/// Coordinates are in the door opening, origin bottom left.
pub struct InteriorGeometry;

impl InteriorGeometry {
    pub const OPENING_WIDTH: f64 = 252.0;
    pub const OPENING_HEIGHT: f64 = 535.0;
    pub const VANISHING_X: f64 = 126.0;
    pub const VANISHING_Y: f64 = 486.0;
    /// Eye to front plane, the same as the door perspective.
    pub const EYE_DISTANCE: f64 = 1150.0;
    pub const CABINET_DEPTH: f64 = 404.0;
    pub const BACK_SCALE: f64 = Self::EYE_DISTANCE / (Self::EYE_DISTANCE + Self::CABINET_DEPTH);
    /// Shelf front edges on the front plane. Shelves 0 and 1 in the fridge, 2 in the freezer.
    pub const SHELF_FRONT_Y: [f64; 3] = [118.0, 238.0, 414.0];
    pub const SHELF_MIN_X: f64 = 8.0;
    pub const SHELF_MAX_X: f64 = 244.0;
    /// Depth fraction (0 front edge, 1 back wall) of each row.
    pub const ROW_DEPTH: [f64; 2] = [0.25, 0.65];
    pub const BASE_ICON_SIZE: f64 = 60.0;

    /// Moves a front-plane point back by `depth` (0...1). Returns (x, y, scale).
    pub fn project(x: f64, y: f64, depth: f64) -> (f64, f64, f64) {
        let s = Self::EYE_DISTANCE / (Self::EYE_DISTANCE + depth * Self::CABINET_DEPTH);
        (Self::VANISHING_X + (x - Self::VANISHING_X) * s, Self::VANISHING_Y + (y - Self::VANISHING_Y) * s, s)
    }

    /// Base centre of an item standing in a slot, plus its scale.
    pub fn anchor(shelf: usize, row: usize, column: usize) -> (f64, f64, f64) {
        let front = Self::SHELF_FRONT_Y[shelf.min(Self::SHELF_FRONT_Y.len() - 1)];
        let columns = ShelfLayout::COLUMN_COUNT as f64;
        let x_front = Self::SHELF_MIN_X + (column as f64 + 0.5) / columns * (Self::SHELF_MAX_X - Self::SHELF_MIN_X);
        let depth = Self::ROW_DEPTH[row.min(Self::ROW_DEPTH.len() - 1)];
        Self::project(x_front, front, depth)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capacity_is_24() {
        assert_eq!(ShelfLayout::CAPACITY, 24);
    }

    #[test]
    fn empty_fridge_uses_the_preferred_shelf() {
        assert_eq!(ShelfLayout::first_free_slot(&HashSet::new(), 1), Some((1, 0)));
    }

    #[test]
    fn full_shelf_fans_out() {
        let occupied: HashSet<usize> = (8..16).collect();
        let (shelf, _) = ShelfLayout::first_free_slot(&occupied, 1).unwrap();
        assert_ne!(shelf, 1);
    }

    #[test]
    fn full_fridge_has_no_slot() {
        let occupied: HashSet<usize> = (0..24).collect();
        assert_eq!(ShelfLayout::first_free_slot(&occupied, 1), None);
    }

    #[test]
    fn back_row_is_smaller_and_higher() {
        let front = InteriorGeometry::anchor(0, 0, 0);
        let back = InteriorGeometry::anchor(0, 1, 0);
        assert!(back.2 < front.2);
        assert!(back.1 > front.1);
    }

    #[test]
    fn every_slot_fits_in_the_opening_and_under_the_next_shelf() {
        for shelf in 0..ShelfLayout::SHELF_COUNT {
            for slot in 0..ShelfLayout::SLOTS_PER_SHELF {
                let (row, column) = ShelfLayout::row_and_column(slot);
                let (x, y, s) = InteriorGeometry::anchor(shelf, row, column);
                let size = InteriorGeometry::BASE_ICON_SIZE * s;
                assert!(x - size / 2.0 >= 0.0 && x + size / 2.0 <= InteriorGeometry::OPENING_WIDTH);
                let ceiling = if shelf + 1 < ShelfLayout::SHELF_COUNT {
                    InteriorGeometry::SHELF_FRONT_Y[shelf + 1]
                } else {
                    InteriorGeometry::OPENING_HEIGHT
                };
                assert!(y + size < ceiling, "shelf {shelf} slot {slot} top {} over {ceiling}", y + size);
            }
        }
    }

    #[test]
    fn nearest_shelf() {
        assert_eq!(ShelfLayout::shelf_nearest(40.0), 0);
        assert_eq!(ShelfLayout::shelf_nearest(480.0), 2);
    }
}

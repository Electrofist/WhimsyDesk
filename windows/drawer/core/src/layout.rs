//! Where each stored item sits on the felt floor, and which one a click hits (PORT-SPEC section 4).
//! Port of `relayout` and `itemIndex(at:)` in `DrawerView.swift`.

use crate::geometry::{Rect, BOX_RECT, FLOOR_TOP};

pub const ICON_SIZE: f64 = 52.0;
pub const LABEL_WIDTH: f64 = 76.0;
pub const LABEL_HEIGHT: f64 = 16.0;
const AREA_INSET: f64 = 28.0;
const MAX_STEP: f64 = 80.0;
const ROW_HEIGHT: f64 = 92.0;
const FIRST_ROW_OFFSET: f64 = 26.0;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ItemSlot {
    pub icon: Rect,
    pub label: Rect,
    /// Items lie slightly askew, as if tossed in. Degrees, positive = counter-clockwise on the Mac;
    /// the sign convention only has to stay consistent with the renderer.
    pub tilt_degrees: f64,
}

/// Number of items per row: one row up to 8 items, then two balanced rows (at least 5 each).
pub fn per_row(count: usize) -> usize {
    if count <= 8 {
        8
    } else {
        5.max(count.div_ceil(2))
    }
}

pub fn tilt_for(index: usize) -> f64 {
    ((index as f64) * 12.9898 + 1.7).sin() * 3.5
}

pub fn layout_items(count: usize) -> Vec<ItemSlot> {
    let per_row = per_row(count);
    let area_x = BOX_RECT.min_x() + AREA_INSET;
    // `per_row` is at least 5 whenever it is used as a divisor.
    let step = MAX_STEP.min((BOX_RECT.w - 56.0 - LABEL_WIDTH) / (per_row as f64 - 1.0));
    (0..count)
        .map(|i| {
            let row = (i / per_row) as f64;
            let col = (i % per_row) as f64;
            let cx = area_x + LABEL_WIDTH / 2.0 + col * step;
            let top = FLOOR_TOP + FIRST_ROW_OFFSET + row * ROW_HEIGHT;
            ItemSlot {
                icon: Rect::new(cx - ICON_SIZE / 2.0, top, ICON_SIZE, ICON_SIZE),
                label: Rect::new(
                    cx - LABEL_WIDTH / 2.0,
                    top + ICON_SIZE + 5.0,
                    LABEL_WIDTH,
                    LABEL_HEIGHT,
                ),
                tilt_degrees: tilt_for(i),
            }
        })
        .collect()
}

/// The topmost (last drawn) item whose icon, inflated by 4 points, or label contains the point.
pub fn hit_test(slots: &[ItemSlot], x: f64, y: f64) -> Option<usize> {
    (0..slots.len()).rev().find(|&i| {
        slots[i].icon.inset_by(-4.0, -4.0).contains(x, y) || slots[i].label.contains(x, y)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_row_up_to_eight() {
        for n in 0..=8 {
            assert_eq!(per_row(n), 8);
        }
        assert_eq!(per_row(9), 5);
        assert_eq!(per_row(10), 5);
        assert_eq!(per_row(11), 6);
        assert_eq!(per_row(20), 10);
    }

    #[test]
    fn first_item_position() {
        let s = layout_items(1);
        // areaX = 74, cx = 74 + 38 = 112, top = 76 + 26 = 102.
        assert_eq!(s[0].icon, Rect::new(86.0, 102.0, 52.0, 52.0));
        assert_eq!(s[0].label, Rect::new(74.0, 159.0, 76.0, 16.0));
    }

    #[test]
    fn eight_items_use_the_full_step() {
        let s = layout_items(8);
        // step = min(80, 556 / 7 = 79.43) = 79.43...
        let step = s[1].icon.x - s[0].icon.x;
        assert!((step - 556.0 / 7.0).abs() < 1e-9);
        assert!(s[7].icon.max_x() <= BOX_RECT.max_x());
    }

    #[test]
    fn nine_items_make_two_rows_with_overlap_step() {
        let s = layout_items(9);
        assert_eq!(s[4].icon.y, 102.0);
        assert_eq!(
            s[5].icon.y,
            102.0 + 92.0,
            "sixth item starts the second row"
        );
        // step = min(80, 556 / 4) = 80.
        assert_eq!(s[1].icon.x - s[0].icon.x, 80.0);
    }

    #[test]
    fn crowded_drawers_shrink_the_step() {
        let s = layout_items(40); // 20 per row
        let step = s[1].icon.x - s[0].icon.x;
        assert!((step - 556.0 / 19.0).abs() < 1e-9);
        assert!(step < ICON_SIZE, "icons overlap when crowded");
    }

    #[test]
    fn tilt_matches_the_formula_and_stays_small() {
        assert!((tilt_for(0) - (1.7f64.sin() * 3.5)).abs() < 1e-12);
        for i in 0..200 {
            assert!(tilt_for(i).abs() <= 3.5);
        }
    }

    #[test]
    fn hit_test_finds_icon_label_and_misses_gaps() {
        let s = layout_items(3);
        let c = s[1].icon;
        assert_eq!(hit_test(&s, c.x + 26.0, c.y + 26.0), Some(1));
        assert_eq!(
            hit_test(&s, c.x - 3.0, c.y + 10.0),
            Some(1),
            "4 point slop around the icon"
        );
        assert_eq!(
            hit_test(&s, s[2].label.x + 5.0, s[2].label.y + 5.0),
            Some(2)
        );
        assert_eq!(hit_test(&s, 5.0, 5.0), None);
    }

    #[test]
    fn overlapping_items_pick_the_topmost() {
        let s = layout_items(40);
        let p = s[1].icon;
        let x = p.x + 1.0; // inside item 1 and also within item 0's inflated icon
        assert_eq!(hit_test(&s, x, p.y + 10.0), Some(1));
    }
}

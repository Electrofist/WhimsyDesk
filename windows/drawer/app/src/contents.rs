//! The things inside the drawer, drawn into one layer that goes between the back and the front
//! of the artwork (PORT-SPEC section 4). Redrawn only when the items, their icons, the theme or
//! the DPI change, not every frame.

use crate::sprite::{Layer, Sprite};
use drawer_core::geometry::FLOOR_TOP;
use drawer_core::layout::ItemSlot;

pub struct ItemView<'a> {
    pub slot: &'a ItemSlot,
    pub icon: Option<&'a Sprite>,
    /// Text already drawn in the label colour, with its shadow.
    pub label: Option<&'a Sprite>,
    /// The item is being dragged out: drawn faint.
    pub lifted: bool,
}

/// The contents layer, `w` x `h` pixels (the artwork's size).
pub fn render(
    w: usize,
    h: usize,
    scale: f64,
    items: &[ItemView],
    hint: Option<&Sprite>,
    hint_centre_x: f64,
) -> Layer {
    let mut layer = Layer::new(w, h);
    if items.is_empty() {
        if let Some(hint) = hint {
            let left = hint_centre_x * scale - hint.lw as f64 / 2.0;
            let top = (FLOOR_TOP + 92.0) * scale;
            layer.draw(hint, left.round(), top.round(), 0.0, 1.0);
        }
        return layer;
    }
    for item in items {
        let alpha = if item.lifted { 0.3 } else { 1.0 };
        let r = &item.slot.icon;
        // Ambient occlusion where the item rests on the felt.
        layer.contact_shadow(
            (r.x + 6.0) * scale,
            (r.max_y() - 8.0) * scale,
            (r.w - 12.0) * scale,
            10.0 * scale,
            0.45 * alpha,
        );
        if let Some(icon) = item.icon {
            // Items lie slightly askew, as if tossed in.
            layer.draw(
                icon,
                (r.x * scale).round(),
                (r.y * scale).round(),
                item.slot.tilt_degrees.to_radians(),
                alpha,
            );
        }
        if let Some(label) = item.label {
            let l = &item.slot.label;
            let left = (l.x + l.w / 2.0) * scale - label.lw as f64 / 2.0;
            layer.draw(label, left.round(), (l.y * scale).round(), 0.0, 1.0);
        }
    }
    layer
}

/// Builds an icon sprite from the shell's picture: scaled to the item's size and given the soft
/// shadow shaped like the icon (offset 0.5, 2.5 pt down, blur 3.5 pt, alpha 0.55).
pub fn icon_sprite(picture: &Sprite, scale: f64) -> Sprite {
    let side = (52.0 * scale).round() as usize;
    picture
        .resized(side, side)
        .with_shadow(3.5 / 2.0 * scale, 0.5 * scale, 2.5 * scale, 0.55)
}

/// Label text with its soft dark shadow (0.5 pt down, blur 2 pt, alpha 0.9). `mask` is the text's
/// coverage; the picture's logical rectangle is the mask's.
pub fn label_sprite(mask: &[u8], w: usize, h: usize, scale: f64, alpha: f32) -> Sprite {
    Sprite::from_mask(w, h, mask, [255, 255, 255], alpha).with_shadow(
        1.0 * scale,
        0.0,
        0.5 * scale,
        0.9,
    )
}

/// The empty-drawer hint: dark text pressed into the felt with a faint light edge below.
pub fn hint_sprite(mask: &[u8], w: usize, h: usize, scale: f64) -> Sprite {
    let text = Sprite::from_mask(w, h, mask, [0, 0, 0], 0.38);
    let light = Sprite::from_mask(w, h, mask, [255, 255, 255], 0.09);
    let mut layer = Layer::new(w, h + 2);
    layer.draw(&light, 0.0, scale.round().max(1.0), 0.0, 1.0);
    layer.draw(&text, 0.0, 0.0, 0.0, 1.0);
    let mut s = Sprite::from_bgra(w, h + 2, layer.data);
    s.lh = h;
    s
}

#[cfg(test)]
mod tests {
    use super::*;
    use drawer_core::layout::layout_items;

    fn square(side: usize, bgra: [u8; 4]) -> Sprite {
        Sprite::from_bgra(
            side,
            side,
            bgra.iter().copied().cycle().take(side * side * 4).collect(),
        )
    }

    #[test]
    fn items_are_drawn_where_the_layout_puts_them() {
        let slots = layout_items(2);
        let icon = icon_sprite(&square(64, [0, 0, 255, 255]), 1.0);
        let views: Vec<_> = slots
            .iter()
            .map(|s| ItemView {
                slot: s,
                icon: Some(&icon),
                label: None,
                lifted: false,
            })
            .collect();
        let layer = render(780, 300, 1.0, &views, None, 390.0);
        for s in &slots {
            let (cx, cy) = (s.icon.x + 26.0, s.icon.y + 26.0);
            let i = ((cy as usize) * 780 + cx as usize) * 4;
            assert_eq!(&layer.data[i..i + 4], &[0, 0, 255, 255]);
        }
        // Between the two items there is only (at most) shadow.
        let gap = ((slots[0].icon.y + 26.0) as usize * 780 + (slots[0].icon.x + 66.0) as usize) * 4;
        assert!(layer.data[gap + 3] < 255);
    }

    #[test]
    fn a_lifted_item_is_faint() {
        let slots = layout_items(1);
        let icon = icon_sprite(&square(52, [0, 0, 200, 255]), 1.0);
        let faint = ItemView {
            slot: &slots[0],
            icon: Some(&icon),
            label: None,
            lifted: true,
        };
        let layer = render(780, 300, 1.0, &[faint], None, 390.0);
        let i = (((slots[0].icon.y + 26.0) as usize) * 780 + (slots[0].icon.x + 26.0) as usize) * 4;
        assert!(
            (layer.data[i + 3] as i32 - 77).abs() <= 2,
            "{}",
            layer.data[i + 3]
        );
    }

    #[test]
    fn an_item_without_a_picture_yet_still_gets_its_contact_shadow() {
        let slots = layout_items(1);
        let v = ItemView {
            slot: &slots[0],
            icon: None,
            label: None,
            lifted: false,
        };
        let layer = render(780, 300, 1.0, &[v], None, 390.0);
        let r = slots[0].icon;
        let i = (((r.max_y() - 3.0) as usize) * 780 + (r.x + 26.0) as usize) * 4;
        assert!(layer.data[i + 3] > 20);
    }

    #[test]
    fn the_hint_shows_only_when_empty() {
        let mask = vec![255u8; 40 * 12];
        let hint = hint_sprite(&mask, 40, 12, 1.0);
        let empty = render(780, 300, 1.0, &[], Some(&hint), 390.0);
        assert!(empty.data.chunks(4).any(|p| p[3] > 0));
        let slots = layout_items(1);
        let v = ItemView {
            slot: &slots[0],
            icon: None,
            label: None,
            lifted: false,
        };
        let full = render(780, 300, 1.0, &[v], Some(&hint), 390.0);
        let near_hint = ((FLOOR_TOP as usize + 95) * 780 + 390) * 4;
        assert_eq!(full.data[near_hint + 3], 0);
        assert!(empty.data[near_hint + 3] > 0);
    }

    #[test]
    fn labels_are_centred_under_the_icon() {
        let slots = layout_items(1);
        let mask = vec![255u8; 30 * 10];
        let label = label_sprite(&mask, 30, 10, 1.0, 0.9);
        let v = ItemView {
            slot: &slots[0],
            icon: None,
            label: Some(&label),
            lifted: false,
        };
        let layer = render(780, 300, 1.0, &[v], None, 390.0);
        let l = slots[0].label;
        let y = (l.y + 3.0) as usize;
        let centre = l.x + l.w / 2.0;
        assert!(layer.data[(y * 780 + centre as usize) * 4 + 3] > 200);
        assert_eq!(
            layer.data[(y * 780 + (centre as usize + 25)) * 4 + 3],
            0,
            "outside the 30 px of text"
        );
    }

    #[test]
    fn scaled_up_sizes_follow_the_scale() {
        let icon = icon_sprite(&square(64, [1, 2, 3, 255]), 1.5);
        assert_eq!((icon.lw, icon.lh), (78, 78));
    }
}

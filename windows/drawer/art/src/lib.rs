//! Every drawing recipe for Desktop Drawer, rendered in software with no dependencies, so the
//! art can be built and checked on any OS (PORT-SPEC section 2).

pub mod canvas;
pub mod material;
pub mod png;
pub mod scene;

pub use canvas::{Canvas, Color};
pub use scene::{
    render_back, render_cast_shadow, render_front, render_layers, render_preview, Layers, Theme,
    DARK, LIGHT,
};

//! Everything in Desktop Drawer that does not touch the screen or the OS: the sliding physics,
//! the geometry and item layout, the synthesized sounds, and moving files in and out of the
//! drawer folder. Ported from `objects/drawer/Sources/DesktopDrawer` (Swift); the behaviour is
//! defined in `docs/PORT-SPEC.md`. Numbers must stay identical to the Mac app.
//!
//! No dependencies on purpose: it builds fast and runs on any OS, so it can be tested anywhere.

pub mod fsutil;
pub mod geometry;
pub mod json;
pub mod layout;
pub mod physics;
pub mod rng;
pub mod sound;
pub mod store;

pub use geometry::Rect;
pub use layout::{hit_test, layout_items, ItemSlot};
pub use physics::{launch_speed, DrawerPhysics, Knock};
pub use rng::SeededRandom;
pub use sound::{KnockKind, SlideSynth};
pub use store::{DrawerError, DrawerItem, DrawerStore, RestoreResult};

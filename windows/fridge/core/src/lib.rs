//! Everything in Desktop Fridge that does not touch the screen or the OS: the door model,
//! frost, where items sit on the shelves, and moving files in and out of the fridge folder.
//! Ported from `objects/fridge/Sources/FridgeCore` (Swift). Numbers must stay identical.

pub mod frost;
pub mod geometry;
pub mod iso;
pub mod layout;
pub mod notes;
pub mod physics;
pub mod rng;
pub mod store;

pub use frost::{FrostModel, FrostState};
pub use layout::{InteriorGeometry, ShelfLayout};
pub use notes::{DoorNote, DoorNotesStore, NoteKind};
pub use physics::{DoorParameters, DoorPhysics};
pub use rng::SeededRandom;
pub use store::{FridgeEntry, FridgeError, FridgeStore, RestoreResult};

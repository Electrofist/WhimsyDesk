use super::*;
use std::fs;

struct Rig {
    _dir: tempfile::TempDir,
    desk: PathBuf,
    model: Model,
}

fn rig() -> Rig {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("Fridge");
    let desktop = dir.path().join("Desktop");
    let desk = dir.path().join("Desk");
    fs::create_dir_all(&desktop).unwrap();
    fs::create_dir_all(&desk).unwrap();
    let store = FridgeStore::open(&root, &desktop).unwrap();
    let notes = DoorNotesStore::open(&root);
    let window = WindowGeom { origin: (100, 100), dpi_scale: 1.0, user_scale: 1.0 };
    Rig { _dir: dir, desk, model: Model::new(store, notes, window, 1.0, 7) }
}

fn view_of_scene(x: f64, y: f64) -> Pt {
    Pt::new(x + BODY_ORIGIN.x, y + BODY_ORIGIN.y)
}

fn mouse(m: &Model, view: Pt) -> Mouse {
    Mouse { view, screen: m.window.screen_point(view), clicks: 1, ctrl: false, alt: false }
}

fn run(m: &mut Model, seconds: f64) -> Vec<Effect> {
    let mut out = Vec::new();
    let mut t = 0.0;
    while t < seconds {
        out.extend(m.tick(1.0 / 60.0, 1000.0));
        t += 1.0 / 60.0;
    }
    out
}

const FRIDGE_DOOR_MIDDLE: (f64, f64) = (200.0, 186.0);

#[test]
fn quiet_at_rest() {
    let r = rig();
    assert!(!r.model.is_animating());
}

#[test]
fn dragging_a_door_opens_it_and_release_keeps_momentum() {
    let mut r = rig();
    let m = &mut r.model;
    let start = view_of_scene(FRIDGE_DOOR_MIDDLE.0, FRIDGE_DOOR_MIDDLE.1);
    let fx = m.mouse_down(&mouse(m, start));
    assert!(fx.contains(&Effect::Capture(true)));
    // A small wiggle is still a click.
    let mut p = mouse(m, Pt::new(start.x - 1.0, start.y));
    m.mouse_move(&p);
    assert!(!m.is_animating());
    let mut fx = Vec::new();
    for i in 1..=20 {
        p = mouse(m, Pt::new(start.x - 8.0 * i as f64, start.y));
        m.mouse_move(&p);
        fx.extend(m.tick(1.0 / 120.0, 0.0));
    }
    assert!(m.door_angles()[0] > 10.0 * DEG);
    fx.extend(run(m, 0.5));
    assert!(fx.contains(&Effect::Play(Sound::Open)));
    assert!(m.door_angles()[0] > 40.0 * DEG);
    let fx = m.mouse_up(&p);
    assert!(fx.contains(&Effect::Capture(false)));
    run(m, 5.0);
    assert!(!m.is_animating(), "a wide open door parks");
    assert!(m.door_angles()[0] > 40.0 * DEG);
}

#[test]
fn double_click_toggles_and_seals_with_a_click() {
    let mut r = rig();
    let m = &mut r.model;
    let p = view_of_scene(FRIDGE_DOOR_MIDDLE.0, FRIDGE_DOOR_MIDDLE.1);
    m.mouse_down(&mouse(m, p));
    m.mouse_up(&mouse(m, p));
    let mut second = mouse(m, p);
    second.clicks = 2;
    m.mouse_down(&second);
    m.mouse_up(&second);
    let fx = run(m, 4.0);
    assert_eq!(fx.iter().filter(|e| **e == Effect::Play(Sound::Open)).count(), 1);
    assert!(m.door_angles()[0] > 90.0 * DEG);
    assert!(!m.is_animating());
    // The open door now stands out of the fridge; double-click it where it is.
    let quad = geo::door_quad(m.door_angles()[0], DoorId::Fridge.spec());
    let c = Pt::new((quad[0].x + quad[1].x + quad[2].x + quad[3].x) / 4.0, (quad[0].y + quad[1].y + quad[2].y + quad[3].y) / 4.0);
    let mut dbl = mouse(m, view_of_scene(c.x, c.y));
    dbl.clicks = 2;
    m.mouse_down(&dbl);
    let fx = run(m, 6.0);
    assert!(fx.contains(&Effect::Play(Sound::Seal)));
    assert!(m.door_angles()[0] < geo::SEALED_ANGLE);
}

#[test]
fn files_drop_only_into_an_open_compartment() {
    let mut r = rig();
    let file = r.desk.join("a.txt");
    fs::write(&file, "x").unwrap();
    let m = &mut r.model;
    let info = DragInfo { files: vec![file.clone()], text: None };
    let allowed = Allowed { copy: true, move_: true, link: true };
    let inside = view_of_scene(140.0, 14.0 + 130.0);
    // Shut: the hover springs the door open, but the drop is refused until it is open.
    let (effect, _) = m.drag_over(inside, &info, allowed);
    assert_eq!(effect, DropEffect::None);
    assert!(m.is_animating());
    run(m, 1.0);
    let (effect, _) = m.drag_over(inside, &info, allowed);
    assert_eq!(effect, DropEffect::Move);
    let (effect, action) = m.drop(inside, &info, allowed);
    assert_eq!(effect, DropEffect::Move);
    let DropAction::Store { shelf, files } = action else { panic!("{action:?}") };
    assert!(DoorId::Fridge.spec().shelves.contains(&shelf));
    let fx = m.store_files(files.into_iter().map(|f| (f, None)).collect(), shelf, 0.0);
    assert!(matches!(fx[0], Effect::NeedIcon { .. }));
    assert!(!file.exists());
    assert_eq!(m.store.entries().len(), 1);
    assert!(m.is_animating(), "drop-in animation");
    // Without Move allowed nothing goes in.
    let (effect, action) = m.drop(inside, &info, Allowed { copy: true, ..Allowed::default() });
    assert_eq!((effect, action), (DropEffect::None, DropAction::Nothing));
}

#[test]
fn items_click_only_on_open_shelves_and_put_back() {
    let mut r = rig();
    let file = r.desk.join("b.txt");
    fs::write(&file, "x").unwrap();
    let m = &mut r.model;
    let entry = m.store.store(&file, None, 0, 0.0).unwrap();
    let rect = item_rect(&entry);
    let center = view_of_scene(rect.x + rect.w / 2.0 + OPENING.x, rect.y + rect.h / 2.0 + OPENING.y);
    let labels = |menu: &[Entry]| menu.iter().filter(|e| matches!(e, Entry::Item { command: Command::PutBack(_), .. })).count();
    assert_eq!(labels(&m.context_menu(center, false)), 0, "shut door: no item menu");
    m.debug_pin(0, 100.0 * DEG);
    assert_eq!(labels(&m.context_menu(center, false)), 1);
    let fx = m.run_command(Command::PutBack(entry.id.clone()));
    assert!(fx.is_empty());
    assert!(file.exists());
    assert!(m.store.entries().is_empty());
}

#[test]
fn move_and_resize_the_window() {
    let mut r = rig();
    let m = &mut r.model;
    let p = view_of_scene(140.0, 300.0);
    let mut down = mouse(m, p);
    down.ctrl = true;
    down.alt = true;
    m.mouse_down(&down);
    let mut moved = down;
    moved.screen = (down.screen.0 + 50.0, down.screen.1 - 20.0);
    assert!(m.mouse_move(&moved).contains(&Effect::WindowMoved));
    assert_eq!(m.window.origin, (150, 80));
    assert!(m.mouse_up(&moved).contains(&Effect::SaveSettings));

    let feet = placement::feet_on_screen(m.window.origin, m.window.scale());
    let mut down = mouse(m, p);
    down.alt = true;
    m.mouse_down(&down);
    let mut up = down;
    up.screen.1 -= 10_000.0;
    m.mouse_move(&up);
    assert_eq!(m.window.user_scale, MAX_SCALE);
    let after = placement::feet_on_screen(m.window.origin, m.window.scale());
    assert!((after.0 - feet.0).abs() <= 1.0 && (after.1 - feet.1).abs() <= 1.0);
    assert!(m.mouse_up(&up).contains(&Effect::WindowResized { rerender: true }));
}

#[test]
fn ctrl_click_makes_a_note_to_write_on() {
    let mut r = rig();
    let m = &mut r.model;
    let p = view_of_scene(150.0, 200.0);
    let mut click = mouse(m, p);
    click.ctrl = true;
    let fx = m.mouse_down(&click);
    assert!(fx.iter().any(|e| matches!(e, Effect::BeginEditor(_))));
    assert_eq!(m.notes.notes().len(), 1);
    // Esc on a brand new note throws it away.
    m.finish_editing(None);
    assert!(m.notes.notes().is_empty());

    m.mouse_down(&click);
    let fx = m.finish_editing(Some("  milk  ".into()));
    assert!(fx.contains(&Effect::EndEditor));
    assert_eq!(m.notes.notes()[0].text, "milk");
    let first_color = m.notes.notes()[0].color;
    // Ctrl-click on the note cycles its colour.
    m.mouse_down(&click);
    m.mouse_up(&click);
    assert_eq!(m.notes.notes()[0].color, (first_color + 1) % 4);
    // Right-click: note menu.
    let menu = m.context_menu(p, false);
    assert!(matches!(&menu[0], Entry::Item { command: Command::EditNote(_), .. }));
}

#[test]
fn ctrl_drag_off_the_door_peels_the_note() {
    let mut r = rig();
    let m = &mut r.model;
    let p = view_of_scene(150.0, 200.0);
    let mut click = mouse(m, p);
    click.ctrl = true;
    m.mouse_down(&click);
    m.finish_editing(Some("x".into()));
    m.mouse_down(&click);
    let mut far = mouse(m, Pt::new(p.x + 400.0, p.y));
    far.ctrl = true;
    m.mouse_move(&far);
    m.mouse_up(&far);
    assert!(m.notes.notes().is_empty());
    assert!(m.is_animating(), "peel animation");
    run(m, 1.0);
    assert!(!m.is_animating());
}

#[test]
fn text_dropped_on_a_shut_door_becomes_a_note() {
    let mut r = rig();
    let m = &mut r.model;
    let p = view_of_scene(150.0, 200.0);
    let info = DragInfo { files: vec![], text: Some("eggs".into()) };
    let allowed = Allowed { copy: true, move_: true, link: false };
    assert_eq!(m.drag_over(p, &info, allowed).0, DropEffect::Copy);
    let (effect, action) = m.drop(p, &info, allowed);
    assert_eq!(effect, DropEffect::Copy);
    let DropAction::StickText { door, point, text } = action else { panic!() };
    m.stick_text(door, point, &text);
    assert_eq!(m.notes.notes()[0].text, "eggs");
}

#[test]
fn pause_freezes_and_stops_sounds() {
    let mut r = rig();
    let m = &mut r.model;
    m.debug_pin(0, 0.0);
    let p = view_of_scene(FRIDGE_DOOR_MIDDLE.0, FRIDGE_DOOR_MIDDLE.1);
    let mut dbl = mouse(m, p);
    dbl.clicks = 2;
    m.mouse_down(&dbl);
    assert!(m.is_animating());
    assert!(m.set_paused(PauseReason::Lock, true).contains(&Effect::StopSounds));
    assert!(!m.is_animating());
    let before = m.door_angles();
    m.tick(0.1, 0.0);
    assert_eq!(before, m.door_angles());
    m.set_paused(PauseReason::Lock, false);
    assert!(m.is_animating());
}

#[test]
fn move_everything_asks_first() {
    let mut r = rig();
    let file = r.desk.join("c.txt");
    fs::write(&file, "x").unwrap();
    let m = &mut r.model;
    assert!(m.run_command(Command::MoveEverythingToDesktop).is_empty());
    m.store.store(&file, None, 1, 0.0).unwrap();
    let fx = m.run_command(Command::MoveEverythingToDesktop);
    assert_eq!(
        fx,
        vec![Effect::ConfirmMoveAll {
            title: "Move everything to your Desktop?".into(),
            message: "The file in the fridge goes back onto your Desktop.".into()
        }]
    );
    assert!(m.move_everything_to_desktop().is_empty());
    assert!(m.store.entries().is_empty());
    assert!(m.store.desktop.join("c.txt").exists());
}

#[test]
fn view_and_screen_points_round_trip() {
    let w = WindowGeom { origin: (-300, 40), dpi_scale: 1.5, user_scale: 0.8 };
    let v = w.view_point((120.0, 600.0));
    let s = w.screen_point(v);
    assert!((s.0 - (-300.0 + 120.0)).abs() < 1e-9 && (s.1 - 640.0).abs() < 1e-9);
}

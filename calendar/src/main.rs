//! Month calendar popup above waybar's clock. Runs only while open: waybar's on-click
//! starts it or kills the running one; Esc, clicking outside or focusing another window closes it.
//! Build/install: cargo install --path ~/dotfiles/calendar --root ~/.local

use gtk::{gdk, glib, prelude::*};
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use std::{cell::Cell, rc::Rc};

// en_US weeks start on Sunday
const WEEKDAYS: [&str; 7] = ["S", "M", "T", "W", "T", "F", "S"];
const MONTHS: [&str; 12] = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
];

// Colors come from ~/.config/gtk-4.0/gtk.css (theme + accent written by theme-toggle.sh).
// The panel background is 0.85 like windows (text stays solid); blur comes from Hyprland's layer rule.
const CSS: &str = r#"
window { background: transparent; }
.panel {
    background: alpha(@window_bg_color, 0.85);
    border: 1px solid alpha(currentColor, 0.2);
    border-radius: 30px;
    padding: 16px 18px 18px;
    font-feature-settings: "ss03", "tnum";
}
.title { font-size: 1.2em; font-weight: 700; }
.nav button {
    min-width: 30px; min-height: 30px; padding: 0;
    border: none; border-radius: 999px; background: none; box-shadow: none;
}
.nav button:hover { background: alpha(currentColor, 0.1); }
.nav .dot { font-size: 0.6em; }
.weekday { font-size: 0.8em; font-weight: 600; color: alpha(currentColor, 0.5); }
.day { min-width: 38px; min-height: 38px; border-radius: 999px; }
.day.other { color: alpha(currentColor, 0.3); }
.day.today { background: @accent_bg_color; color: @accent_fg_color; font-weight: 700; }
"#;

fn days_in_month(y: i32, m: i32) -> i32 {
    match m {
        2 if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

// 0 = Sunday
fn weekday_of_first(y: i32, m: i32) -> i32 {
    let first = glib::DateTime::from_local(y, m, 1, 0, 0, 0.0).unwrap();
    first.day_of_week() % 7
}

fn shift(y: i32, m: i32, by: i32) -> (i32, i32) {
    let i = y * 12 + (m - 1) + by;
    (i.div_euclid(12), i.rem_euclid(12) + 1)
}

fn main() {
    let stamp = std::path::Path::new(&std::env::var("XDG_RUNTIME_DIR").unwrap_or("/tmp".into())).join("calendar-popup.closed");
    let just_closed = std::fs::metadata(&stamp).and_then(|m| m.modified())
        .is_ok_and(|t| t.elapsed().is_ok_and(|e| e.as_millis() < 500));
    if just_closed {
        return;
    }

    // Software rendering: a small short-lived popup is cheaper on the CPU than waking the iGPU
    std::env::set_var("GSK_RENDERER", "cairo");
    // No accessibility bus on this system; skips a failing D-Bus lookup at startup
    std::env::set_var("GTK_A11Y", "none");
    gtk::init().expect("gtk init");

    let provider = gtk::CssProvider::new();
    provider.load_from_string(CSS);
    gtk::style_context_add_provider_for_display(
        &gdk::Display::default().unwrap(),
        &provider,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );

    let now = glib::DateTime::now_local().unwrap();
    let today = (now.year(), now.month(), now.day_of_month());
    let shown = Rc::new(Cell::new((today.0, today.1)));

    let window = gtk::Window::new();
    window.init_layer_shell();
    window.set_namespace(Some("calendar"));
    window.set_layer(Layer::Top);
    // Cover the screen (minus the bar) so a click outside the panel can close it
    for edge in [Edge::Top, Edge::Bottom, Edge::Left, Edge::Right] {
        window.set_anchor(edge, true);
    }
    window.set_keyboard_mode(KeyboardMode::OnDemand);

    let panel = gtk::Box::new(gtk::Orientation::Vertical, 10);
    panel.add_css_class("panel");
    panel.set_halign(gtk::Align::End);
    panel.set_valign(gtk::Align::End);
    panel.set_margin_end(6);
    panel.set_margin_bottom(6);

    let header = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    let title = gtk::Label::new(None);
    title.add_css_class("title");
    title.set_hexpand(true);
    title.set_xalign(0.0);
    let nav = gtk::Box::new(gtk::Orientation::Horizontal, 2);
    nav.add_css_class("nav");
    let prev = gtk::Button::from_icon_name("go-previous-symbolic");
    let home = gtk::Button::with_label("●");
    home.add_css_class("dot");
    home.set_tooltip_text(Some("Today"));
    let next = gtk::Button::from_icon_name("go-next-symbolic");
    for b in [&prev, &home, &next] {
        b.set_focus_on_click(false);
        nav.append(b);
    }
    header.append(&title);
    header.append(&nav);
    panel.append(&header);

    let grid = gtk::Grid::new();
    grid.set_column_homogeneous(true);
    for (c, w) in WEEKDAYS.iter().enumerate() {
        let l = gtk::Label::new(Some(w));
        l.add_css_class("weekday");
        grid.attach(&l, c as i32, 0, 1, 1);
    }
    let cells: Vec<gtk::Label> = (0..42)
        .map(|i| {
            let l = gtk::Label::new(None);
            l.add_css_class("day");
            grid.attach(&l, i % 7, 1 + i / 7, 1, 1);
            l
        })
        .collect();
    panel.append(&grid);
    window.set_child(Some(&panel));

    let render = Rc::new({
        let shown = shown.clone();
        move || {
            let (y, m) = shown.get();
            title.set_text(&format!("{} {}", MONTHS[m as usize - 1], y));
            let lead = weekday_of_first(y, m);
            let (py, pm) = shift(y, m, -1);
            let prev_len = days_in_month(py, pm);
            let len = days_in_month(y, m);
            for (i, cell) in cells.iter().enumerate() {
                let d = i as i32 - lead + 1;
                let (text, other, is_today) = if d < 1 {
                    (prev_len + d, true, false)
                } else if d > len {
                    (d - len, true, false)
                } else {
                    (d, false, (y, m, d) == today)
                };
                cell.set_text(&text.to_string());
                if other { cell.add_css_class("other") } else { cell.remove_css_class("other") }
                if is_today { cell.add_css_class("today") } else { cell.remove_css_class("today") }
            }
        }
    });
    render();

    let go = {
        let (shown, render) = (shown.clone(), render.clone());
        Rc::new(move |by: i32| {
            let (y, m) = shown.get();
            shown.set(if by == 0 { (today.0, today.1) } else { shift(y, m, by) });
            render();
        })
    };
    prev.connect_clicked({ let go = go.clone(); move |_| go(-1) });
    next.connect_clicked({ let go = go.clone(); move |_| go(1) });
    home.connect_clicked({ let go = go.clone(); move |_| go(0) });

    let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::VERTICAL | gtk::EventControllerScrollFlags::DISCRETE);
    scroll.connect_scroll({ let go = go.clone(); move |_, _, dy| { go(if dy > 0.0 { 1 } else { -1 }); glib::Propagation::Stop } });
    window.add_controller(scroll);

    let main_loop = glib::MainLoop::new(None, false);

    let outside = gtk::GestureClick::new();
    outside.set_propagation_phase(gtk::PropagationPhase::Capture);
    outside.connect_pressed({
        let (panel, main_loop) = (panel.clone(), main_loop.clone());
        move |g, _, x, y| {
            let inside = g.widget().and_then(|w| panel.compute_bounds(&w))
                .is_some_and(|b| b.contains_point(&gtk::graphene::Point::new(x as f32, y as f32)));
            if !inside { main_loop.quit() }
        }
    });
    window.add_controller(outside);

    let keys = gtk::EventControllerKey::new();
    keys.connect_key_pressed({
        let (go, main_loop) = (go.clone(), main_loop.clone());
        move |_, key, _, _| {
            match key {
                gdk::Key::Escape => main_loop.quit(),
                gdk::Key::Left | gdk::Key::Page_Up => go(-1),
                gdk::Key::Right | gdk::Key::Page_Down => go(1),
                gdk::Key::Home => go(0),
                _ => return glib::Propagation::Proceed,
            }
            glib::Propagation::Stop
        }
    });
    window.add_controller(keys);

    // Close when focus moves to another window (only after it has had focus once)
    let had_focus = Cell::new(false);
    window.connect_is_active_notify({
        let main_loop = main_loop.clone();
        move |w| {
            if w.is_active() {
                had_focus.set(true)
            } else if had_focus.get() {
                // Clicking the bar's date also drops focus first; the stamp stops that click reopening it
                let _ = std::fs::write(&stamp, "");
                main_loop.quit()
            }
        }
    });
    window.connect_close_request({
        let main_loop = main_loop.clone();
        move |_| { main_loop.quit(); glib::Propagation::Proceed }
    });

    window.present();
    main_loop.run();
}

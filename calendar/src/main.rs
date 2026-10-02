//! Month calendar popup above waybar's clock. Runs only while open: waybar's on-click
//! starts it or kills the running one; Esc, clicking outside or focusing another window closes it.
//! Build/install: cargo install --path ~/dotfiles/calendar --root ~/.local

use gtk::{gdk, glib, prelude::*};
use std::{cell::RefCell, rc::Rc};

// en_US weeks start on Sunday
const WEEKDAYS: [&str; 7] = ["S", "M", "T", "W", "T", "F", "S"];
const MONTHS: [&str; 12] = [
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
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

// Noon, not midnight: a DST jump at midnight would make that local time not exist
fn first_of_month(y: i32, m: i32) -> glib::DateTime {
    glib::DateTime::from_local(y, m, 1, 12, 0, 0.0).expect("valid date")
}

fn set_class(widget: &impl IsA<gtk::Widget>, class: &str, on: bool) {
    if on {
        widget.add_css_class(class);
    } else {
        widget.remove_css_class(class);
    }
}

fn main() {
    let stamp = layer_popup::closed_stamp("calendar-popup");
    if layer_popup::just_closed(&stamp) {
        return;
    }
    layer_popup::init();
    layer_popup::add_css(CSS, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);

    let now = glib::DateTime::now_local().expect("local time");
    let today = (now.year(), now.month(), now.day_of_month());
    // First of the month on display
    let shown = Rc::new(RefCell::new(first_of_month(today.0, today.1)));

    let window = layer_popup::window("calendar");

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
    for (c, w) in (0..).zip(WEEKDAYS) {
        let l = gtk::Label::new(Some(w));
        l.add_css_class("weekday");
        grid.attach(&l, c, 0, 1, 1);
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
            let first = shown.borrow();
            let (y, m) = (first.year(), first.month());
            title.set_text(&format!("{} {y}", MONTHS[m as usize - 1]));
            // Grid starts on the Sunday on or before the 1st (day_of_week: Monday 1 .. Sunday 7)
            let start = first
                .add_days(-(first.day_of_week() % 7))
                .expect("valid date");
            for (i, cell) in (0..).zip(&cells) {
                let day = start.add_days(i).expect("valid date");
                let date = (day.year(), day.month(), day.day_of_month());
                cell.set_text(&date.2.to_string());
                set_class(cell, "other", date.1 != m);
                set_class(cell, "today", date == today);
            }
        }
    });
    render();

    // Months to move by; 0 jumps back to today's month
    let go = Rc::new(move |by: i32| {
        let next = if by == 0 {
            first_of_month(today.0, today.1)
        } else {
            shown.borrow().add_months(by).expect("valid date")
        };
        shown.replace(next);
        render();
    });
    prev.connect_clicked({
        let go = go.clone();
        move |_| go(-1)
    });
    next.connect_clicked({
        let go = go.clone();
        move |_| go(1)
    });
    home.connect_clicked({
        let go = go.clone();
        move |_| go(0)
    });

    let scroll = gtk::EventControllerScroll::new(
        gtk::EventControllerScrollFlags::VERTICAL | gtk::EventControllerScrollFlags::DISCRETE,
    );
    scroll.connect_scroll({
        let go = go.clone();
        move |_, _, dy| {
            go(if dy > 0.0 { 1 } else { -1 });
            glib::Propagation::Stop
        }
    });
    window.add_controller(scroll);

    let main_loop = glib::MainLoop::new(None, false);

    let keys = gtk::EventControllerKey::new();
    keys.connect_key_pressed({
        let go = go.clone();
        move |_, key, _, _| {
            match key {
                gdk::Key::Left | gdk::Key::Page_Up => go(-1),
                gdk::Key::Right | gdk::Key::Page_Down => go(1),
                gdk::Key::Home => go(0),
                _ => return glib::Propagation::Proceed,
            }
            glib::Propagation::Stop
        }
    });
    window.add_controller(keys);

    layer_popup::close_on_dismiss(&window, Some(stamp), {
        let main_loop = main_loop.clone();
        move || main_loop.quit()
    });
    window.present();
    main_loop.run();
}

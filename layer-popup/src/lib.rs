//! What calendar, personalize and popups share: a full-screen layer-shell window whose panel
//! closes on Esc, a click outside it or another window taking focus.
//! Pulled in as a path dependency; each app's `cargo install --path` builds it too.

use gtk::{gdk, glib, prelude::*};
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use std::{
    cell::Cell,
    fs,
    path::{Path, PathBuf},
    rc::Rc,
};

/// Sets up GTK for a short-lived panel. Call before any other GTK use.
pub fn init() {
    // Software rendering: a small short-lived popup is cheaper on the CPU than waking the iGPU
    unsafe { std::env::set_var("GSK_RENDERER", "cairo") };
    // No accessibility bus on this system; skips a failing D-Bus lookup at startup
    unsafe { std::env::set_var("GTK_A11Y", "none") };
    gtk::init().expect("gtk init");
}

/// Marks when `name` last closed by losing focus, in `$XDG_RUNTIME_DIR`.
pub fn closed_stamp(name: &str) -> PathBuf {
    PathBuf::from(std::env::var("XDG_RUNTIME_DIR").unwrap_or("/tmp".into()))
        .join(format!("{name}.closed"))
}

/// Clicking the bar icon of an open popup first drops its focus, closing it, and then
/// launches it again; a stamp under half a second old means this launch is that click.
pub fn just_closed(stamp: &Path) -> bool {
    fs::metadata(stamp)
        .and_then(|m| m.modified())
        .is_ok_and(|t| t.elapsed().is_ok_and(|e| e.as_millis() < 500))
}

pub fn add_css(css: &str, priority: u32) -> gtk::CssProvider {
    let provider = gtk::CssProvider::new();
    provider.load_from_string(css);
    gtk::style_context_add_provider_for_display(
        &gdk::Display::default().expect("display"),
        &provider,
        priority,
    );
    provider
}

pub fn window(namespace: &str) -> gtk::Window {
    let window = gtk::Window::new();
    window.init_layer_shell();
    window.add_css_class("layer-panel");
    window.set_namespace(Some(namespace));
    window.set_layer(Layer::Top);
    // Cover the screen (minus the bar) so a click outside the panel can close it
    for edge in [Edge::Top, Edge::Bottom, Edge::Left, Edge::Right] {
        window.set_anchor(edge, true);
    }
    window.set_keyboard_mode(KeyboardMode::OnDemand);
    window
}

/// Calls `close` on Esc, a click outside the window's child, the window losing focus (only
/// after it has had focus once) or a close request. A focus loss also touches `stamp`.
pub fn close_on_dismiss(window: &gtk::Window, stamp: Option<PathBuf>, close: impl Fn() + 'static) {
    let close = Rc::new(close);

    let outside = gtk::GestureClick::new();
    outside.set_propagation_phase(gtk::PropagationPhase::Capture);
    outside.connect_pressed({
        let (window, close) = (window.clone(), close.clone());
        move |_, _, x, y| {
            let inside = window
                .child()
                .and_then(|panel| panel.compute_bounds(&window))
                .is_some_and(|b| b.contains_point(&gtk::graphene::Point::new(x as f32, y as f32)));
            if !inside {
                close()
            }
        }
    });
    window.add_controller(outside);

    let keys = gtk::EventControllerKey::new();
    keys.connect_key_pressed({
        let close = close.clone();
        move |_, key, _, _| {
            if key != gdk::Key::Escape {
                return glib::Propagation::Proceed;
            }
            close();
            glib::Propagation::Stop
        }
    });
    window.add_controller(keys);

    let had_focus = Cell::new(false);
    window.connect_is_active_notify({
        let close = close.clone();
        move |w| {
            if w.is_active() {
                had_focus.set(true);
            } else if had_focus.get() {
                if let Some(stamp) = &stamp {
                    let _ = fs::write(stamp, "");
                }
                close();
            }
        }
    });
    window.connect_close_request(move |_| {
        close();
        glib::Propagation::Stop
    });
}

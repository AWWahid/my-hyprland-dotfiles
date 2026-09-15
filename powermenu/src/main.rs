//! Power menu above waybar's power button (also SUPER+Escape). Runs only while open:
//! the click starts it or kills the running one; Esc, clicking outside or focusing another window closes it.
//! Restart, Shut Down and Log Out ask for confirmation first.
//! Build/install: cargo install --path ~/dotfiles/powermenu --root ~/.local

use gtk::{gdk, gio, glib, prelude::*};
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use std::{cell::Cell, process::Command, rc::Rc};

// Accent colors come from ~/.config/gtk-4.0/gtk.css.
// Menu and dialog backgrounds are 0.85 like windows (text stays solid); blur comes from Hyprland's layer rule.
const CSS: &str = r#"
window { background: transparent; }
.menu, .dialog {
    background: @pm_bg;
    color: @pm_fg;
    border: 1px solid @pm_border;
}
.menu { border-radius: 12px; padding: 5px; min-width: 210px; }
.menu button {
    min-height: 22px; padding: 1px 10px;
    border: none; border-radius: 7px; background: none; box-shadow: none; outline: none;
    color: @pm_fg; font-weight: 400;
}
.menu button label { font-weight: 400; }
.menu button:focus { background: @accent_bg_color; color: @accent_fg_color; }
.menu separator { background: @pm_border; min-height: 1px; margin: 5px 10px; }

.dialog { border-radius: 26px; padding: 20px 16px 16px; }
.dialog image { color: @pm_fg; margin-bottom: 4px; }
.dialog .title { font-weight: 700; }
.dialog button {
    min-height: 28px; padding: 0 12px;
    border: none; border-radius: 999px; box-shadow: none; outline: none;
    background: @pm_button; color: @pm_fg;
}
.dialog button:hover { background: @pm_button_hover; }
.dialog button.default { background: @accent_bg_color; color: @accent_fg_color; }
.dialog button.default:hover { background: shade(@accent_bg_color, 0.92); }
"#;

const DARK: &str = "@define-color pm_bg alpha(#000000, 0.85); @define-color pm_fg #ffffff; @define-color pm_border alpha(#ffffff, 0.18); \
    @define-color pm_button alpha(#ffffff, 0.14); @define-color pm_button_hover alpha(#ffffff, 0.22);";
const LIGHT: &str = "@define-color pm_bg alpha(#ffffff, 0.85); @define-color pm_fg #000000; @define-color pm_border alpha(#000000, 0.12); \
    @define-color pm_button alpha(#000000, 0.07); @define-color pm_button_hover alpha(#000000, 0.12);";

#[derive(Clone, Copy)]
enum Action { Sleep, Restart, ShutDown, Lock, LogOut }

impl Action {
    fn run(self) {
        let cmd = match self {
            Action::Sleep => "systemctl suspend",
            Action::Restart => "systemctl reboot",
            Action::ShutDown => "systemctl poweroff",
            Action::Lock => "loginctl lock-session",
            Action::LogOut => "command -v hyprshutdown >/dev/null 2>&1 && hyprshutdown || hyprctl dispatch 'hl.dsp.exit()'",
        };
        let _ = Command::new("sh").args(["-c", cmd]).spawn();
    }

    // (icon, question, button) for actions that need confirmation
    fn confirm(self) -> Option<(&'static str, &'static str, &'static str)> {
        match self {
            Action::Restart => Some(("system-reboot-symbolic", "Are you sure you want to restart your computer now?", "Restart")),
            Action::ShutDown => Some(("system-shutdown-symbolic", "Are you sure you want to shut down your computer now?", "Shut Down")),
            Action::LogOut => Some(("system-log-out-symbolic", "Are you sure you want to quit all applications and log out now?", "Log Out")),
            _ => None,
        }
    }
}

fn main() {
    let stamp = std::path::Path::new(&std::env::var("XDG_RUNTIME_DIR").unwrap_or("/tmp".into())).join("powermenu.closed");
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

    let dark = gio::Settings::new("org.gnome.desktop.interface").string("color-scheme") == "prefer-dark";
    let provider = gtk::CssProvider::new();
    provider.load_from_string(&format!("{}{CSS}", if dark { DARK } else { LIGHT }));
    gtk::style_context_add_provider_for_display(
        &gdk::Display::default().unwrap(),
        &provider,
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );

    let window = gtk::Window::new();
    window.init_layer_shell();
    window.set_namespace(Some("powermenu"));
    window.set_layer(Layer::Top);
    // Cover the screen (minus the bar) so a click outside the menu can close it
    for edge in [Edge::Top, Edge::Bottom, Edge::Left, Edge::Right] {
        window.set_anchor(edge, true);
    }
    window.set_keyboard_mode(KeyboardMode::OnDemand);

    let main_loop = glib::MainLoop::new(None, false);
    // Set once the confirmation dialog is showing: it stays up until answered
    let confirming = Rc::new(Cell::new(false));

    let menu = gtk::Box::new(gtk::Orientation::Vertical, 0);
    menu.add_css_class("menu");
    menu.set_halign(gtk::Align::Start);
    menu.set_valign(gtk::Align::End);
    menu.set_margin_start(6);
    menu.set_margin_bottom(6);

    let name = glib::real_name().to_string_lossy().into_owned();
    let name = if name.is_empty() || name == "Unknown" { glib::user_name().to_string_lossy().into_owned() } else { name };
    let logout = format!("Log Out {name}…");
    let items: [Option<(&str, Action)>; 6] = [
        Some(("Sleep", Action::Sleep)),
        Some(("Restart…", Action::Restart)),
        Some(("Shut Down…", Action::ShutDown)),
        None,
        Some(("Lock Screen", Action::Lock)),
        Some((&logout, Action::LogOut)),
    ];

    let show_dialog = {
        let (window, main_loop, confirming) = (window.clone(), main_loop.clone(), confirming.clone());
        move |action: Action| {
            let (icon, question, label) = action.confirm().unwrap();
            confirming.set(true);

            let dialog = gtk::Box::new(gtk::Orientation::Vertical, 10);
            dialog.add_css_class("dialog");
            dialog.set_halign(gtk::Align::Center);
            dialog.set_valign(gtk::Align::Center);
            dialog.set_size_request(260, -1);

            let image = gtk::Image::from_icon_name(icon);
            image.set_pixel_size(56);
            dialog.append(&image);

            let title = gtk::Label::new(Some(question));
            title.add_css_class("title");
            title.set_wrap(true);
            title.set_max_width_chars(24);
            title.set_justify(gtk::Justification::Center);
            dialog.append(&title);

            let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            buttons.set_homogeneous(true);
            buttons.set_margin_top(8);
            let cancel = gtk::Button::with_label("Cancel");
            let ok = gtk::Button::with_label(label);
            ok.add_css_class("default");
            cancel.connect_clicked({ let main_loop = main_loop.clone(); move |_| main_loop.quit() });
            ok.connect_clicked({ let main_loop = main_loop.clone(); move |_| { action.run(); main_loop.quit() } });
            buttons.append(&cancel);
            buttons.append(&ok);
            dialog.append(&buttons);

            // Enter confirms, like macOS's default button
            let keys = gtk::EventControllerKey::new();
            keys.connect_key_pressed({
                let ok = ok.clone();
                move |_, key, _, _| match key {
                    gdk::Key::Return | gdk::Key::KP_Enter => { ok.emit_clicked(); glib::Propagation::Stop }
                    _ => glib::Propagation::Proceed,
                }
            });
            dialog.add_controller(keys);

            window.set_child(Some(&dialog));
            ok.grab_focus();
        }
    };
    let show_dialog = Rc::new(show_dialog);

    for item in items {
        let Some((label, action)) = item else {
            menu.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
            continue;
        };
        let button = gtk::Button::with_label(label);
        if let Some(l) = button.child().and_downcast::<gtk::Label>() {
            l.set_xalign(0.0);
        }
        // Highlight follows the pointer, and arrow keys move the same highlight
        let hover = gtk::EventControllerMotion::new();
        hover.connect_enter({ let b = button.clone(); move |_, _, _| { b.grab_focus(); } });
        button.add_controller(hover);
        button.connect_clicked({
            let (main_loop, show_dialog) = (main_loop.clone(), show_dialog.clone());
            move |_| {
                if action.confirm().is_some() {
                    show_dialog(action)
                } else {
                    action.run();
                    main_loop.quit()
                }
            }
        });
        menu.append(&button);
    }
    window.set_child(Some(&menu));

    let outside = gtk::GestureClick::new();
    outside.set_propagation_phase(gtk::PropagationPhase::Capture);
    outside.connect_pressed({
        let (menu, main_loop, confirming) = (menu.clone(), main_loop.clone(), confirming.clone());
        move |g, _, x, y| {
            if confirming.get() {
                return;
            }
            let inside = g.widget().and_then(|w| menu.compute_bounds(&w))
                .is_some_and(|b| b.contains_point(&gtk::graphene::Point::new(x as f32, y as f32)));
            if !inside { main_loop.quit() }
        }
    });
    window.add_controller(outside);

    let keys = gtk::EventControllerKey::new();
    keys.connect_key_pressed({
        let main_loop = main_loop.clone();
        move |_, key, _, _| {
            if key == gdk::Key::Escape {
                main_loop.quit();
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        }
    });
    window.add_controller(keys);

    // Close the menu when focus moves to another window (only after it has had focus once)
    let had_focus = Cell::new(false);
    window.connect_is_active_notify({
        let (main_loop, confirming) = (main_loop.clone(), confirming.clone());
        move |w| {
            if w.is_active() {
                had_focus.set(true)
            } else if had_focus.get() && !confirming.get() {
                // Clicking the bar's power button also drops focus first; the stamp stops that click reopening it
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
    // Opened by a click: no item highlighted until hovered or an arrow key is pressed
    GtkWindowExt::set_focus(&window, None::<&gtk::Widget>);
    main_loop.run();
}

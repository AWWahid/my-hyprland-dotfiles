//! Popups above waybar's right side: `bar-popup stats` (Performance: live system stats) and `bar-popup toggles`
//! (Bluetooth, Night Shift, VPN). Runs only while open: waybar's on-click starts it or kills the
//! running one; Esc, clicking outside or focusing another window closes it. Stats are read every
//! second while open, from /proc and sysfs only.
//! Build/install: cargo install --path ~/dotfiles/popups --root ~/.local

use gtk::{gdk, gio, glib, prelude::*};
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use std::{cell::{Cell, RefCell}, fs, io::{Read, Write}, path::PathBuf, process::Command, rc::Rc, time::Instant};

// Colors come from ~/.config/gtk-4.0/gtk.css (theme + accent written by theme-toggle.sh), like the calendar
const CSS: &str = r#"
window { background: transparent; }
.panel {
    background: alpha(@window_bg_color, 0.85);
    border: 1px solid alpha(currentColor, 0.2);
    border-radius: 30px;
    padding: 18px;
    font-feature-settings: "ss03", "tnum";
}
.icon { font-family: "Material Symbols Filled"; font-size: 22px; }
.title { font-size: 1.2em; font-weight: 700; }
.dim { color: alpha(currentColor, 0.55); }
.small { font-size: 0.8em; }
.ring { color: @accent_bg_color; }
.ring-value { font-weight: 700; }
.card {
    background: alpha(currentColor, 0.06);
    border-radius: 18px;
    padding: 12px 14px;
}
.card .icon { color: @accent_bg_color; }
.value { font-weight: 600; }
progressbar trough { min-height: 6px; border-radius: 999px; background: alpha(currentColor, 0.1); }
progressbar progress { min-height: 6px; border-radius: 999px; }
.tile {
    background: alpha(currentColor, 0.06);
    border: none; box-shadow: none;
    border-radius: 18px;
    padding: 10px 14px;
}
/* Hover like waybar and fuzzel: solid accent, content black (dark mode) or white (light) */
.tile:hover { background: @accent_bg_color; }
.tile:hover, .tile:hover .dim { color: @hover_fg; }
.tile:hover .badge, .tile.on:hover .badge { background: alpha(currentColor, 0.15); color: inherit; }
.tile .badge {
    min-width: 40px; min-height: 40px; border-radius: 999px;
    background: alpha(currentColor, 0.1);
}
.tile.on .badge { background: @accent_bg_color; color: @accent_fg_color; }
.tile-title { font-weight: 600; }
"#;

const SCRIPTS: &str = ".config/hypr/scripts";

fn read(path: &str) -> Option<String> {
    fs::read_to_string(path).ok()
}

fn read_num(path: &str) -> Option<f64> {
    read(path)?.trim().parse().ok()
}

fn sh(cmd: &str, args: &[&str]) -> String {
    Command::new(cmd).args(args).output().map(|o| String::from_utf8_lossy(&o.stdout).into_owned()).unwrap_or_default()
}

fn script(name: &str) -> String {
    format!("{}/{SCRIPTS}/{name}", std::env::var("HOME").unwrap_or_default())
}

// ---------- stats ----------

// (busy, total) jiffies from the first line of /proc/stat
fn cpu_jiffies() -> (u64, u64) {
    let s = read("/proc/stat").unwrap_or_default();
    let v: Vec<u64> = s.lines().next().unwrap_or("").split_whitespace().skip(1).filter_map(|x| x.parse().ok()).collect();
    let total: u64 = v.iter().take(8).sum();
    let idle = v.get(3).copied().unwrap_or(0) + v.get(4).copied().unwrap_or(0);
    (total - idle, total)
}

fn cpu_dirs() -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir("/sys/devices/system/cpu/cpufreq").into_iter().flatten().flatten()
        .map(|e| e.path().to_string_lossy().into_owned())
        .filter(|p| p.contains("policy")).collect();
    v.sort();
    v
}

// Package temperature: coretemp (Intel), k10temp (AMD), else the first thermal zone
fn temp_path() -> Option<String> {
    for e in fs::read_dir("/sys/class/hwmon").into_iter().flatten().flatten() {
        let p = e.path().to_string_lossy().into_owned();
        let name = read(&format!("{p}/name")).unwrap_or_default();
        if matches!(name.trim(), "coretemp" | "k10temp" | "zenpower") {
            return Some(format!("{p}/temp1_input"));
        }
    }
    let z = "/sys/class/thermal/thermal_zone0/temp";
    fs::metadata(z).is_ok().then(|| z.to_string())
}

// i915/xe actual GPU clock and its top clock
fn gpu_paths() -> Option<(String, f64)> {
    for e in fs::read_dir("/sys/class/drm").into_iter().flatten().flatten() {
        let p = e.path().to_string_lossy().into_owned();
        let act = format!("{p}/gt_act_freq_mhz");
        if fs::metadata(&act).is_ok() {
            let max = read_num(&format!("{p}/gt_RP0_freq_mhz")).unwrap_or(1300.0);
            return Some((act, max));
        }
    }
    None
}

// Bytes received/sent on physical interfaces (those backed by a device), so a VPN tunnel isn't counted twice
fn net_bytes() -> (u64, u64) {
    let mut rx = 0;
    let mut tx = 0;
    for e in fs::read_dir("/sys/class/net").into_iter().flatten().flatten() {
        let p = e.path();
        if !p.join("device").exists() { continue }
        let p = p.to_string_lossy();
        rx += read_num(&format!("{p}/statistics/rx_bytes")).unwrap_or(0.0) as u64;
        tx += read_num(&format!("{p}/statistics/tx_bytes")).unwrap_or(0.0) as u64;
    }
    (rx, tx)
}

fn mem() -> (f64, f64) {
    let s = read("/proc/meminfo").unwrap_or_default();
    let get = |k: &str| s.lines().find(|l| l.starts_with(k)).and_then(|l| l.split_whitespace().nth(1)).and_then(|x| x.parse::<f64>().ok()).unwrap_or(0.0);
    let total = get("MemTotal:");
    (total - get("MemAvailable:"), total)
}

// Physical disks (those backed by a device, so no loop, zram or dm)
fn disk_names() -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir("/sys/block").into_iter().flatten().flatten()
        .filter(|e| e.path().join("device").exists())
        .map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    v.sort();
    v
}

// Per disk: (ms spent doing I/O, sectors read, sectors written) from /sys/block/<disk>/stat.
// Active time is the busy ms over elapsed ms, as Task Manager shows it.
fn disk_stats(names: &[String]) -> Vec<(u64, u64, u64)> {
    names.iter().map(|n| {
        let v: Vec<u64> = read(&format!("/sys/block/{n}/stat")).unwrap_or_default()
            .split_whitespace().filter_map(|x| x.parse().ok()).collect();
        (v.get(9).copied().unwrap_or(0), v.get(2).copied().unwrap_or(0), v.get(6).copied().unwrap_or(0))
    }).collect()
}

fn rate(bytes_per_s: f64) -> String {
    match bytes_per_s {
        b if b >= 1e6 => format!("{:.1} MB/s", b / 1e6),
        b if b >= 1e3 => format!("{:.0} KB/s", b / 1e3),
        b => format!("{:.0} B/s", b),
    }
}

fn uptime() -> String {
    let s = read("/proc/uptime").and_then(|u| u.split_whitespace().next()?.parse::<f64>().ok()).unwrap_or(0.0) as u64;
    let (d, h, m) = (s / 86400, s / 3600 % 24, s / 60 % 60);
    if d > 0 { format!("up {d} d {h} h") } else if h > 0 { format!("up {h} h {m} min") } else { format!("up {m} min") }
}

fn label(text: &str, classes: &[&str]) -> gtk::Label {
    let l = gtk::Label::new(Some(text));
    for c in classes { l.add_css_class(c) }
    l
}

// A ring gauge: accent arc over a faint track, value in the middle, name and detail below
struct Ring { frac: Rc<Cell<f64>>, area: gtk::DrawingArea, value: gtk::Label, detail: gtk::Label }

fn ring(name: &str) -> (gtk::Box, Ring) {
    let col = gtk::Box::new(gtk::Orientation::Vertical, 4);
    let frac = Rc::new(Cell::new(0.0_f64));
    let area = gtk::DrawingArea::new();
    area.add_css_class("ring");
    area.set_content_width(68);
    area.set_content_height(68);
    area.set_draw_func({
        let frac = frac.clone();
        move |a, cr, w, h| {
            let c = a.color();
            let (x, y, r, lw) = (w as f64 / 2.0, h as f64 / 2.0, w.min(h) as f64 / 2.0 - 4.0, 6.0);
            cr.set_line_width(lw);
            cr.set_line_cap(gtk::cairo::LineCap::Round);
            let fg = a.parent().map(|p| p.color()).unwrap_or(c);
            cr.set_source_rgba(fg.red() as f64, fg.green() as f64, fg.blue() as f64, 0.12);
            cr.arc(x, y, r, 0.0, std::f64::consts::TAU);
            let _ = cr.stroke();
            let f = frac.get().clamp(0.0, 1.0);
            if f > 0.0 {
                let start = -std::f64::consts::FRAC_PI_2;
                cr.set_source_rgba(c.red() as f64, c.green() as f64, c.blue() as f64, 1.0);
                cr.arc(x, y, r, start, start + f.max(0.01) * std::f64::consts::TAU);
                let _ = cr.stroke();
            }
        }
    });
    let value = label("…", &["ring-value"]);
    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&area));
    overlay.add_overlay(&value);
    overlay.set_halign(gtk::Align::Center);
    col.append(&overlay);
    col.append(&label(name, &["small"]));
    let detail = label("", &["small", "dim"]);
    col.append(&detail);
    col.set_hexpand(true);
    (col, Ring { frac, area, value, detail })
}

impl Ring {
    fn set(&self, frac: f64, value: &str, detail: &str) {
        self.frac.set(frac);
        self.area.queue_draw();
        self.value.set_text(value);
        self.detail.set_text(detail);
    }
}

// A card row: icon, name, value on the right, optional bar below
fn card(icon: &str, name: &str, with_bar: bool) -> (gtk::Box, gtk::Label, gtk::Label, Option<gtk::ProgressBar>) {
    let b = gtk::Box::new(gtk::Orientation::Vertical, 8);
    b.add_css_class("card");
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    row.append(&label(icon, &["icon"]));
    let n = label(name, &[]);
    n.set_hexpand(true);
    n.set_xalign(0.0);
    row.append(&n);
    let detail = label("", &["small", "dim"]);
    row.append(&detail);
    let value = label("…", &["value"]);
    row.append(&value);
    b.append(&row);
    let bar = with_bar.then(|| { let p = gtk::ProgressBar::new(); b.append(&p); p });
    (b, value, detail, bar)
}

fn build_stats(panel: &gtk::Box) {
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    let title = label("Performance", &["title"]);
    title.set_hexpand(true);
    title.set_xalign(0.0);
    let up = label(&uptime(), &["small", "dim"]);
    header.append(&title);
    header.append(&up);
    panel.append(&header);

    let rings = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    rings.set_homogeneous(true);
    let (c1, cpu_ring) = ring("CPU");
    let (c2, mem_ring) = ring("Memory");
    let (c3, temp_ring) = ring("Temp");
    let (c4, disk_ring) = ring("Disk");
    for c in [&c1, &c2, &c3, &c4] { rings.append(c) }
    panel.append(&rings);

    let (fcard, fval, fdetail, fbar) = card("\u{e322}", "CPU clock", true);
    panel.append(&fcard);
    let gpu = gpu_paths();
    let (gcard, gval, gdetail, gbar) = card("\u{f7a3}", "GPU clock", true);
    if gpu.is_some() { panel.append(&gcard) }
    let (dcard, dval, ddetail, _) = card("\u{f80e}", "Disk", false);
    panel.append(&dcard);
    let (ncard, nval, ndetail, _) = card("\u{e8d5}", "Network", false);
    panel.append(&ncard);
    let disks = disk_names();

    let cpus = cpu_dirs();
    let cpu_max = cpus.iter().filter_map(|p| read_num(&format!("{p}/cpuinfo_max_freq"))).fold(0.0, f64::max);
    let temp = temp_path();
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0);
    fdetail.set_text(&format!("max {:.1} GHz", cpu_max / 1e6));
    if let Some((_, gmax)) = &gpu { gdetail.set_text(&format!("max {:.0} MHz", gmax)) }

    // Single readings, shown the moment the panel opens
    let instant = move || {
        let (used, total) = mem();
        mem_ring.set(used / total.max(1.0), &format!("{:.0}%", used / total.max(1.0) * 100.0),
            &format!("{:.1} / {:.0} GB", used / 1048576.0, total / 1048576.0));

        if let Some(t) = temp.as_deref().and_then(read_num) {
            let c = t / 1000.0;
            temp_ring.set(c / 100.0, &format!("{c:.0}°"), "CPU");
        }

        let freqs: Vec<f64> = cpus.iter().filter_map(|p| read_num(&format!("{p}/scaling_cur_freq"))).collect();
        let avg = freqs.iter().sum::<f64>() / (freqs.len().max(1) as f64);
        fval.set_text(&format!("{:.2} GHz", avg / 1e6));
        if let Some(b) = &fbar { b.set_fraction((avg / cpu_max.max(1.0)).min(1.0)) }

        if let Some((act, gmax)) = &gpu {
            let f = read_num(act).unwrap_or(0.0);
            gval.set_text(&if f > 0.0 { format!("{f:.0} MHz") } else { "idle".into() });
            if let Some(b) = &gbar { b.set_fraction((f / gmax).min(1.0)) }
        }
        up.set_text(&uptime());
    };
    instant();

    // Rates are the difference between two readings: the first is taken now, at launch
    let prev = Rc::new(RefCell::new((cpu_jiffies(), net_bytes(), disk_stats(&disks), Instant::now())));
    let rates = move || {
        let (c, n, d, t) = (cpu_jiffies(), net_bytes(), disk_stats(&disks), Instant::now());
        let (pc, pn, pd, pt) = prev.replace((c, n, d.clone(), t));
        let secs = (t - pt).as_secs_f64().max(0.001);

        let busy = (c.0 - pc.0) as f64 / ((c.1 - pc.1) as f64).max(1.0);
        cpu_ring.set(busy, &format!("{:.0}%", busy * 100.0), &format!("{threads} threads"));

        // The busiest disk's active time; read and write summed over all disks (512-byte sectors)
        let active = d.iter().zip(&pd).map(|(a, b)| (a.0 - b.0) as f64 / (secs * 1000.0)).fold(0.0, f64::max).min(1.0);
        let rd: u64 = d.iter().zip(&pd).map(|(a, b)| a.1 - b.1).sum();
        let wr: u64 = d.iter().zip(&pd).map(|(a, b)| a.2 - b.2).sum();
        disk_ring.set(active, &format!("{:.0}%", active * 100.0), "active");
        ddetail.set_text(&format!("W {}", rate(wr as f64 * 512.0 / secs)));
        dval.set_text(&format!("R {}", rate(rd as f64 * 512.0 / secs)));

        ndetail.set_text(&format!("↑ {}", rate((n.1 - pn.1) as f64 / secs)));
        nval.set_text(&format!("↓ {}", rate((n.0 - pn.0) as f64 / secs)));
    };
    // Second reading after 100 ms, then both kinds every second
    glib::timeout_add_local_once(std::time::Duration::from_millis(100), {
        let (instant, rates) = (Rc::new(instant), Rc::new(rates));
        move || {
            rates();
            let tick = move || { instant(); rates() };
            glib::timeout_add_local(std::time::Duration::from_secs(1), move || { tick(); glib::ControlFlow::Continue });
        }
    });
}

// ---------- toggles ----------

#[derive(Clone)]
struct Tile { button: gtk::Button, badge: gtk::Label, sub: gtk::Label }

fn tile(icon: &str, name: &str, arrow: bool) -> Tile {
    let button = gtk::Button::new();
    button.add_css_class("tile");
    button.set_focus_on_click(false);
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let badge = label(icon, &["icon", "badge"]);
    row.append(&badge);
    let text = gtk::Box::new(gtk::Orientation::Vertical, 0);
    text.set_valign(gtk::Align::Center);
    text.set_hexpand(true);
    let t = label(name, &["tile-title"]);
    t.set_xalign(0.0);
    let sub = label("", &["small", "dim"]);
    sub.set_xalign(0.0);
    sub.set_ellipsize(gtk::pango::EllipsizeMode::End);
    text.append(&t);
    text.append(&sub);
    row.append(&text);
    if arrow { row.append(&label("\u{e5cc}", &["icon", "dim"])) }
    button.set_child(Some(&row));
    Tile { button, badge, sub }
}

impl Tile {
    fn set(&self, on: bool, icon: &str, sub: &str) {
        if on { self.button.add_css_class("on") } else { self.button.remove_css_class("on") }
        self.badge.set_text(icon);
        self.sub.set_text(sub);
    }
}

// The JSON the scripts print for waybar: "class" is on/off, "tooltip" the detail
fn json_field(s: &str, key: &str) -> String {
    let k = format!("\"{key}\":\"");
    s.find(&k).map(|i| &s[i + k.len()..]).and_then(|r| r.find('"').map(|j| r[..j].to_string())).unwrap_or_default()
}

fn bluetooth() -> Option<(bool, String)> {
    let show = sh("bluetoothctl", &["show"]);
    if show.is_empty() || show.contains("No default controller") { return None }
    if !show.contains("Powered: yes") { return Some((false, "Off".into())) }
    let names: Vec<String> = sh("bluetoothctl", &["devices", "Connected"]).lines()
        .filter_map(|l| l.splitn(3, ' ').nth(2).map(str::to_string)).collect();
    Some((true, if names.is_empty() { "On".into() } else { names.join(", ") }))
}

fn night_shift() -> (bool, String) {
    let j = sh(&script("nightshift.sh"), &[]);
    let on = json_field(&j, "class") == "on";
    let warmth = json_field(&j, "tooltip").rsplit(' ').next().unwrap_or("").to_string();
    (on, format!("{} · warmth {warmth}", if on { "On" } else { "Off" }))
}

fn vpn_state() -> (bool, String) {
    let j = sh(&script("vpn-menu.sh"), &["status"]);
    let on = json_field(&j, "class") == "on";
    (on, if on { json_field(&j, "tooltip").trim_start_matches("VPN: ").to_string() } else { "Off".into() })
}

// Last-known tile states, one "key<TAB>on<TAB>subtitle" line each, shown before the real checks answer
fn cache_path() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default()).join(".local/state/bar-popup")
}

fn build_toggles(panel: &gtk::Box, quit: Rc<dyn Fn()>) {
    let title = label("Quick settings", &["title"]);
    title.set_xalign(0.0);
    panel.append(&title);

    let bt = tile("\u{e1a7}", "Bluetooth", true);
    let ns = tile("\u{f03d}", "Night Shift", false);
    let vpn = tile("\u{e0da}", "VPN", true);

    // A controller exists: a file check, so the layout is fixed before anything is drawn
    if fs::read_dir("/sys/class/bluetooth").is_ok_and(|mut d| d.next().is_some()) { panel.append(&bt.button) }
    panel.append(&ns.button);
    panel.append(&vpn.button);

    let cache: Rc<RefCell<Vec<(String, bool, String)>>> = Rc::new(RefCell::new(
        read(&cache_path().to_string_lossy()).unwrap_or_default().lines().filter_map(|l| {
            let mut f = l.splitn(3, '\t');
            Some((f.next()?.to_string(), f.next()? == "1", f.next()?.to_string()))
        }).collect()));

    let apply = Rc::new({
        let (bt, ns, vpn, cache) = (bt.clone(), ns.clone(), vpn.clone(), cache.clone());
        move |key: &str, on: bool, sub: &str, save: bool| {
            match key {
                "bt" => bt.set(on, if !on { "\u{e1a9}" } else if sub != "On" { "\u{e1a8}" } else { "\u{e1a7}" }, sub),
                "ns" => ns.set(on, "\u{f03d}", sub),
                _ => vpn.set(on, "\u{e0da}", sub),
            }
            if !save { return }
            let mut c = cache.borrow_mut();
            c.retain(|(k, _, _)| k != key);
            c.push((key.to_string(), on, sub.to_string()));
            let text: String = c.iter().map(|(k, o, s)| format!("{k}\t{}\t{s}\n", if *o { "1" } else { "0" })).collect();
            let _ = fs::write(cache_path(), text);
        }
    });
    for (k, on, sub) in cache.borrow().clone() { apply(&k, on, &sub, false) }

    // Runs a check off the main thread and updates its tile when it answers
    let check = {
        let apply = apply.clone();
        move |key: &'static str, f: fn() -> Option<(bool, String)>| {
            let apply = apply.clone();
            glib::spawn_future_local(async move {
                if let Ok(Some((on, sub))) = gio::spawn_blocking(f).await { apply(key, on, &sub, true) }
            });
        }
    };
    check("bt", bluetooth);
    check("ns", || Some(night_shift()));
    check("vpn", || Some(vpn_state()));

    // Bluetooth and VPN open their fuzzel menus, so the popup gets out of the way
    let open = |b: &gtk::Button, cmd: String| {
        let quit = quit.clone();
        b.connect_clicked(move |_| {
            let _ = Command::new("setsid").args(["-f", &cmd]).spawn();
            quit();
        });
    };
    open(&bt.button, script("bt-menu.sh"));
    open(&vpn.button, script("vpn-menu.sh"));

    ns.button.connect_clicked({
        let check = check.clone();
        move |_| check("ns", || { sh(&script("nightshift.sh"), &["toggle"]); Some(night_shift()) })
    });
    let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::VERTICAL | gtk::EventControllerScrollFlags::DISCRETE);
    scroll.connect_scroll(move |_, _, dy| {
        if dy < 0.0 {
            check("ns", || { sh(&script("nightshift.sh"), &["warmer"]); Some(night_shift()) })
        } else {
            check("ns", || { sh(&script("nightshift.sh"), &["cooler"]); Some(night_shift()) })
        }
        glib::Propagation::Stop
    });
    ns.button.set_tooltip_text(Some("Scroll to adjust warmth"));
    ns.button.add_controller(scroll);
}

// ---------- window ----------

// Cursor x from Hyprland's socket: the click that opened the popup was on its bar icon
fn cursor_x() -> Option<i32> {
    let dir = PathBuf::from(std::env::var("XDG_RUNTIME_DIR").ok()?).join("hypr").join(std::env::var("HYPRLAND_INSTANCE_SIGNATURE").ok()?);
    let mut s = std::os::unix::net::UnixStream::connect(dir.join(".socket.sock")).ok()?;
    s.write_all(b"cursorpos").ok()?;
    let mut out = String::new();
    s.read_to_string(&mut out).ok()?;
    out.split(',').next()?.trim().parse().ok()
}

fn main() {
    let mode = std::env::args().nth(1).unwrap_or_default();
    if mode != "stats" && mode != "toggles" {
        eprintln!("usage: bar-popup stats|toggles");
        std::process::exit(2);
    }
    let stamp = PathBuf::from(std::env::var("XDG_RUNTIME_DIR").unwrap_or("/tmp".into())).join(format!("bar-popup-{mode}.closed"));
    let just_closed = fs::metadata(&stamp).and_then(|m| m.modified())
        .is_ok_and(|t| t.elapsed().is_ok_and(|e| e.as_millis() < 500));
    if just_closed { return }

    // Software rendering: a small short-lived popup is cheaper on the CPU than waking the iGPU
    unsafe { std::env::set_var("GSK_RENDERER", "cairo") };
    // No accessibility bus on this system; skips a failing D-Bus lookup at startup
    unsafe { std::env::set_var("GTK_A11Y", "none") };
    gtk::init().expect("gtk init");

    let display = gdk::Display::default().unwrap();
    let provider = gtk::CssProvider::new();
    // Hovered tiles: black text in dark mode, white in light, like waybar's icon on its accent fill
    let dark = gio::Settings::new("org.gnome.desktop.interface").string("color-scheme") == "prefer-dark";
    provider.load_from_string(&format!("@define-color hover_fg {};\n{CSS}", if dark { "#000000" } else { "#ffffff" }));
    gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);

    let window = gtk::Window::new();
    window.init_layer_shell();
    window.add_css_class("layer-panel");
    window.set_namespace(Some("bar-popup"));
    window.set_layer(Layer::Top);
    // Cover the screen (minus the bar) so a click outside the panel can close it
    for edge in [Edge::Top, Edge::Bottom, Edge::Left, Edge::Right] {
        window.set_anchor(edge, true);
    }
    window.set_keyboard_mode(KeyboardMode::OnDemand);

    let width = if mode == "stats" { 400 } else { 340 };
    let panel = gtk::Box::new(gtk::Orientation::Vertical, 12);
    panel.add_css_class("panel");
    panel.set_size_request(width, -1);
    panel.set_halign(gtk::Align::Start);
    panel.set_valign(gtk::Align::End);
    panel.set_margin_bottom(6);
    // Centre under the clicked icon, kept 6 px inside the screen
    let screen_w = display.monitors().item(0).and_downcast::<gdk::Monitor>().map(|m| m.geometry().width()).unwrap_or(1920);
    let x = cursor_x().unwrap_or(screen_w);
    panel.set_margin_start((x - width / 2).clamp(6, (screen_w - width - 6).max(6)));
    window.set_child(Some(&panel));

    let main_loop = glib::MainLoop::new(None, false);
    let quit: Rc<dyn Fn()> = Rc::new({ let m = main_loop.clone(); move || m.quit() });

    if mode == "stats" { build_stats(&panel) } else { build_toggles(&panel, quit.clone()) }

    let outside = gtk::GestureClick::new();
    outside.set_propagation_phase(gtk::PropagationPhase::Capture);
    outside.connect_pressed({
        let (panel, quit) = (panel.clone(), quit.clone());
        move |g, _, x, y| {
            let inside = g.widget().and_then(|w| panel.compute_bounds(&w))
                .is_some_and(|b| b.contains_point(&gtk::graphene::Point::new(x as f32, y as f32)));
            if !inside { quit() }
        }
    });
    window.add_controller(outside);

    let keys = gtk::EventControllerKey::new();
    keys.connect_key_pressed({
        let quit = quit.clone();
        move |_, key, _, _| {
            if key == gdk::Key::Escape { quit(); return glib::Propagation::Stop }
            glib::Propagation::Proceed
        }
    });
    window.add_controller(keys);

    // Close when focus moves to another window (only after it has had focus once)
    let had_focus = Cell::new(false);
    window.connect_is_active_notify({
        let quit = quit.clone();
        move |w| {
            if w.is_active() {
                had_focus.set(true)
            } else if had_focus.get() {
                // Clicking the bar icon also drops focus first; the stamp stops that click reopening it
                let _ = fs::write(&stamp, "");
                quit()
            }
        }
    });
    window.connect_close_request({
        let quit = quit.clone();
        move |_| { quit(); glib::Propagation::Proceed }
    });

    window.present();
    main_loop.run();
}

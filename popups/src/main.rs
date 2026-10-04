//! Popups above waybar's right side: `bar-popup stats` (Performance: live system stats) and `bar-popup toggles`
//! (Bluetooth, Night Shift, VPN). Runs only while open: waybar's on-click starts it or kills the
//! running one; Esc, clicking outside or focusing another window closes it. Stats are read every
//! second while open, from /proc and sysfs only.
//! Build/install: cargo install --path ~/dotfiles/popups --root ~/.local

use gtk::{gdk, gio, glib, prelude::*};
use std::{
    cell::{Cell, RefCell},
    f64::consts::{FRAC_PI_2, TAU},
    fs,
    io::{Read, Write},
    path::{Path, PathBuf},
    process::Command,
    rc::Rc,
    time::{Duration, Instant},
};

// Colors come from ~/.config/gtk-4.0/gtk.css (theme + accent written by theme-toggle.sh), like the calendar
const CSS: &str = r#"
window { background: transparent; }
.panel {
    background: @translucent_bg_color;
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

fn read_num<T: std::str::FromStr>(path: impl AsRef<Path>) -> Option<T> {
    fs::read_to_string(path).ok()?.trim().parse().ok()
}

fn sh(cmd: &str, args: &[&str]) -> String {
    Command::new(cmd)
        .args(args)
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default()
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").unwrap_or_default())
}

fn script(name: &str) -> String {
    home()
        .join(SCRIPTS)
        .join(name)
        .to_string_lossy()
        .into_owned()
}

// Sorted entries of a sysfs directory that are backed by a device (physical disks and interfaces,
// so no loop, zram, dm or VPN tunnel)
fn devices(dir: &str) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.join("device").exists())
        .collect();
    v.sort();
    v
}

// ---------- stats ----------

// (busy, total) jiffies from the first line of /proc/stat
fn cpu_jiffies() -> (u64, u64) {
    let s = fs::read_to_string("/proc/stat").unwrap_or_default();
    let v: Vec<u64> = s
        .lines()
        .next()
        .unwrap_or("")
        .split_whitespace()
        .skip(1)
        .filter_map(|x| x.parse().ok())
        .collect();
    let total: u64 = v.iter().take(8).sum();
    let idle: u64 = v.iter().skip(3).take(2).sum();
    (total - idle, total)
}

fn cpu_dirs() -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = fs::read_dir("/sys/devices/system/cpu/cpufreq")
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.file_name()
                .is_some_and(|n| n.to_string_lossy().starts_with("policy"))
        })
        .collect();
    v.sort();
    v
}

// Package temperature: coretemp (Intel), k10temp (AMD), else the first thermal zone
fn temp_path() -> Option<PathBuf> {
    fs::read_dir("/sys/class/hwmon")
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .find(|p| {
            fs::read_to_string(p.join("name"))
                .is_ok_and(|n| matches!(n.trim(), "coretemp" | "k10temp" | "zenpower"))
        })
        .map(|p| p.join("temp1_input"))
        .or_else(|| {
            Some(PathBuf::from("/sys/class/thermal/thermal_zone0/temp")).filter(|z| z.exists())
        })
}

// i915/xe actual GPU clock and its top clock
fn gpu_paths() -> Option<(PathBuf, f64)> {
    let card = fs::read_dir("/sys/class/drm")
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .find(|p| p.join("gt_act_freq_mhz").exists())?;
    Some((
        card.join("gt_act_freq_mhz"),
        read_num(card.join("gt_RP0_freq_mhz")).unwrap_or(1300.0),
    ))
}

// Bytes received/sent on physical interfaces, so a VPN tunnel isn't counted twice. Listed on every
// reading, since interfaces come and go (USB tethering, a dock)
fn net_bytes() -> (u64, u64) {
    devices("/sys/class/net")
        .iter()
        .fold((0, 0), |(rx, tx), p| {
            let get = |f: &str| read_num::<u64>(p.join("statistics").join(f)).unwrap_or(0);
            (rx + get("rx_bytes"), tx + get("tx_bytes"))
        })
}

fn mem() -> (f64, f64) {
    let s = fs::read_to_string("/proc/meminfo").unwrap_or_default();
    let get = |k: &str| {
        s.lines()
            .find_map(|l| l.strip_prefix(k))
            .and_then(|r| r.split_whitespace().next()?.parse::<f64>().ok())
            .unwrap_or(0.0)
    };
    let total = get("MemTotal:");
    (total - get("MemAvailable:"), total)
}

// Per disk: (ms spent doing I/O, sectors read, sectors written) from /sys/block/<disk>/stat.
// Active time is the busy ms over elapsed ms, as Task Manager shows it.
fn disk_stats(stat_files: &[PathBuf]) -> Vec<(u64, u64, u64)> {
    stat_files
        .iter()
        .map(|f| {
            let v: Vec<u64> = fs::read_to_string(f)
                .unwrap_or_default()
                .split_whitespace()
                .filter_map(|x| x.parse().ok())
                .collect();
            let at = |i: usize| v.get(i).copied().unwrap_or(0);
            (at(9), at(2), at(6))
        })
        .collect()
}

fn rate(bytes_per_s: f64) -> String {
    match bytes_per_s {
        b if b >= 1e6 => format!("{:.1} MB/s", b / 1e6),
        b if b >= 1e3 => format!("{:.0} KB/s", b / 1e3),
        b => format!("{b:.0} B/s"),
    }
}

fn uptime() -> String {
    let s = fs::read_to_string("/proc/uptime")
        .ok()
        .and_then(|u| u.split_whitespace().next()?.parse::<f64>().ok())
        .unwrap_or(0.0) as u64;
    let (d, h, m) = (s / 86400, s / 3600 % 24, s / 60 % 60);
    if d > 0 {
        format!("up {d} d {h} h")
    } else if h > 0 {
        format!("up {h} h {m} min")
    } else {
        format!("up {m} min")
    }
}

fn label(text: &str, classes: &[&str]) -> gtk::Label {
    let l = gtk::Label::new(Some(text));
    for c in classes {
        l.add_css_class(c)
    }
    l
}

// A label that takes the free width, text on the left
fn stretch(l: gtk::Label) -> gtk::Label {
    l.set_hexpand(true);
    l.set_xalign(0.0);
    l
}

// A ring gauge: accent arc over a faint track, value in the middle, name and detail below
struct Ring {
    frac: Rc<Cell<f64>>,
    area: gtk::DrawingArea,
    value: gtk::Label,
    detail: gtk::Label,
}

impl Ring {
    fn new(parent: &gtk::Box, name: &str) -> Self {
        let col = gtk::Box::new(gtk::Orientation::Vertical, 4);
        let frac = Rc::new(Cell::new(0.0_f64));
        let area = gtk::DrawingArea::new();
        area.add_css_class("ring");
        area.set_content_width(68);
        area.set_content_height(68);
        area.set_draw_func({
            let frac = frac.clone();
            move |a, cr, w, h| {
                let (w, h) = (f64::from(w), f64::from(h));
                let (x, y, r) = (w / 2.0, h / 2.0, w.min(h) / 2.0 - 4.0);
                cr.set_line_width(6.0);
                cr.set_line_cap(gtk::cairo::LineCap::Round);
                let c = a.color();
                let fg = a.parent().map_or(c, |p| p.color());
                cr.set_source_rgba(fg.red().into(), fg.green().into(), fg.blue().into(), 0.12);
                cr.arc(x, y, r, 0.0, TAU);
                let _ = cr.stroke();
                let f = frac.get().clamp(0.0, 1.0);
                if f > 0.0 {
                    let start = -FRAC_PI_2;
                    cr.set_source_rgba(c.red().into(), c.green().into(), c.blue().into(), 1.0);
                    cr.arc(x, y, r, start, start + f.max(0.01) * TAU);
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
        parent.append(&col);
        Ring {
            frac,
            area,
            value,
            detail,
        }
    }

    // `frac` of the ring filled, shown as a percentage unless `value` is given
    fn set(&self, frac: f64, value: Option<&str>, detail: &str) {
        self.frac.set(frac);
        self.area.queue_draw();
        match value {
            Some(v) => self.value.set_text(v),
            None => self.value.set_text(&format!("{:.0}%", frac * 100.0)),
        }
        self.detail.set_text(detail);
    }
}

// A card row: icon, name, detail and value on the right, optional bar below
struct Card {
    root: gtk::Box,
    value: gtk::Label,
    detail: gtk::Label,
    bar: Option<gtk::ProgressBar>,
}

impl Card {
    fn new(icon: &str, name: &str, with_bar: bool) -> Self {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 8);
        root.add_css_class("card");
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        row.append(&label(icon, &["icon"]));
        row.append(&stretch(label(name, &[])));
        let detail = label("", &["small", "dim"]);
        row.append(&detail);
        let value = label("…", &["value"]);
        row.append(&value);
        root.append(&row);
        let bar = with_bar.then(|| {
            let p = gtk::ProgressBar::new();
            root.append(&p);
            p
        });
        Card {
            root,
            value,
            detail,
            bar,
        }
    }

    fn set(&self, value: &str, frac: f64) {
        self.value.set_text(value);
        if let Some(b) = &self.bar {
            b.set_fraction(frac.min(1.0))
        }
    }
}

fn build_stats(panel: &gtk::Box) {
    let header = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    header.append(&stretch(label("Performance", &["title"])));
    let up = label(&uptime(), &["small", "dim"]);
    header.append(&up);
    panel.append(&header);

    let rings = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    rings.set_homogeneous(true);
    let cpu_ring = Ring::new(&rings, "CPU");
    let mem_ring = Ring::new(&rings, "Memory");
    let temp_ring = Ring::new(&rings, "Temp");
    let disk_ring = Ring::new(&rings, "Disk");
    panel.append(&rings);

    let cpu_card = Card::new("\u{e322}", "CPU clock", true);
    panel.append(&cpu_card.root);
    let gpu = gpu_paths();
    let gpu_card = Card::new("\u{f7a3}", "GPU clock", true);
    if let Some((_, gmax)) = &gpu {
        gpu_card.detail.set_text(&format!("max {gmax:.0} MHz"));
        panel.append(&gpu_card.root);
    }
    let disk_card = Card::new("\u{f80e}", "Disk", false);
    panel.append(&disk_card.root);
    let net_card = Card::new("\u{e8d5}", "Network", false);
    panel.append(&net_card.root);

    let cpus = cpu_dirs();
    let cpu_max = cpus
        .iter()
        .filter_map(|p| read_num(p.join("cpuinfo_max_freq")))
        .fold(0.0, f64::max);
    cpu_card
        .detail
        .set_text(&format!("max {:.1} GHz", cpu_max / 1e6));
    let cur_freqs: Vec<PathBuf> = cpus.iter().map(|p| p.join("scaling_cur_freq")).collect();
    let temp = temp_path();
    let threads = std::thread::available_parallelism().map_or(0, std::num::NonZero::get);
    let disks: Vec<PathBuf> = devices("/sys/block")
        .iter()
        .map(|p| p.join("stat"))
        .collect();

    // Single readings, shown the moment the panel opens
    let instant = move || {
        let (used, total) = mem();
        mem_ring.set(
            used / total.max(1.0),
            None,
            &format!("{:.1} / {:.0} GB", used / 1_048_576.0, total / 1_048_576.0),
        );

        if let Some(c) = temp.as_ref().and_then(read_num::<f64>).map(|t| t / 1000.0) {
            temp_ring.set(c / 100.0, Some(&format!("{c:.0}°")), "CPU");
        }

        let freqs: Vec<f64> = cur_freqs.iter().filter_map(read_num).collect();
        let avg = freqs.iter().sum::<f64>() / (freqs.len().max(1) as f64);
        cpu_card.set(&format!("{:.2} GHz", avg / 1e6), avg / cpu_max.max(1.0));

        if let Some((act, gmax)) = &gpu {
            let f = read_num::<f64>(act).unwrap_or(0.0);
            gpu_card.set(
                &if f > 0.0 {
                    format!("{f:.0} MHz")
                } else {
                    "idle".into()
                },
                f / gmax,
            );
        }
        up.set_text(&uptime());
    };
    instant();

    // Rates are the difference between two readings: the first is taken now, at launch.
    // Differences saturate, since a counter can step back (iowait, an interface going away)
    let prev = RefCell::new((
        cpu_jiffies(),
        net_bytes(),
        disk_stats(&disks),
        Instant::now(),
    ));
    let rates = move || {
        let (c, n, d, t) = (
            cpu_jiffies(),
            net_bytes(),
            disk_stats(&disks),
            Instant::now(),
        );
        let last = prev.borrow();
        let (pc, pn, pd, pt) = &*last;
        let secs = (t - *pt).as_secs_f64().max(0.001);

        let busy = c.0.saturating_sub(pc.0) as f64 / (c.1.saturating_sub(pc.1) as f64).max(1.0);
        cpu_ring.set(busy, None, &format!("{threads} threads"));

        // The busiest disk's active time; read and write summed over all disks (512-byte sectors)
        let (mut active, mut rd, mut wr) = (0.0_f64, 0, 0);
        for (a, b) in d.iter().zip(pd) {
            active = active.max(a.0.saturating_sub(b.0) as f64 / (secs * 1000.0));
            rd += a.1.saturating_sub(b.1);
            wr += a.2.saturating_sub(b.2);
        }
        disk_ring.set(active.min(1.0), None, "active");
        disk_card
            .detail
            .set_text(&format!("W {}", rate(wr as f64 * 512.0 / secs)));
        disk_card
            .value
            .set_text(&format!("R {}", rate(rd as f64 * 512.0 / secs)));

        net_card.detail.set_text(&format!(
            "↑ {}",
            rate(n.1.saturating_sub(pn.1) as f64 / secs)
        ));
        net_card.value.set_text(&format!(
            "↓ {}",
            rate(n.0.saturating_sub(pn.0) as f64 / secs)
        ));
        drop(last);
        prev.replace((c, n, d, t));
    };
    // Second reading after 100 ms, then both kinds every second
    glib::timeout_add_local_once(Duration::from_millis(100), move || {
        rates();
        glib::timeout_add_local(Duration::from_secs(1), move || {
            instant();
            rates();
            glib::ControlFlow::Continue
        });
    });
}

// ---------- toggles ----------

#[derive(Clone)]
struct Tile {
    button: gtk::Button,
    badge: gtk::Label,
    sub: gtk::Label,
}

impl Tile {
    fn new(icon: &str, name: &str, arrow: bool) -> Self {
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
        if arrow {
            row.append(&label("\u{e5cc}", &["icon", "dim"]))
        }
        button.set_child(Some(&row));
        Tile { button, badge, sub }
    }

    fn set(&self, on: bool, icon: &str, sub: &str) {
        if on {
            self.button.add_css_class("on")
        } else {
            self.button.remove_css_class("on")
        }
        self.badge.set_text(icon);
        self.sub.set_text(sub);
    }
}

// The JSON the scripts print for waybar: "class" is on/off, "tooltip" the detail
fn json_field<'a>(s: &'a str, key: &str) -> &'a str {
    let k = format!("\"{key}\":\"");
    s.split_once(&k)
        .and_then(|(_, r)| r.split_once('"'))
        .map_or("", |(v, _)| v)
}

fn bluetooth() -> Option<(bool, String)> {
    // Without bluetoothd running, bluetoothctl waits for it forever
    let show = sh("timeout", &["2", "bluetoothctl", "show"]);
    if show.is_empty() || show.contains("No default controller") {
        return None;
    }
    if !show.contains("Powered: yes") {
        return Some((false, "Off".into()));
    }
    let names: Vec<String> = sh("timeout", &["2", "bluetoothctl", "devices", "Connected"])
        .lines()
        .filter_map(|l| l.splitn(3, ' ').nth(2).map(str::to_string))
        .collect();
    Some((
        true,
        if names.is_empty() {
            "On".into()
        } else {
            names.join(", ")
        },
    ))
}

// Runs nightshift.sh with `arg` first (toggle, warmer, cooler) if given, then reads its state
fn night_shift(arg: Option<&str>) -> Option<(bool, String)> {
    let script = script("nightshift.sh");
    if let Some(a) = arg {
        sh(&script, &[a]);
    }
    let j = sh(&script, &[]);
    let on = json_field(&j, "class") == "on";
    let warmth = json_field(&j, "tooltip").rsplit(' ').next().unwrap_or("");
    Some((
        on,
        format!("{} · warmth {warmth}", if on { "On" } else { "Off" }),
    ))
}

fn vpn_state() -> Option<(bool, String)> {
    let j = sh(&script("vpn-menu.sh"), &["status"]);
    let on = json_field(&j, "class") == "on";
    Some((
        on,
        if on {
            json_field(&j, "tooltip")
                .trim_start_matches("VPN: ")
                .to_string()
        } else {
            "Off".into()
        },
    ))
}

// Last-known tile states, one "key<TAB>on<TAB>subtitle" line each, shown before the real checks answer
fn cache_path() -> PathBuf {
    home().join(".local/state/bar-popup")
}

type Cache = Vec<(String, bool, String)>;

fn load_cache() -> Cache {
    fs::read_to_string(cache_path())
        .unwrap_or_default()
        .lines()
        .filter_map(|l| {
            let mut f = l.splitn(3, '\t');
            Some((
                f.next()?.to_string(),
                f.next()? == "1",
                f.next()?.to_string(),
            ))
        })
        .collect()
}

fn save_cache(cache: &Cache) {
    let text: String = cache
        .iter()
        .map(|(k, on, s)| format!("{k}\t{}\t{s}\n", u8::from(*on)))
        .collect();
    let _ = fs::write(cache_path(), text);
}

fn build_toggles(panel: &gtk::Box, quit: &Rc<dyn Fn()>) {
    let title = label("Quick settings", &["title"]);
    title.set_xalign(0.0);
    panel.append(&title);

    let bt = Tile::new("\u{e1a7}", "Bluetooth", true);
    let ns = Tile::new("\u{f03d}", "Night Shift", false);
    let vpn = Tile::new("\u{e0da}", "VPN", true);

    // A controller exists: a file check, so the layout is fixed before anything is drawn
    let has_bt = fs::read_dir("/sys/class/bluetooth").is_ok_and(|mut d| d.next().is_some());
    if has_bt {
        panel.append(&bt.button)
    }
    panel.append(&ns.button);
    panel.append(&vpn.button);

    let cache = Rc::new(RefCell::new(load_cache()));
    let apply = Rc::new({
        let (bt, ns, vpn, cache) = (bt.clone(), ns.clone(), vpn.clone(), cache.clone());
        move |key: &str, on: bool, sub: &str, save: bool| {
            match key {
                "bt" => bt.set(
                    on,
                    if !on {
                        "\u{e1a9}"
                    } else if sub != "On" {
                        "\u{e1a8}"
                    } else {
                        "\u{e1a7}"
                    },
                    sub,
                ),
                "ns" => ns.set(on, "\u{f03d}", sub),
                _ => vpn.set(on, "\u{e0da}", sub),
            }
            if save {
                let mut c = cache.borrow_mut();
                c.retain(|(k, _, _)| k != key);
                c.push((key.to_string(), on, sub.to_string()));
                save_cache(&c);
            }
        }
    });
    for (k, on, sub) in cache.borrow().iter() {
        apply(k, *on, sub, false)
    }

    // Runs a check off the main thread and updates its tile when it answers
    let check = move |key: &'static str, f: Box<dyn FnOnce() -> Option<(bool, String)> + Send>| {
        let apply = apply.clone();
        glib::spawn_future_local(async move {
            if let Ok(Some((on, sub))) = gio::spawn_blocking(f).await {
                apply(key, on, &sub, true)
            }
        });
    };
    if has_bt {
        check("bt", Box::new(bluetooth));
    }
    check("ns", Box::new(|| night_shift(None)));
    check("vpn", Box::new(vpn_state));

    // Bluetooth and VPN open their fuzzel menus, so the popup gets out of the way
    for (button, name) in [(&bt.button, "bt-menu.sh"), (&vpn.button, "vpn-menu.sh")] {
        let (quit, cmd) = (quit.clone(), script(name));
        button.connect_clicked(move |_| {
            let _ = Command::new("setsid").args(["-f", &cmd]).spawn();
            quit();
        });
    }

    let check = Rc::new(check);
    ns.button.connect_clicked({
        let check = check.clone();
        move |_| check("ns", Box::new(|| night_shift(Some("toggle"))))
    });
    let scroll = gtk::EventControllerScroll::new(
        gtk::EventControllerScrollFlags::VERTICAL | gtk::EventControllerScrollFlags::DISCRETE,
    );
    scroll.connect_scroll(move |_, _, dy| {
        let arg = if dy < 0.0 { "warmer" } else { "cooler" };
        check("ns", Box::new(move || night_shift(Some(arg))));
        glib::Propagation::Stop
    });
    ns.button.set_tooltip_text(Some("Scroll to adjust warmth"));
    ns.button.add_controller(scroll);
}

// ---------- window ----------

// Cursor x from Hyprland's socket: the click that opened the popup was on its bar icon
fn cursor_x() -> Option<i32> {
    let dir = PathBuf::from(std::env::var("XDG_RUNTIME_DIR").ok()?)
        .join("hypr")
        .join(std::env::var("HYPRLAND_INSTANCE_SIGNATURE").ok()?);
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
    let stamp = layer_popup::closed_stamp(&format!("bar-popup-{mode}"));
    if layer_popup::just_closed(&stamp) {
        return;
    }

    layer_popup::init();
    // Hovered tiles: black text in dark mode, white in light, like waybar's icon on its accent fill
    let dark =
        gio::Settings::new("org.gnome.desktop.interface").string("color-scheme") == "prefer-dark";
    let hover_fg = if dark { "#000000" } else { "#ffffff" };
    layer_popup::add_css(
        &format!("@define-color hover_fg {hover_fg};\n{CSS}"),
        gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
    );

    let window = layer_popup::window("bar-popup");
    let width = if mode == "stats" { 400 } else { 340 };
    let panel = gtk::Box::new(gtk::Orientation::Vertical, 12);
    panel.add_css_class("panel");
    panel.set_size_request(width, -1);
    panel.set_halign(gtk::Align::Start);
    panel.set_valign(gtk::Align::End);
    panel.set_margin_bottom(6);
    // Centre under the clicked icon, kept 6 px inside the screen
    let screen_w = gdk::Display::default()
        .and_then(|d| d.monitors().item(0))
        .and_downcast::<gdk::Monitor>()
        .map_or(1920, |m| m.geometry().width());
    let x = cursor_x().unwrap_or(screen_w);
    panel.set_margin_start((x - width / 2).clamp(6, (screen_w - width - 6).max(6)));
    window.set_child(Some(&panel));

    let main_loop = glib::MainLoop::new(None, false);
    let quit: Rc<dyn Fn()> = Rc::new({
        let m = main_loop.clone();
        move || m.quit()
    });

    if mode == "stats" {
        build_stats(&panel)
    } else {
        build_toggles(&panel, &quit)
    }
    layer_popup::close_on_dismiss(&window, Some(stamp), move || quit());

    window.present();
    main_loop.run();
}

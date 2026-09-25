//! Personalize panel (SUPER+W): light/dark, accent color, menu bar icon color, background and hover, and wallpaper.
//! Runs only while open: SUPER+W starts it or kills the running one; Esc, clicking outside or focusing another window closes it.
//! Wallpaper accents come from matugen (scheme-smart, both modes); a manual accent is used as picked, for the current mode only.
//! Build/install: cargo install --path ~/dotfiles/personalize --root ~/.local
// ColorChooserWidget is deprecated, but its replacement (ColorDialog) opens a separate window, which would close this panel
#![allow(deprecated)]

use gtk::{gdk, gdk_pixbuf, gio, glib, prelude::*};
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};
use std::{cell::{Cell, RefCell}, fs, path::{Path, PathBuf}, process::Command, rc::Rc};

// macOS accent colors
const PRESETS: [(&str, &str); 8] = [
    ("Blue", "#007aff"), ("Purple", "#af52de"), ("Pink", "#ff2d55"), ("Red", "#ff3b30"),
    ("Orange", "#ff9500"), ("Yellow", "#ffcc00"), ("Green", "#34c759"), ("Graphite", "#8e8e93"),
];

fn home() -> PathBuf { PathBuf::from(std::env::var("HOME").unwrap_or_default()) }
fn cfg(p: &str) -> PathBuf { home().join(".config").join(p) }
fn wallpaper_dir() -> PathBuf { home().join(".local/share/wallpaper") }
/// What hyprpaper and hyprlock show: a screen-sized copy of the chosen wallpaper (or the original)
fn wallpaper_link() -> PathBuf { wallpaper_dir().join("current") }
/// The chosen wallpaper itself, so the panel can tell which picture is current
fn source_link() -> PathBuf { wallpaper_dir().join("source") }
/// Not in ~/.cache: hyprpaper needs the copy at login, so a cache cleaner must not remove it
fn scaled_dir() -> PathBuf { wallpaper_dir().join("scaled") }
/// Holds the folder the panel opens in, set with Make default
fn folder_file() -> PathBuf { home().join(".local/state/personalize/wallpaper-folder") }
fn default_folder() -> PathBuf {
    fs::read_to_string(folder_file()).ok().map(|p| PathBuf::from(p.trim())).filter(|p| p.is_dir())
        .unwrap_or_else(|| home().join("Pictures/Wallpapers"))
}

fn mtime(p: &Path) -> Option<u64> {
    Some(fs::metadata(p).ok()?.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_secs())
}

/// Swaps a symlink in one rename, so readers never see it missing
fn relink(link: &Path, target: &Path) {
    let tmp = link.with_extension("new");
    let _ = fs::create_dir_all(link.parent().unwrap());
    let _ = fs::remove_file(&tmp);
    if std::os::unix::fs::symlink(target, &tmp).is_ok() { let _ = fs::rename(&tmp, link); }
}

#[derive(Clone)]
struct State {
    dark: bool,
    from_wallpaper: bool,
    accent_dark: String,
    accent_light: String,
    icons_accent: bool,
    bar_solid: bool,
    hover: String,
    wallpaper: Option<PathBuf>,
}

impl State {
    fn load() -> State {
        let conf = fs::read_to_string(cfg("hypr/accent.conf")).unwrap_or_default();
        let get = |k: &str| conf.lines().find_map(|l| l.strip_prefix(k)?.strip_prefix('=')).map(|v| v.trim().to_string());
        State {
            dark: gio::Settings::new("org.gnome.desktop.interface").string("color-scheme") == "prefer-dark",
            from_wallpaper: get("source").as_deref() == Some("wallpaper"),
            accent_dark: get("dark").unwrap_or("#33ccff".into()),
            accent_light: get("light").unwrap_or("#0077b3".into()),
            icons_accent: fs::read_link(cfg("waybar/icons.css")).is_ok_and(|t| t.to_string_lossy().contains("accent")),
            bar_solid: fs::read_link(cfg("waybar/bar.css")).is_ok_and(|t| t.to_string_lossy().contains("solid")),
            // themes/hover-<style>.css
            hover: fs::read_link(cfg("waybar/hover.css")).ok()
                .and_then(|t| t.file_stem()?.to_str()?.strip_prefix("hover-").map(String::from))
                .unwrap_or("pill".into()),
            // Falls back to `current` for a wallpaper set before `source` existed
            wallpaper: fs::canonicalize(source_link()).ok()
                .or_else(|| fs::canonicalize(wallpaper_link()).ok().filter(|p| !p.starts_with(scaled_dir()))),
        }
    }

    fn accent(&self) -> &str { if self.dark { &self.accent_dark } else { &self.accent_light } }

    fn save_accent(&self) {
        let source = if self.from_wallpaper { "wallpaper" } else { "manual" };
        let _ = fs::write(cfg("hypr/accent.conf"), format!(
            "# Written by personalize (SUPER+W); apply with: theme-toggle.sh apply\n\
             # source=wallpaper: matugen sets both on wallpaper change; manual: each mode keeps its own pick\n\
             source={source}\ndark={}\nlight={}\n", self.accent_dark, self.accent_light));
    }
}

enum Op { Mode(bool), Wallpaper(PathBuf, Option<PathBuf>), Refit(PathBuf), FromWallpaper(Option<PathBuf>), Manual(String), Icons(bool), Bar(bool), Hover(&'static str) }

/// Sets both accents from the image, each from its own matugen run with that mode's fallback
/// (white for dark, black for light); false (accents untouched) if matugen fails.
/// matugen downscales to 112x112 before quantizing, so callers pass the cached
/// thumbnail when there is one: same colors, without decoding the full image.
fn matugen(img: &Path, s: &mut State) -> bool {
    let primary = |mode: &str, fallback: &str| -> Option<String> {
        let out = Command::new("matugen").arg("image").arg(img)
            .args(["-t", "scheme-smart", "-m", mode, "--fallback-color", fallback, "--source-color-index", "0", "--dry-run", "-q", "-j", "hex"])
            .output().ok()?;
        let text = String::from_utf8_lossy(&out.stdout);
        let json: serde_json::Value = serde_json::from_str(&text[text.find('{')?..]).ok()?;
        json["colors"]["primary"][mode]["color"].as_str().map(String::from)
    };
    let (Some(dark), Some(light)) = (primary("dark", "#ffffff"), primary("light", "#000000")) else { return false };
    s.accent_dark = dark;
    s.accent_light = light;
    true
}

/// Size the wallpaper has to cover: the largest monitor in device pixels, turned for rotated ones
fn screen_size() -> Option<(i32, i32)> {
    let out = Command::new("hyprctl").args(["monitors", "-j"]).output().ok()?;
    let mons: Vec<serde_json::Value> = serde_json::from_slice(&out.stdout).ok()?;
    mons.iter().filter_map(|m| {
        let (w, h) = (m["width"].as_i64()? as i32, m["height"].as_i64()? as i32);
        Some(if m["transform"].as_i64().unwrap_or(0) % 2 == 1 { (h, w) } else { (w, h) })
    }).reduce(|a, b| (a.0.max(b.0), a.1.max(b.1)))
}

/// The image to show for `src`: a copy scaled down to just cover the screen (hyprpaper crops it,
/// as before), with its size; or `src` itself when it is no bigger than the screen or can't be measured.
/// Everything past the screen size is memory the compositor holds for pixels it never shows.
fn fit(src: &Path) -> (PathBuf, Option<(i32, i32)>) {
    let copy = || {
        let (sw, sh) = screen_size()?;
        let (_, iw, ih) = gdk_pixbuf::Pixbuf::file_info(src)?;
        let k = f64::max(sw as f64 / iw as f64, sh as f64 / ih as f64);
        // Outside home (a removable or shared drive) always gets a copy, so login never waits on that drive
        if k >= 1.0 && src.starts_with(home()) { return None }
        let k = k.min(1.0);
        let (w, h) = ((iw as f64 * k).ceil() as i32, (ih as f64 * k).ceil() as i32);
        let name = format!("{}-{}-{w}x{h}.png", src.file_name()?.to_string_lossy(), mtime(src)?);
        Some((scaled_dir().join(name), (w, h)))
    };
    match copy() { Some((p, size)) => (p, Some(size)), None => (src.to_path_buf(), None) }
}

/// Shows `src` (as its screen-sized copy) now and after restarts, and deletes every other copy
fn set_wallpaper(src: &Path) {
    let (mut shown, size) = fit(src);
    if let (Some((w, h)), false) = (size, shown.exists()) {
        let _ = fs::create_dir_all(scaled_dir());
        // Written aside and renamed in, so hyprpaper never loads half a file
        let part = shown.with_extension("part");
        let saved = gdk_pixbuf::Pixbuf::from_file_at_scale(src, w, h, false)
            .and_then(|p| p.savev(&part, "png", &[])).is_ok();
        if !(saved && fs::rename(&part, &shown).is_ok()) {
            let _ = fs::remove_file(&part);
            shown = src.to_path_buf();
        }
    }
    // Links change only once the copy exists: being killed mid-scale leaves the old wallpaper intact
    relink(&source_link(), src);
    relink(&wallpaper_link(), &shown);
    // Apply live; if hyprpaper isn't reachable, restart it (it reads the symlink on start)
    let _ = Command::new("sh").args(["-c",
        r#"hyprctl hyprpaper wallpaper ",$1" >/dev/null 2>&1 || { pkill -x hyprpaper; setsid -f hyprpaper >/dev/null 2>&1; }"#,
        "sh"]).arg(&shown).status();
    // Only the shown copy is needed; hyprpaper already holds it, and a later pick rescales from the original
    for stale in fs::read_dir(scaled_dir()).into_iter().flatten().flatten().map(|e| e.path()) {
        if stale != shown { let _ = fs::remove_file(stale); }
    }
}

/// Points a waybar css file at a themes/ variant, like colors.css, and reloads waybar's style
fn waybar_link(name: &str, target: &str) {
    let (tmp, link) = (cfg(&format!("waybar/{name}.new")), cfg(&format!("waybar/{name}")));
    let _ = fs::remove_file(&tmp);
    if std::os::unix::fs::symlink(target, &tmp).is_ok() { let _ = fs::rename(&tmp, link); }
    let _ = Command::new("pkill").args(["-USR2", "-x", "waybar"]).status();
}

/// Runs off the UI thread; the panel reloads its state from disk afterwards
fn run(op: Op, mut s: State) {
    let theme = |arg: &str| { let _ = Command::new(cfg("hypr/scripts/theme-toggle.sh")).arg(arg).status(); };
    match op {
        Op::Mode(dark) => theme(if dark { "dark" } else { "light" }),
        Op::Icons(accent) => waybar_link("icons.css", if accent { "themes/icons-accent.css" } else { "themes/icons-mono.css" }),
        Op::Hover(style) => waybar_link("hover.css", &format!("themes/hover-{style}.css")),
        Op::Bar(solid) => waybar_link("bar.css", if solid { "themes/bar-solid.css" } else { "themes/bar-translucent.css" }),
        Op::Manual(hex) => {
            s.from_wallpaper = false;
            if s.dark { s.accent_dark = hex } else { s.accent_light = hex }
            s.save_accent();
            theme("apply");
        }
        Op::FromWallpaper(thumb) => {
            s.from_wallpaper = true;
            if let Some(w) = thumb.or_else(|| s.wallpaper.clone()) { matugen(&w, &mut s); }
            s.save_accent();
            theme("apply");
        }
        Op::Refit(path) => set_wallpaper(&path),
        Op::Wallpaper(path, thumb) => {
            set_wallpaper(&path);
            if s.from_wallpaper && matugen(thumb.as_deref().unwrap_or(&path), &mut s) {
                s.save_accent();
                theme("apply");
            }
        }
    }
}

/// (wallpaper, cached thumbnail); thumbnails are keyed by mtime so an edited image gets a new one.
/// Thumbnails left over from removed or edited wallpapers are dropped here, at panel open, so
/// nothing has to run in the background to keep the cache from growing.
fn wallpapers(folder: &Path) -> Vec<(PathBuf, PathBuf)> {
    let cache = home().join(".cache/personalize");
    let _ = fs::create_dir_all(&cache);
    // Returning before the prune matters: an unreadable directory must not empty the cache
    let Ok(dir) = fs::read_dir(folder) else { return vec![] };
    // Formats hyprpaper can load
    let mut files: Vec<PathBuf> = dir.flatten().map(|e| e.path())
        .filter(|p| p.extension().and_then(|e| e.to_str())
            .is_some_and(|e| ["png", "jpg", "jpeg", "webp", "jxl"].contains(&e.to_lowercase().as_str())))
        .collect();
    files.sort();
    let walls: Vec<(PathBuf, PathBuf)> = files.into_iter().filter_map(|p| {
        let thumb = cache.join(format!("{}-{}.png", p.file_name()?.to_string_lossy(), mtime(&p)?));
        if !thumb.exists() {
            gdk_pixbuf::Pixbuf::from_file_at_scale(&p, 240, 240, true).ok()?.savev(&thumb, "png", &[]).ok()?;
        }
        Some((fs::canonicalize(&p).unwrap_or(p), thumb))
    }).collect();
    // Thumbnails are derived data, so deleting one that is still wanted only costs a rescale
    for stale in fs::read_dir(&cache).into_iter().flatten().flatten().map(|e| e.path()) {
        if !walls.iter().any(|(_, thumb)| *thumb == stale) {
            let _ = fs::remove_file(stale);
        }
    }
    walls
}

fn css(s: &State, walls: &[(PathBuf, PathBuf)]) -> String {
    let (bg, fg, dim, border, card, ctrl, ctrl_on) = if s.dark {
        ("alpha(#000000, 0.85)", "#ffffff", "alpha(#ffffff, 0.55)", "alpha(#ffffff, 0.14)", "alpha(#ffffff, 0.06)", "alpha(#ffffff, 0.10)", "alpha(#ffffff, 0.28)")
    } else {
        ("alpha(#ffffff, 0.85)", "#000000", "alpha(#000000, 0.50)", "alpha(#000000, 0.10)", "alpha(#000000, 0.04)", "alpha(#000000, 0.07)", "#ffffff")
    };
    let accent = s.accent();
    let rgb = |i: usize| u32::from_str_radix(accent.get(i..i + 2).unwrap_or("00"), 16).unwrap_or(0);
    let on_accent = if rgb(1) * 299 + rgb(3) * 587 + rgb(5) * 114 > 150000 { "#000000" } else { "#ffffff" };
    let presets: String = PRESETS.iter().enumerate().map(|(i, (_, c))| format!(".sw{i} {{ background: {c}; }}\n")).collect();
    let custom = if custom_accent(s) {
        accent.to_string()
    } else {
        "conic-gradient(#ff3b30, #ffcc00, #34c759, #5ac8fa, #007aff, #af52de, #ff3b30)".into()
    };
    // Images as CSS backgrounds: a Picture's natural size (the thumbnail) would stretch the layout
    let mut images: String = walls.iter().enumerate()
        .map(|(i, (_, t))| format!(".wall{i} {{ background-image: url(\"file://{}\"); }}\n", t.display())).collect();
    // The shown copy stands in when the current wallpaper is not in the browsed folder
    let current = walls.iter().find(|(w, _)| Some(w) == s.wallpaper.as_ref()).map(|(_, t)| t.clone())
        .or_else(|| fs::canonicalize(wallpaper_link()).ok());
    if let Some(t) = current {
        images += &format!(".current-wall {{ background-image: url(\"file://{}\"); }}\n", t.display());
    }
    format!(r#"
@define-color p_bg {bg}; @define-color p_fg {fg}; @define-color p_dim {dim}; @define-color p_border {border};
@define-color p_card {card}; @define-color p_ctrl {ctrl}; @define-color p_ctrl_on {ctrl_on};
@define-color p_accent {accent}; @define-color p_on_accent {on_accent};
window {{ background: transparent; }}
.panel {{ background: @p_bg; color: @p_fg; border: 1px solid @p_border; border-radius: 26px; }}
button {{ border: none; box-shadow: none; outline: none; background: none; color: @p_fg; padding: 0; min-height: 0; min-width: 0; }}

.sidebar {{ background: @p_card; border: 1px solid @p_border; border-radius: 18px; margin: 8px; padding: 12px 8px 8px; }}
.sidebar button {{ border-radius: 8px; padding: 7px 8px; }}
.sidebar button:hover:not(.selected) {{ background: @p_ctrl; }}
.sidebar button.selected {{ background: @p_accent; color: @p_on_accent; }}
.pane-icon {{ border-radius: 6px; min-width: 22px; min-height: 22px; color: #ffffff; }}
.pane-icon.appearance {{ background: #3a3a3c; }}
.pane-icon.wallpaper {{ background: #32ade6; }}

.pane-title {{ margin: 16px 24px 10px; }}
.pane {{ padding: 0 24px 24px; }}
.section {{ font-weight: 700; margin: 18px 4px 8px; }}
.card {{ background: @p_card; border-radius: 12px; padding: 0 12px; }}
.card separator {{ background: @p_border; min-height: 1px; }}
.row {{ min-height: 40px; padding: 8px 0; }}
.caption {{ color: @p_dim; font-size: smaller; }}

.tile .preview {{ min-width: 80px; min-height: 52px; margin: 3px; border-radius: 7px; border: 1px solid @p_border; }}
.tile .preview.light {{ background: #f2f2f7; }}
.tile .preview.dark {{ background: #1c1c1e; }}
.tile .bar {{ min-width: 28px; min-height: 6px; margin: 7px; border-radius: 3px; background: @p_accent; }}
.tile:hover .preview {{ box-shadow: 0 0 0 3px @p_border; }}
.tile.selected .preview {{ box-shadow: 0 0 0 3px @p_accent; }}
.tile label {{ margin-top: 3px; }}

.swatch {{ margin: 3px; border-radius: 999px; }}
.swatch:hover {{ box-shadow: 0 0 0 2px @p_bg, 0 0 0 4px @p_border; }}
.swatch.selected, .swatch.selected:hover {{ box-shadow: 0 0 0 2px @p_bg, 0 0 0 4px @p_fg; }}
.sw-custom {{ background: {custom}; }}
.sw-wall {{ background: @p_ctrl; }}
{presets}{images}
.current-wall, .thumb {{ background-size: cover; background-position: center; }}
.current-wall {{ border-radius: 10px; }}

.seg {{ background: @p_ctrl; border-radius: 7px; padding: 2px; }}
.seg button {{ padding: 5px 16px; border-radius: 5px; }}
.seg button:hover:not(:checked) {{ background: alpha(@p_ctrl_on, 0.5); }}
.seg button:checked {{ background: @p_ctrl_on; }}

.thumb {{ margin: 5px; border-radius: 8px; }}
.thumb:hover {{ box-shadow: 0 0 0 3px @p_border; }}
.thumb.selected {{ box-shadow: 0 0 0 3px @p_accent; }}
.folder-btn {{ background: @p_ctrl; border-radius: 7px; padding: 4px 12px; font-weight: normal; }}
.folder-btn:hover {{ background: @p_ctrl_on; }}
.use {{ background: @p_accent; color: @p_on_accent; border-radius: 999px; padding: 6px 16px; }}
.use:hover {{ background: shade(@p_accent, 1.1); }}
"#)
}

fn custom_accent(s: &State) -> bool {
    !s.from_wallpaper && !PRESETS.iter().any(|(_, c)| c.eq_ignore_ascii_case(s.accent()))
}

#[derive(Clone, Copy, PartialEq)]
enum Pane { Appearance, Wallpaper }

struct Ctx {
    window: gtk::Window,
    provider: gtk::CssProvider,
    main_loop: glib::MainLoop,
    folder: RefCell<PathBuf>,
    walls: RefCell<Vec<(PathBuf, PathBuf)>>,
    /// The folder picker is open: the panel is hidden, and losing focus must not close it
    picking: Cell<bool>,
    pane: Cell<Pane>,
    busy: Cell<bool>,
    quit_pending: Cell<bool>,
}

impl Ctx {
    /// Closing mid-apply would kill the half-written theme: hide now, quit once it finishes
    fn close(&self) {
        if self.picking.get() { return }
        if self.busy.get() {
            self.window.set_visible(false);
            self.quit_pending.set(true);
        } else {
            self.main_loop.quit();
        }
    }
}

fn dispatch(ctx: &Rc<Ctx>, op: Op) {
    if ctx.busy.replace(true) {
        return;
    }
    let (ctx, s) = (ctx.clone(), State::load());
    glib::spawn_future_local(async move {
        let _ = gio::spawn_blocking(move || run(op, s)).await;
        ctx.busy.set(false);
        if ctx.quit_pending.get() { ctx.main_loop.quit() } else { refresh(&ctx) }
    });
}

fn refresh(ctx: &Rc<Ctx>) {
    let s = State::load();
    ctx.provider.load_from_string(&css(&s, &ctx.walls.borrow()));
    ctx.window.set_child(Some(&build(ctx, &s)));
}

fn sized(class: &str, w: i32, h: i32) -> gtk::Button {
    let b = gtk::Button::new();
    b.add_css_class(class);
    b.set_size_request(w, h);
    b.set_valign(gtk::Align::Center);
    b.set_halign(gtk::Align::Center);
    b
}

fn label(text: &str, class: &str) -> gtk::Label {
    let l = gtk::Label::new(Some(text));
    l.set_xalign(0.0);
    if !class.is_empty() { l.add_css_class(class) }
    l
}

fn row(title: &str, control: &impl IsA<gtk::Widget>) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    row.add_css_class("row");
    let l = label(title, "");
    l.set_hexpand(true);
    l.set_valign(gtk::Align::Start);
    l.set_margin_top(3);
    row.append(&l);
    control.set_valign(gtk::Align::Center);
    row.append(control);
    row
}

fn build(ctx: &Rc<Ctx>, s: &State) -> gtk::Box {
    let panel = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    panel.add_css_class("panel");
    panel.set_halign(gtk::Align::Center);
    panel.set_valign(gtk::Align::Center);
    panel.set_size_request(820, 600);

    // Sidebar
    let sidebar = gtk::Box::new(gtk::Orientation::Vertical, 2);
    sidebar.add_css_class("sidebar");
    sidebar.set_size_request(200, -1);
    for (pane, name, icon, class) in [
        (Pane::Appearance, "Appearance", "preferences-desktop-appearance-symbolic", "appearance"),
        (Pane::Wallpaper, "Wallpaper", "preferences-desktop-wallpaper-symbolic", "wallpaper"),
    ] {
        let b = gtk::Button::new();
        if ctx.pane.get() == pane { b.add_css_class("selected") }
        let content = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        let img = gtk::Image::from_icon_name(icon);
        img.set_pixel_size(14);
        img.add_css_class("pane-icon");
        img.add_css_class(class);
        content.append(&img);
        content.append(&label(name, ""));
        b.set_child(Some(&content));
        b.connect_clicked({ let ctx = ctx.clone(); move |_| if ctx.pane.get() != pane { ctx.pane.set(pane); refresh(&ctx) } });
        sidebar.append(&b);
    }
    panel.append(&sidebar);

    // Pane: title, then scrollable grouped content
    let main = gtk::Box::new(gtk::Orientation::Vertical, 0);
    main.set_hexpand(true);
    let title = gtk::Label::new(None);
    title.set_markup(&format!("<span size='large' weight='bold'>{}</span>",
        if ctx.pane.get() == Pane::Appearance { "Appearance" } else { "Wallpaper" }));
    title.set_xalign(0.0);
    title.add_css_class("pane-title");
    main.append(&title);
    let scroll = gtk::ScrolledWindow::new();
    scroll.set_hscrollbar_policy(gtk::PolicyType::Never);
    scroll.set_vexpand(true);
    let pane = gtk::Box::new(gtk::Orientation::Vertical, 0);
    pane.add_css_class("pane");
    match ctx.pane.get() {
        Pane::Appearance => appearance(ctx, s, &pane),
        Pane::Wallpaper => wallpaper(ctx, s, &pane),
    }
    scroll.set_child(Some(&pane));
    main.append(&scroll);
    panel.append(&main);
    panel
}

fn appearance(ctx: &Rc<Ctx>, s: &State, pane: &gtk::Box) {
    let card = gtk::Box::new(gtk::Orientation::Vertical, 0);
    card.add_css_class("card");

    let tiles = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    for (name, dark) in [("Light", false), ("Dark", true)] {
        let tile = gtk::Button::new();
        tile.add_css_class("tile");
        if s.dark == dark { tile.add_css_class("selected") }
        let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let preview = gtk::Box::new(gtk::Orientation::Vertical, 0);
        preview.add_css_class("preview");
        preview.add_css_class(if dark { "dark" } else { "light" });
        let bar = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        bar.add_css_class("bar");
        bar.set_halign(gtk::Align::Start);
        preview.append(&bar);
        content.append(&preview);
        content.append(&gtk::Label::new(Some(name)));
        tile.set_child(Some(&content));
        let current = s.dark;
        tile.connect_clicked({ let ctx = ctx.clone(); move |_| if current != dark { dispatch(&ctx, Op::Mode(dark)) } });
        tiles.append(&tile);
    }
    card.append(&row("Appearance", &tiles));
    card.append(&gtk::Separator::new(gtk::Orientation::Horizontal));

    // Accent: swatches with the selected name underneath
    let accent = gtk::Box::new(gtk::Orientation::Vertical, 4);
    let swatches = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    let wall_swatch = sized("swatch", 30, 30);
    wall_swatch.add_css_class("sw-wall");
    wall_swatch.add_css_class("current-wall");
    wall_swatch.set_tooltip_text(Some("Wallpaper"));
    if s.from_wallpaper { wall_swatch.add_css_class("selected") }
    let cur_thumb = ctx.walls.borrow().iter().find(|(w, _)| Some(w) == s.wallpaper.as_ref()).map(|(_, t)| t.clone());
    wall_swatch.connect_clicked({ let ctx = ctx.clone(); move |_| dispatch(&ctx, Op::FromWallpaper(cur_thumb.clone())) });
    swatches.append(&wall_swatch);
    let mut selected = if s.from_wallpaper { "Wallpaper" } else { "Custom" };
    for (i, (name, hex)) in PRESETS.iter().enumerate() {
        let b = sized("swatch", 30, 30);
        b.add_css_class(&format!("sw{i}"));
        b.set_tooltip_text(Some(name));
        if !s.from_wallpaper && hex.eq_ignore_ascii_case(s.accent()) { b.add_css_class("selected"); selected = name; }
        b.connect_clicked({ let ctx = ctx.clone(); move |_| dispatch(&ctx, Op::Manual(hex.to_string())) });
        swatches.append(&b);
    }
    let custom = sized("swatch", 30, 30);
    custom.add_css_class("sw-custom");
    custom.set_tooltip_text(Some("Custom"));
    if custom_accent(s) { custom.add_css_class("selected") }
    swatches.append(&custom);
    accent.append(&swatches);
    let caption = label(selected, "caption");
    caption.set_margin_start(2);
    accent.append(&caption);
    card.append(&row("Accent color", &accent));

    // Custom picker, shown inline: a separate dialog window would take focus and close the panel
    let picker = gtk::Box::new(gtk::Orientation::Vertical, 8);
    picker.set_visible(false);
    picker.set_margin_bottom(10);
    let chooser = gtk::ColorChooserWidget::new();
    chooser.set_use_alpha(false);
    chooser.set_property("show-editor", true);
    if let Ok(rgba) = gdk::RGBA::parse(s.accent()) { chooser.set_rgba(&rgba) }
    let use_color = gtk::Button::with_label("Use Color");
    use_color.add_css_class("use");
    use_color.set_halign(gtk::Align::End);
    use_color.connect_clicked({
        let (ctx, chooser) = (ctx.clone(), chooser.clone());
        move |_| {
            let c = chooser.rgba();
            let ch = |v: f32| (v.clamp(0.0, 1.0) * 255.0).round() as u8;
            dispatch(&ctx, Op::Manual(format!("#{:02x}{:02x}{:02x}", ch(c.red()), ch(c.green()), ch(c.blue()))))
        }
    });
    picker.append(&chooser);
    picker.append(&use_color);
    custom.connect_clicked({ let picker = picker.clone(); move |_| picker.set_visible(!picker.is_visible()) });
    card.append(&picker);
    card.append(&gtk::Separator::new(gtk::Orientation::Horizontal));

    card.append(&row("Menu bar icons", &segmented(ctx, &[("Accent", true), ("Mono", false)], s.icons_accent, Op::Icons)));
    card.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    card.append(&row("Menu bar background", &segmented(ctx, &[("Solid", true), ("Translucent", false)], s.bar_solid, Op::Bar)));
    card.append(&gtk::Separator::new(gtk::Orientation::Horizontal));
    let hovers = [("Color", "color"), ("Pill", "pill"), ("Underline", "underline"), ("Lines", "lines")];
    let current = hovers.iter().map(|&(_, v)| v).find(|v| *v == s.hover).unwrap_or("pill");
    card.append(&row("Menu bar hover", &segmented(ctx, &hovers, current, Op::Hover)));
    pane.append(&card);
}

/// Segmented control: one toggle per (label, value), the current value checked
fn segmented<T: Copy + PartialEq + 'static>(ctx: &Rc<Ctx>, options: &[(&str, T)], current: T, op: fn(T) -> Op) -> gtk::Box {
    let seg = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    seg.add_css_class("seg");
    let mut first: Option<gtk::ToggleButton> = None;
    for &(name, value) in options {
        let b = gtk::ToggleButton::with_label(name);
        b.set_group(first.as_ref());
        b.set_active(value == current);
        b.connect_toggled({ let ctx = ctx.clone(); move |b| if b.is_active() && current != value { dispatch(&ctx, op(value)) } });
        seg.append(&b);
        first.get_or_insert(b);
    }
    seg
}

fn wallpaper(ctx: &Rc<Ctx>, s: &State, pane: &gtk::Box) {
    // Current wallpaper
    let card = gtk::Box::new(gtk::Orientation::Horizontal, 16);
    card.add_css_class("card");
    card.set_margin_top(4);
    let preview = gtk::Box::new(gtk::Orientation::Vertical, 0);
    preview.add_css_class("current-wall");
    preview.set_size_request(176, 99);
    preview.set_margin_top(12);
    preview.set_margin_bottom(12);
    card.append(&preview);
    // Name as listed in the folder (the resolved path may be a system file behind a symlink)
    let walls = ctx.walls.borrow();
    let name = walls.iter().find(|(w, _)| Some(w) == s.wallpaper.as_ref())
        .and_then(|(_, t)| t.file_name()?.to_str()?.rsplit_once('-').map(|(n, _)| n.to_string()))
        .or_else(|| s.wallpaper.as_ref()?.file_name().map(|n| n.to_string_lossy().into_owned()))
        .and_then(|n| Path::new(&n).file_stem().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_default();
    let l = label(&name, "");
    l.set_valign(gtk::Align::Center);
    card.append(&l);
    pane.append(&card);

    let folder = ctx.folder.borrow().clone();
    let head = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    head.add_css_class("section");
    let title = label(&folder.file_name().map_or("/".into(), |n| n.to_string_lossy().into_owned()), "");
    title.set_tooltip_text(Some(&folder.to_string_lossy()));
    title.set_hexpand(true);
    title.set_ellipsize(gtk::pango::EllipsizeMode::Middle);
    head.append(&title);
    if folder != default_folder() {
        let b = gtk::Button::with_label("Make default");
        b.add_css_class("folder-btn");
        b.connect_clicked({ let ctx = ctx.clone(); move |_| {
            let _ = fs::create_dir_all(folder_file().parent().unwrap());
            let _ = fs::write(folder_file(), ctx.folder.borrow().to_string_lossy().as_bytes());
            refresh(&ctx);
        }});
        head.append(&b);
    }
    let browse = gtk::Button::with_label("Browse…");
    browse.add_css_class("folder-btn");
    browse.connect_clicked({ let ctx = ctx.clone(); move |_| browse_folder(&ctx) });
    head.append(&browse);
    pane.append(&head);
    if walls.is_empty() { pane.append(&label("No pictures in this folder", "caption")); }
    let grid = gtk::FlowBox::new();
    grid.set_selection_mode(gtk::SelectionMode::None);
    grid.set_homogeneous(true);
    grid.set_min_children_per_line(4);
    grid.set_max_children_per_line(4);
    grid.set_valign(gtk::Align::Start);
    for (i, (wall, thumb)) in walls.iter().enumerate() {
        let b = sized("thumb", 124, 70);
        b.add_css_class(&format!("wall{i}"));
        if Some(wall) == s.wallpaper.as_ref() { b.add_css_class("selected") }
        let (current, wall, thumb) = (s.wallpaper.as_ref() == Some(wall), wall.clone(), thumb.clone());
        b.connect_clicked({ let ctx = ctx.clone(); move |_| if !current { dispatch(&ctx, Op::Wallpaper(wall.clone(), Some(thumb.clone()))) } });
        grid.append(&b);
    }
    pane.append(&grid);
}

/// Picks the folder the grid shows. The picker is a normal window, which this layer-shell panel
/// would cover, so the panel hides until it is closed.
fn browse_folder(ctx: &Rc<Ctx>) {
    let dialog = gtk::FileDialog::new();
    dialog.set_title("Wallpaper folder");
    dialog.set_initial_folder(Some(&gio::File::for_path(&*ctx.folder.borrow())));
    ctx.picking.set(true);
    ctx.window.set_visible(false);
    let ctx = ctx.clone();
    glib::spawn_future_local(async move {
        if let Some(path) = dialog.select_folder_future(None::<&gtk::Window>).await.ok().and_then(|f| f.path()) {
            *ctx.walls.borrow_mut() = wallpapers(&path);
            *ctx.folder.borrow_mut() = path;
            refresh(&ctx);
        }
        ctx.window.present();
        ctx.picking.set(false);
    });
}

fn main() {
    // Software rendering: a short-lived panel is cheaper on the CPU than waking the iGPU
    std::env::set_var("GSK_RENDERER", "cairo");
    // No accessibility bus on this system; skips a failing D-Bus lookup at startup
    std::env::set_var("GTK_A11Y", "none");
    gtk::init().expect("gtk init");
    // Instant state changes: no hover/press/toggle transitions
    if let Some(settings) = gtk::Settings::default() { settings.set_gtk_enable_animations(false) }

    let provider = gtk::CssProvider::new();
    // Above USER: ~/.config/gtk-4.0/gtk.css sets button min-heights that would stretch the swatches
    gtk::style_context_add_provider_for_display(&gdk::Display::default().unwrap(), &provider, gtk::STYLE_PROVIDER_PRIORITY_USER + 1);

    let window = gtk::Window::new();
    window.init_layer_shell();
    window.add_css_class("layer-panel");
    window.set_namespace(Some("personalize"));
    window.set_layer(Layer::Top);
    // Cover the screen (minus the bar) so a click outside the panel can close it
    for edge in [Edge::Top, Edge::Bottom, Edge::Left, Edge::Right] {
        window.set_anchor(edge, true);
    }
    window.set_keyboard_mode(KeyboardMode::OnDemand);

    let ctx = Rc::new(Ctx {
        window: window.clone(),
        provider,
        main_loop: glib::MainLoop::new(None, false),
        walls: RefCell::new(wallpapers(&default_folder())),
        folder: RefCell::new(default_folder()),
        picking: Cell::new(false),
        pane: Cell::new(Pane::Wallpaper),
        busy: Cell::new(false),
        quit_pending: Cell::new(false),
    });
    refresh(&ctx);
    // Rescales the current wallpaper when its copy no longer matches: set before copies existed,
    // edited since, or scaled for a monitor that has been swapped. A missing original keeps the old copy.
    if let Some(src) = State::load().wallpaper.filter(|p| p.exists()) {
        if fs::canonicalize(wallpaper_link()).ok() != Some(fit(&src).0) { dispatch(&ctx, Op::Refit(src)) }
    }

    let outside = gtk::GestureClick::new();
    outside.set_propagation_phase(gtk::PropagationPhase::Capture);
    outside.connect_pressed({
        let ctx = ctx.clone();
        move |g, _, x, y| {
            let inside = g.widget().zip(ctx.window.child())
                .and_then(|(w, panel)| panel.compute_bounds(&w))
                .is_some_and(|b| b.contains_point(&gtk::graphene::Point::new(x as f32, y as f32)));
            if !inside { ctx.close() }
        }
    });
    window.add_controller(outside);

    let keys = gtk::EventControllerKey::new();
    keys.connect_key_pressed({
        let ctx = ctx.clone();
        move |_, key, _, _| {
            if key == gdk::Key::Escape { ctx.close(); return glib::Propagation::Stop }
            glib::Propagation::Proceed
        }
    });
    window.add_controller(keys);

    // Close when focus moves to another window (only after it has had focus once)
    let had_focus = Cell::new(false);
    window.connect_is_active_notify({
        let ctx = ctx.clone();
        move |w| if w.is_active() { had_focus.set(true) } else if had_focus.get() { ctx.close() }
    });
    window.connect_close_request({
        let ctx = ctx.clone();
        move |_| { ctx.close(); glib::Propagation::Stop }
    });

    window.present();
    GtkWindowExt::set_focus(&window, None::<&gtk::Widget>);
    ctx.main_loop.run();
}

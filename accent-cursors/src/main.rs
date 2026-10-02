//! Build an xcursor theme whose busy cursors are a minimal accent-colored spinner.
//!
//! usage: accent-cursors RRGGBB dark|light OUTDIR
//!
//! Both modes get a thin Windows-style I-beam (black in dark mode, white in light).
//! Light mode also gets a white arrow and the original white macOS hands (the cursor takes the
//! background's color); everything else is inherited from macOS-plain (black arrow and hands).
//! Runs only when the accent or this binary changes (theme-toggle.sh checks both);
//! the animation itself is played by the compositor.
//!
//! Build/install: cargo install --path ~/dotfiles/accent-cursors --root ~/.local
//! The spinner is drawn by cairo on an image surface, which is CPU-only (pixman) and never
//! touches the GPU. Everything else is byte work on the xcursor container format.

use cairo::{Context, Format, ImageSurface, LineCap};
use std::{
    collections::BTreeMap,
    f64::consts::PI,
    fs,
    os::unix,
    path::{Path, PathBuf},
    process::exit,
};

/// Only 28 (hyprctl setcursor) and 32 (`XCURSOR_SIZE`, gsettings cursor-size) are ever requested;
/// 24 and 48 are headroom, and libXcursor falls back to the nearest size for anything else.
/// Cost is quadratic in size, so a short list is most of this program's speed.
const SIZES: [u32; 4] = [24, 28, 32, 48];
const FRAMES: u32 = 30;
const DELAY: u32 = 33; // one turn per second
const ARC: f64 = 100.0 * PI / 180.0; // length of the moving arc
const IMAGE: u32 = 0xFFFD_0002; // xcursor chunk type for an image

type Rgb = (u8, u8, u8);
const BLACK: Rgb = (0, 0, 0);
const WHITE: Rgb = (255, 255, 255);

/// One frame of an xcursor image chunk. `px` is premultiplied BGRA, which is both what the
/// format stores (little-endian ARGB32) and what cairo's `ARgb32` surfaces hold.
struct Frame {
    size: u32,
    w: u32,
    h: u32,
    xhot: u32,
    yhot: u32,
    delay: u32,
    px: Vec<u8>,
}

fn u32_at(d: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(d[at..at + 4].try_into().unwrap())
}

fn read(path: &Path) -> Vec<u8> {
    fs::read(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

/// (nominal size, chunk offset, pixel byte range) of every image chunk in a cursor file.
fn images(d: &[u8]) -> impl Iterator<Item = (u32, usize, std::ops::Range<usize>)> {
    (0..u32_at(d, 12) as usize).filter_map(move |i| {
        let toc = 16 + i * 12;
        if u32_at(d, toc) != IMAGE {
            return None;
        }
        let pos = u32_at(d, toc + 8) as usize;
        let len = (u32_at(d, pos + 16) * u32_at(d, pos + 20) * 4) as usize;
        Some((u32_at(d, toc + 4), pos, pos + 36..pos + 36 + len))
    })
}

/// {nominal size: first frame of that size} from a cursor file.
fn read_cursor(path: &Path) -> BTreeMap<u32, Frame> {
    let d = read(path);
    let mut out = BTreeMap::new();
    for (size, pos, px) in images(&d) {
        out.entry(size).or_insert_with(|| Frame {
            size,
            w: u32_at(&d, pos + 16),
            h: u32_at(&d, pos + 20),
            xhot: u32_at(&d, pos + 24),
            yhot: u32_at(&d, pos + 28),
            delay: 0,
            px: d[px].to_vec(),
        });
    }
    out
}

fn write_cursor(path: &Path, frames: &[Frame]) {
    let mut pos = 16 + 12 * frames.len() as u32;
    let mut out = b"Xcur".to_vec();
    for v in [16, 0x10000, frames.len() as u32] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    for f in frames {
        for v in [IMAGE, f.size, pos] {
            out.extend_from_slice(&v.to_le_bytes());
        }
        pos += 36 + f.px.len() as u32;
    }
    for f in frames {
        for v in [36, IMAGE, f.size, 1, f.w, f.h, f.xhot, f.yhot, f.delay] {
            out.extend_from_slice(&v.to_le_bytes());
        }
        out.extend_from_slice(&f.px);
    }
    fs::write(path, out).unwrap();
}

/// Swap black and white in a cursor file, keeping the faint drop shadow dark.
fn invert(path: &Path) -> Vec<u8> {
    let mut d = read(path);
    let ranges: Vec<_> = images(&d).map(|(_, _, px)| px).collect();
    for range in ranges {
        for p in d[range].as_chunks_mut::<4>().0 {
            let a = f64::from(p[3]);
            if a == 0.0 {
                continue;
            }
            let t = ((a / 255.0 - 0.45) / 0.35).clamp(0.0, 1.0);
            let f = t * t * (3.0 - 2.0 * t); // solid glyph inverts, low-alpha shadow doesn't
            for c in &mut p[..3] {
                let v = f64::from(*c) / a * 255.0;
                *c = ((v + (255.0 - 2.0 * v) * f) * a / 255.0).round_ties_even() as u8;
            }
        }
    }
    d
}

/// Recreate every macOS alias pointing at `targets`, so lookups don't fall through to macOS-plain.
fn link_aliases(macos: &Path, cur: &Path, targets: &[&str]) {
    for entry in fs::read_dir(macos).unwrap().flatten() {
        let Ok(target) = fs::read_link(entry.path()) else {
            continue;
        };
        if !targets.contains(&target.to_string_lossy().as_ref()) {
            continue;
        }
        relink(&target, &cur.join(entry.file_name()));
    }
}

fn relink(target: &Path, link: &Path) {
    let _ = fs::remove_file(link);
    unix::fs::symlink(target, link).unwrap();
}

/// Thin Windows-style text cursor, snapped to whole pixels so it stays crisp.
fn ibeam(s: u32, fill: Rgb, outline: Rgb) -> Frame {
    let (si, sf) = (i64::from(s), f64::from(s));
    let w = (sf / 24.0).round_ties_even().max(1.0) as i64; // stroke
    let o = (sf / 48.0).round_ties_even().max(1.0) as i64; // outline
    let h = (sf * 0.66).round_ties_even() as i64;
    let mut bar = (sf * 0.26).round_ties_even() as i64;
    if (bar - w) % 2 != 0 {
        bar += 1; // keep the caps symmetric around the stem
    }
    let (x0, y0) = ((si - w) / 2, (si - h) / 2);
    let bx = x0 - (bar - w) / 2;
    let rects = [(x0, y0, w, h), (bx, y0, bar, w), (bx, y0 + h - w, bar, w)];

    let mut px = vec![0u8; (s * s * 4) as usize];
    for (grow, (r, g, b)) in [(o, outline), (0, fill)] {
        for (x, y, rw, rh) in rects {
            for yy in y - grow..y + rh + grow {
                for xx in x - grow..x + rw + grow {
                    if !(0..si).contains(&yy) || !(0..si).contains(&xx) {
                        continue;
                    }
                    let i = ((yy * si + xx) * 4) as usize;
                    px[i..i + 4].copy_from_slice(&[b, g, r, 255]);
                }
            }
        }
    }
    Frame {
        size: s,
        w: s,
        h: s,
        xhot: (x0 + w / 2) as u32,
        yhot: (si / 2) as u32,
        delay: 0,
        px,
    }
}

/// Composite a spinner (halo + faint track + arc with round caps) onto a cairo surface.
fn ring(
    cr: &Context,
    (cx, cy): (f64, f64),
    radius: f64,
    stroke: f64,
    angle: f64,
    accent: (f64, f64, f64),
    halo: (f64, f64, f64, f64),
) {
    let (r, g, b) = accent;
    cr.set_line_cap(LineCap::Round);
    // Contrast outline, so the ring stays visible on either background
    cr.set_line_width(stroke + 2.0 * (stroke * 0.35).max(1.0));
    cr.set_source_rgba(halo.0, halo.1, halo.2, halo.3);
    cr.arc(cx, cy, radius, 0.0, 2.0 * PI);
    cr.stroke().unwrap();
    // Faint full-circle track
    cr.set_line_width(stroke);
    cr.set_source_rgba(r, g, b, 0.30);
    cr.arc(cx, cy, radius, 0.0, 2.0 * PI);
    cr.stroke().unwrap();
    // Moving arc
    cr.set_source_rgba(r, g, b, 1.0);
    cr.arc(cx, cy, radius, angle, angle + ARC);
    cr.stroke().unwrap();
}

/// Draw `f` onto a surface (seeded with `base` when the spinner sits on top of the arrow),
/// then read the premultiplied BGRA back out, dropping cairo's row padding.
fn draw(w: u32, h: u32, base: Option<&[u8]>, f: impl FnOnce(&Context)) -> Vec<u8> {
    let mut surf = ImageSurface::create(Format::ARgb32, w as i32, h as i32).unwrap();
    let stride = surf.stride() as usize;
    let row = (w * 4) as usize;
    if let Some(base) = base {
        let mut data = surf.data().unwrap();
        for (dst, src) in data.chunks_mut(stride).zip(base.chunks_exact(row)) {
            dst[..row].copy_from_slice(src);
        }
    }
    let cr = Context::new(&surf).unwrap();
    f(&cr);
    drop(cr);
    let data = surf.data().unwrap();
    data.chunks(stride)
        .take(h as usize)
        .flat_map(|r| &r[..row])
        .copied()
        .collect()
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let usage = || -> ! {
        eprintln!("usage: accent-cursors RRGGBB dark|light OUTDIR");
        exit(2)
    };
    let [_, hex, mode, outdir] = args.as_slice() else {
        usage()
    };
    let hex = hex.trim_start_matches('#');
    let rgb = match u32::from_str_radix(hex, 16) {
        Ok(v) if hex.len() == 6 && !hex.starts_with('+') => v,
        _ => usage(),
    };
    let dark = match mode.as_str() {
        "dark" => true,
        "light" => false,
        _ => usage(),
    };
    let outdir = Path::new(outdir);
    let channel = |shift: u32| f64::from((rgb >> shift) & 0xFF) / 255.0;
    let accent = (channel(16), channel(8), channel(0));
    let halo = if dark {
        (0.0, 0.0, 0.0, 0.55)
    } else {
        (1.0, 1.0, 1.0, 0.85)
    };
    let macos = PathBuf::from(std::env::var("HOME").expect("HOME is not set"))
        .join(".local/share/icons/macOS/cursors");
    let cur = outdir.join("cursors");
    fs::create_dir_all(&cur).unwrap();

    if !dark {
        fs::write(cur.join("left_ptr"), invert(&macos.join("left_ptr"))).unwrap();
        for hand in ["hand1", "hand2", "move"] {
            fs::copy(macos.join(hand), cur.join(hand)).unwrap();
        }
        link_aliases(&macos, &cur, &["left_ptr", "hand1", "hand2", "move"]);
    }

    let arrows = read_cursor(&if dark { &macos } else { &cur }.join("left_ptr"));
    let (mut wait, mut progress) = (Vec::new(), Vec::new());
    for s in SIZES {
        let a = &arrows[&s];
        let sf = f64::from(s);
        for f in 0..FRAMES {
            let angle = 2.0 * PI * f64::from(f) / f64::from(FRAMES) - PI / 2.0;
            let spin = |center, radius, stroke| {
                move |cr: &Context| ring(cr, center, radius, stroke, angle, accent, halo)
            };
            let px = draw(s, s, None, spin((sf / 2.0, sf / 2.0), sf * 0.34, sf * 0.10));
            wait.push(Frame {
                size: s,
                w: s,
                h: s,
                xhot: s / 2,
                yhot: s / 2,
                delay: DELAY,
                px,
            });
            // macOS arrow with a small spinner at the lower right
            let center = (f64::from(a.w) * 0.76, f64::from(a.h) * 0.76);
            let px = draw(a.w, a.h, Some(&a.px), spin(center, sf * 0.15, sf * 0.075));
            progress.push(Frame {
                size: s,
                w: a.w,
                h: a.h,
                xhot: a.xhot,
                yhot: a.yhot,
                delay: DELAY,
                px,
            });
        }
    }

    let (fill, outline) = if dark { (BLACK, WHITE) } else { (WHITE, BLACK) };
    let texts: Vec<Frame> = SIZES.iter().map(|&s| ibeam(s, fill, outline)).collect();

    write_cursor(&cur.join("xterm"), &texts);
    write_cursor(&cur.join("wait"), &wait);
    write_cursor(&cur.join("left_ptr_watch"), &progress);
    link_aliases(&macos, &cur, &["xterm"]);
    for (alias, target) in [
        ("watch", "wait"),
        ("progress", "left_ptr_watch"),
        ("half-busy", "left_ptr_watch"),
        ("00000000000000020006000e7e9ffc3f", "left_ptr_watch"),
        ("08e8e1c95fe2fc01f976f1e063a24ccd", "left_ptr_watch"),
        ("3ecb610c1bf2410f44200f48c40d3599", "left_ptr_watch"),
    ] {
        relink(Path::new(target), &cur.join(alias));
    }
    let name = outdir.file_name().unwrap().to_string_lossy();
    // accent= lets theme-toggle.sh skip a rebuild when only the mtime changed
    fs::write(
        outdir.join("index.theme"),
        format!("[Icon Theme]\nName={name}\nComment=macOS cursors with an accent spinner\nInherits=macOS-plain\naccent=#{hex}\n"),
    )
    .unwrap();
}

user_pref("layout.css.devPixelsPerPx", "1.25");
user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);
user_pref("browser.uidensity", 1);
// Toolbar translucency (userChrome.css): give the window an alpha channel and stop declaring it opaque to the compositor
user_pref("widget.transparent-windows", true);
user_pref("widget.wayland.opaque-region.enabled", false);

// Hardware video decoding on the Intel iGPU (VA-API), much lighter on the battery than
// decoding on the CPU. On by default for Intel since Firefox 101; pinned here so the
// setting travels with the repo. Check it at about:support -> HARDWARE_VIDEO_DECODING.
user_pref("media.hardware-video-decoding.enabled", true);
user_pref("media.ffmpeg.vaapi.enabled", true);

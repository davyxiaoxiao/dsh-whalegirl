//! App state, settings persistence, window placement and the native monitor /
//! hit-test loops.

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tauri::{
    AppHandle, Emitter, LogicalPosition, LogicalSize, Manager, PhysicalPosition, WebviewWindow,
};
use whalegirl_core::models::FleetView;
use whalegirl_core::monitor::AgentMonitor;
use whalegirl_core::paths::WgPaths;
use whalegirl_core::providers::ProviderContext;

use crate::platform::{self, HitRect};

pub const PET_LABEL: &str = "pet";
pub const BOARD_LABEL: &str = "board";
pub const PET_WIDTH: f64 = 360.0;
pub const PET_HEIGHT: f64 = 400.0;
pub const SPRITE_HEIGHT: f64 = 224.0;
pub const MIN_SCALE: f64 = 0.55;
pub const MAX_SCALE: f64 = 1.25;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub pet_scale: f64,
    /// Logical screen position (physical / scale factor).
    pub x: Option<f64>,
    pub y: Option<f64>,
    pub sounds: bool,
    pub wander: bool,
    pub drop_tumble: bool,
    pub paused: bool,
    pub opencode_fetch_quotas: bool,
    pub opencode_plan: String,
    pub board_channel: Option<String>,
    pub bubble_collapsed: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            pet_scale: 1.0,
            x: None,
            y: None,
            sounds: true,
            wander: true,
            drop_tumble: true,
            paused: false,
            opencode_fetch_quotas: true,
            opencode_plan: "go".to_string(),
            board_channel: None,
            bubble_collapsed: false,
        }
    }
}

pub struct AppState {
    pub monitor: Mutex<AgentMonitor>,
    pub fleet: Mutex<Option<FleetView>>,
    pub settings: Mutex<Settings>,
    pub settings_path: PathBuf,
    pub paths: WgPaths,
    pub hit_rect: Mutex<Option<HitRect>>,
    pub dragging: AtomicBool,
    pub visible: AtomicBool,
    pub board_open: AtomicBool,
    pub last_ignore: AtomicBool,
}

impl AppState {
    pub fn settings_snapshot(&self) -> Settings {
        self.settings
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .clone()
    }
}

pub fn panel_height(scale: f64) -> f64 {
    PET_HEIGHT + SPRITE_HEIGHT * (clamp_scale(scale) - 1.0)
}

pub fn clamp_scale(scale: f64) -> f64 {
    if !scale.is_finite() || scale <= 0.0 {
        return 1.0;
    }
    scale.clamp(MIN_SCALE, MAX_SCALE)
}

// MARK: - Setup

pub fn setup(app: &mut tauri::App, safe_mode: bool) -> Result<(), Box<dyn std::error::Error>> {
    crate::diagnostics::write("setup: begin");
    let handle = app.handle().clone();
    // A desktop pet must not own the Dock or the app menu bar.
    #[cfg(target_os = "macos")]
    {
        app.set_activation_policy(tauri::ActivationPolicy::Accessory);
    }
    let paths = WgPaths::default_paths();
    let settings_path = app
        .path()
        .app_config_dir()
        .map(|dir| dir.join("settings.json"))
        .unwrap_or_else(|_| {
            std::env::temp_dir()
                .join("com.daiwei.whalegirl")
                .join("settings.json")
        });
    crate::diagnostics::write(format!("setup: settings={settings_path:?}"));
    let settings = load_settings(&settings_path);

    let mut ctx = ProviderContext::new(paths.clone());
    ctx.opencode_fetch_quotas = settings.opencode_fetch_quotas;
    ctx.opencode_plan = settings.opencode_plan.clone();
    ctx.opencode_quotas_opt_out = !settings.opencode_fetch_quotas;
    #[cfg(debug_assertions)]
    {
        ctx.log = Some(std::sync::Arc::new(|line: &str| eprintln!("[wg] {line}")));
    }

    let mut monitor = AgentMonitor::new(&ctx);
    monitor.set_paused(settings.paused);

    app.manage(AppState {
        monitor: Mutex::new(monitor),
        fleet: Mutex::new(None),
        settings: Mutex::new(settings),
        settings_path,
        paths,
        hit_rect: Mutex::new(None),
        dragging: AtomicBool::new(false),
        visible: AtomicBool::new(true),
        board_open: AtomicBool::new(false),
        last_ignore: AtomicBool::new(false),
    });

    if let Err(error) = apply_initial_window(&handle) {
        crate::diagnostics::write(format!("setup: apply_initial_window failed: {error:?}"));
    }
    #[cfg(target_os = "macos")]
    {
        if let Some(pet) = handle.get_webview_window(PET_LABEL) {
            platform::configure_overlay(&pet);
        }
        if let Some(board) = handle.get_webview_window(BOARD_LABEL) {
            platform::configure_overlay(&board);
        }
    }
    if safe_mode {
        crate::diagnostics::write("setup: SAFE MODE (tray/control/monitor/deep-link skipped)");
        write_pet_state(&handle);
        crate::diagnostics::write("setup: done (safe mode)");
        return Ok(());
    }

    start_monitor(handle.clone());
    start_hit_test(handle.clone());
    if let Err(error) = crate::menu::install_tray(&handle) {
        crate::diagnostics::write(format!(
            "setup: install_tray failed (continuing): {error:?}"
        ));
    } else {
        crate::diagnostics::write("setup: tray installed");
    }
    crate::control::start(handle.clone());
    crate::diagnostics::write("setup: control started");
    write_pet_state(&handle);

    #[cfg(desktop)]
    {
        use tauri_plugin_deep_link::DeepLinkExt;
        let deep_handle = handle.clone();
        app.deep_link().on_open_url(move |event| {
            for url in event.urls() {
                handle_url(&deep_handle, url.as_str());
            }
        });
        if let Err(error) = app.deep_link().register_all() {
            crate::diagnostics::write(format!("setup: deep-link registration failed: {error}"));
        }
    }

    crate::diagnostics::write("setup: done");
    Ok(())
}

fn apply_initial_window(app: &AppHandle) -> tauri::Result<()> {
    let settings = app.state::<AppState>().settings_snapshot();
    if let Some(pet) = app.get_webview_window(PET_LABEL) {
        let height = panel_height(settings.pet_scale);
        pet.set_size(LogicalSize::new(PET_WIDTH, height))?;
        let position = match (settings.x, settings.y) {
            (Some(x), Some(y)) => LogicalPosition::new(x, y),
            _ => default_pet_position(&pet, height)?,
        };
        pet.set_position(position)?;
        clamp_pet_to_work_area(&pet);
        // A desktop pet must never steal keyboard focus from the editor. On
        // macOS this also matches the old non-activating NSPanel; on Windows
        // the window stays focusable so native menus behave normally.
        #[cfg(target_os = "macos")]
        let _ = pet.set_focusable(false);
        let _ = pet.set_ignore_cursor_events(true);
    }
    if let Some(board) = app.get_webview_window(BOARD_LABEL) {
        let _ = board.hide();
    }
    Ok(())
}

fn default_pet_position(pet: &WebviewWindow, height: f64) -> tauri::Result<LogicalPosition<f64>> {
    let monitor = pet
        .current_monitor()?
        .or_else(|| pet.primary_monitor().ok().flatten());
    if let Some(monitor) = monitor {
        let scale = monitor.scale_factor();
        let work = monitor.work_area();
        let pos = work.position;
        let size = work.size;
        let width = panel_width();
        return Ok(LogicalPosition::new(
            (pos.x + size.width as i32) as f64 / scale - width - 20.0,
            (pos.y + size.height as i32) as f64 / scale - height - 12.0,
        ));
    }
    Ok(LogicalPosition::new(1140.0, 680.0))
}

pub fn panel_width() -> f64 {
    PET_WIDTH
}

// MARK: - Settings

pub fn load_settings(path: &PathBuf) -> Settings {
    let Ok(data) = fs::read(path) else {
        return Settings::default();
    };
    serde_json::from_slice(&data).unwrap_or_default()
}

pub fn save_settings(app: &AppHandle) {
    let state = app.state::<AppState>();
    let settings = state.settings_snapshot();
    if let Some(parent) = state.settings_path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(data) = serde_json::to_vec_pretty(&settings) {
        let _ = fs::write(&state.settings_path, data);
    }
}

pub fn mutate_settings(app: &AppHandle, mutate: impl FnOnce(&mut Settings)) {
    {
        let state = app.state::<AppState>();
        let mut settings = state.settings.lock().unwrap_or_else(|e| e.into_inner());
        mutate(&mut settings);
    }
    save_settings(app);
    crate::menu::rebuild_tray(app);
    emit_settings(app);
}

pub fn emit_settings(app: &AppHandle) {
    let settings = app.state::<AppState>().settings_snapshot();
    let _ = app.emit("settings", &settings);
    let _ = app.emit("state", &crate::UiState::snapshot(app));
}

// MARK: - Windows

pub fn show_pet(app: &AppHandle) {
    let state = app.state::<AppState>();
    state.visible.store(true, Ordering::Relaxed);
    if let Some(pet) = app.get_webview_window(PET_LABEL) {
        let _ = pet.show();
    }
    write_pet_state(app);
    let _ = app.emit("pet:visible", true);
    emit_settings(app);
}

pub fn hide_pet(app: &AppHandle) {
    let state = app.state::<AppState>();
    state.visible.store(false, Ordering::Relaxed);
    set_board_open(app, false);
    if let Some(pet) = app.get_webview_window(PET_LABEL) {
        let _ = pet.hide();
        let _ = pet.set_ignore_cursor_events(true);
    }
    write_pet_state(app);
    let _ = app.emit("pet:visible", false);
}

pub fn toggle_pet(app: &AppHandle) {
    if app.state::<AppState>().visible.load(Ordering::Relaxed) {
        hide_pet(app);
    } else {
        show_pet(app);
    }
}

pub fn is_pet_visible(app: &AppHandle) -> bool {
    app.state::<AppState>().visible.load(Ordering::Relaxed)
}

pub fn is_board_open(app: &AppHandle) -> bool {
    app.state::<AppState>().board_open.load(Ordering::Relaxed)
}

pub fn set_board_open(app: &AppHandle, open: bool) {
    let state = app.state::<AppState>();
    state.board_open.store(open, Ordering::Relaxed);
    if let Some(board) = app.get_webview_window(BOARD_LABEL) {
        if open {
            let _ = position_board(app, &board);
            let _ = board.show();
            let _ = board.set_focus();
        } else {
            let _ = board.hide();
        }
    }
    let _ = app.emit("board:open", open);
    crate::menu::rebuild_tray(app);
}

pub fn toggle_board(app: &AppHandle, open: Option<bool>) {
    let target = open.unwrap_or(!is_board_open(app));
    set_board_open(app, target);
}

pub fn position_board(app: &AppHandle, board: &WebviewWindow) -> tauri::Result<()> {
    let Some(pet) = app.get_webview_window(PET_LABEL) else {
        return Ok(());
    };
    let pet_pos = pet.outer_position()?;
    let pet_size = pet.outer_size()?;
    let board_size = board.outer_size()?;
    let scale = board.scale_factor().unwrap_or(1.0);
    let gap = (8.0 * scale) as i32;
    let margin = (10.0 * scale) as i32;

    let monitor = pet
        .current_monitor()?
        .or_else(|| pet.primary_monitor().ok().flatten());
    let (mon_x, mon_y, mon_w, mon_h) = monitor
        .map(|m| {
            let work = m.work_area();
            (
                work.position.x,
                work.position.y,
                work.size.width as i32,
                work.size.height as i32,
            )
        })
        .unwrap_or((0, 0, 1920, 1080));

    // Prefer the left side of the pet, then the right side, then overlap.
    let mut x = pet_pos.x - board_size.width as i32 - gap;
    if x < mon_x + margin {
        x = pet_pos.x + pet_size.width as i32 + gap;
    }
    if x + board_size.width as i32 > mon_x + mon_w - margin {
        x = pet_pos.x + pet_size.width as i32 - board_size.width as i32;
    }
    let mut y = pet_pos.y + pet_size.height as i32 - board_size.height as i32;
    x = x.clamp(
        mon_x + margin,
        mon_x + mon_w - board_size.width as i32 - margin,
    );
    y = y.clamp(
        mon_y + margin,
        mon_y + mon_h - board_size.height as i32 - margin - (40.0 * scale) as i32,
    );
    board.set_position(PhysicalPosition::new(x, y))
}

#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PetBounds {
    pub left: f64,
    pub top: f64,
    pub right: f64,
    pub bottom: f64,
    pub win_x: f64,
    pub win_y: f64,
    pub width: f64,
    pub height: f64,
}

/// Monitor and window geometry in logical (CSS) pixels, used by the frontend
/// for wandering and edge detection.
pub fn pet_bounds(app: &AppHandle) -> Option<PetBounds> {
    let pet = app.get_webview_window(PET_LABEL)?;
    let position = pet.outer_position().ok()?;
    let size = pet.outer_size().ok()?;
    let scale = pet.scale_factor().ok()?;
    let monitor = pet
        .current_monitor()
        .ok()
        .flatten()
        .or_else(|| pet.primary_monitor().ok().flatten())?;
    let work = monitor.work_area();
    let mon_pos = work.position;
    let mon_size = work.size;
    Some(PetBounds {
        left: mon_pos.x as f64 / scale,
        top: mon_pos.y as f64 / scale,
        right: (mon_pos.x + mon_size.width as i32) as f64 / scale,
        bottom: (mon_pos.y + mon_size.height as i32) as f64 / scale,
        win_x: position.x as f64 / scale,
        win_y: position.y as f64 / scale,
        width: size.width as f64 / scale,
        height: size.height as f64 / scale,
    })
}

/// Keep the pet above the Dock / taskbar and inside the active monitor's work
/// area. Called after restoring a saved position, a drag, and a scale change.
pub fn clamp_pet_to_work_area(pet: &WebviewWindow) {
    let (Ok(position), Ok(size), Ok(scale)) =
        (pet.outer_position(), pet.outer_size(), pet.scale_factor())
    else {
        return;
    };
    let monitor = pet
        .current_monitor()
        .ok()
        .flatten()
        .or_else(|| pet.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else {
        return;
    };
    let work = monitor.work_area();
    let margin = (8.0 * scale) as i32;
    let left = work.position.x + margin;
    let top = work.position.y + margin;
    let right = work.position.x + work.size.width as i32 - size.width as i32 - margin;
    let bottom = work.position.y + work.size.height as i32 - size.height as i32 - margin;
    let x = position.x.clamp(left, right.max(left));
    let y = position.y.clamp(top, bottom.max(top));
    if x != position.x || y != position.y {
        let _ = pet.set_position(PhysicalPosition::new(x, y));
    }
}

pub fn recenter(app: &AppHandle) {
    let Some(pet) = app.get_webview_window(PET_LABEL) else {
        return;
    };
    let height = panel_height(app.state::<AppState>().settings_snapshot().pet_scale);
    if let Ok(position) = default_pet_position(&pet, height) {
        let _ = pet.set_position(position);
        clamp_pet_to_work_area(&pet);
        save_logical_position(app, position.x, position.y);
    }
    if is_board_open(app) {
        if let Some(board) = app.get_webview_window(BOARD_LABEL) {
            let _ = position_board(app, &board);
        }
    }
}

pub fn set_pet_scale(app: &AppHandle, scale: f64) -> Settings {
    let target = clamp_scale(scale);
    let current = app.state::<AppState>().settings_snapshot();
    if (target - current.pet_scale).abs() < 0.001 {
        return current;
    }

    let old_height = panel_height(current.pet_scale);
    let new_height = panel_height(target);
    let mut saved_x = current.x;
    let mut saved_y = current.y;

    if let Some(pet) = app.get_webview_window(PET_LABEL) {
        if let (Ok(position), Ok(scale_factor)) = (pet.outer_position(), pet.scale_factor()) {
            // Anchor the bottom edge (her feet) so growing / shrinking does not
            // make the pet jump up or down the screen.
            let x = position.x as f64 / scale_factor;
            let bottom = position.y as f64 / scale_factor + old_height;
            saved_x = Some(x);
            saved_y = Some(bottom - new_height);
            let _ = pet.set_size(LogicalSize::new(PET_WIDTH, new_height));
            let _ = pet.set_position(LogicalPosition::new(x, bottom - new_height));
            clamp_pet_to_work_area(&pet);
        } else {
            let _ = pet.set_size(LogicalSize::new(PET_WIDTH, new_height));
        }
    }

    mutate_settings(app, |settings| {
        settings.pet_scale = target;
        settings.x = saved_x;
        settings.y = saved_y;
    });
    if is_board_open(app) {
        if let Some(board) = app.get_webview_window(BOARD_LABEL) {
            let _ = position_board(app, &board);
        }
    }
    app.state::<AppState>().settings_snapshot()
}

pub fn save_position_from_window(app: &AppHandle, pet: &WebviewWindow) {
    if let (Ok(pos), Ok(scale)) = (pet.outer_position(), pet.scale_factor()) {
        let x = pos.x as f64 / scale;
        let y = pos.y as f64 / scale;
        let state = app.state::<AppState>();
        let mut settings = state.settings.lock().unwrap_or_else(|e| e.into_inner());
        settings.x = Some(x);
        settings.y = Some(y);
        drop(settings);
        save_settings(app);
    }
}

pub fn save_logical_position(app: &AppHandle, x: f64, y: f64) {
    let state = app.state::<AppState>();
    {
        let mut settings = state.settings.lock().unwrap_or_else(|e| e.into_inner());
        settings.x = Some(x);
        settings.y = Some(y);
    }
    save_settings(app);
}

// MARK: - Monitor loop

fn start_monitor(app: AppHandle) {
    thread::spawn(move || loop {
        let paused = app
            .state::<AppState>()
            .settings
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .paused;

        if !paused {
            let view = {
                let state = app.state::<AppState>();
                let mut monitor = state.monitor.lock().unwrap_or_else(|e| e.into_inner());
                monitor.refresh_now(whalegirl_core::now_ms())
            };
            {
                let state = app.state::<AppState>();
                *state.fleet.lock().unwrap_or_else(|e| e.into_inner()) = Some(view.clone());
            }
            let _ = app.emit("fleet", &view);
            if let Some(tray) = app.tray_by_id("main") {
                let _ = tray.set_tooltip(Some(format!(
                    "鲸鱼娘 · {} · {}",
                    view.mood_text, view.headline
                )));
            }
        }
        thread::sleep(Duration::from_millis(1_500));
    });
}

// MARK: - Click-through

fn start_hit_test(app: AppHandle) {
    thread::spawn(move || loop {
        let state = app.state::<AppState>();
        let visible = state.visible.load(Ordering::Relaxed);
        let dragging = state.dragging.load(Ordering::Relaxed);
        if let Some(pet) = app.get_webview_window(PET_LABEL) {
            let target_ignore = if !visible {
                true
            } else if dragging {
                false
            } else {
                let rect = *state.hit_rect.lock().unwrap_or_else(|e| e.into_inner());
                match rect {
                    Some(rect) => !platform::cursor_in_window(&pet, rect),
                    None => true,
                }
            };
            if state.last_ignore.swap(target_ignore, Ordering::Relaxed) != target_ignore {
                let _ = pet.set_ignore_cursor_events(target_ignore);
            }
        }
        thread::sleep(Duration::from_millis(70));
    });
}

// MARK: - DSH plugin state file

pub fn write_pet_state(app: &AppHandle) {
    let state = app.state::<AppState>();
    let visible = state.visible.load(Ordering::Relaxed);
    let payload = serde_json::json!({
        "visible": visible,
        "pid": std::process::id(),
        "updatedAt": chrono::Local::now().timestamp_millis() as f64 / 1000.0,
        "platform": std::env::consts::OS,
    });
    let path = state.paths.dsh_pet_state();
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(data) = serde_json::to_vec_pretty(&payload) {
        let _ = fs::write(path, data);
    }
}

// MARK: - Deep links / control actions

pub fn handle_url(app: &AppHandle, raw: &str) {
    let rest = raw
        .strip_prefix("bluefish://")
        .or_else(|| raw.strip_prefix("whalegirl://"));
    let Some(rest) = rest else {
        return;
    };
    let mut pieces = rest.trim_end_matches('/').splitn(2, ['/', '?']);
    let host = pieces.next().unwrap_or("").to_lowercase();
    let tail = pieces.next().unwrap_or("");

    match host.as_str() {
        "toggle" => toggle_pet(app),
        "show" => show_pet(app),
        "hide" => hide_pet(app),
        "quit" => app.exit(0),
        "recenter" => recenter(app),
        "board" => toggle_board(app, Some(true)),
        "size" => {
            if let Ok(value) = tail.trim_matches('/').parse::<f64>() {
                let scale = if value > 2.0 { value / 100.0 } else { value };
                set_pet_scale(app, scale);
            }
        }
        "check-update" => {
            let _ = app.emit("update:check", ());
        }
        "update" => {
            let _ = app.emit("update:perform", ());
        }
        _ => {}
    }
}

pub fn handle_args(app: &AppHandle, args: &[String]) {
    if let Some(url) = args
        .iter()
        .find(|a| a.starts_with("bluefish://") || a.starts_with("whalegirl://"))
    {
        handle_url(app, url);
    }
}

// MARK: - UI state

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UiState {
    pub pet_visible: bool,
    pub board_open: bool,
    pub platform: String,
}

impl UiState {
    pub fn snapshot(app: &AppHandle) -> Self {
        let state = app.state::<AppState>();
        Self {
            pet_visible: state.visible.load(Ordering::Relaxed),
            board_open: state.board_open.load(Ordering::Relaxed),
            platform: std::env::consts::OS.to_string(),
        }
    }
}

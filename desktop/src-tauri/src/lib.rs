#![allow(unexpected_cfgs)]

mod control;
mod diagnostics;
mod menu;
mod platform;
mod state;

use std::sync::atomic::Ordering;

use tauri::{AppHandle, Emitter, Manager, PhysicalPosition};

use platform::HitRect;
use state::{AppState, Settings, UiState};

#[tauri::command]
fn get_settings(app: AppHandle) -> Settings {
    app.state::<AppState>().settings_snapshot()
}

#[tauri::command]
fn get_fleet(app: AppHandle) -> Option<whalegirl_core::FleetView> {
    app.state::<AppState>()
        .fleet
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
}

#[tauri::command]
fn refresh_fleet(app: AppHandle) -> Option<whalegirl_core::FleetView> {
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
    Some(view)
}

#[tauri::command]
fn get_ui_state(app: AppHandle) -> UiState {
    UiState::snapshot(&app)
}

#[tauri::command]
fn toggle_board(app: AppHandle, open: Option<bool>) {
    crate::diagnostics::write(format!("command: toggle_board open={open:?}"));
    state::toggle_board(&app, open);
}

#[tauri::command]
fn show_pet_menu(app: AppHandle, window: tauri::Window) -> Result<(), String> {
    menu::show_pet_menu(&app, &window).map_err(|e| e.to_string())
}

#[tauri::command]
fn report_hit_rect(app: AppHandle, rect: Option<HitRect>) {
    let state = app.state::<AppState>();
    *state.hit_rect.lock().unwrap_or_else(|e| e.into_inner()) = rect;
}

#[tauri::command]
fn set_dragging(app: AppHandle, dragging: bool) {
    app.state::<AppState>()
        .dragging
        .store(dragging, Ordering::Relaxed);
}

#[tauri::command]
fn pet_drag_by(app: AppHandle, dx: f64, dy: f64) {
    let Some(pet) = app.get_webview_window(state::PET_LABEL) else {
        return;
    };
    let (Ok(position), Ok(scale)) = (pet.outer_position(), pet.scale_factor()) else {
        return;
    };
    let next = PhysicalPosition::new(
        position.x + (dx * scale).round() as i32,
        position.y + (dy * scale).round() as i32,
    );
    let _ = pet.set_position(next);
    // Keep her out from under the Dock / taskbar even mid-drag; otherwise she
    // is partly covered during the drop and the window jumps when clamped on
    // release.
    state::clamp_pet_to_work_area(&pet);
}

#[tauri::command]
fn pet_drag_end(app: AppHandle) {
    app.state::<AppState>()
        .dragging
        .store(false, Ordering::Relaxed);
    if let Some(pet) = app.get_webview_window(state::PET_LABEL) {
        state::clamp_pet_to_work_area(&pet);
        state::save_position_from_window(&app, &pet);
    }
    if state::is_board_open(&app) {
        if let Some(board) = app.get_webview_window(state::BOARD_LABEL) {
            let _ = state::position_board(&app, &board);
        }
    }
}

#[tauri::command]
fn get_pet_bounds(app: AppHandle) -> Option<state::PetBounds> {
    state::pet_bounds(&app)
}

#[tauri::command]
fn pet_set_scale(app: AppHandle, scale: f64) -> Settings {
    state::set_pet_scale(&app, scale)
}

#[tauri::command]
fn set_toggle(app: AppHandle, key: String, value: bool) {
    match key.as_str() {
        "paused" => {
            app.state::<AppState>()
                .monitor
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .set_paused(value);
            state::mutate_settings(&app, |settings| settings.paused = value);
            let _ = app.emit("monitor:paused", value);
        }
        "sounds" => state::mutate_settings(&app, |settings| settings.sounds = value),
        "wander" => state::mutate_settings(&app, |settings| settings.wander = value),
        "dropTumble" => state::mutate_settings(&app, |settings| settings.drop_tumble = value),
        "bubbleCollapsed" => {
            state::mutate_settings(&app, |settings| settings.bubble_collapsed = value)
        }
        "opencodeQuotas" => {
            state::mutate_settings(&app, |settings| settings.opencode_fetch_quotas = value)
        }
        _ => {}
    }
}

#[tauri::command]
fn set_board_channel(app: AppHandle, channel: Option<String>) {
    state::mutate_settings(&app, |settings| settings.board_channel = channel);
}

#[tauri::command]
fn set_bubble_collapsed(app: AppHandle, value: bool) {
    state::mutate_settings(&app, |settings| settings.bubble_collapsed = value);
}

#[tauri::command]
fn save_pet_position(app: AppHandle, x: f64, y: f64) {
    state::save_logical_position(&app, x, y);
}

#[tauri::command]
fn recenter(app: AppHandle) {
    state::recenter(&app);
}

#[tauri::command]
fn open_path(path: String) -> Result<(), String> {
    platform::open_path(&path)
}

#[tauri::command]
fn reveal_path(app: AppHandle, path: Option<String>) -> Result<(), String> {
    let target = path.or_else(|| {
        app.state::<AppState>()
            .fleet
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .and_then(|fleet| fleet.reveal_path.clone())
    });
    match target {
        Some(path) => platform::open_path(&path),
        None => Err("还没有可打开的目录".to_string()),
    }
}

#[tauri::command]
fn copy_text(text: String) -> Result<(), String> {
    platform::copy_text(&text)
}

#[tauri::command]
fn open_session(app: AppHandle, uid: String) -> Result<String, String> {
    let session = {
        let state = app.state::<AppState>();
        let fleet = state.fleet.lock().unwrap_or_else(|e| e.into_inner());
        fleet.as_ref().and_then(|fleet| {
            fleet
                .sessions
                .iter()
                .find(|session| session.uid == uid)
                .cloned()
        })
    };
    let Some(session) = session else {
        return Err("找不到这个会话，等下一次刷新再试".to_string());
    };
    let title = session.display_title.clone();
    let _ = platform::copy_text(&title);
    if session.provider_id == "dsh" {
        match platform::activate_dsh() {
            Ok(()) => Ok(format!(
                "已复制「{title}」，并切到 DSH。精确会话跳转将在后续版本接入。"
            )),
            Err(error) => Ok(format!("已复制「{title}」（{error}）")),
        }
    } else {
        Ok(format!(
            "已复制「{title}」。{} 暂未提供会话跳转接口。",
            session.provider_name
        ))
    }
}

#[tauri::command]
fn check_updates() -> String {
    "跨平台自动更新还在接签名与发布通道，先手动下载新版吧".to_string()
}

#[tauri::command]
fn quit(app: AppHandle) {
    app.exit(0);
}

/// Write a startup marker and install a panic hook before Tauri is created.
/// Safe to call from `main` even on the release Windows subsystem.
pub fn install_diagnostics() {
    diagnostics::install();
}

pub fn run() {
    let safe_mode =
        std::env::args().any(|arg| arg == "--safe") || std::env::var("WHALEGIRL_SAFE_MODE").is_ok();
    diagnostics::write(format!("run: building app (safe_mode={safe_mode})"));
    let result = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            state::show_pet(app);
            state::handle_args(app, &argv);
        }))
        .plugin(tauri_plugin_deep_link::init())
        .setup(move |app| {
            state::setup(app, safe_mode)?;
            let handle = app.handle().clone();
            state::handle_args(&handle, &std::env::args().collect::<Vec<_>>());
            Ok(())
        })
        .on_menu_event(|app, event| {
            menu::handle_menu_event(app, event);
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
                if window.label() == state::BOARD_LABEL {
                    state::set_board_open(window.app_handle(), false);
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            get_settings,
            get_fleet,
            refresh_fleet,
            get_ui_state,
            toggle_board,
            show_pet_menu,
            report_hit_rect,
            set_dragging,
            pet_drag_by,
            pet_drag_end,
            get_pet_bounds,
            pet_set_scale,
            set_toggle,
            set_board_channel,
            set_bubble_collapsed,
            save_pet_position,
            recenter,
            open_path,
            reveal_path,
            copy_text,
            open_session,
            check_updates,
            quit,
        ])
        .run(tauri::generate_context!());
    if let Err(error) = result {
        diagnostics::write(format!("run error: {error:?}"));
    } else {
        diagnostics::write("run: exited normally");
    }
}

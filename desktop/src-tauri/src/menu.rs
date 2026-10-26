//! Native tray menu and the pet's right-click menu. Both are built from the
//! same settings snapshot so check marks never disagree.

use tauri::menu::{
    CheckMenuItem, ContextMenu, Menu, MenuBuilder, MenuEvent, MenuItem, SubmenuBuilder,
};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager, Wry};

use crate::state::{self, AppState};

const TRAY_ID: &str = "main";

fn check(
    app: &AppHandle,
    id: &str,
    label: &str,
    checked: bool,
) -> tauri::Result<CheckMenuItem<Wry>> {
    CheckMenuItem::with_id(app, id, label, true, checked, None::<&str>)
}

pub fn build_menu(app: &AppHandle) -> tauri::Result<Menu<Wry>> {
    let settings = app.state::<AppState>().settings_snapshot();
    let board_open = state::is_board_open(app);

    let size_menu = SubmenuBuilder::new(app, "宠物大小")
        .item(&check(
            app,
            "size:tiny",
            "迷你 · 60%",
            (settings.pet_scale - 0.6).abs() < 0.001,
        )?)
        .item(&check(
            app,
            "size:small",
            "小 · 75%",
            (settings.pet_scale - 0.75).abs() < 0.001,
        )?)
        .item(&check(
            app,
            "size:standard",
            "标准 · 100%",
            (settings.pet_scale - 1.0).abs() < 0.001,
        )?)
        .item(&check(
            app,
            "size:large",
            "大 · 120%",
            (settings.pet_scale - 1.2).abs() < 0.001,
        )?)
        .build()?;

    let header = MenuItem::with_id(
        app,
        "header",
        format!(
            "鲸鱼娘 · {}",
            if settings.paused {
                "监控暂停".to_string()
            } else {
                app.state::<AppState>()
                    .fleet
                    .lock()
                    .ok()
                    .and_then(|f| f.as_ref().map(|v| v.mood_text.clone()))
                    .unwrap_or_else(|| "本地代理桌宠".to_string())
            }
        ),
        false,
        None::<&str>,
    )?;

    #[allow(unused_mut)]
    let mut builder = MenuBuilder::new(app)
        .item(&header)
        .separator()
        .item(&MenuItem::with_id(
            app,
            "board",
            if board_open {
                "收起任务面板"
            } else {
                "打开任务面板"
            },
            true,
            Some("CmdOrCtrl+T"),
        )?)
        .item(&check(app, "pause", "暂停监控", settings.paused)?)
        .item(&check(app, "sound", "提示音", settings.sounds)?)
        .item(&check(app, "wander", "空闲时自己散步", settings.wander)?)
        .item(&check(app, "tumble", "放下时摔一跤", settings.drop_tumble)?)
        .item(&size_menu)
        .separator()
        .item(&MenuItem::with_id(
            app,
            "update",
            "检查更新…",
            true,
            None::<&str>,
        )?)
        .item(&MenuItem::with_id(
            app,
            "reset",
            "回到右下角",
            true,
            None::<&str>,
        )?)
        .item(&MenuItem::with_id(
            app,
            "hide",
            if state::is_pet_visible(app) {
                "隐藏桌宠"
            } else {
                "显示桌宠"
            },
            true,
            None::<&str>,
        )?);
    #[cfg(target_os = "macos")]
    {
        builder = builder.separator().item(&MenuItem::with_id(
            app,
            "permission",
            "授权跳转（辅助功能）…",
            true,
            None::<&str>,
        )?);
    }
    builder
        .separator()
        .item(&MenuItem::with_id(
            app,
            "quit",
            "退出鲸鱼娘",
            true,
            Some("CmdOrCtrl+Q"),
        )?)
        .build()
}

pub fn install_tray(app: &AppHandle) -> tauri::Result<()> {
    let menu = build_menu(app)?;
    #[cfg(target_os = "macos")]
    let tray_icon = tauri::image::Image::from_bytes(include_bytes!("../icons/tray-mac.png"))?;
    #[cfg(not(target_os = "macos"))]
    let tray_icon = tauri::image::Image::from_bytes(include_bytes!("../icons/tray-win.png"))?;

    let builder = TrayIconBuilder::with_id(TRAY_ID)
        .menu(&menu)
        .show_menu_on_left_click(true)
        .tooltip("鲸鱼娘 · 本地代理桌宠")
        .icon(tray_icon);
    #[cfg(target_os = "macos")]
    let builder = builder.icon_as_template(true);
    builder.build(app)?;
    Ok(())
}

pub fn rebuild_tray(app: &AppHandle) {
    let Some(tray) = app.tray_by_id(TRAY_ID) else {
        return;
    };
    if let Ok(menu) = build_menu(app) {
        let _ = tray.set_menu(Some(menu));
    }
}

pub fn show_pet_menu(app: &AppHandle, window: &tauri::Window) -> tauri::Result<()> {
    let menu = build_menu(app)?;
    menu.popup(window.clone())
}

pub fn handle_menu_event(app: &AppHandle, event: MenuEvent) {
    let id = event.id().as_ref().to_string();
    match id.as_str() {
        "board" => state::toggle_board(app, None),
        "pause" => toggle_paused(app),
        "sound" => toggle_bool(app, "sounds"),
        "wander" => toggle_bool(app, "wander"),
        "tumble" => toggle_bool(app, "dropTumble"),
        "size:tiny" => {
            state::set_pet_scale(app, 0.6);
        }
        "size:small" => {
            state::set_pet_scale(app, 0.75);
        }
        "size:standard" => {
            state::set_pet_scale(app, 1.0);
        }
        "size:large" => {
            state::set_pet_scale(app, 1.2);
        }
        "reset" => state::recenter(app),
        "hide" => state::toggle_pet(app),
        "update" => {
            let _ = app.emit("update:check", ());
        }
        "permission" => {
            let _ = app.emit("jump:permission", ());
        }
        "quit" => app.exit(0),
        _ => {}
    }
}

fn toggle_paused(app: &AppHandle) {
    let paused = !app.state::<AppState>().settings_snapshot().paused;
    app.state::<AppState>()
        .monitor
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .set_paused(paused);
    state::mutate_settings(app, |settings| {
        settings.paused = paused;
    });
    let _ = app.emit("monitor:paused", paused);
}

fn toggle_bool(app: &AppHandle, key: &str) {
    state::mutate_settings(app, |settings| match key {
        "sounds" => settings.sounds = !settings.sounds,
        "wander" => settings.wander = !settings.wander,
        "dropTumble" => settings.drop_tumble = !settings.drop_tumble,
        "bubbleCollapsed" => settings.bubble_collapsed = !settings.bubble_collapsed,
        _ => {}
    });
}

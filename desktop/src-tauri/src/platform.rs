//! Platform-specific glue: global cursor hit testing, clipboard, opening paths
//! and activating the DSH desktop app.
//!
//! Everything OS-specific in the Tauri shell lives here so the rest of the app
//! is a normal cross-platform Rust program.

use std::fs;
use std::process::Command;

use serde::{Deserialize, Serialize};
use tauri::WebviewWindow;

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
pub struct HitRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl HitRect {
    pub fn contains(self, x: f64, y: f64) -> bool {
        x >= self.x && x <= self.x + self.w && y >= self.y && y <= self.y + self.h
    }
}

/// Is the global cursor inside `rect` (window-local CSS pixels)?
pub fn cursor_in_window(window: &WebviewWindow, rect: HitRect) -> bool {
    #[cfg(target_os = "macos")]
    {
        use std::sync::mpsc;
        use std::time::Duration;
        let (tx, rx) = mpsc::channel();
        let clone = window.clone();
        let sent = window.run_on_main_thread(move || {
            let inside = clone
                .ns_window()
                .ok()
                .map(|ptr| mac::hit(ptr, rect))
                .unwrap_or(false);
            let _ = tx.send(inside);
        });
        if sent.is_err() {
            return false;
        }
        return rx.recv_timeout(Duration::from_millis(150)).unwrap_or(false);
    }

    #[cfg(target_os = "windows")]
    {
        return win::hit(window, rect);
    }

    #[allow(unreachable_code)]
    false
}

#[cfg(target_os = "macos")]
#[allow(unexpected_cfgs)]
mod mac {
    use std::ffi::c_void;

    use objc::runtime::Object;
    use objc::{class, msg_send, sel, sel_impl};

    use super::HitRect;

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CGPoint {
        x: f64,
        y: f64,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CGSize {
        width: f64,
        height: f64,
    }

    #[repr(C)]
    #[derive(Clone, Copy)]
    struct CGRect {
        origin: CGPoint,
        size: CGSize,
    }

    /// `frame` and `NSEvent.mouseLocation` are both in Cocoa screen points with
    /// a bottom-left origin, so no DPI or multi-monitor conversion is needed.
    /// The reported rect is top-left based CSS pixels, which equal points on
    /// macOS because the webview uses a 1:1 logical coordinate space.
    pub fn hit(ns_window: *mut c_void, rect: HitRect) -> bool {
        if ns_window.is_null() {
            return false;
        }
        unsafe {
            let window = ns_window as *mut Object;
            let frame: CGRect = msg_send![window, frame];
            let mouse: CGPoint = msg_send![class!(NSEvent), mouseLocation];
            let x = mouse.x - frame.origin.x;
            let y = frame.size.height - (mouse.y - frame.origin.y);
            rect.contains(x, y)
        }
    }
}

#[cfg(target_os = "windows")]
mod win {
    use tauri::WebviewWindow;
    use windows::Win32::Foundation::{POINT, RECT};
    use windows::Win32::UI::WindowsAndMessaging::{GetCursorPos, GetWindowRect};

    use super::HitRect;

    pub fn hit(window: &WebviewWindow, rect: HitRect) -> bool {
        let Ok(hwnd) = window.hwnd() else {
            return false;
        };
        let mut point = POINT::default();
        let mut bounds = RECT::default();
        unsafe {
            if GetCursorPos(&mut point).is_err() {
                return false;
            }
            if GetWindowRect(hwnd, &mut bounds).is_err() {
                return false;
            }
        }
        let scale = window.scale_factor().unwrap_or(1.0);
        let x = (point.x - bounds.left) as f64 / scale;
        let y = (point.y - bounds.top) as f64 / scale;
        rect.contains(x, y)
    }
}

/// Let the window follow the user across Spaces and float over full-screen
/// apps. Tauri's `visibleOnAllWorkspaces` covers the first part; the auxiliary
/// bit is what makes the pet stay visible over a full-screen browser.
#[cfg(target_os = "macos")]
pub fn configure_overlay(window: &WebviewWindow) {
    use objc::{msg_send, sel, sel_impl};
    if let Ok(ns_window) = window.ns_window() {
        if ns_window.is_null() {
            return;
        }
        unsafe {
            let object = ns_window as *mut objc::runtime::Object;
            // CanJoinAllSpaces | IgnoresCycle | FullScreenAuxiliary
            let behavior: u64 = (1 << 0) | (1 << 6) | (1 << 8);
            let _: () = msg_send![object, setCollectionBehavior: behavior];
        }
    }
}

/// Copy text through the shared cross-platform clipboard backend. Avoids the
/// Windows `clip` OEM-code-page (which garbles Chinese titles).
pub fn copy_text(text: &str) -> Result<(), String> {
    let mut clipboard = arboard::Clipboard::new().map_err(|e| format!("clipboard: {e}"))?;
    clipboard
        .set_text(text.to_string())
        .map_err(|e| format!("clipboard: {e}"))
}

/// Open a directory / file in the platform file manager.
pub fn open_path(path: &str) -> Result<(), String> {
    if !fs::exists(path).unwrap_or(false) {
        return Err(format!("路径不存在：{path}"));
    }
    #[cfg(target_os = "macos")]
    let status = Command::new("open")
        .arg(path)
        .status()
        .map_err(|e| e.to_string())?;

    #[cfg(target_os = "windows")]
    let status = Command::new("explorer")
        .arg(path)
        .status()
        .map_err(|e| e.to_string())?;

    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    return Err("当前平台暂不支持打开目录".to_string());

    #[cfg(any(target_os = "macos", target_os = "windows"))]
    if status.success() {
        Ok(())
    } else {
        Err("打开目录失败".to_string())
    }
}

/// Bring the DSH desktop app forward. Session-level accessibility jumping is a
/// later milestone; this is the graceful fallback both platforms share.
pub fn activate_dsh() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let status = Command::new("open")
            .args(["-b", "com.deepseek.dsh"])
            .status()
            .map_err(|e| e.to_string())?;
        if status.success() {
            Ok(())
        } else {
            Err("没有找到 DSH 桌面版".to_string())
        }
    }
    #[cfg(target_os = "windows")]
    {
        Err("Windows 上暂未接入 DSH 会话跳转".to_string())
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        Err("当前平台暂不支持".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rect_hit() {
        let rect = HitRect {
            x: 10.0,
            y: 10.0,
            w: 100.0,
            h: 50.0,
        };
        assert!(rect.contains(10.0, 10.0));
        assert!(rect.contains(110.0, 60.0));
        assert!(!rect.contains(9.9, 10.0));
        assert!(!rect.contains(10.0, 60.1));
    }
}

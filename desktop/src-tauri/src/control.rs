//! Tiny localhost control server, compatible with the DSH plugin's existing
//! `127.0.0.1:47113` protocol.

use std::thread;

use tauri::{AppHandle, Emitter, Manager};
use tiny_http::{Header, Method, Response, Server, StatusCode};

use crate::state::{self, AppState};

pub const PORT: u16 = 47113;

pub fn start(app: AppHandle) {
    thread::spawn(move || {
        let address = format!("127.0.0.1:{PORT}");
        let server = match Server::http(&address) {
            Ok(server) => server,
            Err(error) => {
                eprintln!("[wg] control server failed on {address}: {error}");
                return;
            }
        };
        eprintln!("[wg] control server listening on {address}");
        for request in server.incoming_requests() {
            let method = request.method().clone();
            let path = request.url().split('?').next().unwrap_or("/").to_string();
            if method == Method::Options {
                let _ = request.respond(with_cors(Response::empty(StatusCode(204))));
                continue;
            }
            let (status, body) = handle(&app, &method, &path);
            let response = Response::from_string(body)
                .with_status_code(StatusCode(status))
                .with_header(header("Content-Type", "application/json; charset=utf-8"));
            let _ = request.respond(with_cors(response));
        }
    });
}

fn handle(app: &AppHandle, method: &Method, path: &str) -> (u16, String) {
    match (method, path) {
        (&Method::Get, "/status") => (200, status_body(app, true)),
        (&Method::Get, "/debug") => (200, debug_body(app)),
        (&Method::Post, "/toggle") => {
            state::toggle_pet(app);
            (200, status_body(app, true))
        }
        (&Method::Post, "/show") => {
            state::show_pet(app);
            (200, status_body(app, true))
        }
        (&Method::Post, "/hide") => {
            state::hide_pet(app);
            (200, status_body(app, true))
        }
        (&Method::Post, "/recenter") => {
            state::recenter(app);
            (200, status_body(app, true))
        }
        (&Method::Post, "/board") => {
            state::toggle_board(app, Some(true));
            (200, status_body(app, true))
        }
        (&Method::Post, "/quit") => {
            app.exit(0);
            (200, "{\"ok\":true}".to_string())
        }
        (&Method::Get, path) if path.starts_with("/scale/") => {
            let raw = path.trim_start_matches("/scale/");
            match raw.parse::<f64>() {
                Ok(value) => {
                    let scale = if value > 2.0 { value / 100.0 } else { value };
                    crate::state::set_pet_scale(app, scale);
                    (200, status_body(app, true))
                }
                Err(_) => (400, "{\"ok\":false,\"error\":\"bad scale\"}".to_string()),
            }
        }
        (&Method::Post, "/axdump") => {
            let _ = app.emit("jump:axdump", ());
            (200, "{\"ok\":true}".to_string())
        }
        _ => (404, "{\"ok\":false}".to_string()),
    }
}

fn debug_body(app: &AppHandle) -> String {
    let state = app.state::<AppState>();
    let settings = state.settings_snapshot();
    let pet = app.get_webview_window("pet");
    let board = app.get_webview_window("board");
    let geometry = |window: Option<tauri::WebviewWindow>| {
        window
            .and_then(|window| {
                let position = window.outer_position().ok()?;
                let size = window.outer_size().ok()?;
                let scale = window.scale_factor().ok()?;
                Some(serde_json::json!({
                    "x": position.x,
                    "y": position.y,
                    "width": size.width,
                    "height": size.height,
                    "scale": scale,
                    "visible": window.is_visible().unwrap_or(false),
                }))
            })
            .unwrap_or(serde_json::Value::Null)
    };
    let monitor = app
        .get_webview_window("pet")
        .and_then(|pet| pet.current_monitor().ok().flatten())
        .map(|m| {
            serde_json::json!({
                "x": m.position().x,
                "y": m.position().y,
                "width": m.size().width,
                "height": m.size().height,
                "scale": m.scale_factor(),
            })
        });
    serde_json::json!({
        "monitor": monitor,
        "pet": geometry(pet),
        "board": geometry(board),
        "settings": settings,
        "hitRect": *state.hit_rect.lock().unwrap_or_else(|e| e.into_inner()),
        "dragging": state.dragging.load(std::sync::atomic::Ordering::Relaxed),
    })
    .to_string()
}

fn status_body(app: &AppHandle, running: bool) -> String {
    let state = app.state::<AppState>();
    let visible = state.visible.load(std::sync::atomic::Ordering::Relaxed);
    let board = state.board_open.load(std::sync::atomic::Ordering::Relaxed);
    serde_json::json!({
        "ok": true,
        "running": running,
        "visible": visible,
        "board": board,
        "platform": std::env::consts::OS,
    })
    .to_string()
}

fn header(name: &str, value: &str) -> Header {
    Header::from_bytes(name.as_bytes(), value.as_bytes()).expect("static header")
}

fn with_cors<R: std::io::Read>(mut response: Response<R>) -> Response<R> {
    response = response
        .with_header(header("Access-Control-Allow-Origin", "*"))
        .with_header(header("Access-Control-Allow-Methods", "GET, POST, OPTIONS"))
        .with_header(header("Access-Control-Allow-Headers", "Content-Type"));
    response
}

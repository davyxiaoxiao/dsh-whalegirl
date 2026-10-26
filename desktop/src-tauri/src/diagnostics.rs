//! Startup / panic diagnostics.
//!
//! Windows release builds have no console (`windows_subsystem = "windows"`), so
//! a panic otherwise looks like an immediate exit. Every launch writes a line
//! to a log file; the panic hook appends the message and a backtrace. If the
//! file is missing entirely, the failure happened before Rust's `main` (for
//! example a missing WebView2 runtime or VC++ loader failure).

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::PathBuf;
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

static LOG_PATH: OnceLock<PathBuf> = OnceLock::new();

pub fn path() -> &'static PathBuf {
    LOG_PATH.get_or_init(|| {
        #[cfg(target_os = "windows")]
        {
            if let Ok(local) = std::env::var("LOCALAPPDATA") {
                return PathBuf::from(local)
                    .join("com.daiwei.whalegirl")
                    .join("logs")
                    .join("whalegirl.log");
            }
        }
        let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
        PathBuf::from(home)
            .join("Library")
            .join("Logs")
            .join("WhaleGirl")
            .join("whalegirl.log")
    })
}

pub fn write(message: impl AsRef<str>) {
    let path = path();
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(path) {
        let millis = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let _ = writeln!(
            file,
            "[{millis}] [{}] {}",
            std::process::id(),
            message.as_ref()
        );
    }
}

pub fn install() {
    write(format!(
        "=== process start version={} os={} arch={} args={:?}",
        env!("CARGO_PKG_VERSION"),
        std::env::consts::OS,
        std::env::consts::ARCH,
        std::env::args().collect::<Vec<_>>()
    ));
    let default_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        write(format!(
            "PANIC: {info}\n{}",
            std::backtrace::Backtrace::force_capture()
        ));
        default_hook(info);
    }));
}

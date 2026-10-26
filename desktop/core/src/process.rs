//! Cross-platform process detection.
//!
//! Agents can be quit while their logs stay fresh; the pet uses this to flip to
//! "disconnected" immediately. The list is cached for a few seconds because
//! enumerating processes is comparatively expensive.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use sysinfo::System;

const CACHE_TTL: Duration = Duration::from_secs(5);

static CACHE: Mutex<Option<(Instant, Vec<String>)>> = Mutex::new(None);

/// Lowercased process names plus executable paths.
fn process_signatures() -> Vec<String> {
    let mut guard = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((at, list)) = guard.as_ref() {
        if at.elapsed() < CACHE_TTL {
            return list.clone();
        }
    }

    let system = System::new_all();
    let mut list = Vec::new();
    for process in system.processes().values() {
        let mut signature = process.name().to_string_lossy().to_lowercase();
        if let Some(exe) = process.exe() {
            signature.push('|');
            signature.push_str(&exe.to_string_lossy().to_lowercase());
        }
        list.push(signature);
    }
    *guard = Some((Instant::now(), list.clone()));
    list
}

/// True when any process signature contains one of the markers.
pub fn is_running(markers: &[&str]) -> bool {
    if markers.is_empty() {
        return false;
    }
    let signatures = process_signatures();
    signatures.iter().any(|signature| {
        markers
            .iter()
            .any(|marker| signature.contains(&marker.to_lowercase()))
    })
}

pub const DSH_DESKTOP_MARKERS: &[&str] = &["deepseek harness", "com.deepseek.dsh"];
pub const CODEX_DESKTOP_MARKERS: &[&str] = &["/codex.app/", "\\codex.exe"];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_marker_is_false() {
        assert!(!is_running(&["definitely-not-a-real-process-name-xyz"]));
    }
}

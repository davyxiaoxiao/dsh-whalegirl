//! WhaleGirl core: provider-neutral monitoring for DSH, Codex and OpenCode.
//!
//! This crate has no UI or windowing dependency. The Tauri shell and the
//! `wg-dump` diagnostic binary both consume it, so the same parsing code runs
//! on macOS and Windows.

pub mod format;
pub mod jsonutil;
pub mod logtail;
pub mod models;
pub mod monitor;
pub mod paths;
pub mod process;
pub mod providers;
pub mod usage;

use chrono::{Local, TimeZone};

pub use models::FleetView;

/// Current wall clock as epoch milliseconds (the wire format used everywhere).
pub fn now_ms() -> i64 {
    Local::now().timestamp_millis()
}

/// Local midnight for the day containing `now`, as epoch milliseconds.
pub fn day_start_ms(now: i64) -> i64 {
    let Some(dt) = Local.timestamp_millis_opt(now).single() else {
        return now;
    };
    dt.date_naive()
        .and_hms_opt(0, 0, 0)
        .and_then(|naive| Local.from_local_datetime(&naive).single())
        .map(|midnight| midnight.timestamp_millis())
        .unwrap_or(now)
}

/// UTC week start (Monday 00:00) for OpenCode quota windows.
pub fn utc_week_start_ms(now: i64) -> i64 {
    use chrono::{Datelike, Utc};
    let Some(dt) = Utc.timestamp_millis_opt(now).single() else {
        return now;
    };
    let weekday = dt.weekday().num_days_from_monday() as i64;
    let midnight = dt
        .date_naive()
        .and_hms_opt(0, 0, 0)
        .and_then(|naive| Utc.from_local_datetime(&naive).single())
        .map(|d| d.timestamp_millis())
        .unwrap_or(now);
    midnight - weekday * 86_400_000
}

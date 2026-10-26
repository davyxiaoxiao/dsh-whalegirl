//! Shared display formatting (ported from the Swift `Theme.swift` helpers).

use chrono::{Local, TimeZone, Timelike};
use std::path::Path;

pub fn short_duration(ms: i64) -> String {
    if ms < 0 {
        return "0s".to_string();
    }
    let s = ((ms as f64) / 1000.0).round() as i64;
    if s < 60 {
        return format!("{s}s");
    }
    let m = s / 60;
    if m < 60 {
        return format!("{m}m{:02}s", s % 60);
    }
    let h = m / 60;
    format!("{h}h{:02}m", m % 60)
}

pub fn compact_tokens(n: i64) -> String {
    if n >= 1_000_000 {
        return format!("{:.1}M", n as f64 / 1_000_000.0);
    }
    if n >= 1_000 {
        return format!("{:.1}k", n as f64 / 1_000.0);
    }
    format!("{n}")
}

pub fn tail(s: &str, count: usize) -> String {
    let chars: Vec<char> = s.chars().collect();
    if chars.len() <= count {
        return s.to_string();
    }
    let mut out: String = chars.into_iter().take(count.saturating_sub(1)).collect();
    out.push('…');
    out
}

pub fn base_name(path: &str) -> String {
    if path.is_empty() {
        return String::new();
    }
    Path::new(path)
        .file_name()
        .map(|name| name.to_string_lossy().to_string())
        .filter(|name| !name.is_empty())
        .unwrap_or_else(|| path.to_string())
}

pub fn shorten_path(path: &str, home: &Path) -> String {
    let home_str = home.to_string_lossy();
    if let Some(rest) = path.strip_prefix(home_str.as_ref()) {
        return format!("~{rest}");
    }
    path.to_string()
}

/// "HH:mm:ss" for today, "MM-dd HH:mm" otherwise.
pub fn clock_string(ms: Option<i64>) -> String {
    let Some(ms) = ms else {
        return "—".to_string();
    };
    let Some(dt) = Local.timestamp_millis_opt(ms).single() else {
        return "—".to_string();
    };
    let now = Local::now();
    if dt.date_naive() == now.date_naive() {
        format!("{:02}:{:02}:{:02}", dt.hour(), dt.minute(), dt.second())
    } else {
        format!(
            "{:02}-{:02} {:02}:{:02}",
            dt.month(),
            dt.day(),
            dt.hour(),
            dt.minute()
        )
    }
}

use chrono::Datelike;

pub fn relative_age(at_ms: i64, now_ms: i64) -> String {
    let delta = (now_ms - at_ms).max(0);
    if delta < 60_000 {
        return "刚刚".to_string();
    }
    if delta < 3_600_000 {
        return format!("{} 分钟前", delta / 60_000);
    }
    if delta < 86_400_000 {
        return format!("{} 小时前", delta / 3_600_000);
    }
    format!("{} 天前", delta / 86_400_000)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duration_buckets() {
        assert_eq!(short_duration(0), "0s");
        assert_eq!(short_duration(59_400), "59s");
        assert_eq!(short_duration(61_000), "1m01s");
        assert_eq!(short_duration(3_660_000), "1h01m");
    }

    #[test]
    fn tokens_compact() {
        assert_eq!(compact_tokens(999), "999");
        assert_eq!(compact_tokens(1_500), "1.5k");
        assert_eq!(compact_tokens(83_900_000), "83.9M");
    }

    #[test]
    fn tail_is_char_safe() {
        assert_eq!(tail("abcdef", 4), "abc…");
        assert_eq!(tail("鲸鱼娘你好", 3), "鲸鱼…");
    }
}

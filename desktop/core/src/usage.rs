//! Cost / quota readers. DSH keeps a local ledger written by `dsh-cost-meter`;
//! the reader normalizes it and caches for 20 s so the 1.5 s monitor poll stays
//! cheap.

use std::path::{Path, PathBuf};

use chrono::{DateTime, Local, TimeZone};
use serde_json::Value;

use crate::jsonutil::{as_f64, as_i64, as_str};
use crate::models::{UsageQuota, UsageTotals};

#[derive(Clone, Debug)]
pub struct UsageReading {
    pub today: UsageTotals,
    pub quotas: Vec<UsageQuota>,
    pub source_label: String,
}

impl UsageReading {
    pub fn is_empty(&self) -> bool {
        self.today.is_empty() && self.quotas.is_empty()
    }
}

#[derive(Debug)]
pub struct CostMeterLedgerReader {
    url: PathBuf,
    refresh_ms: i64,
    last_read_at: i64,
    has_loaded: bool,
    cached: Option<UsageReading>,
}

impl CostMeterLedgerReader {
    pub fn new(url: PathBuf, refresh_ms: i64) -> Self {
        Self {
            url,
            refresh_ms,
            last_read_at: i64::MIN / 2,
            has_loaded: false,
            cached: None,
        }
    }

    pub fn at(path: impl AsRef<Path>) -> Self {
        Self::new(path.as_ref().to_path_buf(), 20_000)
    }

    /// Read the ledger, honoring the 20 s refresh window. `now` is epoch ms.
    pub fn read(&mut self, now: i64) -> Option<UsageReading> {
        if self.has_loaded && now - self.last_read_at < self.refresh_ms {
            return self.cached.clone();
        }
        self.has_loaded = true;
        self.last_read_at = now;
        self.cached = self.load(now);
        self.cached.clone()
    }

    fn load(&self, now: i64) -> Option<UsageReading> {
        let data = std::fs::read(&self.url).ok()?;
        let root: Value = serde_json::from_slice(&data).ok()?;

        let mut today = UsageTotals::default();
        let day_key = Local
            .timestamp_millis_opt(now)
            .single()
            .unwrap_or_else(Local::now)
            .format("%Y-%m-%d")
            .to_string();

        if let Some(day) = root.get("days").and_then(|d| d.get(&day_key)) {
            today.cost_cny = as_f64(day.get("costCny"));
            today.calls = as_i64(day.get("calls"));
            let mut tokens = 0i64;
            for key in ["input", "output", "cacheRead", "cacheWrite", "reasoning"] {
                tokens += as_i64(day.get(key)).unwrap_or(0);
            }
            if day.get("input").is_some() || day.get("output").is_some() {
                today.tokens = Some(tokens);
            }
        }

        Some(UsageReading {
            today,
            quotas: parse_plan_quotas(root.get("planSamples")),
            source_label: "dsh-cost-meter".to_string(),
        })
    }
}

/// dsh-cost-meter keeps one sample per quota window:
///   planSamples.go.fiveHour[] = { t, p, lt, lc, r, s }
/// where `p` is the provider-reported percentage and `r` the reset time.
fn parse_plan_quotas(raw: Option<&Value>) -> Vec<UsageQuota> {
    let Some(providers) = raw.and_then(Value::as_object) else {
        return Vec::new();
    };
    let mut keys: Vec<&String> = providers.keys().collect();
    keys.sort_by(|a, b| {
        if a.as_str() == "go" {
            std::cmp::Ordering::Less
        } else if b.as_str() == "go" {
            std::cmp::Ordering::Greater
        } else {
            a.cmp(b)
        }
    });

    let windows = [("fiveHour", "5h"), ("weekly", "周"), ("monthly", "月")];
    for key in keys {
        let Some(windows_obj) = providers.get(key).and_then(Value::as_object) else {
            continue;
        };
        let provider = plan_provider_label(key);
        let mut quotas = Vec::new();
        for (name, label) in windows {
            let Some(samples) = windows_obj.get(name).and_then(Value::as_array) else {
                continue;
            };
            if samples.is_empty() {
                continue;
            }
            let latest = samples
                .iter()
                .rev()
                .find(|s| as_i64(s.get("p")).is_some())
                .or_else(|| samples.last());
            let Some(latest) = latest else {
                continue;
            };
            let percent = as_i64(latest.get("p")).unwrap_or(0);
            let resets_at = as_str(latest.get("r")).and_then(parse_iso_ms);
            let sampled_at = as_f64(latest.get("t")).map(|ms| ms as i64);
            quotas.push(UsageQuota {
                provider: provider.clone(),
                window: label.to_string(),
                percent,
                resets_at,
                sampled_at,
            });
        }
        if !quotas.is_empty() {
            return quotas;
        }
    }
    Vec::new()
}

fn plan_provider_label(key: &str) -> String {
    match key.to_lowercase().as_str() {
        "go" => "Go".to_string(),
        "codex" => "Codex".to_string(),
        "minimax" => "MiniMax".to_string(),
        "volcengine-agent" => "火山".to_string(),
        "tencent-coding" | "tencent-token" => "腾讯".to_string(),
        "baidu-coding" => "百度".to_string(),
        "bailian" => "百炼".to_string(),
        other => {
            let mut chars = other.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
                None => other.to_string(),
            }
        }
    }
}

fn parse_iso_ms(text: &str) -> Option<i64> {
    DateTime::parse_from_rfc3339(text)
        .ok()
        .map(|d| d.timestamp_millis())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_plan_samples_and_day() {
        let now = Local
            .with_ymd_and_hms(2026, 10, 26, 12, 0, 0)
            .single()
            .unwrap()
            .timestamp_millis();
        let day = Local
            .timestamp_millis_opt(now)
            .single()
            .unwrap()
            .format("%Y-%m-%d")
            .to_string();
        let ledger = json!({
            "days": { day: { "costCny": 4.53, "calls": 171, "input": 100, "output": 200, "cacheRead": 300 } },
            "planSamples": {
                "go": {
                    "fiveHour": [{ "t": 1.0, "p": 7, "r": "2026-10-26T15:00:00Z" }],
                    "weekly":  [{ "t": 1.0, "p": 11 }],
                    "monthly": [{ "t": 1.0, "p": 5 }]
                }
            }
        });
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("ledger.json");
        std::fs::write(&path, serde_json::to_vec(&ledger).unwrap()).unwrap();
        let mut reader = CostMeterLedgerReader::at(&path);
        let reading = reader.read(now).unwrap();
        assert_eq!(reading.today.cost_cny, Some(4.53));
        assert_eq!(reading.today.calls, Some(171));
        assert_eq!(reading.today.tokens, Some(600));
        assert_eq!(reading.quotas.len(), 3);
        assert_eq!(reading.quotas[0].label(), "Go 5h 7%");
    }

    #[test]
    fn label_capitalizes_unknown_provider() {
        assert_eq!(plan_provider_label("go"), "Go");
        assert_eq!(plan_provider_label("custom"), "Custom");
    }
}

//! JSON helpers that tolerate the loose, evolving shapes written by agents.

use chrono::DateTime;
use serde_json::Value;

pub fn get<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value.get(key)
}

pub fn as_str(value: Option<&Value>) -> Option<&str> {
    value.and_then(Value::as_str)
}

pub fn as_string(value: Option<&Value>) -> Option<String> {
    as_str(value).map(str::to_string)
}

pub fn as_i64(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(n) => n
            .as_i64()
            .or_else(|| n.as_f64().map(|f| f as i64))
            .or_else(|| n.as_u64().map(|u| u as i64)),
        Value::String(s) => s.trim().parse::<i64>().ok(),
        Value::Bool(b) => Some(if *b { 1 } else { 0 }),
        _ => None,
    }
}

pub fn as_f64(value: Option<&Value>) -> Option<f64> {
    match value? {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse::<f64>().ok(),
        _ => None,
    }
}

pub fn as_bool(value: Option<&Value>) -> Option<bool> {
    value?.as_bool()
}

pub fn as_array(value: Option<&Value>) -> &[Value] {
    value
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

pub fn field<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value.get(key)
}

pub fn str_field(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).map(str::to_string)
}

pub fn i64_field(value: &Value, key: &str) -> Option<i64> {
    as_i64(value.get(key))
}

pub fn f64_field(value: &Value, key: &str) -> Option<f64> {
    as_f64(value.get(key))
}

pub fn bool_field(value: &Value, key: &str) -> Option<bool> {
    value.get(key).and_then(Value::as_bool)
}

pub fn array_field<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value
        .get(key)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

pub fn object_field<'a>(value: &'a Value, key: &str) -> Option<&'a serde_json::Map<String, Value>> {
    value.get(key).and_then(Value::as_object)
}

/// Epoch milliseconds from `1234`, `"1234"` or `1234.0`.
pub fn date_from_ms(value: Option<&Value>) -> Option<i64> {
    as_f64(value).map(|n| n as i64)
}

/// Epoch seconds from a numeric value.
pub fn date_from_epoch(value: Option<&Value>) -> Option<i64> {
    as_f64(value).map(|n| (n * 1000.0) as i64)
}

/// RFC 3339 (with or without fractional seconds).
pub fn date_from_iso(value: Option<&Value>) -> Option<i64> {
    let text = value?.as_str()?;
    DateTime::parse_from_rfc3339(text)
        .ok()
        .map(|d| d.timestamp_millis())
}

/// Parse a JSON string argument that may be either an object or JSON text.
pub fn parse_object_or_text(value: Option<&Value>) -> serde_json::Map<String, Value> {
    let Some(value) = value else {
        return serde_json::Map::new();
    };
    if let Some(map) = value.as_object() {
        return map.clone();
    }
    if let Some(text) = value.as_str() {
        if let Ok(Value::Object(map)) = serde_json::from_str(text) {
            return map;
        }
    }
    serde_json::Map::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn numbers_and_dates() {
        assert_eq!(as_i64(Some(&json!(42))), Some(42));
        assert_eq!(as_i64(Some(&json!("42"))), Some(42));
        assert_eq!(as_i64(Some(&json!(42.9))), Some(42));
        assert_eq!(
            date_from_ms(Some(&json!(1_700_000_000_000i64))),
            Some(1_700_000_000_000)
        );
        assert!(date_from_iso(Some(&json!("2026-10-26T12:00:00.123Z"))).is_some());
    }
}

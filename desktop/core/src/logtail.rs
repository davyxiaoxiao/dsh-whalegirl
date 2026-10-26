//! Tail reading for zstd-framed and plain JSONL logs.
//!
//! DSH appends concatenated zstd frames, one JSON event per line. Polls only
//! read the last few hundred KB from a frame boundary, which keeps a refresh at
//! a few milliseconds even for 50 MB logs. Codex writes plain JSONL and uses
//! the same helpers.

use std::fs::File;
use std::io::{BufRead, BufReader, Read, Seek, SeekFrom};
use std::path::Path;

use serde_json::Value;

pub const ZSTD_MAGIC: [u8; 4] = [0x28, 0xB5, 0x2F, 0xFD];
pub const MAX_LINE_BYTES: usize = 8 * 1024 * 1024;

/// Byte offsets of zstd frame magic numbers in `data`.
pub fn frame_offsets(data: &[u8]) -> Vec<usize> {
    if data.len() < 4 {
        return Vec::new();
    }
    let mut offsets = Vec::new();
    let mut i = 0;
    while i + 3 < data.len() {
        if data[i..i + 4] == ZSTD_MAGIC {
            offsets.push(i);
            i += 4;
        } else {
            i += 1;
        }
    }
    offsets
}

/// Read up to `limit` bytes from the end of the file (from `size`).
pub fn read_tail(path: &Path, size: u64, limit: u64) -> Option<Vec<u8>> {
    if size == 0 {
        return None;
    }
    let mut file = File::open(path).ok()?;
    let start = size.saturating_sub(limit);
    file.seek(SeekFrom::Start(start)).ok()?;
    let mut data = Vec::new();
    file.read_to_end(&mut data).ok()?;
    (!data.is_empty()).then_some(data)
}

/// Decompress in-memory zstd data. A chunk cut at the end may be truncated, so
/// anything successfully decoded before the error is kept.
pub fn decompress(data: &[u8]) -> Option<Vec<u8>> {
    if data.is_empty() {
        return None;
    }
    let mut decoder = zstd::stream::read::Decoder::new(data).ok()?;
    let mut out = Vec::new();
    let _ = decoder.read_to_end(&mut out);
    (!out.is_empty()).then_some(out)
}

/// Parse one JSON object per line out of decompressed data, keeping the last
/// `max_events` objects (tail windows).
pub fn parse_objects(data: &[u8], max_events: usize) -> Option<Vec<Value>> {
    parse_objects_inner(data, max_events, false)
}

/// Parse the first `max_events` objects. Used for session headers, where the
/// title / metadata lives at the beginning of the log.
pub fn parse_objects_head(data: &[u8], max_events: usize) -> Option<Vec<Value>> {
    parse_objects_inner(data, max_events, true)
}

fn parse_objects_inner(data: &[u8], max_events: usize, from_head: bool) -> Option<Vec<Value>> {
    let mut events = Vec::new();
    for line in data.split(|b| *b == b'\n') {
        if line.len() <= 8 || line.len() > MAX_LINE_BYTES {
            continue;
        }
        if let Ok(value) = serde_json::from_slice::<Value>(line) {
            if value.is_object() {
                events.push(value);
            }
        }
    }
    if events.is_empty() {
        return None;
    }
    if events.len() > max_events {
        if from_head {
            events.truncate(max_events);
        } else {
            let skip = events.len() - max_events;
            events.drain(0..skip);
        }
    }
    Some(events)
}

/// Read the tail of a zstd-framed event log, starting from an early frame in
/// the tail window so the caller sees a complete run of events.
pub fn zstd_tail_events(
    path: &Path,
    size: u64,
    limits: &[u64],
    max_events: usize,
) -> Option<Vec<Value>> {
    for &limit in limits {
        let Some(data) = read_tail(path, size, limit) else {
            continue;
        };
        let offsets = frame_offsets(&data);
        for offset in offsets.into_iter().take(4) {
            let chunk = &data[offset..];
            let Some(out) = decompress(chunk) else {
                continue;
            };
            if let Some(events) = parse_objects(&out, max_events) {
                return Some(events);
            }
        }
    }
    None
}

/// Read the tail of a plain JSONL file. The first partial line is dropped when
/// the read started mid-file.
pub fn read_json_lines_tail(
    path: &Path,
    size: u64,
    limit: u64,
    max_events: usize,
) -> Option<Vec<Value>> {
    let data = read_tail(path, size, limit)?;
    let mut lines: Vec<&[u8]> = data.split(|b| *b == b'\n').collect();
    if size > limit && lines.len() > 1 {
        lines.remove(0);
    }
    parse_lines(lines.into_iter(), max_events, false)
}

/// Read complete JSONL records from the beginning of a file (session metadata).
pub fn read_json_lines_head(path: &Path, limit: u64, max_events: usize) -> Option<Vec<Value>> {
    let mut file = File::open(path).ok()?;
    let mut data = Vec::new();
    file.by_ref().take(limit).read_to_end(&mut data).ok()?;
    if data.is_empty() {
        return None;
    }
    let mut lines: Vec<&[u8]> = data.split(|b| *b == b'\n').collect();
    if data.last() != Some(&b'\n') && lines.len() > 1 {
        lines.pop();
    }
    parse_lines(lines.into_iter(), max_events, true)
}

fn parse_lines<'a, I: Iterator<Item = &'a [u8]>>(
    lines: I,
    max_events: usize,
    from_head: bool,
) -> Option<Vec<Value>> {
    let mut events = Vec::new();
    for line in lines {
        if line.len() <= 8 || line.len() > MAX_LINE_BYTES {
            continue;
        }
        if let Ok(value) = serde_json::from_slice::<Value>(line) {
            if value.is_object() {
                events.push(value);
            }
        }
    }
    if events.is_empty() {
        return None;
    }
    if events.len() > max_events {
        if from_head {
            events.truncate(max_events);
        } else {
            let skip = events.len() - max_events;
            events.drain(0..skip);
        }
    }
    Some(events)
}

/// Stream every line of a zstd file through `f`. Used only as a one-off
/// backfill when the pet starts in the middle of a turn.
pub fn scan_zstd_file<F: FnMut(&Value)>(path: &Path, mut f: F) {
    let Ok(file) = File::open(path) else {
        return;
    };
    let Ok(decoder) = zstd::stream::read::Decoder::new(file) else {
        return;
    };
    let reader = BufReader::new(decoder);
    for line in reader.lines() {
        let Ok(line) = line else {
            break;
        };
        if line.len() <= 10 || line.len() > MAX_LINE_BYTES {
            continue;
        }
        if !line.contains("\"turn/start\"") && !line.contains("\"turn/end\"") {
            continue;
        }
        if let Ok(value) = serde_json::from_str::<Value>(&line) {
            f(&value);
        }
    }
}

/// Zstd-compress a string (tests / fixtures).
pub fn compress_for_test(data: &[u8], level: i32) -> Vec<u8> {
    zstd::encode_all(data, level).expect("zstd encode")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn finds_frames_and_reads_tail() {
        let payload_a = b"{\"type\":\"turn/start\",\"time\":1700000000000}\n";
        let payload_b = b"{\"type\":\"turn/end\",\"time\":1700000001000,\"data\":{\"reason\":{\"kind\":\"completed\"}}}\n";
        let mut bytes = compress_for_test(payload_a, 3);
        bytes.extend(compress_for_test(payload_b, 3));

        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("session.v4.jsonl.zstd");
        let mut file = File::create(&path).unwrap();
        file.write_all(&bytes).unwrap();
        drop(file);

        let offsets = frame_offsets(&bytes);
        assert_eq!(offsets.len(), 2);

        let events = zstd_tail_events(&path, bytes.len() as u64, &[384 * 1024], 100).unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0]["type"], "turn/start");
    }

    #[test]
    fn plain_jsonl_tail_drops_partial_first_line() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("rollout.jsonl");
        let mut text = String::new();
        for i in 0..20 {
            text.push_str(&format!("{{\"i\":{i},\"pad\":\"0123456789\"}}\n"));
        }
        std::fs::write(&path, &text).unwrap();
        let size = text.len() as u64;
        let events = read_json_lines_tail(&path, size, 80, 100).unwrap();
        assert!(events.len() < 20);
        assert!(events.last().unwrap()["i"] == 19);
    }
}

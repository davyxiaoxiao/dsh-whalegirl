//! Codex adapter.
//!
//! Codex writes one rollout JSONL per thread under
//! `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`. The tail is enough to know
//! what a thread is doing: `task_started` / `task_complete` frame a turn,
//! `item_completed` carries tools and the final answer, and
//! `token_usage_record` / `token_count` carry usage.
//!
//! Ported from `Sources/BlueFish/CodexProvider.swift`. Timestamps inside the
//! core are epoch milliseconds; Codex logs mix RFC 3339 strings with epoch
//! seconds, so both shapes are accepted.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use chrono::{Local, TimeZone};
use serde_json::{Map, Value};

use crate::format::{base_name, tail};
use crate::jsonutil::*;
use crate::logtail;
use crate::models::{
    AgentSession, Capabilities, ProviderStatus, ProviderUsage, UsageQuota, UsageTotals,
};
use crate::paths::WgPaths;
use crate::process;
use crate::providers::{AgentProvider, LogFn, ProviderContext};

/// Events kept from the tail of one rollout. Codex logs are chatty, so this is
/// deliberately larger than the DSH window.
const MAX_EVENTS: usize = 900;
/// Bytes read from the head of a file to find `session_meta` / the first user
/// message.
const HEAD_BYTES: u64 = 256 * 1024;
const HEAD_EVENTS: usize = 60;
/// A rollout touched this recently means Codex is running even when no process
/// is detected (CLI sessions).
const FRESH_FALLBACK_MS: i64 = 20_000;
/// Window for trusting a tail that starts mid-turn.
const MID_TURN_FRESH_MS: i64 = 120_000;
/// `sessions/YYYY/MM/DD/file.jsonl` is 3 levels; keep headroom for odd layouts.
const MAX_SCAN_DEPTH: usize = 8;
/// Stand-in for Swift's `Date.distantPast`.
const DISTANT_PAST: i64 = i64::MIN / 4;

/// Events that mean "a turn is in progress" when the tail begins mid-turn.
const MID_TURN_TYPES: &[&str] = &[
    "item_completed",
    "token_count",
    "token_usage_record",
    "custom_tool_call",
    "function_call",
    "reasoning",
    "message",
    "compacted",
    "turn_context",
];

#[derive(Clone, Debug)]
pub struct CodexConfig {
    pub max_sessions: usize,
    /// Only files modified inside this window are considered.
    pub recent_window_ms: i64,
    pub tail_bytes: u64,
    pub big_tail_bytes: u64,
    /// Override for tests / `wg-dump`; defaults to `~/.codex/sessions`.
    pub root: Option<PathBuf>,
}

impl Default for CodexConfig {
    fn default() -> Self {
        Self {
            max_sessions: 40,
            recent_window_ms: crate::models::RECENT_WINDOW_MS,
            tail_bytes: 512 * 1024,
            big_tail_bytes: 4 * 1024 * 1024,
            root: None,
        }
    }
}

#[derive(Clone, Debug, Default)]
struct HeaderInfo {
    session_id: String,
    cwd: String,
    created_at: Option<i64>,
    first_user_text: String,
    first_user_at: Option<i64>,
}

#[derive(Clone, Debug, Default)]
struct CacheEntry {
    size: u64,
    mtime: i64,
    header: Option<HeaderInfo>,
    header_tried: bool,
    snapshot: Option<AgentSession>,
    tokens_today: i64,
    calls_today: i64,
}

#[derive(Clone, Debug)]
struct ParsedTail {
    turn_active: bool,
    turn_started_at: Option<i64>,
    turn_number: i64,
    step_number: i64,
    started_tool_calls: i64,
    completed_tool_items: i64,
    last_event_at: i64,
    last_event_type: String,
    last_tool_name: Option<String>,
    last_tool_detail: Option<String>,
    last_tool_started_at: Option<i64>,
    last_assistant_text: Option<String>,
    last_user_text: Option<String>,
    last_user_at: Option<i64>,
    tokens_this_turn: i64,
    last_turn_tokens: i64,
    thread_tokens: i64,
    today_tokens: i64,
    calls_today: i64,
    last_completed_at: Option<i64>,
    last_error_at: Option<i64>,
    last_error_text: Option<String>,
    last_turn_errored: bool,
    saw_boundary: bool,
    saw_usage_record: bool,
    cwd: String,
    quotas: Vec<UsageQuota>,
}

impl Default for ParsedTail {
    fn default() -> Self {
        Self {
            turn_active: false,
            turn_started_at: None,
            turn_number: 0,
            step_number: 0,
            started_tool_calls: 0,
            completed_tool_items: 0,
            last_event_at: DISTANT_PAST,
            last_event_type: String::new(),
            last_tool_name: None,
            last_tool_detail: None,
            last_tool_started_at: None,
            last_assistant_text: None,
            last_user_text: None,
            last_user_at: None,
            tokens_this_turn: 0,
            last_turn_tokens: 0,
            thread_tokens: 0,
            today_tokens: 0,
            calls_today: 0,
            last_completed_at: None,
            last_error_at: None,
            last_error_text: None,
            last_turn_errored: false,
            saw_boundary: false,
            saw_usage_record: false,
            cwd: String::new(),
            quotas: Vec::new(),
        }
    }
}

/// One candidate rollout file plus the stat information used for caching.
#[derive(Clone, Debug)]
struct LogFile {
    path: PathBuf,
    size: u64,
    mtime: i64,
}

pub struct CodexProvider {
    paths: WgPaths,
    config: CodexConfig,
    log: Option<LogFn>,
    cache: HashMap<String, CacheEntry>,
    quotas: Vec<UsageQuota>,
}

impl CodexProvider {
    pub fn new(ctx: ProviderContext) -> Self {
        Self {
            paths: ctx.paths.clone(),
            config: CodexConfig::default(),
            log: ctx.log.clone(),
            cache: HashMap::new(),
            quotas: Vec::new(),
        }
    }

    pub fn with_config(mut self, config: CodexConfig) -> Self {
        self.config = config;
        self
    }

    fn root(&self) -> PathBuf {
        self.config
            .root
            .clone()
            .unwrap_or_else(|| self.paths.codex_sessions())
    }

    fn log_line(&self, line: impl AsRef<str>) {
        if let Some(log) = &self.log {
            log(line.as_ref());
        }
    }

    // MARK: - Files

    /// Every `.jsonl` under the sessions root, newest first, inside the recent
    /// window and capped at `max_sessions`.
    fn recent_files(&self, now: i64) -> Vec<LogFile> {
        let mut files = Vec::new();
        collect_jsonl(&self.root(), 0, &mut files);
        let cutoff = now - self.config.recent_window_ms;
        files.retain(|file| file.mtime > cutoff);
        files.sort_by(|a, b| b.mtime.cmp(&a.mtime));
        files.truncate(self.config.max_sessions);
        files
    }

    // MARK: - Header

    fn read_header(&self, log_path: &Path) -> HeaderInfo {
        let mut info = HeaderInfo::default();
        if let Some(events) = logtail::read_json_lines_head(log_path, HEAD_BYTES, HEAD_EVENTS) {
            for event in events.iter() {
                let top = as_map(Some(event));
                let ty = str_at(top, "type").unwrap_or("");
                let payload = as_map(event.get("payload"));

                if ty == "session_meta" {
                    info.session_id = str_at(payload, "session_id")
                        .or_else(|| str_at(payload, "id"))
                        .unwrap_or("")
                        .to_string();
                    info.cwd = str_at(payload, "cwd")
                        .map(str::to_string)
                        .or_else(|| {
                            payload
                                .get("runtime_workspace_roots")
                                .and_then(Value::as_array)
                                .and_then(|roots| roots.first())
                                .and_then(Value::as_str)
                                .map(str::to_string)
                        })
                        .unwrap_or_default();
                    info.created_at = date_from_iso(payload.get("timestamp"))
                        .or_else(|| date_from_iso(event.get("timestamp")));
                } else if ty == "turn_context" && info.cwd.is_empty() {
                    info.cwd = str_at(payload, "cwd").unwrap_or("").to_string();
                } else if info.first_user_text.is_empty() {
                    if ty == "event_msg" && str_at(payload, "type") == Some("item_completed") {
                        let item = as_map(payload.get("item"));
                        if str_at(item, "type") == Some("UserMessage") {
                            info.first_user_text =
                                text_from_content(item.get("content"), &["text", "Text"]);
                            info.first_user_at = date_from_iso(event.get("timestamp"));
                        }
                    } else if ty == "response_item"
                        && str_at(payload, "type") == Some("message")
                        && str_at(payload, "role") == Some("user")
                    {
                        info.first_user_text =
                            text_from_content(payload.get("content"), &["input_text", "text"]);
                        info.first_user_at = date_from_iso(event.get("timestamp"));
                    }
                }
            }
        }
        if info.session_id.is_empty() {
            info.session_id = stem(log_path);
        }
        self.log_line(format!(
            "codex header {} cwd={} session={}",
            file_name_of(log_path),
            info.cwd,
            info.session_id
        ));
        info
    }

    // MARK: - Tail

    fn parse_tail(&self, log_path: &Path, size: u64, now: i64, day_start: i64) -> ParsedTail {
        for limit in [self.config.tail_bytes, self.config.big_tail_bytes] {
            let Some(events) = logtail::read_json_lines_tail(log_path, size, limit, MAX_EVENTS)
            else {
                continue;
            };
            if events.is_empty() {
                continue;
            }
            return parse_events(&events, now, day_start);
        }
        ParsedTail::default()
    }
}

impl AgentProvider for CodexProvider {
    fn id(&self) -> &'static str {
        "codex"
    }

    fn display_name(&self) -> &'static str {
        "Codex"
    }

    fn short_name(&self) -> &'static str {
        "Codex"
    }

    fn watch_path(&self) -> Option<String> {
        Some(self.root().to_string_lossy().to_string())
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities(Capabilities::SESSIONS.0 | Capabilities::USAGE.0 | Capabilities::REVEAL.0)
    }

    fn refresh(&mut self, now: i64) -> ProviderStatus {
        let day_start = local_day_start(now);
        let files = self.recent_files(now);

        let mut sessions: Vec<AgentSession> = Vec::new();
        let mut seen: HashSet<String> = HashSet::new();

        for file in files {
            let path = file.path.to_string_lossy().to_string();
            seen.insert(path.clone());

            let mut entry = self.cache.remove(&path).unwrap_or_default();
            let header_changed = entry.snapshot.is_none();
            if !entry.header_tried || header_changed {
                entry.header = Some(self.read_header(&file.path));
                entry.header_tried = true;
            }

            if entry.size != file.size || entry.snapshot.is_none() {
                let parsed = self.parse_tail(&file.path, file.size, now, day_start);
                let (snapshot, tokens_today, calls_today) = build_snapshot(
                    &file.path,
                    file.mtime,
                    entry.header.as_ref(),
                    &parsed,
                    now,
                    day_start,
                );
                entry.snapshot = Some(snapshot);
                entry.tokens_today = tokens_today;
                entry.calls_today = calls_today;
                entry.size = file.size;
                entry.mtime = file.mtime;
                if !parsed.quotas.is_empty() {
                    self.quotas = parsed.quotas.clone();
                }
            } else if let Some(snapshot) = entry.snapshot.as_mut() {
                snapshot.file_modified_at = file.mtime;
                snapshot.derive_phase(now);
            }

            if let Some(mut snapshot) = entry.snapshot.clone() {
                snapshot.derive_phase(now);
                sessions.push(snapshot);
            }
            self.cache.insert(path, entry);
        }

        // Rollouts outside the recent window stop counting towards today.
        self.cache.retain(|key, _| seen.contains(key));

        sessions.sort_by(|a, b| b.last_event_at.cmp(&a.last_event_at));
        sessions.truncate(self.config.max_sessions);

        let app_running = process::is_running(process::CODEX_DESKTOP_MARKERS);
        let any_fresh = sessions
            .iter()
            .any(|session| now - session.last_event_at < FRESH_FALLBACK_MS);
        let running = app_running || any_fresh;

        let tokens_today: i64 = self.cache.values().map(|entry| entry.tokens_today).sum();
        let calls_today: i64 = self.cache.values().map(|entry| entry.calls_today).sum();

        let usage = if tokens_today > 0 || calls_today > 0 || !self.quotas.is_empty() {
            Some(ProviderUsage {
                provider_id: "codex".to_string(),
                provider_name: "Codex".to_string(),
                today: Some(UsageTotals {
                    cost_cny: None,
                    cost_usd: None,
                    calls: (calls_today > 0).then_some(calls_today),
                    tokens: (tokens_today > 0).then_some(tokens_today),
                }),
                quotas: self.quotas.clone(),
                source_label: Some("~/.codex/sessions".to_string()),
            })
        } else {
            None
        };

        ProviderStatus {
            id: "codex".to_string(),
            name: "Codex".to_string(),
            short_name: "Codex".to_string(),
            running,
            sessions,
            usage,
            watch_path: Some(self.root().to_string_lossy().to_string()),
            capabilities: self.capabilities(),
            updated_at: now,
            note: None,
        }
    }
}

// MARK: - Event mapping

fn parse_events(events: &[Value], now: i64, day_start: i64) -> ParsedTail {
    let mut p = ParsedTail::default();
    let mut latest: i64 = DISTANT_PAST;
    let mut fallback_today = 0i64;
    let mut fallback_turn = 0i64;
    let mut fallback_calls = 0i64;

    for event in events {
        let top = as_map(Some(event));
        let ty = str_at(top, "type").unwrap_or("");
        let payload = as_map(event.get("payload"));
        let sub_type = str_at(payload, "type").unwrap_or("");
        let time = date_from_iso(event.get("timestamp")).unwrap_or(latest);
        if time > latest {
            latest = time;
        }
        p.last_event_type = if sub_type.is_empty() {
            ty.to_string()
        } else {
            sub_type.to_string()
        };
        let is_today = time >= day_start;

        match ty {
            "session_meta" | "turn_context" => {
                if let Some(cwd) = str_at(payload, "cwd").filter(|cwd| !cwd.is_empty()) {
                    p.cwd = cwd.to_string();
                }
            }

            "event_msg" => match sub_type {
                "task_started" => {
                    let start = date_from_epoch(payload.get("started_at")).unwrap_or(time);
                    p.turn_active = true;
                    p.turn_started_at = Some(start);
                    p.turn_number += 1;
                    p.step_number = 0;
                    p.started_tool_calls = 0;
                    p.completed_tool_items = 0;
                    p.tokens_this_turn = 0;
                    p.last_turn_tokens = 0;
                    fallback_turn = 0;
                    p.last_completed_at = None;
                    p.last_error_at = None;
                    p.last_error_text = None;
                    p.last_turn_errored = false;
                    p.last_tool_name = None;
                    p.last_tool_detail = None;
                    p.last_tool_started_at = None;
                    p.last_assistant_text = None;
                    p.saw_boundary = true;
                }

                "task_complete" => {
                    p.turn_active = false;
                    p.last_completed_at =
                        date_from_epoch(payload.get("completed_at")).or(Some(time));
                    p.last_error_at = None;
                    p.last_error_text = None;
                    p.last_turn_errored = false;
                    p.saw_boundary = true;
                    let message = str_at(payload, "last_agent_message").unwrap_or("");
                    if !message.trim().is_empty() {
                        p.last_assistant_text = Some(tail(message, 160));
                    }
                }

                "turn_aborted" => {
                    let reason = str_at(payload, "reason").unwrap_or("interrupted");
                    p.turn_active = false;
                    p.last_error_at = date_from_epoch(payload.get("completed_at")).or(Some(time));
                    p.last_error_text = Some(if reason == "interrupted" {
                        "本轮被中止".to_string()
                    } else {
                        format!("本轮失败：{reason}")
                    });
                    p.last_turn_errored = true;
                    p.saw_boundary = true;
                }

                "task_failed" | "error" | "stream_error" => {
                    p.turn_active = false;
                    p.last_error_at = Some(time);
                    p.last_error_text = Some(
                        str_at(payload, "message")
                            .or_else(|| str_at(payload, "error"))
                            .unwrap_or("本轮失败")
                            .to_string(),
                    );
                    p.last_turn_errored = true;
                    p.saw_boundary = true;
                }

                "item_completed" => {
                    if let Some(item) = payload.get("item").and_then(Value::as_object) {
                        apply_item(item, time, &mut p);
                    }
                }

                "token_count" => {
                    if let Some(info) = payload.get("info").and_then(Value::as_object) {
                        if let Some(thread) = nested_int(info, "total_token_usage", "total_tokens")
                        {
                            if thread > p.thread_tokens {
                                p.thread_tokens = thread;
                            }
                        }
                        if let Some(last) = nested_int(info, "last_token_usage", "total_tokens") {
                            fallback_turn += last;
                            if is_today {
                                fallback_today += last;
                                fallback_calls += 1;
                            }
                        }
                    }
                    let parsed = parse_quotas(payload.get("rate_limits"), now);
                    if !parsed.is_empty() {
                        p.quotas = parsed;
                    }
                }

                _ => {}
            },

            "response_item" => apply_response_item(payload, time, &mut p),

            "token_usage_record" => {
                p.saw_usage_record = true;
                let usage = as_map(payload.get("usage"));
                if let Some(total) = int_at(usage, "total_tokens") {
                    if total > 0 {
                        p.tokens_this_turn += total;
                        if is_today {
                            p.today_tokens += total;
                            p.calls_today += 1;
                        }
                    }
                }
                if let Some(turn) = nested_int(payload, "turn_token_usage", "total_tokens") {
                    if turn > p.last_turn_tokens {
                        p.last_turn_tokens = turn;
                    }
                }
                if let Some(thread) = nested_int(payload, "thread_token_usage", "total_tokens") {
                    if thread > p.thread_tokens {
                        p.thread_tokens = thread;
                    }
                }
            }

            "compacted" => {
                p.last_tool_name = Some("整理记忆".to_string());
                p.last_tool_detail = None;
            }

            _ => {}
        }
    }

    p.last_event_at = latest;

    // Older Codex builds only emit `token_count`; newer ones emit both. Only
    // fall back when the tail has no per-response usage records.
    if !p.saw_usage_record {
        if fallback_today > p.today_tokens {
            p.today_tokens = fallback_today;
            p.calls_today = p.calls_today.max(fallback_calls);
        }
        if fallback_turn > p.tokens_this_turn {
            p.tokens_this_turn = fallback_turn;
        }
    }
    if p.turn_active && p.last_turn_tokens > p.tokens_this_turn {
        p.tokens_this_turn = p.last_turn_tokens;
    }
    p.step_number = p.started_tool_calls.max(p.completed_tool_items);
    p
}

fn apply_item(item: &Map<String, Value>, time: i64, p: &mut ParsedTail) {
    match str_at(item, "type").unwrap_or("") {
        "UserMessage" => {
            let text = text_from_content(item.get("content"), &["text", "Text"]);
            if !text.is_empty() {
                p.last_user_text = Some(tail(&text, 160));
                p.last_user_at = Some(time);
            }
        }

        "AgentMessage" => {
            let text = text_from_content(item.get("content"), &["Text", "text"]);
            if !text.trim().is_empty() {
                p.last_assistant_text = Some(tail(&text, 160));
            }
        }

        "CommandExecution" | "FileChange" | "McpToolCall" | "Extension" | "ContextCompaction"
        | "ImageView" => {
            p.completed_tool_items += 1;
            let (action, detail) = describe_item(item);
            p.last_tool_name = Some(action);
            p.last_tool_detail = detail;
            p.last_tool_started_at = Some(time);
        }

        _ => {}
    }
}

fn apply_response_item(payload: &Map<String, Value>, time: i64, p: &mut ParsedTail) {
    match str_at(payload, "type").unwrap_or("") {
        "message" => {
            let role = str_at(payload, "role").unwrap_or("");
            let text = text_from_content(
                payload.get("content"),
                &["input_text", "output_text", "text", "Text"],
            );
            if text.trim().is_empty() {
                return;
            }
            if role == "user" {
                p.last_user_text = Some(tail(&text, 160));
                p.last_user_at = Some(time);
            } else if role == "assistant" {
                p.last_assistant_text = Some(tail(&text, 160));
            }
        }

        "custom_tool_call" => {
            p.started_tool_calls += 1;
            let name = str_at(payload, "name").unwrap_or("tool");
            let input = str_at(payload, "input").unwrap_or("");
            let (action, detail) = describe_custom_tool(name, input);
            p.last_tool_name = Some(action);
            p.last_tool_detail = detail;
            p.last_tool_started_at = Some(time);
        }

        "function_call" => {
            p.started_tool_calls += 1;
            let name = str_at(payload, "name").unwrap_or("tool");
            let namespace = str_at(payload, "namespace").unwrap_or("");
            let args = parse_object_or_text(payload.get("arguments"));
            let (action, detail) = describe_function_call(name, namespace, &args);
            p.last_tool_name = Some(action);
            p.last_tool_detail = detail;
            p.last_tool_started_at = Some(time);
        }

        "image_generation_call" => {
            p.started_tool_calls += 1;
            let prompt = str_at(payload, "revised_prompt").unwrap_or("");
            p.last_tool_name = Some("画图".to_string());
            p.last_tool_detail = if prompt.is_empty() {
                None
            } else {
                Some(tail(&one_line(prompt), 34))
            };
            p.last_tool_started_at = Some(time);
        }

        "web_search_call" | "web_search" => {
            p.started_tool_calls += 1;
            let query =
                str_at(payload, "query").or_else(|| str_at(as_map(payload.get("action")), "query"));
            p.last_tool_name = Some("上网搜".to_string());
            p.last_tool_detail = query.map(|query| tail(query, 34));
            p.last_tool_started_at = Some(time);
        }

        "local_shell_call" | "shell_call" => {
            p.started_tool_calls += 1;
            p.last_tool_name = Some("跑命令".to_string());
            p.last_tool_detail = None;
            p.last_tool_started_at = Some(time);
        }

        _ => {}
    }
}

fn describe_item(item: &Map<String, Value>) -> (String, Option<String>) {
    let kind = str_at(item, "type").unwrap_or("");
    match kind {
        "CommandExecution" => {
            let mut detail =
                command_string(item.get("command")).map(|command| tail(&one_line(&command), 40));
            if str_at(item, "status") == Some("failed") {
                detail = Some(match detail {
                    Some(detail) => format!("{detail} · 失败"),
                    None => "失败了".to_string(),
                });
            }
            ("跑命令".to_string(), detail)
        }

        "FileChange" => {
            let changes = as_map(item.get("changes"));
            if changes.len() > 1 {
                return (
                    "改文件".to_string(),
                    Some(format!("{} 个文件", changes.len())),
                );
            }
            if let Some(path) = changes.keys().next() {
                return ("改文件".to_string(), Some(base_name(path)));
            }
            ("改文件".to_string(), None)
        }

        "McpToolCall" => {
            let server = str_at(item, "server").unwrap_or("MCP");
            let tool = str_at(item, "tool").unwrap_or("tool");
            let args = as_map(item.get("arguments"));
            let title = str_at(args, "title").filter(|title| !title.is_empty());
            let detail = match title {
                Some(title) => tail(title, 34),
                None => format!("{server}/{tool}"),
            };
            ("调工具".to_string(), Some(detail))
        }

        "Extension" => {
            let kind = str_at(item, "kind").unwrap_or("扩展");
            if kind == "clock.sleep" {
                if let Some(ms) = int_at(item, "durationMs") {
                    return ("等待".to_string(), Some(format!("{}s", (ms / 1000).max(1))));
                }
            }
            ("扩展".to_string(), Some(kind.to_string()))
        }

        "ContextCompaction" => ("整理记忆".to_string(), None),

        "ImageView" => {
            let path = str_at(item, "path").unwrap_or("");
            (
                "看图片".to_string(),
                if path.is_empty() {
                    None
                } else {
                    Some(base_name(path))
                },
            )
        }

        _ => (
            if kind.is_empty() {
                "工具".to_string()
            } else {
                kind.to_string()
            },
            None,
        ),
    }
}

fn describe_custom_tool(name: &str, input: &str) -> (String, Option<String>) {
    let lower = name.to_lowercase();
    if lower.contains("exec") || input.contains("exec_command") || input.contains("tools.exec") {
        return (
            "跑命令".to_string(),
            extract_exec_command(input).map(|command| tail(&one_line(&command), 40)),
        );
    }
    if lower.contains("patch") || lower.contains("edit") || lower.contains("write") {
        return (
            "改代码".to_string(),
            first_patch_path(input).map(|path| base_name(&path)),
        );
    }
    (
        if name.is_empty() {
            "工具".to_string()
        } else {
            name.to_string()
        },
        if input.is_empty() {
            None
        } else {
            Some(tail(&one_line(input), 34))
        },
    )
}

fn describe_function_call(
    name: &str,
    namespace: &str,
    args: &Map<String, Value>,
) -> (String, Option<String>) {
    if let Some(cmd) = str_at(args, "cmd").or_else(|| str_at(args, "command")) {
        return ("跑命令".to_string(), Some(tail(&one_line(cmd), 40)));
    }
    if let Some(title) = str_at(args, "title").filter(|title| !title.is_empty()) {
        return ("调工具".to_string(), Some(tail(title, 34)));
    }
    if let Some(code) = str_at(args, "code").filter(|code| !code.is_empty()) {
        return ("调工具".to_string(), Some(tail(&one_line(code), 34)));
    }
    let qualified = if namespace.is_empty() {
        name.to_string()
    } else {
        format!("{namespace}/{name}")
    };
    ("调工具".to_string(), Some(qualified))
}

fn command_string(raw: Option<&Value>) -> Option<String> {
    match raw? {
        Value::Array(items) => items
            .last()
            .and_then(Value::as_str)
            .filter(|command| !command.is_empty())
            .map(str::to_string),
        Value::String(command) if !command.is_empty() => Some(command.clone()),
        _ => None,
    }
}

/// Codex's `exec` tool is a JS snippet. Pull out `cmd: "..."` without
/// pretending to be a JavaScript parser.
fn extract_exec_command(input: &str) -> Option<String> {
    let bytes = input.as_bytes();
    let mut marker = None;
    let mut i = 0;
    while i + 3 <= bytes.len() {
        if bytes[i..i + 3] == *b"cmd" {
            let mut j = i + 3;
            while j < bytes.len() && bytes[j].is_ascii_whitespace() {
                j += 1;
            }
            if j < bytes.len() && bytes[j] == b':' {
                j += 1;
                while j < bytes.len() && bytes[j].is_ascii_whitespace() {
                    j += 1;
                }
                if j < bytes.len() && bytes[j] == b'"' {
                    marker = Some(j + 1);
                    break;
                }
            }
        }
        i += 1;
    }
    let start = marker?;

    let mut result = String::new();
    let mut escaped = false;
    for ch in input[start..].chars() {
        if escaped {
            match ch {
                'n' => result.push('\n'),
                't' => result.push('\t'),
                other => result.push(other),
            }
            escaped = false;
            continue;
        }
        if ch == '\\' {
            escaped = true;
            continue;
        }
        if ch == '"' {
            break;
        }
        result.push(ch);
    }
    let value = result.trim();
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}

fn first_patch_path(input: &str) -> Option<String> {
    const PREFIXES: [&str; 3] = ["*** Update File: ", "*** Add File: ", "*** Delete File: "];
    for line in input.split('\n') {
        for prefix in PREFIXES {
            if let Some(rest) = line.strip_prefix(prefix) {
                return Some(rest.to_string());
            }
        }
    }
    None
}

// MARK: - Snapshot

fn build_snapshot(
    log_path: &Path,
    mtime: i64,
    header: Option<&HeaderInfo>,
    parsed: &ParsedTail,
    now: i64,
    day_start: i64,
) -> (AgentSession, i64, i64) {
    let cwd = if parsed.cwd.is_empty() {
        header.map(|h| h.cwd.clone()).unwrap_or_default()
    } else {
        parsed.cwd.clone()
    };
    let header_created = header.and_then(|h| h.created_at);

    let mut tokens_today = parsed.today_tokens;
    // A thread created today has a cumulative thread total that covers the
    // whole day even when the tail no longer contains the early records.
    if let Some(created) = header_created {
        if created >= day_start {
            tokens_today = tokens_today.max(parsed.thread_tokens);
        }
    }

    let id = header
        .map(|h| h.session_id.clone())
        .filter(|id| !id.is_empty())
        .unwrap_or_else(|| stem(log_path));
    let directory = log_path
        .parent()
        .map(|parent| parent.to_string_lossy().to_string())
        .unwrap_or_default();
    let workspace_name = if cwd.is_empty() {
        "Codex".to_string()
    } else {
        base_name(&cwd)
    };
    let last_event_at = if parsed.last_event_at == DISTANT_PAST {
        mtime
    } else {
        parsed.last_event_at
    };

    let mut snapshot = AgentSession::new(
        id,
        directory,
        log_path.to_string_lossy().to_string(),
        "",
        cwd,
        workspace_name,
        header_created,
        last_event_at,
        mtime,
    );
    snapshot.provider_id = "codex".to_string();
    snapshot.provider_name = "Codex".to_string();

    snapshot.turn_active = parsed.turn_active;
    snapshot.turn_started_at = parsed.turn_started_at;
    snapshot.task_started_at = parsed
        .last_user_at
        .or_else(|| header.and_then(|h| h.first_user_at))
        .or(parsed.turn_started_at);
    snapshot.turn_number = parsed.turn_number;
    snapshot.step_number = parsed.step_number;
    snapshot.last_turn_errored = parsed.last_turn_errored;
    snapshot.last_error_text = parsed.last_error_text.clone();
    snapshot.last_completed_at = parsed.last_completed_at;
    snapshot.last_error_at = parsed.last_error_at;
    snapshot.last_tool_name = parsed.last_tool_name.clone();
    snapshot.last_tool_detail = parsed.last_tool_detail.clone();
    snapshot.last_tool_started_at = parsed.last_tool_started_at;
    snapshot.last_assistant_text = parsed.last_assistant_text.clone();
    snapshot.last_user_text = parsed
        .last_user_text
        .clone()
        .or_else(|| header.map(|h| h.first_user_text.clone()))
        .filter(|text| !text.is_empty());
    snapshot.tokens_this_turn = parsed.tokens_this_turn;
    snapshot.last_event_type = parsed.last_event_type.clone();

    // The tail may start in the middle of a turn. If the file is fresh and the
    // last event is a mid-turn event, trust it rather than showing idle.
    if !snapshot.turn_active && !parsed.saw_boundary {
        let last_known = parsed.last_event_at.max(mtime);
        let fresh = now - last_known < MID_TURN_FRESH_MS;
        if fresh && MID_TURN_TYPES.contains(&parsed.last_event_type.as_str()) {
            snapshot.turn_active = true;
            let last_event = (parsed.last_event_at != DISTANT_PAST).then_some(parsed.last_event_at);
            snapshot.turn_started_at = parsed
                .turn_started_at
                .or(parsed.last_user_at)
                .or(last_event);
        }
    }

    snapshot.derive_phase(now);
    (snapshot, tokens_today, parsed.calls_today)
}

// MARK: - Rate limits

fn parse_quotas(raw: Option<&Value>, now: i64) -> Vec<UsageQuota> {
    let Some(dict) = raw.and_then(Value::as_object) else {
        return Vec::new();
    };
    let mut result = Vec::new();
    for (key, fallback_window) in [("primary", "5h"), ("secondary", "周")] {
        let Some(window) = dict.get(key).and_then(Value::as_object) else {
            continue;
        };
        let Some(percent) = int_at(window, "used_percent")
            .or_else(|| int_at(window, "usedPercent"))
            .or_else(|| int_at(window, "percent"))
        else {
            continue;
        };
        let minutes = int_at(window, "window_minutes").or_else(|| int_at(window, "windowMinutes"));
        let label = match minutes {
            Some(minutes) => {
                if minutes >= 1440 {
                    "周".to_string()
                } else {
                    format!("{}h", (minutes / 60).max(1))
                }
            }
            None => fallback_window.to_string(),
        };
        let resets_at = int_at(window, "resets_in_seconds")
            .or_else(|| int_at(window, "resetsInSeconds"))
            .map(|seconds| now + seconds.saturating_mul(1000))
            .or_else(|| date_from_epoch(window.get("resets_at")));
        result.push(UsageQuota {
            provider: "Codex".to_string(),
            window: label,
            percent,
            resets_at,
            sampled_at: Some(now),
        });
    }
    result
}

// MARK: - Helpers

/// Local midnight for the day containing `now`, as epoch milliseconds.
fn local_day_start(now: i64) -> i64 {
    let Some(dt) = Local.timestamp_millis_opt(now).single() else {
        return now;
    };
    dt.date_naive()
        .and_hms_opt(0, 0, 0)
        .and_then(|naive| Local.from_local_datetime(&naive).single())
        .map(|midnight| midnight.timestamp_millis())
        .unwrap_or(now)
}

fn collect_jsonl(dir: &Path, depth: usize, out: &mut Vec<LogFile>) {
    if depth > MAX_SCAN_DEPTH {
        return;
    }
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.starts_with('.') {
            continue;
        }
        let path = entry.path();
        let Ok(meta) = fs::metadata(&path) else {
            continue;
        };
        if meta.is_dir() {
            collect_jsonl(&path, depth + 1, out);
            continue;
        }
        if !meta.is_file() || path.extension().and_then(|ext| ext.to_str()) != Some("jsonl") {
            continue;
        }
        let Ok(modified) = meta.modified() else {
            continue;
        };
        let Ok(age) = modified.duration_since(std::time::UNIX_EPOCH) else {
            continue;
        };
        out.push(LogFile {
            path,
            size: meta.len(),
            mtime: age.as_millis() as i64,
        });
    }
}

fn text_from_content(value: Option<&Value>, keys: &[&str]) -> String {
    let Some(blocks) = value.and_then(Value::as_array) else {
        return String::new();
    };
    blocks
        .iter()
        .filter(|block| keys.contains(&block.get("type").and_then(Value::as_str).unwrap_or("")))
        .filter_map(|block| block.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

fn one_line(value: &str) -> String {
    value.replace('\n', " ")
}

fn stem(path: &Path) -> String {
    path.file_stem()
        .map(|stem| stem.to_string_lossy().to_string())
        .unwrap_or_default()
}

fn file_name_of(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().to_string())
        .unwrap_or_default()
}

fn empty_map() -> &'static Map<String, Value> {
    static EMPTY: OnceLock<Map<String, Value>> = OnceLock::new();
    EMPTY.get_or_init(Map::new)
}

/// Object view of an optional JSON field; an empty map when absent.
fn as_map(value: Option<&Value>) -> &Map<String, Value> {
    value
        .and_then(Value::as_object)
        .unwrap_or_else(|| empty_map())
}

fn str_at<'a>(map: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    map.get(key).and_then(Value::as_str)
}

fn int_at(map: &Map<String, Value>, key: &str) -> Option<i64> {
    as_i64(map.get(key))
}

fn nested_int(map: &Map<String, Value>, outer: &str, inner: &str) -> Option<i64> {
    int_at(as_map(map.get(outer)), inner)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn task_started_and_complete_frame_a_turn() {
        let events = vec![
            json!({
                "timestamp": "2026-10-26T02:59:00.000Z",
                "type": "session_meta",
                "payload": {"id": "s-1", "cwd": "/tmp/proj"}
            }),
            json!({
                "timestamp": "2026-10-26T03:00:01.250Z",
                "type": "event_msg",
                "payload": {"type": "task_started", "started_at": 1761447601.25}
            }),
            json!({
                "timestamp": "2026-10-26T03:00:02.000Z",
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "修一下登录"}]
                }
            }),
            json!({
                "timestamp": "2026-10-26T03:00:03.000Z",
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "assistant",
                    "content": [{"type": "output_text", "text": "好了"}]
                }
            }),
            json!({
                "timestamp": "2026-10-26T03:00:04.000Z",
                "type": "event_msg",
                "payload": {"type": "task_complete", "completed_at": 1761447604}
            }),
        ];

        let parsed = parse_events(&events, 1_761_447_600_000, 0);

        assert!(!parsed.turn_active);
        assert!(parsed.saw_boundary);
        assert_eq!(parsed.turn_number, 1);
        assert_eq!(parsed.cwd, "/tmp/proj");
        assert_eq!(parsed.last_user_text.as_deref(), Some("修一下登录"));
        assert_eq!(parsed.last_assistant_text.as_deref(), Some("好了"));
        assert_eq!(parsed.last_completed_at, Some(1_761_447_604_000));
        assert_eq!(parsed.last_event_type, "task_complete");
    }

    #[test]
    fn token_usage_records_drive_today_accounting() {
        let events = vec![
            json!({
                "timestamp": "2026-10-26T03:00:00.000Z",
                "type": "event_msg",
                "payload": {"type": "task_started"}
            }),
            json!({
                "timestamp": "2026-10-26T03:00:05.000Z",
                "type": "token_usage_record",
                "payload": {
                    "usage": {"total_tokens": 1200},
                    "turn_token_usage": {"total_tokens": 1200},
                    "thread_token_usage": {"total_tokens": 5000}
                }
            }),
            json!({
                "timestamp": "2026-10-26T03:00:09.000Z",
                "type": "token_usage_record",
                "payload": {
                    "usage": {"total_tokens": 800},
                    "thread_token_usage": {"total_tokens": 5800}
                }
            }),
            json!({
                "timestamp": "2026-10-26T03:00:10.000Z",
                "type": "event_msg",
                "payload": {"type": "task_complete", "completed_at": 1761447610}
            }),
        ];

        let parsed = parse_events(&events, 1_761_447_615_000, 0);

        assert!(parsed.saw_usage_record);
        assert_eq!(parsed.today_tokens, 2000);
        assert_eq!(parsed.calls_today, 2);
        assert_eq!(parsed.tokens_this_turn, 2000);
        assert_eq!(parsed.thread_tokens, 5800);
        assert_eq!(parsed.last_turn_tokens, 1200);
    }

    #[test]
    fn token_count_fallback_and_quota_windows() {
        let now = 1_761_447_600_000;
        let events = vec![
            json!({
                "timestamp": "2026-10-26T03:00:00.000Z",
                "type": "event_msg",
                "payload": {"type": "task_started"}
            }),
            json!({
                "timestamp": "2026-10-26T03:00:07.000Z",
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "info": {
                        "total_token_usage": {"total_tokens": 9000},
                        "last_token_usage": {"total_tokens": 1500}
                    },
                    "rate_limits": {
                        "primary": {"used_percent": 7, "window_minutes": 300, "resets_in_seconds": 120},
                        "secondary": {"used_percent": 11, "window_minutes": 10080, "resets_at": 1761451200}
                    }
                }
            }),
            json!({
                "timestamp": "2026-10-26T03:00:08.000Z",
                "type": "compacted",
                "payload": {}
            }),
        ];

        let parsed = parse_events(&events, now, 0);

        assert!(!parsed.saw_usage_record);
        assert_eq!(parsed.today_tokens, 1500);
        assert_eq!(parsed.calls_today, 1);
        assert_eq!(parsed.tokens_this_turn, 1500);
        assert_eq!(parsed.thread_tokens, 9000);
        assert_eq!(parsed.last_tool_name.as_deref(), Some("整理记忆"));

        assert_eq!(parsed.quotas.len(), 2);
        assert_eq!(parsed.quotas[0].provider, "Codex");
        assert_eq!(parsed.quotas[0].window, "5h");
        assert_eq!(parsed.quotas[0].percent, 7);
        assert_eq!(parsed.quotas[0].resets_at, Some(now + 120_000));
        assert_eq!(parsed.quotas[1].window, "周");
        assert_eq!(parsed.quotas[1].percent, 11);
        assert_eq!(parsed.quotas[1].resets_at, Some(1_761_451_200_000));
    }
}

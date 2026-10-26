//! DSH adapter: watches `~/.dsh/sessions` and `dsh-cost-meter`.
//!
//! The session log is an append-only file of concatenated zstd frames, one JSON
//! event per line. We only need the last handful of events, so instead of
//! decompressing whole (potentially 50 MB) logs we decompress the last chunk
//! starting from a zstd frame boundary.

use std::collections::{HashMap, HashSet};
use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::format::{base_name, tail};
use crate::jsonutil::*;
use crate::logtail;
use crate::models::{
    AgentSession, ApprovalRequest, Capabilities, JobInfo, ProviderStatus, ProviderUsage,
};
use crate::paths::WgPaths;
use crate::process;
use crate::providers::{event_obj, url_host, AgentProvider, LogFn, ProviderContext};
use crate::usage::CostMeterLedgerReader;

#[derive(Clone, Debug)]
pub struct DSHConfig {
    pub tail_bytes: u64,
    pub big_tail_bytes: u64,
    pub max_sessions: usize,
}

impl Default for DSHConfig {
    fn default() -> Self {
        Self {
            tail_bytes: 384 * 1024,
            big_tail_bytes: 2 * 1024 * 1024,
            max_sessions: 40,
        }
    }
}

pub struct DSHProvider {
    paths: WgPaths,
    config: DSHConfig,
    usage: CostMeterLedgerReader,
    log: Option<LogFn>,
    cache: HashMap<String, CacheEntry>,
    archived_ids: HashSet<String>,
    workspace_meta_updated_at: i64,
    last_app_running: bool,
}

#[derive(Clone, Debug, Default)]
struct HeaderInfo {
    cwd: String,
    created_at: Option<i64>,
    title: String,
    first_user_text: String,
    first_user_at: Option<i64>,
}

#[derive(Clone, Debug, Default)]
struct CacheEntry {
    size: u64,
    mtime: i64,
    header: Option<HeaderInfo>,
    header_tried: bool,
    last_turn_start: Option<i64>,
    snapshot: Option<AgentSession>,
}

#[derive(Clone, Debug, Default)]
struct ParsedTail {
    turn_active: bool,
    turn_started_at: Option<i64>,
    turn_number: i64,
    step_number: i64,
    last_event_at: i64,
    last_event_type: String,
    pending_approval: Option<ApprovalRequest>,
    last_tool_name: Option<String>,
    last_tool_detail: Option<String>,
    last_tool_started_at: Option<i64>,
    last_assistant_text: Option<String>,
    last_user_text: Option<String>,
    last_user_at: Option<i64>,
    tokens_this_turn: i64,
    jobs: HashMap<String, JobInfo>,
    deliverables: Vec<String>,
    last_completed_at: Option<i64>,
    last_assistant_had_tool_call: bool,
    last_assistant_had_text: bool,
    last_error_at: Option<i64>,
    last_error_text: Option<String>,
    last_turn_errored: bool,
    title: String,
    cwd: String,
    saw_turn_start: bool,
    last_turn_marker_start: Option<bool>,
}

impl DSHProvider {
    pub fn new(ctx: ProviderContext) -> Self {
        let usage = CostMeterLedgerReader::at(ctx.paths.dsh_cost_ledger());
        Self {
            paths: ctx.paths.clone(),
            config: DSHConfig::default(),
            usage,
            log: ctx.log.clone(),
            cache: HashMap::new(),
            archived_ids: HashSet::new(),
            workspace_meta_updated_at: i64::MIN / 2,
            last_app_running: false,
        }
    }

    pub fn with_config(mut self, config: DSHConfig) -> Self {
        self.config = config;
        self
    }

    fn root(&self) -> PathBuf {
        self.paths.dsh_sessions()
    }

    fn log_line(&self, line: impl AsRef<str>) {
        if let Some(log) = &self.log {
            log(line.as_ref());
        }
    }

    // MARK: - Scan

    fn update_workspace_meta(&mut self, now: i64) {
        if now - self.workspace_meta_updated_at <= 60_000 {
            return;
        }
        self.workspace_meta_updated_at = now;
        let Ok(data) = fs::read(self.paths.dsh_workspace_json()) else {
            return;
        };
        let Ok(root): Result<Value, _> = serde_json::from_slice(&data) else {
            return;
        };
        if let Some(archived) = root
            .get("global")
            .and_then(|g| g.get("archivedSessionIds"))
            .and_then(Value::as_array)
        {
            self.archived_ids = archived
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect();
        }
    }

    fn collect_session_dirs(&self) -> Vec<(PathBuf, PathBuf)> {
        let mut out = Vec::new();
        let Ok(workspaces) = fs::read_dir(self.root()) else {
            return out;
        };
        for workspace in workspaces.flatten() {
            if !is_dir(&workspace.path()) || is_hidden(&workspace.path()) {
                continue;
            }
            let Ok(sessions) = fs::read_dir(workspace.path()) else {
                continue;
            };
            for session in sessions.flatten() {
                let path = session.path();
                let name = session.file_name();
                let name = name.to_string_lossy();
                if !name.starts_with("session-") || !is_dir(&path) {
                    continue;
                }
                out.push((path, workspace.path()));
            }
        }
        out
    }

    fn make_snapshot(
        &self,
        session_dir: &Path,
        log_path: &Path,
        mtime: i64,
        header: Option<&HeaderInfo>,
        parsed: &ParsedTail,
        turn_start_hint: Option<i64>,
        now: i64,
    ) -> AgentSession {
        let id = session_dir
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let workspace_dir_name = session_dir
            .parent()
            .and_then(Path::file_name)
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_default();
        let workspace_path = decode_workspace_path(&workspace_dir_name);
        let cwd = if parsed.cwd.is_empty() {
            header
                .map(|h| h.cwd.clone())
                .filter(|c| !c.is_empty())
                .unwrap_or(workspace_path.clone())
        } else {
            parsed.cwd.clone()
        };
        let workspace_name = base_name(if cwd.is_empty() {
            &workspace_path
        } else {
            &cwd
        });
        let title = if parsed.title.is_empty() {
            header.map(|h| h.title.clone()).unwrap_or_default()
        } else {
            parsed.title.clone()
        };
        let last_user = parsed
            .last_user_text
            .clone()
            .filter(|t| !t.is_empty())
            .or_else(|| header.map(|h| h.first_user_text.clone()))
            .filter(|t| !t.is_empty());

        let mut snapshot = AgentSession::new(
            id.clone(),
            session_dir.to_string_lossy().to_string(),
            log_path.to_string_lossy().to_string(),
            title,
            cwd,
            workspace_name,
            header.and_then(|h| h.created_at),
            if parsed.last_event_at == 0 {
                mtime
            } else {
                parsed.last_event_at
            },
            mtime,
        );
        snapshot.turn_active = parsed.turn_active;
        snapshot.turn_started_at = parsed.turn_started_at.or(turn_start_hint);
        snapshot.turn_number = parsed.turn_number;
        snapshot.step_number = parsed.step_number;
        snapshot.last_turn_errored = parsed.last_turn_errored;
        snapshot.last_error_text = parsed.last_error_text.clone();
        snapshot.last_completed_at = parsed.last_completed_at;
        snapshot.last_error_at = parsed.last_error_at;
        snapshot.pending_approval = parsed.pending_approval.clone();
        snapshot.last_tool_name = parsed.last_tool_name.clone();
        snapshot.last_tool_detail = parsed.last_tool_detail.clone();
        snapshot.last_tool_started_at = parsed.last_tool_started_at;
        snapshot.last_assistant_text = parsed.last_assistant_text.clone();
        snapshot.last_user_text = last_user;
        snapshot.task_started_at = parsed
            .last_user_at
            .or_else(|| header.and_then(|h| h.first_user_at));
        snapshot.tokens_this_turn = parsed.tokens_this_turn;
        snapshot.running_jobs = parsed.jobs.values().cloned().collect();
        snapshot
            .running_jobs
            .sort_by(|a, b| a.started_at.cmp(&b.started_at));
        snapshot.deliverables = parsed.deliverables.clone();
        snapshot.last_event_type = parsed.last_event_type.clone();
        snapshot.is_archived = self.archived_ids.contains(&id);
        snapshot.derive_phase(now);
        snapshot
    }

    // MARK: - Tail parsing

    fn parse_tail(&self, log_path: &Path, size: u64, now: i64) -> ParsedTail {
        let limits = [self.config.tail_bytes, self.config.big_tail_bytes];
        let Some(events) = logtail::zstd_tail_events(log_path, size, &limits, 800) else {
            return ParsedTail::default();
        };
        parse_events(&events, now)
    }

    fn read_header(&self, log_path: &Path) -> Option<HeaderInfo> {
        let mut file = File::open(log_path).ok()?;
        let mut data = Vec::new();
        file.by_ref().take(96 * 1024).read_to_end(&mut data).ok()?;
        if data.is_empty() {
            return None;
        }
        let offsets = logtail::frame_offsets(&data);
        let first = *offsets.first()?;
        let out = logtail::decompress(&data[first..])?;
        let events = logtail::parse_objects_head(&out, 40)?;

        let mut info = HeaderInfo::default();
        for event in events.iter().take(40) {
            let ty = as_str(event.get("type")).unwrap_or("");
            let d = event_obj(event);
            match ty {
                "session" => {
                    info.cwd =
                        as_string(event.get("cwd").or_else(|| d.get("cwd"))).unwrap_or_default();
                    info.created_at = date_from_ms(event.get("createdAt"));
                }
                "session/title" => {
                    if let Some(title) = as_string(d.get("title")) {
                        info.title = title;
                    }
                }
                "user/message" if info.first_user_text.is_empty() => {
                    info.first_user_text = text_blocks(d.get("content"), "text").join(" ");
                    info.first_user_at = date_from_ms(event.get("time"));
                }
                "agent/inbox/spliced" if info.first_user_text.is_empty() => {
                    if let Some(inserted) = d.get("inserted").and_then(Value::as_array) {
                        if let Some(first) = inserted.first() {
                            if as_str(first.get("role")) == Some("user") {
                                info.first_user_text =
                                    text_blocks(first.get("content"), "text").join(" ");
                                info.first_user_at = date_from_ms(event.get("time"));
                            }
                        }
                    }
                }
                _ => {}
            }
        }
        self.log_line(format!(
            "header {} cwd={} title={}",
            log_path
                .file_name()
                .map(|n| n.to_string_lossy().to_string())
                .unwrap_or_default(),
            info.cwd,
            info.title
        ));
        Some(info)
    }

    fn find_last_turn_start(&self, log_path: &Path) -> Option<i64> {
        let mut last: Option<(bool, i64)> = None;
        logtail::scan_zstd_file(log_path, |event| {
            let ty = as_str(event.get("type")).unwrap_or("");
            if (ty == "turn/start" || ty == "turn/end")
                && last.is_none_or(|(_, t)| {
                    date_from_ms(event.get("time")).is_some_and(|time| time >= t)
                })
            {
                if let Some(time) = date_from_ms(event.get("time")) {
                    last = Some((ty == "turn/start", time));
                }
            }
        });
        match last {
            Some((true, time)) => Some(time),
            _ => None,
        }
    }
}

impl AgentProvider for DSHProvider {
    fn id(&self) -> &'static str {
        "dsh"
    }

    fn display_name(&self) -> &'static str {
        "DeepSeek Harness"
    }

    fn short_name(&self) -> &'static str {
        "DSH"
    }

    fn watch_path(&self) -> Option<String> {
        Some(self.root().to_string_lossy().to_string())
    }

    fn capabilities(&self) -> Capabilities {
        let mut caps = Capabilities::SESSIONS.0 | Capabilities::USAGE.0 | Capabilities::REVEAL.0;
        if cfg!(target_os = "macos") {
            caps |= Capabilities::SESSION_JUMP.0;
        }
        Capabilities(caps)
    }

    fn refresh(&mut self, now: i64) -> ProviderStatus {
        self.update_workspace_meta(now);

        let dirs = self.collect_session_dirs();
        let mut sessions: Vec<AgentSession> = Vec::new();
        let mut seen: HashSet<String> = HashSet::new();

        for (session_dir, _workspace_dir) in dirs {
            let log_path = session_dir.join("session.v4.jsonl.zstd");
            let Ok(meta) = fs::metadata(&log_path) else {
                continue;
            };
            let size = meta.len();
            let mtime = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .map(|d| d.as_millis() as i64)
                .unwrap_or(0);
            let path = log_path.to_string_lossy().to_string();
            seen.insert(path.clone());

            let mut entry = self.cache.remove(&path).unwrap_or_default();
            let header_changed = entry.snapshot.is_none() || entry.size == 0;
            if !entry.header_tried || header_changed {
                entry.header = self.read_header(&log_path);
                entry.header_tried = true;
            }

            if entry.size != size || entry.snapshot.is_none() {
                let parsed = self.parse_tail(&log_path, size, now);
                if let Some(started) = parsed.turn_started_at {
                    entry.last_turn_start = Some(started);
                }
                if entry.last_turn_start.is_none() && parsed.turn_active {
                    entry.last_turn_start = self.find_last_turn_start(&log_path);
                }
                let mut snapshot = self.make_snapshot(
                    &session_dir,
                    &log_path,
                    mtime,
                    entry.header.as_ref(),
                    &parsed,
                    entry.last_turn_start,
                    now,
                );
                if !snapshot.turn_active {
                    entry.last_turn_start = None;
                }
                if snapshot.title.is_empty() {
                    if let Some(previous) = entry.snapshot.as_ref() {
                        snapshot.title = previous.title.clone();
                    }
                }
                snapshot.is_archived = self.archived_ids.contains(&snapshot.id);
                entry.snapshot = Some(snapshot);
                entry.size = size;
                entry.mtime = mtime;
            } else if let Some(snapshot) = entry.snapshot.as_mut() {
                snapshot.file_modified_at = mtime;
                if entry.last_turn_start.is_some() && snapshot.turn_active {
                    snapshot.turn_started_at = entry.last_turn_start;
                }
                snapshot.is_archived = self.archived_ids.contains(&snapshot.id);
            }

            if let Some(mut snapshot) = entry.snapshot.clone() {
                snapshot.derive_phase(now);
                if !snapshot.is_archived {
                    sessions.push(snapshot);
                }
            }
            self.cache.insert(path, entry);
        }

        let stale: Vec<String> = self
            .cache
            .keys()
            .filter(|key| !seen.contains(*key))
            .cloned()
            .collect();
        for key in stale {
            self.cache.remove(&key);
        }

        sessions.sort_by(|a, b| b.last_event_at.cmp(&a.last_event_at));
        sessions.truncate(self.config.max_sessions);

        let app_running = process::is_running(process::DSH_DESKTOP_MARKERS);
        let any_fresh = sessions.iter().any(|s| now - s.last_event_at < 12_000);
        let was_app_running = self.last_app_running;
        self.last_app_running = app_running;
        // The desktop app quitting should flip the pet to "disconnected"
        // immediately; the freshness fallback only covers CLI-run backends.
        let running = app_running || (!was_app_running && any_fresh);

        let usage = self.usage.read(now).map(|reading| ProviderUsage {
            provider_id: self.id().to_string(),
            provider_name: self.short_name().to_string(),
            today: Some(reading.today),
            quotas: reading.quotas,
            source_label: Some(reading.source_label),
        });

        ProviderStatus {
            id: self.id().to_string(),
            name: self.display_name().to_string(),
            short_name: self.short_name().to_string(),
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

fn parse_events(events: &[Value], now: i64) -> ParsedTail {
    let mut p = ParsedTail::default();
    let mut pending: HashMap<String, ApprovalRequest> = HashMap::new();
    let mut job_map: HashMap<String, JobInfo> = HashMap::new();
    let mut latest_time = 0i64;
    let mut tokens_since_turn_start = 0i64;
    let mut compaction_active = false;

    for event in events {
        let ty = as_str(event.get("type")).unwrap_or("");
        let time = date_from_ms(event.get("time")).unwrap_or(latest_time);
        if time > latest_time {
            latest_time = time;
        }
        p.last_event_type = ty.to_string();
        let d = event_obj(event);

        match ty {
            "session" => {
                if let Some(cwd) = as_string(d.get("cwd").or_else(|| event.get("cwd"))) {
                    p.cwd = cwd;
                }
            }
            "session/title" => {
                if let Some(title) = as_string(d.get("title")).filter(|t| !t.is_empty()) {
                    p.title = title;
                }
            }
            "turn/start" => {
                p.turn_active = true;
                p.turn_started_at = Some(time);
                p.turn_number = as_i64(d.get("turn")).unwrap_or(p.turn_number);
                p.step_number = 0;
                p.last_turn_errored = false;
                p.last_error_at = None;
                p.last_completed_at = None;
                p.tokens_this_turn = 0;
                tokens_since_turn_start = 0;
                p.saw_turn_start = true;
                p.last_turn_marker_start = Some(true);
            }
            "turn/end" => {
                p.turn_active = false;
                p.last_turn_marker_start = Some(false);
                if let Some(reason) = d.get("reason") {
                    let kind = as_str(reason.get("kind")).unwrap_or("");
                    if kind == "completed" {
                        // DSH ends a turn after every model call, including
                        // tool-call turns. A real task completion is the turn
                        // whose final assistant message has text but no tool
                        // call.
                        let final_answer =
                            !p.last_assistant_had_tool_call && p.last_assistant_had_text;
                        p.last_completed_at = final_answer.then_some(time);
                        p.last_turn_errored = false;
                        p.last_error_at = None;
                    } else if kind == "aborted" {
                        p.last_error_at = Some(time);
                        p.last_error_text = Some("本轮被中止".to_string());
                        p.last_turn_errored = true;
                    } else {
                        p.last_error_at = Some(time);
                        p.last_turn_errored = true;
                        p.last_error_text = Some(
                            reason
                                .get("error")
                                .and_then(|e| as_string(e.get("message")))
                                .unwrap_or_else(|| "本轮失败".to_string()),
                        );
                    }
                }
                if let Some(usage) = d.get("usage") {
                    if let Some(total) = as_i64(usage.get("totalTokens")) {
                        p.tokens_this_turn = total;
                    }
                }
            }
            "step/start" => {
                p.step_number = as_i64(d.get("step")).unwrap_or(p.step_number);
            }
            "assistant/message" => {
                if let Some(usage) = d.get("usage") {
                    if let Some(total) = as_i64(usage.get("totalTokens")) {
                        tokens_since_turn_start += total;
                        p.tokens_this_turn = tokens_since_turn_start;
                    }
                }
                if let Some(message) = d.get("message") {
                    let content = array_field(message, "content");
                    p.last_assistant_had_tool_call = content
                        .iter()
                        .any(|block| as_str(block.get("type")) == Some("tool-call"));
                    let text = text_blocks(message.get("content"), "text").join("\n");
                    p.last_assistant_had_text = !text.is_empty();
                    if !text.is_empty() {
                        p.last_assistant_text = Some(tail(&text, 160));
                    }
                }
            }
            "user/message" => {
                p.last_user_at = Some(time);
                let text = text_blocks(d.get("content"), "text").join(" ");
                if !text.is_empty() {
                    p.last_user_text = Some(tail(&text, 160));
                }
            }
            "tool/call" => {
                let raw = as_string(d.get("name")).unwrap_or_else(|| "tool".to_string());
                let args = parse_arguments(d.get("arguments"));
                let (action, detail) = describe_tool(&raw, &args);
                p.last_tool_name = Some(action);
                p.last_tool_detail = detail;
                p.last_tool_started_at = Some(time);
            }
            "tool/result" => {
                if let Some(message) = d.get("message") {
                    if as_bool(message.get("isError")) == Some(true) {
                        p.last_tool_detail = Some("报错了".to_string());
                    }
                }
            }
            "approval/asked" => {
                let id = as_string(d.get("id")).unwrap_or_else(|| format!("approval-{time}"));
                let tool = as_string(d.get("toolName")).unwrap_or_else(|| "操作".to_string());
                let reason = as_string(d.get("reason")).unwrap_or_default();
                pending.insert(
                    id.clone(),
                    ApprovalRequest {
                        id,
                        tool,
                        reason,
                        since: time,
                    },
                );
            }
            "approval/decided" => {
                if let Some(id) = as_str(d.get("id")) {
                    pending.remove(id);
                }
            }
            "job/registered" => {
                if let Some(id) = as_string(d.get("jobId")) {
                    job_map.insert(
                        id.clone(),
                        JobInfo {
                            id,
                            label: as_string(d.get("label"))
                                .or_else(|| as_string(d.get("kind")))
                                .unwrap_or_else(|| "任务".to_string()),
                            kind: as_string(d.get("kind")).unwrap_or_default(),
                            started_at: date_from_ms(d.get("startedAt")).unwrap_or(time),
                        },
                    );
                }
            }
            "job/settled" => {
                if let Some(id) = as_str(d.get("jobId")) {
                    job_map.remove(id);
                }
            }
            "deliverables/presented" => {
                if let Some(files) = d.get("files").and_then(Value::as_array) {
                    p.deliverables = files
                        .iter()
                        .filter_map(|file| as_string(file.get("path")))
                        .collect();
                }
            }
            "compaction/start" => {
                compaction_active = true;
                p.last_tool_name = Some("整理记忆".to_string());
                p.last_tool_detail = None;
            }
            "compaction/end" => {
                compaction_active = false;
            }
            _ => {}
        }
    }

    p.last_event_at = latest_time;
    if !p.turn_active && p.last_turn_marker_start.is_none() && !events.is_empty() {
        // The tail window started in the middle of a turn: trust it when the
        // last event belongs to a turn-in-progress.
        const MID_TURN: &[&str] = &[
            "step/start",
            "step/end",
            "assistant/message",
            "tool/call",
            "tool/result",
            "job/registered",
            "job/settled",
            "approval/asked",
            "approval/decided",
            "llm/retry",
            "llm/retry-started",
            "compaction/start",
            "compaction/end",
        ];
        if MID_TURN.contains(&p.last_event_type.as_str()) {
            p.turn_active = true;
        }
    }
    if compaction_active {
        p.last_tool_name = Some("整理记忆".to_string());
    }
    if !pending.is_empty() {
        p.pending_approval = pending.into_values().max_by_key(|approval| approval.since);
        if let Some(approval) = &p.pending_approval {
            if now - approval.since > 3_600_000 {
                p.pending_approval = None;
            }
        }
    }
    p.jobs = job_map;
    p
}

fn text_blocks(value: Option<&Value>, wanted_type: &str) -> Vec<String> {
    let Some(blocks) = value.and_then(Value::as_array) else {
        return Vec::new();
    };
    blocks
        .iter()
        .filter(|block| as_str(block.get("type")) == Some(wanted_type))
        .filter_map(|block| as_string(block.get("text")))
        .collect()
}

fn parse_arguments(raw: Option<&Value>) -> Map<String, Value> {
    parse_object_or_text(raw)
}

fn short(value: &str, limit: usize) -> String {
    tail(&value.replace('\n', " "), limit)
}

fn field(args: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    for key in keys {
        if let Some(value) = as_string(args.get(*key)).filter(|v| !v.is_empty()) {
            return Some(value);
        }
    }
    None
}

fn describe_tool(name: &str, args: &Map<String, Value>) -> (String, Option<String>) {
    match name {
        "bash" => {
            if let Some(desc) = field(args, &["description"]) {
                return ("跑命令".into(), Some(short(&desc, 34)));
            }
            if let Some(cmd) = field(args, &["command"]) {
                return ("跑命令".into(), Some(short(&cmd, 34)));
            }
            ("跑命令".into(), None)
        }
        "read" => (
            "读文件".into(),
            field(args, &["file_path"]).map(|p| base_name(&p)),
        ),
        "write" => (
            "写文件".into(),
            field(args, &["file_path"]).map(|p| base_name(&p)),
        ),
        "edit" => (
            "改代码".into(),
            field(args, &["file_path"]).map(|p| base_name(&p)),
        ),
        "grep" => (
            "搜代码".into(),
            field(args, &["pattern"]).map(|p| short(&p, 34)),
        ),
        "glob" => (
            "找文件".into(),
            field(args, &["pattern"]).map(|p| short(&p, 34)),
        ),
        "web_search" => {
            let first = args
                .get("queries")
                .and_then(Value::as_array)
                .and_then(|q| q.first())
                .and_then(Value::as_str);
            ("上网搜".into(), first.map(|q| short(q, 34)))
        }
        "web_fetch" => {
            let host = field(args, &["url"]).and_then(|url| url_host(&url));
            ("看网页".into(), host)
        }
        "generate_image" | "generate_images" | "edit_image" => (
            "画图".into(),
            field(args, &["prompt"]).map(|p| short(&p, 34)),
        ),
        "todo_write" => {
            let first = args
                .get("todos")
                .and_then(Value::as_array)
                .and_then(|t| t.first())
                .and_then(|t| as_string(t.get("content")));
            ("写计划".into(), first.map(|t| short(&t, 34)))
        }
        "present" => {
            let path = args
                .get("files")
                .and_then(Value::as_array)
                .and_then(|f| f.first())
                .and_then(|f| as_string(f.get("path")));
            ("交付".into(), path.map(|p| base_name(&p)))
        }
        "ask_user_question" => {
            let question = args
                .get("questions")
                .and_then(Value::as_array)
                .and_then(|q| q.first())
                .and_then(|q| as_string(q.get("question")));
            ("问你".into(), question.map(|q| short(&q, 34)))
        }
        "subagent" | "subagent_fork" => (
            "派子代理".into(),
            field(args, &["description"]).map(|d| short(&d, 34)),
        ),
        "job_output" | "job_list" => ("看后台任务".into(), None),
        "update_goal" | "create_goal" => ("更新目标".into(), None),
        "skill" => ("加载技能".into(), field(args, &["name"])),
        _ => (name.to_string(), None),
    }
}

/// Decode a DSH workspace directory name back into a path. macOS uses
/// `--Users-name-project--`; Windows archives may use `C--Users-name`.
fn decode_workspace_path(name: &str) -> String {
    if name.is_empty() {
        return String::new();
    }
    let bytes = name.as_bytes();
    if bytes.len() > 3 && bytes[0].is_ascii_alphabetic() && bytes[1] == b'-' && bytes[2] == b'-' {
        let drive = name.chars().next().unwrap().to_ascii_uppercase();
        let rest = name[3..].replace('-', "/");
        return format!("{drive}:/{rest}");
    }
    let mut s = name.to_string();
    if let Some(stripped) = s.strip_prefix("--") {
        s = stripped.to_string();
    }
    if let Some(stripped) = s.strip_suffix("--") {
        s = stripped.to_string();
    }
    if let Some(stripped) = s.strip_prefix('-') {
        s = stripped.to_string();
    }
    format!("/{}", s.replace('-', "/"))
}

fn is_dir(path: &Path) -> bool {
    fs::metadata(path).map(|m| m.is_dir()).unwrap_or(false)
}

fn is_hidden(path: &Path) -> bool {
    path.file_name()
        .map(|n| n.to_string_lossy().starts_with('.'))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn workspace_decode() {
        assert_eq!(
            decode_workspace_path("--Users-daiwei-project-myself-dshpeg--"),
            "/Users/daiwei/project/myself/dshpeg"
        );
        assert_eq!(
            decode_workspace_path("C--Users-daiwei-project"),
            "C:/Users/daiwei/project"
        );
    }

    #[test]
    fn turn_state_machine_waits_for_final_text() {
        let events = vec![
            json!({"type":"turn/start","time":1_700_000_000_000i64,"data":{"turn":1}}),
            json!({"type":"assistant/message","time":1_700_000_001_000i64,"data":{"message":{"content":[{"type":"tool-call"}]}}}),
            json!({"type":"turn/end","time":1_700_000_002_000i64,"data":{"reason":{"kind":"completed"}}}),
            json!({"type":"turn/start","time":1_700_000_003_000i64,"data":{"turn":2}}),
            json!({"type":"assistant/message","time":1_700_000_004_000i64,"data":{"message":{"content":[{"type":"text","text":"搞定"}]}}}),
            json!({"type":"turn/end","time":1_700_000_005_000i64,"data":{"reason":{"kind":"completed"}}}),
        ];
        let parsed = parse_events(&events, 1_700_000_006_000);
        assert!(!parsed.turn_active);
        assert_eq!(parsed.last_completed_at, Some(1_700_000_005_000));
        assert_eq!(parsed.turn_number, 2);
        assert_eq!(parsed.last_assistant_text.as_deref(), Some("搞定"));
    }
}

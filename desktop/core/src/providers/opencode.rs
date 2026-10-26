//! OpenCode adapter: reads sessions out of `opencode.db` (SQLite) and the Go
//! plan usage meters out of the web console.
//!
//! Ported from `Sources/BlueFish/OpenCodeProvider.swift` and
//! `OpenCodeQuota.swift`. OpenCode stores titles, cwd, model, cumulative
//! tokens/cost and timestamps in the `session` table; `message` / `part` carry
//! the turn and tool details. The database is opened read-only with a 150 ms
//! busy timeout, so a running agent holding the writer lock can never block the
//! monitor: a missing or locked DB simply yields an empty status. Per-session
//! detail is cached until `session.time_updated` changes.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, UNIX_EPOCH};

use chrono::{SecondsFormat, TimeZone, Utc};
use rusqlite::types::ValueRef;
use rusqlite::{params, Connection, OpenFlags, Params, Row};
use serde_json::{Map, Value};

use crate::format::{base_name, tail};
use crate::jsonutil::{as_f64, as_i64};
use crate::models::{
    AgentSession, ApprovalRequest, Capabilities, ProviderStatus, ProviderUsage, UsageQuota,
    UsageTotals,
};
use crate::providers::{url_host, AgentProvider, LogFn, ProviderContext};
use crate::{day_start_ms, utc_week_start_ms};

pub const PROVIDER_ID: &str = "opencode";
pub const DISPLAY_NAME: &str = "OpenCode";
pub const SHORT_NAME: &str = "OpenCode";
/// Label the Swift adapter always reports for the local database.
const DB_SOURCE_LABEL: &str = "~/.local/share/opencode/opencode.db";

const DEFAULT_MAX_SESSIONS: usize = 40;
/// Sessions older than a week are irrelevant to the pet.
const RECENT_WINDOW_MS: i64 = 7 * 24 * 3600 * 1000;
/// A session counts as "running" when it saw activity in the last two minutes.
const FRESH_MS: i64 = 120_000;
/// Quota network round-trips are rate limited to one attempt every two minutes.
const QUOTA_REFRESH_MS: i64 = 120_000;
/// Go plan limits are expressed in micro-cents, 1e8 per dollar.
const QUOTA_MICRO_CENTS_PER_DOLLAR: i64 = 100_000_000;
const QUOTA_BASE: &str = "https://opencode.ai/console/api";
const SQLITE_BUSY_TIMEOUT_MS: u64 = 150;

const SQL_SESSIONS: &str = "\
SELECT id, title, directory, model, agent, cost, \
       tokens_input, tokens_output, tokens_reasoning, \
       tokens_cache_read, tokens_cache_write, \
       time_created, time_updated, time_compacting, permission \
FROM session \
WHERE time_archived IS NULL AND time_updated >= ? \
ORDER BY time_updated DESC \
LIMIT ?";

const SQL_MESSAGES: &str = "\
SELECT id, data, time_created FROM message \
WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT 8";

const SQL_PARTS: &str = "\
SELECT message_id, data, time_created FROM part \
WHERE session_id = ? ORDER BY time_created DESC, id DESC LIMIT 24";

const SQL_TOKENS_THIS_TURN: &str = "\
SELECT COALESCE(SUM(CAST(json_extract(data, '$.tokens.total') AS INTEGER)), 0) \
FROM message \
WHERE session_id = ? AND json_extract(data, '$.role') = 'assistant' \
      AND time_created >= ?";

const SQL_TURN_NUMBER: &str = "\
SELECT COUNT(*) FROM message \
WHERE session_id = ? AND json_extract(data, '$.role') = 'user'";

const SQL_STEP_NUMBER: &str = "\
SELECT COUNT(*) FROM part \
WHERE session_id = ? AND json_extract(data, '$.type') = 'tool' \
      AND time_created >= ?";

const SQL_TODAY_AGGREGATE: &str = "\
SELECT COUNT(*), \
       COALESCE(SUM(CAST(json_extract(data, '$.tokens.total') AS INTEGER)), 0), \
       COALESCE(SUM(CAST(json_extract(data, '$.cost') AS REAL)), 0) \
FROM message \
WHERE session_id = ? AND json_extract(data, '$.role') = 'assistant' \
      AND time_created >= ?";

const SQL_CREDENTIALS: &str = "\
SELECT a.access_token AS token, s.active_org_id AS org \
FROM account_state s \
JOIN account a ON a.id = s.active_account_id \
LIMIT 1";

/// Query parameter list for statements that take no bindings.
const NO_PARAMS: &[&dyn rusqlite::ToSql] = &[];

#[derive(Clone, Debug)]
pub struct OpenCodeConfig {
    pub max_sessions: usize,
    pub recent_window_ms: i64,
    /// Opt-out for a fully offline app: the Go quota lookup is local-only when
    /// this is false.
    pub fetch_quotas: bool,
    pub quotas_opt_out: bool,
    /// `"go"` or `"go-plus"` (as chosen in settings / `BLUEFISH_OPENCODE_PLAN`).
    pub plan: String,
}

impl Default for OpenCodeConfig {
    fn default() -> Self {
        Self {
            max_sessions: DEFAULT_MAX_SESSIONS,
            recent_window_ms: RECENT_WINDOW_MS,
            fetch_quotas: true,
            quotas_opt_out: false,
            plan: "go".to_string(),
        }
    }
}

#[derive(Clone, Debug)]
struct CacheEntry {
    /// `session.time_updated` the snapshot was built from.
    updated: i64,
    snapshot: AgentSession,
    tokens_today: i64,
    calls_today: i64,
    cost_today: f64,
}

#[derive(Debug, Default)]
struct QuotaState {
    cached: Vec<UsageQuota>,
    last_attempt_at: Option<i64>,
    in_flight: bool,
}

pub struct OpenCodeProvider {
    data_dir: PathBuf,
    db_path: PathBuf,
    log_path: PathBuf,
    config: OpenCodeConfig,
    log: Option<LogFn>,
    cache: HashMap<String, CacheEntry>,
    /// Shared with the quota worker thread so `refresh` never blocks on HTTP.
    quotas: Arc<Mutex<QuotaState>>,
}

impl OpenCodeProvider {
    pub fn new(ctx: ProviderContext) -> Self {
        let config = OpenCodeConfig {
            max_sessions: DEFAULT_MAX_SESSIONS,
            recent_window_ms: RECENT_WINDOW_MS,
            fetch_quotas: ctx.opencode_fetch_quotas,
            quotas_opt_out: ctx.opencode_quotas_opt_out,
            plan: ctx.opencode_plan.clone(),
        };
        Self {
            data_dir: ctx.paths.opencode_data_dir.clone(),
            db_path: ctx.paths.opencode_db.clone(),
            log_path: ctx.paths.opencode_log(),
            config,
            log: ctx.log.clone(),
            cache: HashMap::new(),
            quotas: Arc::new(Mutex::new(QuotaState::default())),
        }
    }

    pub fn with_config(mut self, config: OpenCodeConfig) -> Self {
        self.config = config;
        self
    }

    /// Test / `--dump-opencode` override for the database location.
    pub fn with_database(mut self, path: impl Into<PathBuf>) -> Self {
        self.db_path = path.into();
        self
    }

    fn log_line(&self, message: impl AsRef<str>) {
        if let Some(log) = &self.log {
            log(message.as_ref());
        }
    }

    fn empty_status(&self, now: i64) -> ProviderStatus {
        ProviderStatus {
            id: PROVIDER_ID.to_string(),
            name: DISPLAY_NAME.to_string(),
            short_name: SHORT_NAME.to_string(),
            running: false,
            sessions: Vec::new(),
            usage: None,
            watch_path: Some(self.data_dir.to_string_lossy().to_string()),
            capabilities: self.capabilities(),
            updated_at: now,
            note: None,
        }
    }

    fn log_is_fresh(&self, now: i64) -> bool {
        let Ok(meta) = fs::metadata(&self.log_path) else {
            return false;
        };
        let Ok(modified) = meta.modified() else {
            return false;
        };
        let Ok(stamp) = modified.duration_since(UNIX_EPOCH) else {
            return false;
        };
        now - (stamp.as_millis() as i64) < FRESH_MS
    }

    // MARK: - Session details

    fn build_entry(
        &self,
        row: &SessionRow,
        conn: &Connection,
        now: i64,
        day_start: i64,
    ) -> CacheEntry {
        let session_id = row.id.clone();
        let directory = row.directory.clone();
        let created = row.created;
        let updated = row.updated;
        let raw_title = row.title.clone();
        let title = clean_title(&raw_title);
        let compacting_at = row.compacting_at;

        let messages = load_messages(conn, &session_id);
        let parts = load_parts(conn, &session_id);
        let mut role_by_message: HashMap<&str, &str> = HashMap::new();
        for message in &messages {
            role_by_message.insert(message.id.as_str(), message.role.as_str());
        }
        let last_message = messages.first();
        let last_user = messages.iter().find(|message| message.role == "user");
        let last_assistant = messages.iter().find(|message| message.role == "assistant");
        let last_user_at = last_user.map(|message| message.created);

        let mut last_user_text: Option<String> = None;
        let mut last_assistant_text: Option<String> = None;
        let mut action_tool: Option<(String, Option<String>, i64)> = None;
        let mut action_decided = false;
        for part in &parts {
            let role = role_by_message
                .get(part.message_id.as_str())
                .copied()
                .unwrap_or("");
            if part.kind == "text" {
                if let Some(text) = part.data.get("text").and_then(Value::as_str) {
                    let text = text.trim();
                    if !text.is_empty() {
                        if role == "user" && last_user_text.is_none() {
                            last_user_text = Some(tail(text, 160));
                        } else if role == "assistant" && last_assistant_text.is_none() {
                            last_assistant_text = Some(tail(text, 160));
                        }
                        // The most recent visible part is assistant text: no tool
                        // line, but keep scanning for the latest user prompt.
                        if !action_decided && role == "assistant" {
                            action_decided = true;
                        }
                    }
                }
            }
            if !action_decided && part.kind == "tool" {
                if let Some((action, detail)) = describe_tool(part) {
                    action_tool = Some((action, detail, part.created));
                    action_decided = true;
                }
            }
        }

        let pending_approval = parse_permission(row.permission.as_deref(), &session_id, updated);

        let mut turn_active = false;
        if pending_approval.is_some() {
            turn_active = true;
        } else if compacting_at > 0 {
            turn_active = true;
        } else if let Some(last) = last_message {
            if last.role == "assistant" {
                if last.completed.is_none() {
                    turn_active = true;
                } else if last.finish.to_lowercase().contains("tool") {
                    turn_active = true;
                }
            } else if last.role == "user" {
                turn_active = now - last.created < FRESH_MS;
            }
        }
        if let Some(tool_part) = parts.iter().find(|part| part.kind == "tool") {
            if let Some(state) = tool_part.data.get("state").and_then(Value::as_object) {
                if let Some(status) = state.get("status").and_then(Value::as_str) {
                    let status = status.to_lowercase();
                    if status == "running" || status == "pending" {
                        turn_active = true;
                    }
                }
            }
        }

        let mut last_completed_at: Option<i64> = None;
        if pending_approval.is_none() && compacting_at == 0 {
            if let Some(last) = last_message {
                if last.role == "assistant" && !last.finish.to_lowercase().contains("tool") {
                    last_completed_at = last.completed;
                }
            }
        }

        let mut last_error_at: Option<i64> = None;
        let mut last_error_text: Option<String> = None;
        if let (Some(assistant), Some(last)) = (last_assistant, last_message) {
            if assistant.id == last.id {
                if let Some(error) = assistant.error.clone().filter(|text| !text.is_empty()) {
                    last_error_at = Some(assistant.created);
                    last_error_text = Some(error);
                    last_completed_at = None;
                }
            }
        }

        let tokens_this_turn = match last_user_at {
            Some(since) => scalar_i64(conn, SQL_TOKENS_THIS_TURN, params![session_id, since]),
            None => 0,
        };

        let turn_number = scalar_i64(conn, SQL_TURN_NUMBER, params![session_id]);

        let step_number = match last_user_at {
            Some(since) => scalar_i64(conn, SQL_STEP_NUMBER, params![session_id, since]),
            None => 0,
        };

        let today = today_aggregate(conn, &session_id, day_start);
        let session_tokens = row.tokens_input
            + row.tokens_output
            + row.tokens_reasoning
            + row.tokens_cache_read
            + row.tokens_cache_write;
        let session_cost = row.cost;
        let created_today = created >= day_start;
        let tokens_today = if created_today {
            session_tokens
        } else {
            today.tokens
        };
        let cost_today = if created_today {
            session_cost
        } else {
            today.cost
        };

        let cwd = directory;
        let mut snapshot = AgentSession::new(
            session_id.clone(),
            self.data_dir.to_string_lossy().to_string(),
            self.db_path.to_string_lossy().to_string(),
            title.clone(),
            cwd.clone(),
            if cwd.is_empty() {
                SHORT_NAME.to_string()
            } else {
                base_name(&cwd)
            },
            if created > 0 { Some(created) } else { None },
            updated.max(last_message.map(|message| message.created).unwrap_or(0)),
            updated,
        );
        snapshot.provider_id = PROVIDER_ID.to_string();
        snapshot.provider_name = SHORT_NAME.to_string();
        snapshot.turn_active = turn_active;
        snapshot.turn_started_at = last_user_at;
        snapshot.task_started_at = last_user_at;
        snapshot.turn_number = turn_number;
        snapshot.step_number = step_number;
        snapshot.last_turn_errored = last_error_at.is_some();
        snapshot.last_error_text = last_error_text;
        snapshot.last_completed_at = last_completed_at;
        snapshot.last_error_at = last_error_at;
        snapshot.pending_approval = pending_approval;
        if let Some((name, detail, started)) = action_tool {
            snapshot.last_tool_name = Some(name);
            snapshot.last_tool_detail = detail;
            snapshot.last_tool_started_at = Some(started);
        }
        snapshot.last_assistant_text = last_assistant_text;
        snapshot.last_user_text = match last_user_text {
            Some(text) => Some(text),
            None => {
                if title.is_empty() {
                    None
                } else {
                    Some(raw_title.clone())
                }
            }
        };
        snapshot.tokens_this_turn = tokens_this_turn;
        snapshot.last_event_type = match last_message {
            Some(message) => format!("message/{}", message.role),
            None => match parts.first() {
                Some(part) => format!("part/{}", part.kind),
                None => "session".to_string(),
            },
        };
        snapshot.derive_phase(now);

        self.log_line(format!(
            "opencode session {} updated={} active={} today={}",
            session_id, updated, turn_active, tokens_today
        ));

        CacheEntry {
            updated,
            snapshot,
            tokens_today,
            calls_today: today.calls,
            cost_today,
        }
    }

    // MARK: - Go quota

    fn current_quotas(&self) -> Vec<UsageQuota> {
        lock_quotas(&self.quotas).cached.clone()
    }

    /// Starts at most one background fetch every two minutes. `refresh` itself
    /// never waits on the network.
    fn maybe_refresh_quotas(&self, now: i64) {
        if !self.config.fetch_quotas || self.config.quotas_opt_out {
            return;
        }
        let should_start = {
            let mut state = lock_quotas(&self.quotas);
            let due = match state.last_attempt_at {
                Some(at) => now - at >= QUOTA_REFRESH_MS,
                None => true,
            };
            if state.in_flight || !due {
                false
            } else {
                state.in_flight = true;
                state.last_attempt_at = Some(now);
                true
            }
        };
        if !should_start {
            return;
        }

        let state = Arc::clone(&self.quotas);
        let reader = OpenCodeQuotaReader::new(
            self.db_path.clone(),
            self.config.plan.clone(),
            self.log.clone(),
        );
        std::thread::spawn(move || {
            let quotas = reader.fetch_sync(now);
            let mut guard = lock_quotas(&state);
            guard.cached = quotas;
            guard.in_flight = false;
        });
    }
}

impl AgentProvider for OpenCodeProvider {
    fn id(&self) -> &'static str {
        PROVIDER_ID
    }

    fn display_name(&self) -> &'static str {
        DISPLAY_NAME
    }

    fn short_name(&self) -> &'static str {
        SHORT_NAME
    }

    fn watch_path(&self) -> Option<String> {
        Some(self.data_dir.to_string_lossy().to_string())
    }

    fn capabilities(&self) -> Capabilities {
        Capabilities(Capabilities::SESSIONS.0 | Capabilities::USAGE.0 | Capabilities::REVEAL.0)
    }

    fn refresh(&mut self, now: i64) -> ProviderStatus {
        let Some(conn) = open_read_only(&self.db_path) else {
            self.cache.clear();
            self.log_line(format!(
                "opencode db open failed: {}",
                self.db_path.display()
            ));
            return self.empty_status(now);
        };

        let day_start = day_start_ms(now);
        let cutoff = now - self.config.recent_window_ms;
        let rows = load_session_rows(&conn, cutoff, self.config.max_sessions);

        let mut sessions: Vec<AgentSession> = Vec::new();
        let mut seen: HashSet<String> = HashSet::new();
        for row in rows {
            if row.id.is_empty() {
                continue;
            }
            seen.insert(row.id.clone());
            let cached = self
                .cache
                .get(&row.id)
                .filter(|entry| entry.updated == row.updated)
                .cloned();
            let entry = match cached {
                Some(entry) => entry,
                None => {
                    let entry = self.build_entry(&row, &conn, now, day_start);
                    self.cache.insert(row.id.clone(), entry.clone());
                    entry
                }
            };
            let mut snapshot = entry.snapshot;
            snapshot.derive_phase(now);
            sessions.push(snapshot);
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

        let any_fresh = sessions
            .iter()
            .any(|session| now - session.last_event_at < FRESH_MS);
        let log_fresh = self.log_is_fresh(now);

        let mut tokens_today = 0i64;
        let mut calls_today = 0i64;
        let mut cost_today = 0f64;
        for entry in self.cache.values() {
            tokens_today += entry.tokens_today;
            calls_today += entry.calls_today;
            cost_today += entry.cost_today;
        }

        self.maybe_refresh_quotas(now);
        let quotas = self.current_quotas();
        let has_quotas = !quotas.is_empty();
        let usage = if tokens_today > 0 || calls_today > 0 || cost_today > 0.0 || has_quotas {
            Some(ProviderUsage {
                provider_id: PROVIDER_ID.to_string(),
                provider_name: SHORT_NAME.to_string(),
                today: Some(UsageTotals {
                    cost_cny: None,
                    cost_usd: if cost_today > 0.0 {
                        Some(cost_today)
                    } else {
                        None
                    },
                    calls: if calls_today > 0 {
                        Some(calls_today)
                    } else {
                        None
                    },
                    tokens: if tokens_today > 0 {
                        Some(tokens_today)
                    } else {
                        None
                    },
                }),
                quotas,
                source_label: Some(DB_SOURCE_LABEL.to_string()),
            })
        } else {
            None
        };

        ProviderStatus {
            id: PROVIDER_ID.to_string(),
            name: DISPLAY_NAME.to_string(),
            short_name: SHORT_NAME.to_string(),
            running: any_fresh || log_fresh,
            sessions,
            usage,
            watch_path: Some(self.data_dir.to_string_lossy().to_string()),
            capabilities: self.capabilities(),
            updated_at: now,
            note: None,
        }
    }
}

// MARK: - Row model

struct SessionRow {
    id: String,
    title: String,
    directory: String,
    cost: f64,
    tokens_input: i64,
    tokens_output: i64,
    tokens_reasoning: i64,
    tokens_cache_read: i64,
    tokens_cache_write: i64,
    created: i64,
    updated: i64,
    compacting_at: i64,
    permission: Option<String>,
}

struct MessageInfo {
    id: String,
    role: String,
    created: i64,
    completed: Option<i64>,
    finish: String,
    /// Token/cost totals are kept for parity with the Swift adapter; the
    /// snapshot aggregates them with SQL instead.
    #[allow(dead_code)]
    tokens: i64,
    #[allow(dead_code)]
    cost: f64,
    error: Option<String>,
}

struct PartInfo {
    message_id: String,
    created: i64,
    kind: String,
    data: Map<String, Value>,
}

#[derive(Default)]
struct TodayAggregate {
    calls: i64,
    tokens: i64,
    cost: f64,
}

// MARK: - Database

fn open_read_only(path: &Path) -> Option<Connection> {
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    let conn = Connection::open_with_flags(path, flags).ok()?;
    let _ = conn.busy_timeout(Duration::from_millis(SQLITE_BUSY_TIMEOUT_MS));
    Some(conn)
}

fn load_session_rows(conn: &Connection, cutoff: i64, limit: usize) -> Vec<SessionRow> {
    let Ok(mut statement) = conn.prepare(SQL_SESSIONS) else {
        return Vec::new();
    };
    let Ok(mapped) = statement.query_map(params![cutoff, limit as i64], |row| {
        Ok(SessionRow {
            id: col_text(row, 0).unwrap_or_default(),
            title: col_text(row, 1).unwrap_or_default(),
            directory: col_text(row, 2).unwrap_or_default(),
            cost: col_f64(row, 5).unwrap_or(0.0),
            tokens_input: col_i64(row, 6).unwrap_or(0),
            tokens_output: col_i64(row, 7).unwrap_or(0),
            tokens_reasoning: col_i64(row, 8).unwrap_or(0),
            tokens_cache_read: col_i64(row, 9).unwrap_or(0),
            tokens_cache_write: col_i64(row, 10).unwrap_or(0),
            created: col_i64(row, 11).unwrap_or(0),
            updated: col_i64(row, 12).unwrap_or(0),
            compacting_at: col_i64(row, 13).unwrap_or(0),
            permission: col_text(row, 14),
        })
    }) else {
        return Vec::new();
    };
    mapped.filter_map(Result::ok).collect()
}

fn load_messages(conn: &Connection, session_id: &str) -> Vec<MessageInfo> {
    let Ok(mut statement) = conn.prepare(SQL_MESSAGES) else {
        return Vec::new();
    };
    let Ok(mapped) = statement.query_map(params![session_id], |row| {
        let id = col_text(row, 0);
        let data = col_text(row, 1).and_then(|text| serde_json::from_str::<Value>(&text).ok());
        let row_time = col_i64(row, 2).unwrap_or(0);
        Ok(match (id, data) {
            (Some(id), Some(Value::Object(data))) => Some(message_info(id, &data, row_time)),
            _ => None,
        })
    }) else {
        return Vec::new();
    };
    mapped.filter_map(Result::ok).flatten().collect()
}

fn load_parts(conn: &Connection, session_id: &str) -> Vec<PartInfo> {
    let Ok(mut statement) = conn.prepare(SQL_PARTS) else {
        return Vec::new();
    };
    let Ok(mapped) = statement.query_map(params![session_id], |row| {
        let message_id = col_text(row, 0);
        let data = col_text(row, 1).and_then(|text| serde_json::from_str::<Value>(&text).ok());
        let created = col_i64(row, 2).unwrap_or(0);
        Ok(match (message_id, data) {
            (Some(message_id), Some(Value::Object(data))) => {
                map_str(&data, "type").map(|kind| PartInfo {
                    message_id,
                    created,
                    kind,
                    data,
                })
            }
            _ => None,
        })
    }) else {
        return Vec::new();
    };
    mapped.filter_map(Result::ok).flatten().collect()
}

fn message_info(id: String, data: &Map<String, Value>, row_time: i64) -> MessageInfo {
    let time = data.get("time").and_then(Value::as_object);
    let tokens = data.get("tokens").and_then(Value::as_object);
    let error = match data.get("error") {
        Some(Value::String(text)) if !text.is_empty() => Some(text.clone()),
        Some(Value::Object(dict)) => map_str(dict, "message").or_else(|| map_str(dict, "name")),
        _ => None,
    };
    MessageInfo {
        id,
        role: map_str(data, "role").unwrap_or_default(),
        created: time
            .and_then(|time| as_i64(time.get("created")))
            .unwrap_or(row_time),
        completed: time.and_then(|time| as_i64(time.get("completed"))),
        finish: map_str(data, "finish").unwrap_or_default(),
        tokens: tokens
            .and_then(|tokens| as_i64(tokens.get("total")))
            .unwrap_or(0),
        cost: as_f64(data.get("cost")).unwrap_or(0.0),
        error,
    }
}

fn scalar_i64(conn: &Connection, sql: &str, args: impl Params) -> i64 {
    conn.query_row(sql, args, |row| row.get::<_, Option<i64>>(0))
        .ok()
        .flatten()
        .unwrap_or(0)
}

fn today_aggregate(conn: &Connection, session_id: &str, since: i64) -> TodayAggregate {
    conn.query_row(SQL_TODAY_AGGREGATE, params![session_id, since], |row| {
        Ok(TodayAggregate {
            calls: row.get::<_, Option<i64>>(0)?.unwrap_or(0),
            tokens: row.get::<_, Option<i64>>(1)?.unwrap_or(0),
            cost: row.get::<_, Option<f64>>(2)?.unwrap_or(0.0),
        })
    })
    .unwrap_or_default()
}

fn col_i64(row: &Row<'_>, index: usize) -> Option<i64> {
    match row.get_ref(index).ok()? {
        ValueRef::Integer(value) => Some(value),
        ValueRef::Real(value) => Some(value as i64),
        ValueRef::Text(bytes) => std::str::from_utf8(bytes).ok()?.trim().parse::<i64>().ok(),
        _ => None,
    }
}

fn col_f64(row: &Row<'_>, index: usize) -> Option<f64> {
    match row.get_ref(index).ok()? {
        ValueRef::Integer(value) => Some(value as f64),
        ValueRef::Real(value) => Some(value),
        ValueRef::Text(bytes) => std::str::from_utf8(bytes).ok()?.trim().parse::<f64>().ok(),
        _ => None,
    }
}

fn col_text(row: &Row<'_>, index: usize) -> Option<String> {
    match row.get_ref(index).ok()? {
        ValueRef::Text(bytes) => Some(String::from_utf8_lossy(bytes).to_string()),
        _ => None,
    }
}

// MARK: - Mapping helpers

fn map_str(map: &Map<String, Value>, key: &str) -> Option<String> {
    map.get(key).and_then(Value::as_str).map(str::to_string)
}

fn clean_title(raw: &str) -> String {
    let title = raw.trim();
    if title.is_empty() {
        return String::new();
    }
    if title.starts_with("New session - ") || title == "Untitled" {
        return String::new();
    }
    title.to_string()
}

fn short_tail(value: &str, limit: usize) -> String {
    tail(&value.replace('\n', " "), limit)
}

fn tool_field(input: Option<&Map<String, Value>>, keys: &[&str]) -> Option<String> {
    let input = input?;
    for key in keys {
        if let Some(value) = input.get(*key).and_then(Value::as_str) {
            if !value.is_empty() {
                return Some(value.to_string());
            }
        }
    }
    None
}

fn describe_tool(part: &PartInfo) -> Option<(String, Option<String>)> {
    let data = &part.data;
    let name = map_str(data, "tool")
        .or_else(|| map_str(data, "name"))
        .unwrap_or_else(|| "tool".to_string());
    let state = data.get("state").and_then(Value::as_object);
    let input = state
        .and_then(|state| state.get("input"))
        .and_then(Value::as_object)
        .or_else(|| data.get("input").and_then(Value::as_object));
    let status = state
        .and_then(|state| state.get("status"))
        .and_then(Value::as_str)
        .or_else(|| data.get("status").and_then(Value::as_str))
        .unwrap_or("")
        .to_lowercase();

    let lower = name.to_lowercase();
    let (action, detail) = match lower.as_str() {
        "bash" | "shell" => (
            "跑命令".to_string(),
            tool_field(input, &["description", "command"]).map(|value| short_tail(&value, 38)),
        ),
        "read" => (
            "读文件".to_string(),
            tool_field(input, &["filePath", "file_path", "path"]).map(|path| base_name(&path)),
        ),
        "write" => (
            "写文件".to_string(),
            tool_field(input, &["filePath", "file_path", "path"]).map(|path| base_name(&path)),
        ),
        "edit" | "patch" => (
            "改代码".to_string(),
            tool_field(input, &["filePath", "file_path", "path"]).map(|path| base_name(&path)),
        ),
        "grep" => (
            "搜代码".to_string(),
            tool_field(input, &["pattern", "query"]).map(|value| short_tail(&value, 38)),
        ),
        "glob" => (
            "找文件".to_string(),
            tool_field(input, &["pattern"]).map(|value| short_tail(&value, 38)),
        ),
        "webfetch" | "web_fetch" => (
            "看网页".to_string(),
            tool_field(input, &["url"]).and_then(|url| url_host(&url)),
        ),
        "task" => (
            "派子代理".to_string(),
            tool_field(input, &["description"]).map(|value| short_tail(&value, 38)),
        ),
        "todowrite" | "todo_write" => (
            "写计划".to_string(),
            tool_field(input, &["content"]).map(|value| short_tail(&value, 38)),
        ),
        _ => (
            name,
            tool_field(input, &["description"]).map(|value| short_tail(&value, 38)),
        ),
    };
    let detail = if status == "error" || status == "failed" {
        Some(match detail {
            Some(detail) => format!("{detail} · 失败"),
            None => "失败了".to_string(),
        })
    } else {
        detail
    };
    Some((action, detail))
}

fn parse_permission(raw: Option<&str>, session_id: &str, since: i64) -> Option<ApprovalRequest> {
    let text = raw?;
    if text.is_empty() {
        return None;
    }

    let mut dict: Option<Map<String, Value>> = None;
    if let Ok(value) = serde_json::from_str::<Value>(text) {
        match value {
            Value::Object(map) => dict = Some(map),
            Value::Array(mut items) => {
                if let Some(Value::Object(map)) = items.drain(..).next() {
                    dict = Some(map);
                }
            }
            _ => {}
        }
    }

    let Some(dict) = dict else {
        // Plain tool name rather than a JSON payload.
        return Some(ApprovalRequest {
            id: session_id.to_string(),
            tool: text.to_string(),
            reason: String::new(),
            since,
        });
    };
    if dict.is_empty() {
        return None;
    }

    let tool = map_str(&dict, "title")
        .or_else(|| map_str(&dict, "permission"))
        .or_else(|| map_str(&dict, "type"))
        .or_else(|| map_str(&dict, "action"))
        .unwrap_or_else(|| "操作".to_string());
    let reason = map_str(&dict, "description")
        .or_else(|| map_str(&dict, "resource"))
        .or_else(|| map_str(&dict, "pattern"))
        .unwrap_or_default();
    let id = map_str(&dict, "id").unwrap_or_else(|| session_id.to_string());
    Some(ApprovalRequest {
        id,
        tool,
        reason,
        since,
    })
}

// MARK: - Quota cache lock

fn lock_quotas(state: &Mutex<QuotaState>) -> MutexGuard<'_, QuotaState> {
    state
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

// MARK: - OpenCode Go quota

/// Fetches OpenCode Go plan usage.
///
/// OpenCode stores the Go subscription flag and session cost locally, but the
/// 5h / week / month meters are only rendered by the web console. The console
/// exposes a read-only usage endpoint that accepts the same account token the
/// CLI already stores in `opencode.db`. We use it at most once every two
/// minutes, and only when the account is actually on a Go plan.
///
/// The 5h window is a rolling window here (OpenCode measures from first use),
/// and the month window is the last 30 days (the paid period can start on any
/// day). They are intentionally approximate; the week window uses the UTC
/// calendar week (Monday first), which matches OpenCode's `utcCalendarWeek`.
pub struct OpenCodeQuotaReader {
    database_url: PathBuf,
    plan: String,
    log: Option<LogFn>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct GoPlan {
    label: &'static str,
    five_hour: i64,
    week: i64,
    month: i64,
}

fn plan_limits(plan: &str) -> GoPlan {
    if plan.to_lowercase().contains("plus") {
        return GoPlan {
            label: "Go+",
            five_hour: 48 * QUOTA_MICRO_CENTS_PER_DOLLAR,
            week: 120 * QUOTA_MICRO_CENTS_PER_DOLLAR,
            month: 240 * QUOTA_MICRO_CENTS_PER_DOLLAR,
        };
    }
    GoPlan {
        label: "Go",
        five_hour: 12 * QUOTA_MICRO_CENTS_PER_DOLLAR,
        week: 30 * QUOTA_MICRO_CENTS_PER_DOLLAR,
        month: 60 * QUOTA_MICRO_CENTS_PER_DOLLAR,
    }
}

fn quota_percent(used: i64, limit: i64) -> i64 {
    if limit <= 0 {
        return 0;
    }
    let raw = ((used as f64) / (limit as f64) * 100.0).round();
    raw.clamp(0.0, 999.0) as i64
}

fn iso_millis(ms: i64) -> String {
    Utc.timestamp_millis_opt(ms)
        .single()
        .map(|date| date.to_rfc3339_opts(SecondsFormat::Millis, true))
        .unwrap_or_else(|| "1970-01-01T00:00:00.000Z".to_string())
}

fn http_agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(8))
        .timeout_read(Duration::from_secs(8))
        .build()
}

impl OpenCodeQuotaReader {
    pub fn new(
        database_url: impl Into<PathBuf>,
        plan: impl Into<String>,
        log: Option<LogFn>,
    ) -> Self {
        Self {
            database_url: database_url.into(),
            plan: plan.into(),
            log,
        }
    }

    /// Blocking variant, run by the provider's background thread and available
    /// to a `--dump-opencode-quota` diagnostic.
    pub fn fetch_sync(&self, now: i64) -> Vec<UsageQuota> {
        let Some((token, org)) = self.credentials() else {
            self.log_line("opencode quota: no active account");
            return Vec::new();
        };

        let agent = http_agent();
        let current_url = format!("{QUOTA_BASE}/orgs/current");
        let current = self.get_json(&agent, &current_url, &token, &org);
        let has_go = current
            .as_ref()
            .and_then(|value| value.get("hasGoSubscription"))
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if !has_go {
            self.log_line("opencode quota: no Go subscription");
            return Vec::new();
        }

        let plan = plan_limits(&self.plan);
        let week_start = utc_week_start_ms(now);
        let windows: [(&str, i64, i64); 3] = [
            ("5h", now - 5 * 3600 * 1000, plan.five_hour),
            ("周", week_start, plan.week),
            ("月", now - 30 * 24 * 3600 * 1000, plan.month),
        ];

        let mut quotas: Vec<UsageQuota> = Vec::new();
        for (label, since, limit) in windows {
            let Some(used) = self.used_micro_cents(&agent, since, &token, &org) else {
                continue;
            };
            self.log_line(format!("opencode quota {label} used={used} limit={limit}"));
            let percent = quota_percent(used, limit);
            let resets_at = match label {
                "5h" => now + 5 * 3600 * 1000,
                "周" => week_start + 7 * 24 * 3600 * 1000,
                _ => now + 30 * 24 * 3600 * 1000,
            };
            quotas.push(UsageQuota {
                provider: plan.label.to_string(),
                window: label.to_string(),
                percent,
                resets_at: Some(resets_at),
                sampled_at: Some(now),
            });
        }
        self.log_line(format!(
            "opencode quota: {}",
            quotas
                .iter()
                .map(UsageQuota::label)
                .collect::<Vec<_>>()
                .join(", ")
        ));
        quotas
    }

    // MARK: HTTP

    fn used_micro_cents(
        &self,
        agent: &ureq::Agent,
        since: i64,
        token: &str,
        org: &str,
    ) -> Option<i64> {
        let url = format!("{QUOTA_BASE}/usage/summary?since={}", iso_millis(since));
        let json = self.get_json(agent, &url, token, org)?;
        as_i64(json.get("totalCostMicroCents"))
    }

    fn get_json(&self, agent: &ureq::Agent, url: &str, token: &str, org: &str) -> Option<Value> {
        let response = agent
            .get(url)
            .set("Authorization", &format!("Bearer {token}"))
            .set("x-org-id", org)
            .set("Accept", "application/json")
            .set("User-Agent", "whalegirl-openquote/1.0")
            .call();
        match response {
            Ok(response) => match response.into_json::<Value>() {
                Ok(value) => Some(value),
                Err(error) => {
                    self.log_line(format!("opencode quota: invalid response: {error}"));
                    None
                }
            },
            Err(error) => {
                self.log_line(format!("opencode quota: request failed: {error}"));
                None
            }
        }
    }

    // MARK: Account

    fn credentials(&self) -> Option<(String, String)> {
        let conn = open_read_only(&self.database_url)?;
        let (token, org) = conn
            .query_row(SQL_CREDENTIALS, NO_PARAMS, |row| {
                Ok((col_text(row, 0), col_text(row, 1)))
            })
            .ok()?;
        let token = token.filter(|token| !token.is_empty())?;
        let org = org.filter(|org| !org.is_empty())?;
        Some((token, org))
    }

    fn log_line(&self, message: impl AsRef<str>) {
        if let Some(log) = &self.log {
            log(message.as_ref());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::SessionPhase;
    use crate::paths::WgPaths;
    use chrono::{Local, TimeZone};
    use rusqlite::params;
    use serde_json::json;

    fn test_now() -> i64 {
        Local
            .with_ymd_and_hms(2026, 10, 26, 12, 0, 0)
            .single()
            .expect("valid local noon")
            .timestamp_millis()
    }

    fn fixture_provider(db_path: &Path, home: &Path) -> OpenCodeProvider {
        let ctx = ProviderContext::new(WgPaths::with_home(home));
        OpenCodeProvider::new(ctx)
            .with_config(OpenCodeConfig {
                fetch_quotas: false,
                ..OpenCodeConfig::default()
            })
            .with_database(db_path)
    }

    fn create_schema(conn: &Connection) {
        conn.execute_batch(
            "CREATE TABLE session (
                 id TEXT PRIMARY KEY,
                 title TEXT,
                 directory TEXT,
                 model TEXT,
                 agent TEXT,
                 cost REAL,
                 tokens_input INTEGER,
                 tokens_output INTEGER,
                 tokens_reasoning INTEGER,
                 tokens_cache_read INTEGER,
                 tokens_cache_write INTEGER,
                 time_created INTEGER,
                 time_updated INTEGER,
                 time_compacting INTEGER,
                 time_archived INTEGER,
                 permission TEXT
             );
             CREATE TABLE message (
                 id TEXT PRIMARY KEY,
                 session_id TEXT,
                 data TEXT,
                 time_created INTEGER
             );
             CREATE TABLE part (
                 id TEXT PRIMARY KEY,
                 session_id TEXT,
                 message_id TEXT,
                 data TEXT,
                 time_created INTEGER
             );",
        )
        .unwrap();
    }

    fn insert_session(
        conn: &Connection,
        id: &str,
        title: &str,
        directory: &str,
        cost: f64,
        tokens: [i64; 5],
        created: i64,
        updated: i64,
    ) {
        conn.execute(
            "INSERT INTO session (id, title, directory, model, agent, cost,
                 tokens_input, tokens_output, tokens_reasoning, tokens_cache_read,
                 tokens_cache_write, time_created, time_updated, time_compacting,
                 time_archived, permission)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, 0, NULL, NULL)",
            params![
                id,
                title,
                directory,
                "claude-sonnet-4",
                "build",
                cost,
                tokens[0],
                tokens[1],
                tokens[2],
                tokens[3],
                tokens[4],
                created,
                updated,
            ],
        )
        .unwrap();
    }

    fn insert_message(conn: &Connection, id: &str, session: &str, data: Value, created: i64) {
        conn.execute(
            "INSERT INTO message (id, session_id, data, time_created) VALUES (?1, ?2, ?3, ?4)",
            params![id, session, data.to_string(), created],
        )
        .unwrap();
    }

    fn insert_part(
        conn: &Connection,
        id: &str,
        session: &str,
        message: &str,
        data: Value,
        created: i64,
    ) {
        conn.execute(
            "INSERT INTO part (id, session_id, message_id, data, time_created) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![id, session, message, data.to_string(), created],
        )
        .unwrap();
    }

    /// One finished session with a placeholder title and one running session.
    fn write_fixture(db_path: &Path, now: i64) {
        let conn = Connection::open(db_path).unwrap();
        create_schema(&conn);

        let done_created = now - 3_600_000;
        let done_updated = now - 1_800_000;
        insert_session(
            &conn,
            "ses_done",
            "New session - 2026-10-26T03:59:00.000Z",
            "/tmp/demo",
            0.42,
            [100, 50, 10, 5, 5],
            done_created,
            done_updated,
        );
        let user_created = now - 3_590_000;
        let assistant_created = now - 3_500_000;
        insert_message(
            &conn,
            "msg_u1",
            "ses_done",
            json!({"role": "user", "time": {"created": user_created}}),
            user_created,
        );
        insert_message(
            &conn,
            "msg_a1",
            "ses_done",
            json!({
                "role": "assistant",
                "time": {"created": assistant_created, "completed": now - 3_400_000},
                "finish": "stop",
                "tokens": {"total": 900},
                "cost": 0.42
            }),
            assistant_created,
        );
        insert_part(
            &conn,
            "prt_u1",
            "ses_done",
            "msg_u1",
            json!({"type": "text", "text": "你好"}),
            user_created,
        );
        insert_part(
            &conn,
            "prt_a1",
            "ses_done",
            "msg_a1",
            json!({"type": "text", "text": "搞定"}),
            assistant_created,
        );

        let live_created = now - 26 * 3_600_000;
        let live_updated = now - 60_000;
        insert_session(
            &conn,
            "ses_live",
            "修复登录",
            "/tmp/demo2",
            0.5,
            [0, 0, 0, 0, 0],
            live_created,
            live_updated,
        );
        let live_user = now - 120_000;
        let live_assistant = now - 100_000;
        insert_message(
            &conn,
            "msg_u2",
            "ses_live",
            json!({"role": "user", "time": {"created": live_user}}),
            live_user,
        );
        insert_message(
            &conn,
            "msg_a2",
            "ses_live",
            json!({
                "role": "assistant",
                "time": {"created": live_assistant},
                "tokens": {"total": 1234},
                "cost": 0.5
            }),
            live_assistant,
        );
        insert_part(
            &conn,
            "prt_t1",
            "ses_live",
            "msg_a2",
            json!({
                "type": "tool",
                "tool": "read",
                "state": {"status": "running", "input": {"filePath": "/tmp/demo2/src/main.rs"}}
            }),
            live_assistant - 5_000,
        );
    }

    #[test]
    fn maps_sessions_turn_state_and_titles() {
        let home = tempfile::tempdir().unwrap();
        let db_path = home.path().join("opencode.db");
        let now = test_now();
        write_fixture(&db_path, now);
        let provider = fixture_provider(&db_path, home.path());
        let day_start = day_start_ms(now);

        let db = open_read_only(&db_path).unwrap();
        let rows = load_session_rows(&db, now - RECENT_WINDOW_MS, 40);
        assert_eq!(rows.len(), 2);

        let done_row = rows.iter().find(|row| row.id == "ses_done").unwrap();
        let done = provider.build_entry(done_row, &db, now, day_start);
        assert_eq!(done.snapshot.title, "", "placeholder titles are hidden");
        assert_eq!(done.snapshot.workspace_name, "demo");
        assert!(!done.snapshot.turn_active);
        assert_eq!(done.snapshot.last_completed_at, Some(now - 3_400_000));
        assert_eq!(done.snapshot.turn_number, 1);
        assert_eq!(done.snapshot.step_number, 0);
        assert_eq!(done.snapshot.tokens_this_turn, 900);
        assert_eq!(done.snapshot.last_user_text.as_deref(), Some("你好"));
        assert_eq!(done.snapshot.last_assistant_text.as_deref(), Some("搞定"));
        assert_eq!(done.snapshot.last_event_type, "message/assistant");
        assert_eq!(done.snapshot.last_event_at, now - 1_800_000);
        assert_eq!(done.tokens_today, 170);
        assert_eq!(done.calls_today, 1);
        assert!((done.cost_today - 0.42).abs() < 1e-9);

        let live_row = rows.iter().find(|row| row.id == "ses_live").unwrap();
        let live = provider.build_entry(live_row, &db, now, day_start);
        assert_eq!(live.snapshot.title, "修复登录");
        assert_eq!(live.snapshot.workspace_name, "demo2");
        assert!(live.snapshot.turn_active);
        assert_eq!(live.snapshot.last_completed_at, None);
        assert_eq!(live.snapshot.last_tool_name.as_deref(), Some("读文件"));
        assert_eq!(live.snapshot.last_tool_detail.as_deref(), Some("main.rs"));
        assert_eq!(live.snapshot.turn_started_at, Some(now - 120_000));
        assert_eq!(live.snapshot.step_number, 1);
        assert_eq!(live.snapshot.tokens_this_turn, 1234);
        // Created yesterday, so today's numbers come from the message rows.
        assert_eq!(live.tokens_today, 1234);
        assert_eq!(live.calls_today, 1);
        assert!((live.cost_today - 0.5).abs() < 1e-9);

        drop(db);

        let mut provider = provider;
        let status = provider.refresh(now);
        assert_eq!(status.id, "opencode");
        assert_eq!(status.name, "OpenCode");
        assert_eq!(status.short_name, "OpenCode");
        assert!(status.watch_path.is_some());
        assert!(status.running);
        assert_eq!(status.sessions.len(), 2);
        assert_eq!(status.sessions[0].id, "ses_live");
        assert_eq!(status.sessions[0].phase, SessionPhase::Working);
        assert_eq!(status.sessions[1].id, "ses_done");
        assert_eq!(status.sessions[1].phase, SessionPhase::Idle);

        let usage = status.usage.as_ref().expect("usage block");
        assert!(usage.quotas.is_empty());
        assert_eq!(usage.source_label.as_deref(), Some(DB_SOURCE_LABEL));
        let today = usage.today.as_ref().expect("today totals");
        assert_eq!(today.tokens, Some(1404));
        assert_eq!(today.calls, Some(2));
        assert_eq!(today.cost_cny, None);
        assert!((today.cost_usd.unwrap() - 0.92).abs() < 1e-9);

        // A missing database must degrade to an empty, non-running status.
        let missing = home.path().join("missing.db");
        let mut empty_provider =
            OpenCodeProvider::new(ProviderContext::new(WgPaths::with_home(home.path())))
                .with_config(OpenCodeConfig {
                    fetch_quotas: false,
                    ..OpenCodeConfig::default()
                })
                .with_database(missing.as_path());
        let empty = empty_provider.refresh(now);
        assert!(empty.sessions.is_empty());
        assert!(empty.usage.is_none());
        assert!(!empty.running);
    }

    #[test]
    fn selects_go_and_go_plus_limits() {
        let go = plan_limits("go");
        assert_eq!(go.label, "Go");
        assert_eq!(go.five_hour, 12 * QUOTA_MICRO_CENTS_PER_DOLLAR);
        assert_eq!(go.week, 30 * QUOTA_MICRO_CENTS_PER_DOLLAR);
        assert_eq!(go.month, 60 * QUOTA_MICRO_CENTS_PER_DOLLAR);

        let plus = plan_limits("go-plus");
        assert_eq!(plus.label, "Go+");
        assert_eq!(plus.five_hour, 48 * QUOTA_MICRO_CENTS_PER_DOLLAR);
        assert_eq!(plus.week, 120 * QUOTA_MICRO_CENTS_PER_DOLLAR);
        assert_eq!(plus.month, 240 * QUOTA_MICRO_CENTS_PER_DOLLAR);

        assert_eq!(quota_percent(600_000_000, 1_200_000_000), 50);
        assert_eq!(quota_percent(1_200_000_000, 1_200_000_000), 100);
        assert_eq!(quota_percent(10, 1), 999);
        assert_eq!(quota_percent(0, 0), 0);
    }

    #[test]
    fn parses_permissions_and_tool_parts() {
        let approval = parse_permission(
            Some(r#"{"title":"Bash","description":"rm -rf /tmp/x","id":"perm-1"}"#),
            "ses_1",
            1_700_000_000_000,
        )
        .expect("json permission");
        assert_eq!(approval.id, "perm-1");
        assert_eq!(approval.tool, "Bash");
        assert_eq!(approval.reason, "rm -rf /tmp/x");
        assert_eq!(approval.since, 1_700_000_000_000);

        assert!(parse_permission(None, "ses_1", 1).is_none());
        assert!(parse_permission(Some(""), "ses_1", 1).is_none());

        let plain = parse_permission(Some("Write"), "ses_1", 7).expect("plain tool name");
        assert_eq!(plain.tool, "Write");
        assert_eq!(plain.id, "ses_1");
        assert_eq!(plain.reason, "");

        let listed = parse_permission(Some(r#"[{"permission":"Edit"}]"#), "ses_1", 7)
            .expect("array permission");
        assert_eq!(listed.tool, "Edit");

        let data = json!({
            "tool": "bash",
            "state": {"status": "error", "input": {"description": "ls\n-la"}}
        });
        let part = PartInfo {
            message_id: "m1".to_string(),
            created: 5,
            kind: "tool".to_string(),
            data: data.as_object().unwrap().clone(),
        };
        let (action, detail) = describe_tool(&part).unwrap();
        assert_eq!(action, "跑命令");
        assert_eq!(detail.as_deref(), Some("ls -la · 失败"));

        let data = json!({
            "type": "tool",
            "tool": "webfetch",
            "state": {"input": {"url": "https://opencode.ai/docs"}}
        });
        let part = PartInfo {
            message_id: "m1".to_string(),
            created: 5,
            kind: "tool".to_string(),
            data: data.as_object().unwrap().clone(),
        };
        assert_eq!(
            describe_tool(&part).unwrap(),
            ("看网页".to_string(), Some("opencode.ai".to_string()))
        );
    }
}

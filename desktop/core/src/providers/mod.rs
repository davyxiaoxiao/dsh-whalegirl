//! Agent adapters and the single registry where new agents are plugged in.

use std::sync::Arc;

use crate::models::{AgentSession, Capabilities, ProviderStatus};
use crate::paths::WgPaths;

pub mod codex;
pub mod dsh;
pub mod opencode;

pub type LogFn = Arc<dyn Fn(&str) + Send + Sync>;

#[derive(Clone)]
pub struct ProviderContext {
    pub paths: WgPaths,
    pub log: Option<LogFn>,
    pub opencode_fetch_quotas: bool,
    pub opencode_plan: String,
    pub opencode_quotas_opt_out: bool,
}

impl ProviderContext {
    pub fn new(paths: WgPaths) -> Self {
        Self {
            paths,
            log: None,
            opencode_fetch_quotas: true,
            opencode_plan: "go".to_string(),
            opencode_quotas_opt_out: false,
        }
    }

    pub fn log(&self, message: impl AsRef<str>) {
        if let Some(log) = &self.log {
            log(message.as_ref());
        }
    }
}

/// One monitored coding agent.
///
/// An adapter owns everything agent-specific: where logs live, how to detect a
/// running app, how to translate events into `AgentSession`, and where cost
/// data comes from. The monitor and UI only see `ProviderStatus` / `FleetView`.
pub trait AgentProvider: Send {
    fn id(&self) -> &'static str;
    fn display_name(&self) -> &'static str;
    fn short_name(&self) -> &'static str;
    fn watch_path(&self) -> Option<String>;
    fn capabilities(&self) -> Capabilities;

    /// Called from the monitor thread every poll interval. Must stay cheap.
    fn refresh(&mut self, now: i64) -> ProviderStatus;

    /// True when this adapter can jump to one of its sessions.
    fn supports_session_jump(&self) -> bool {
        self.capabilities().contains(Capabilities::SESSION_JUMP)
    }

    /// Optional one-off diagnostic payload for `wg-dump`.
    fn note(&self) -> Option<String> {
        None
    }
}

/// The single place to plug a new agent in.
pub fn default_providers(ctx: &ProviderContext) -> Vec<Box<dyn AgentProvider>> {
    vec![
        Box::new(dsh::DSHProvider::new(ctx.clone())),
        Box::new(codex::CodexProvider::new(ctx.clone())),
        Box::new(opencode::OpenCodeProvider::new(ctx.clone())),
    ]
}

/// Stamp provider identity on sessions a adapter forgot to fill in.
pub fn stamp_sessions(status: &mut ProviderStatus) {
    for session in &mut status.sessions {
        if session.provider_id.is_empty() {
            session.provider_id = status.id.clone();
        }
        if session.provider_name.is_empty() {
            session.provider_name = status.short_name.clone();
        }
    }
}

/// Sorted, capped session list shared by every file-based adapter.
pub fn finish_sessions(sessions: &mut Vec<AgentSession>, max: usize) {
    sessions.sort_by(|a, b| b.last_event_at.cmp(&a.last_event_at));
    sessions.truncate(max);
}

/// Union helper for a zstd/JSON tail event field.
pub fn event_obj<'a>(
    event: &'a serde_json::Value,
) -> &'a serde_json::Map<String, serde_json::Value> {
    event
        .get("data")
        .and_then(serde_json::Value::as_object)
        .unwrap_or_else(|| empty_object())
}

fn empty_object() -> &'static serde_json::Map<String, serde_json::Value> {
    use std::sync::OnceLock;
    static EMPTY: OnceLock<serde_json::Map<String, serde_json::Value>> = OnceLock::new();
    EMPTY.get_or_init(serde_json::Map::new)
}

/// Host part of a URL without pulling in a URL parser.
pub fn url_host(raw: &str) -> Option<String> {
    let rest = raw
        .strip_prefix("https://")
        .or_else(|| raw.strip_prefix("http://"))
        .unwrap_or(raw);
    let host = rest.split(['/', '?', '#']).next()?;
    let host = host.rsplit('@').next()?;
    if host.is_empty() {
        None
    } else {
        Some(host.to_string())
    }
}

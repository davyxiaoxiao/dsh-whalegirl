//! Provider-neutral data model shared by every adapter, the monitor and the UI.
//!
//! The shape mirrors the original Swift `AgentModels.swift`: adapters only fill
//! raw session fields, the monitor stamps provider identity, and `FleetView` is
//! the single snapshot the frontend consumes.

use serde::Serialize;

use crate::format::{compact_tokens, tail};

pub const RECENT_WINDOW_MS: i64 = 7 * 24 * 3600 * 1000;

// MARK: - Session primitives

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ApprovalRequest {
    pub id: String,
    pub tool: String,
    pub reason: String,
    /// Epoch milliseconds.
    pub since: i64,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JobInfo {
    pub id: String,
    pub label: String,
    pub kind: String,
    pub started_at: i64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum SessionPhase {
    #[default]
    Idle,
    Working,
    Waiting,
    Stalled,
    Done,
    Error,
}

impl SessionPhase {
    /// Lower rank sorts first on the task board.
    pub fn rank(self) -> u8 {
        match self {
            SessionPhase::Waiting => 0,
            SessionPhase::Working => 1,
            SessionPhase::Stalled => 2,
            SessionPhase::Error => 3,
            SessionPhase::Done => 4,
            SessionPhase::Idle => 5,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PetMood {
    #[default]
    Idle,
    Working,
    Waiting,
    Happy,
    Panic,
    Sleeping,
    Offline,
}

impl PetMood {
    pub fn title(self) -> &'static str {
        match self {
            PetMood::Offline => "断连",
            PetMood::Sleeping => "呼呼大睡",
            PetMood::Idle => "待命中",
            PetMood::Working => "干饭中",
            PetMood::Waiting => "等你确认",
            PetMood::Happy => "完成啦",
            PetMood::Panic => "出错了",
        }
    }
}

/// One monitored agent session. All timestamps are epoch milliseconds.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentSession {
    pub id: String,
    pub provider_id: String,
    pub provider_name: String,
    pub directory: String,
    pub log_path: String,

    pub title: String,
    pub cwd: String,
    pub workspace_name: String,
    pub created_at: Option<i64>,
    pub last_event_at: i64,
    pub file_modified_at: i64,

    pub turn_active: bool,
    pub turn_started_at: Option<i64>,
    pub task_started_at: Option<i64>,
    pub turn_number: i64,
    pub step_number: i64,
    pub last_turn_errored: bool,
    pub last_error_text: Option<String>,
    pub last_completed_at: Option<i64>,
    pub last_error_at: Option<i64>,
    pub pending_approval: Option<ApprovalRequest>,
    pub last_tool_name: Option<String>,
    pub last_tool_detail: Option<String>,
    pub last_tool_started_at: Option<i64>,
    pub last_assistant_text: Option<String>,
    pub last_user_text: Option<String>,
    pub tokens_this_turn: i64,
    pub running_jobs: Vec<JobInfo>,
    pub deliverables: Vec<String>,
    pub last_event_type: String,
    pub is_archived: bool,
    pub phase: SessionPhase,
}

impl AgentSession {
    pub fn new(
        id: impl Into<String>,
        directory: impl Into<String>,
        log_path: impl Into<String>,
        title: impl Into<String>,
        cwd: impl Into<String>,
        workspace_name: impl Into<String>,
        created_at: Option<i64>,
        last_event_at: i64,
        file_modified_at: i64,
    ) -> Self {
        Self {
            id: id.into(),
            provider_id: String::new(),
            provider_name: String::new(),
            directory: directory.into(),
            log_path: log_path.into(),
            title: title.into(),
            cwd: cwd.into(),
            workspace_name: workspace_name.into(),
            created_at,
            last_event_at,
            file_modified_at,
            turn_active: false,
            turn_started_at: None,
            task_started_at: None,
            turn_number: 0,
            step_number: 0,
            last_turn_errored: false,
            last_error_text: None,
            last_completed_at: None,
            last_error_at: None,
            pending_approval: None,
            last_tool_name: None,
            last_tool_detail: None,
            last_tool_started_at: None,
            last_assistant_text: None,
            last_user_text: None,
            tokens_this_turn: 0,
            running_jobs: Vec::new(),
            deliverables: Vec::new(),
            last_event_type: String::new(),
            is_archived: false,
            phase: SessionPhase::Idle,
        }
    }

    pub fn uid(&self) -> String {
        format!("{}/{}", self.provider_id, self.id)
    }

    pub fn display_title(&self) -> String {
        let title = self.title.trim();
        if !title.is_empty() {
            return title.to_string();
        }
        if let Some(text) = self.last_user_text.as_deref() {
            let text = text.replace('\n', " ");
            let text = text.trim();
            if !text.is_empty() {
                return tail(text, 42);
            }
        }
        self.workspace_name.clone()
    }

    pub fn short_id(&self) -> String {
        let stripped = self.id.replace("session-", "");
        stripped.chars().take(8).collect()
    }

    pub fn action_line(&self) -> Option<String> {
        if let Some(approval) = &self.pending_approval {
            return Some(format!("等待确认 {}", approval.tool));
        }
        if let Some(tool) = &self.last_tool_name {
            if let Some(detail) = &self.last_tool_detail {
                if !detail.is_empty() {
                    return Some(format!("{tool} · {detail}"));
                }
            }
            return Some(tool.clone());
        }
        self.last_assistant_text.clone()
    }

    pub fn elapsed_ms(&self, now: i64) -> i64 {
        if self.turn_active {
            if let Some(task) = self.task_started_at {
                if task <= self.last_event_at {
                    return (now - task).max(0);
                }
            }
            if let Some(started) = self.turn_started_at {
                return (now - started).max(0);
            }
            return 0;
        }
        if let Some(ended) = self.last_completed_at {
            let start = self
                .task_started_at
                .or(self.turn_started_at)
                .unwrap_or(ended);
            return (ended - start).max(0);
        }
        0
    }

    pub fn age_ms(&self, now: i64) -> i64 {
        (now - self.last_event_at).max(0)
    }

    pub fn is_live(&self, now: i64) -> bool {
        now - self.last_event_at < 120_000
    }

    pub fn derive_phase(&mut self, now: i64) {
        if self.pending_approval.is_some() && self.turn_active {
            self.phase = SessionPhase::Waiting;
            return;
        }
        if self.turn_active {
            if !self.running_jobs.is_empty() {
                self.phase = SessionPhase::Working;
            } else if now - self.last_event_at > 360_000 {
                self.phase = SessionPhase::Stalled;
            } else {
                self.phase = SessionPhase::Working;
            }
            return;
        }
        if let Some(error_at) = self.last_error_at {
            if now - error_at < 180_000 {
                self.phase = SessionPhase::Error;
                return;
            }
        }
        if let Some(done_at) = self.last_completed_at {
            if now - done_at < 120_000 && now - self.last_event_at > 1_600 {
                self.phase = SessionPhase::Done;
                return;
            }
        }
        self.phase = SessionPhase::Idle;
    }
}

// MARK: - Usage / cost

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageTotals {
    pub cost_cny: Option<f64>,
    pub cost_usd: Option<f64>,
    pub calls: Option<i64>,
    pub tokens: Option<i64>,
}

impl UsageTotals {
    pub fn is_empty(&self) -> bool {
        self.cost_cny.is_none()
            && self.cost_usd.is_none()
            && self.calls.is_none()
            && self.tokens.is_none()
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageQuota {
    pub provider: String,
    pub window: String,
    pub percent: i64,
    pub resets_at: Option<i64>,
    pub sampled_at: Option<i64>,
}

impl UsageQuota {
    pub fn label(&self) -> String {
        format!("{} {} {}%", self.provider, self.window, self.percent)
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderUsage {
    pub provider_id: String,
    pub provider_name: String,
    pub today: Option<UsageTotals>,
    pub quotas: Vec<UsageQuota>,
    pub source_label: Option<String>,
}

impl ProviderUsage {
    pub fn is_empty(&self) -> bool {
        self.today.as_ref().map(|t| t.is_empty()).unwrap_or(true) && self.quotas.is_empty()
    }
}

// MARK: - Provider status

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Capabilities(pub u8);

impl Capabilities {
    pub const SESSIONS: Capabilities = Capabilities(1 << 0);
    pub const USAGE: Capabilities = Capabilities(1 << 1);
    pub const SESSION_JUMP: Capabilities = Capabilities(1 << 2);
    pub const REVEAL: Capabilities = Capabilities(1 << 3);

    pub fn all() -> Self {
        Capabilities(Self::SESSIONS.0 | Self::USAGE.0 | Self::SESSION_JUMP.0 | Self::REVEAL.0)
    }

    pub fn contains(self, other: Capabilities) -> bool {
        self.0 & other.0 == other.0
    }

    pub fn names(self) -> Vec<&'static str> {
        let mut out = Vec::new();
        if self.contains(Self::SESSIONS) {
            out.push("sessions");
        }
        if self.contains(Self::USAGE) {
            out.push("usage");
        }
        if self.contains(Self::SESSION_JUMP) {
            out.push("sessionJump");
        }
        if self.contains(Self::REVEAL) {
            out.push("reveal");
        }
        out
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderStatus {
    pub id: String,
    pub name: String,
    pub short_name: String,
    pub running: bool,
    pub sessions: Vec<AgentSession>,
    pub usage: Option<ProviderUsage>,
    pub watch_path: Option<String>,
    #[serde(skip)]
    pub capabilities: Capabilities,
    pub updated_at: i64,
    pub note: Option<String>,
}

// MARK: - Fleet snapshot

#[derive(Clone, Debug, Default)]
pub struct FleetStatus {
    pub providers: Vec<ProviderStatus>,
    pub updated_at: i64,
}

impl FleetStatus {
    pub fn sessions(&self) -> Vec<&AgentSession> {
        self.providers
            .iter()
            .flat_map(|p| p.sessions.iter())
            .collect()
    }

    pub fn running_providers(&self) -> Vec<&ProviderStatus> {
        self.providers.iter().filter(|p| p.running).collect()
    }

    pub fn any_running(&self) -> bool {
        self.providers.iter().any(|p| p.running)
    }

    pub fn primary_provider(&self) -> Option<&ProviderStatus> {
        self.running_providers()
            .first()
            .copied()
            .or_else(|| self.providers.first())
    }

    pub fn watch_target_name(&self) -> String {
        if self.providers.len() == 1 {
            return self.providers[0].short_name.clone();
        }
        let running = self.running_providers();
        if running.len() == 1 {
            return running[0].short_name.clone();
        }
        "本地代理".to_string()
    }

    pub fn usage_sources(&self) -> Vec<&ProviderUsage> {
        self.providers
            .iter()
            .filter_map(|p| p.usage.as_ref())
            .filter(|u| !u.is_empty())
            .collect()
    }

    pub fn today_cost_cny(&self) -> Option<f64> {
        sum_option_f64(
            self.usage_sources()
                .iter()
                .filter_map(|u| u.today.as_ref()?.cost_cny),
        )
    }

    pub fn today_cost_usd(&self) -> Option<f64> {
        sum_option_f64(
            self.usage_sources()
                .iter()
                .filter_map(|u| u.today.as_ref()?.cost_usd),
        )
    }

    pub fn today_calls(&self) -> Option<i64> {
        sum_option_i64(
            self.usage_sources()
                .iter()
                .filter_map(|u| u.today.as_ref()?.calls),
        )
    }

    pub fn today_tokens(&self) -> Option<i64> {
        sum_option_i64(
            self.usage_sources()
                .iter()
                .filter_map(|u| u.today.as_ref()?.tokens),
        )
    }

    pub fn plan_quotas(&self) -> Vec<UsageQuota> {
        self.usage_sources()
            .iter()
            .flat_map(|u| u.quotas.iter().cloned())
            .collect()
    }

    /// "Go 5h 7% · Go 周 11% · Go 月 5% · 今日 83.9M tok"
    pub fn cost_line(&self, now: i64) -> String {
        let sources = self.usage_sources();
        let multi_source = sources.len() > 1;
        let depth = sources.iter().map(|u| u.quotas.len()).max().unwrap_or(0);
        let mut quotas: Vec<(UsageQuota, &ProviderUsage)> = Vec::new();
        for index in 0..depth {
            for usage in &sources {
                if let Some(quota) = usage.quotas.get(index) {
                    quotas.push((quota.clone(), usage));
                }
            }
        }
        let mut parts: Vec<String> = quotas
            .iter()
            .map(|(quota, usage)| {
                if multi_source {
                    format!("{} {}", usage.provider_name, quota.label())
                } else {
                    quota.label()
                }
            })
            .collect();
        parts.truncate(3);
        if let Some(tokens) = self.today_tokens() {
            if tokens > 0 {
                parts.push(format!("今日 {} tok", compact_tokens(tokens)));
            }
        }
        let _ = now;
        parts.join(" · ")
    }

    pub fn visible_sessions(&self) -> Vec<&AgentSession> {
        let mut sessions: Vec<&AgentSession> = self
            .sessions()
            .into_iter()
            .filter(|s| !s.is_archived)
            .collect();
        sessions.sort_by(|a, b| {
            a.phase
                .rank()
                .cmp(&b.phase.rank())
                .then_with(|| b.last_event_at.cmp(&a.last_event_at))
        });
        sessions
    }

    pub fn recent_sessions(&self, now: i64) -> Vec<&AgentSession> {
        self.visible_sessions()
            .into_iter()
            .filter(|s| s.last_event_at > now - RECENT_WINDOW_MS)
            .collect()
    }

    pub fn active_sessions(&self, now: i64) -> Vec<&AgentSession> {
        let running: Vec<&str> = self
            .running_providers()
            .iter()
            .map(|p| p.id.as_str())
            .collect();
        self.recent_sessions(now)
            .into_iter()
            .filter(|s| running.contains(&s.provider_id.as_str()))
            .collect()
    }

    pub fn working_sessions(&self, now: i64) -> Vec<&AgentSession> {
        self.recent_sessions(now)
            .into_iter()
            .filter(|s| {
                matches!(s.phase, SessionPhase::Working | SessionPhase::Stalled)
                    && s.age_ms(now) < 1_800_000
            })
            .collect()
    }

    pub fn attention_sessions(&self, now: i64) -> Vec<&AgentSession> {
        self.active_sessions(now)
            .into_iter()
            .filter(|s| s.phase == SessionPhase::Waiting)
            .collect()
    }

    pub fn error_sessions(&self, now: i64) -> Vec<&AgentSession> {
        self.recent_sessions(now)
            .into_iter()
            .filter(|s| s.phase == SessionPhase::Error)
            .collect()
    }

    pub fn done_sessions(&self, now: i64) -> Vec<&AgentSession> {
        self.recent_sessions(now)
            .into_iter()
            .filter(|s| s.phase == SessionPhase::Done)
            .collect()
    }

    pub fn mood(&self, now: i64) -> PetMood {
        if !self.any_running() {
            return PetMood::Offline;
        }
        let live = self.active_sessions(now);
        if live.iter().any(|s| s.phase == SessionPhase::Waiting) {
            return PetMood::Waiting;
        }
        if let Some(err) = live.iter().find(|s| s.phase == SessionPhase::Error) {
            let at = err.last_error_at.unwrap_or(err.last_event_at);
            if now - at < 45_000 {
                return PetMood::Panic;
            }
        }
        if live.iter().any(|s| {
            matches!(s.phase, SessionPhase::Working | SessionPhase::Stalled)
                && s.age_ms(now) < 1_800_000
        }) {
            return PetMood::Working;
        }
        if let Some(done) = live.iter().find(|s| s.phase == SessionPhase::Done) {
            let at = done.last_completed_at.unwrap_or(done.last_event_at);
            if now - at < 25_000 {
                return PetMood::Happy;
            }
        }
        if let Some(latest) = live.iter().max_by_key(|s| s.last_event_at) {
            if now - latest.last_event_at > 20 * 60 * 1000 {
                return PetMood::Sleeping;
            }
        }
        PetMood::Idle
    }

    pub fn mood_text(&self, now: i64) -> String {
        let mood = self.mood(now);
        if mood == PetMood::Offline {
            format!("{} 断连", self.watch_target_name())
        } else {
            mood.title().to_string()
        }
    }

    pub fn session_context(&self, session: &AgentSession) -> String {
        if self.providers.len() > 1 && !session.provider_name.is_empty() {
            format!("{} · {}", session.provider_name, session.workspace_name)
        } else {
            session.workspace_name.clone()
        }
    }

    pub fn headline(&self, now: i64) -> String {
        let attention = self.attention_sessions(now);
        if let Some(approval) = attention.first() {
            return format!("{} 在等你确认", self.session_context(approval));
        }
        if let Some(err) = self.error_sessions(now).first() {
            let at = err.last_error_at.unwrap_or(err.last_event_at);
            if now - at < 300_000 {
                return format!("{} 出错了", self.session_context(err));
            }
        }
        let working = self.working_sessions(now);
        if working.len() > 1 {
            return format!("{} 个任务一起游着", working.len());
        }
        if let Some(first) = working.first() {
            return match first.action_line() {
                Some(action) => format!("{}：{}", self.session_context(first), action),
                None => format!("{} 干饭中", self.session_context(first)),
            };
        }
        if let Some(done) = self.done_sessions(now).first() {
            return format!("{} 完成啦", self.session_context(done));
        }
        if !self.any_running() {
            return format!("{} 断连了", self.watch_target_name());
        }
        "在海底待命".to_string()
    }

    pub fn subtitle(&self) -> String {
        if self.providers.is_empty() {
            return "本地监控".to_string();
        }
        if self.providers.len() == 1 {
            let p = &self.providers[0];
            return format!(
                "{} · {}",
                p.name,
                if p.running {
                    "本地监控"
                } else {
                    "已断连"
                }
            );
        }
        let online = self.running_providers().len();
        if online == 0 {
            return "全部代理已断连".to_string();
        }
        format!("{}/{} 个代理在线", online, self.providers.len())
    }

    pub fn footer_text(&self) -> String {
        let jump_providers: Vec<&ProviderStatus> = self
            .providers
            .iter()
            .filter(|p| p.capabilities.contains(Capabilities::SESSION_JUMP))
            .collect();
        if !self.providers.is_empty() && jump_providers.len() == self.providers.len() {
            let names: Vec<&str> = jump_providers
                .iter()
                .map(|p| p.short_name.as_str())
                .collect();
            return format!("点击会话跳到 {} · 仅读取本地日志", names.join(" / "));
        }
        "仅读取本地日志 · 每 1.5s 刷新".to_string()
    }

    pub fn reveal_path(&self) -> Option<String> {
        self.primary_provider()
            .and_then(|p| p.watch_path.clone())
            .or_else(|| self.providers.iter().find_map(|p| p.watch_path.clone()))
    }

    pub fn to_view(&self, now: i64) -> FleetView {
        let running_ids: Vec<String> = self
            .running_providers()
            .iter()
            .map(|p| p.id.clone())
            .collect();

        let providers: Vec<ProviderView> = self
            .providers
            .iter()
            .map(|p| {
                let is_running = p.running;
                let sessions: Vec<SessionDto> = p
                    .sessions
                    .iter()
                    .map(|s| SessionDto::from_session(s, now))
                    .collect();
                let recent: Vec<&SessionDto> = sessions
                    .iter()
                    .filter(|s| !s.is_archived && s.last_event_at > now - RECENT_WINDOW_MS)
                    .collect();
                let working_count = recent
                    .iter()
                    .filter(|s| {
                        matches!(s.phase, SessionPhase::Working | SessionPhase::Stalled)
                            && now - s.last_event_at < 1_800_000
                    })
                    .count() as i64;
                let attention_count = if is_running {
                    recent
                        .iter()
                        .filter(|s| s.phase == SessionPhase::Waiting)
                        .count() as i64
                } else {
                    0
                };
                let done_count = recent
                    .iter()
                    .filter(|s| s.phase == SessionPhase::Done)
                    .count() as i64;
                let error_count = recent
                    .iter()
                    .filter(|s| s.phase == SessionPhase::Error)
                    .count() as i64;

                ProviderView {
                    id: p.id.clone(),
                    name: p.name.clone(),
                    short_name: p.short_name.clone(),
                    running: is_running,
                    watch_path: p.watch_path.clone(),
                    capabilities: p
                        .capabilities
                        .names()
                        .into_iter()
                        .map(str::to_string)
                        .collect(),
                    note: p.note.clone(),
                    usage: p.usage.clone(),
                    working_count,
                    attention_count,
                    done_count,
                    error_count,
                    session_count: sessions.len() as i64,
                    sessions,
                }
            })
            .collect();

        let sessions: Vec<SessionDto> = self
            .visible_sessions()
            .into_iter()
            .map(|s| SessionDto::from_session(s, now))
            .collect();

        let mood = self.mood(now);
        FleetView {
            providers,
            sessions,
            mood,
            mood_text: self.mood_text(now),
            headline: self.headline(now),
            subtitle: self.subtitle(),
            footer_text: self.footer_text(),
            cost_line: self.cost_line(now),
            watch_target_name: self.watch_target_name(),
            any_running: self.any_running(),
            running_provider_ids: running_ids,
            updated_at: now,
            working_count: self.working_sessions(now).len() as i64,
            attention_count: self.attention_sessions(now).len() as i64,
            done_count: self.done_sessions(now).len() as i64,
            error_count: self.error_sessions(now).len() as i64,
            today_cost_cny: self.today_cost_cny(),
            today_cost_usd: self.today_cost_usd(),
            today_tokens: self.today_tokens(),
            today_calls: self.today_calls(),
            reveal_path: self.reveal_path(),
            primary_provider_id: self.primary_provider().map(|p| p.id.clone()),
            providers_len: self.providers.len() as i64,
        }
    }
}

// MARK: - Wire DTOs

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionDto {
    pub id: String,
    pub provider_id: String,
    pub provider_name: String,
    pub directory: String,
    pub log_path: String,
    pub title: String,
    pub cwd: String,
    pub workspace_name: String,
    pub created_at: Option<i64>,
    pub last_event_at: i64,
    pub file_modified_at: i64,
    pub turn_active: bool,
    pub turn_started_at: Option<i64>,
    pub task_started_at: Option<i64>,
    pub turn_number: i64,
    pub step_number: i64,
    pub last_turn_errored: bool,
    pub last_error_text: Option<String>,
    pub last_completed_at: Option<i64>,
    pub last_error_at: Option<i64>,
    pub pending_approval: Option<ApprovalRequest>,
    pub last_tool_name: Option<String>,
    pub last_tool_detail: Option<String>,
    pub last_tool_started_at: Option<i64>,
    pub last_assistant_text: Option<String>,
    pub last_user_text: Option<String>,
    pub tokens_this_turn: i64,
    pub running_jobs: Vec<JobInfo>,
    pub deliverables: Vec<String>,
    pub last_event_type: String,
    pub is_archived: bool,
    pub phase: SessionPhase,
    pub display_title: String,
    pub short_id: String,
    pub action_line: Option<String>,
    pub elapsed_ms: i64,
    pub age_ms: i64,
    pub is_live: bool,
    pub uid: String,
}

impl SessionDto {
    fn from_session(s: &AgentSession, now: i64) -> Self {
        Self {
            id: s.id.clone(),
            provider_id: s.provider_id.clone(),
            provider_name: s.provider_name.clone(),
            directory: s.directory.clone(),
            log_path: s.log_path.clone(),
            title: s.title.clone(),
            cwd: s.cwd.clone(),
            workspace_name: s.workspace_name.clone(),
            created_at: s.created_at,
            last_event_at: s.last_event_at,
            file_modified_at: s.file_modified_at,
            turn_active: s.turn_active,
            turn_started_at: s.turn_started_at,
            task_started_at: s.task_started_at,
            turn_number: s.turn_number,
            step_number: s.step_number,
            last_turn_errored: s.last_turn_errored,
            last_error_text: s.last_error_text.clone(),
            last_completed_at: s.last_completed_at,
            last_error_at: s.last_error_at,
            pending_approval: s.pending_approval.clone(),
            last_tool_name: s.last_tool_name.clone(),
            last_tool_detail: s.last_tool_detail.clone(),
            last_tool_started_at: s.last_tool_started_at,
            last_assistant_text: s.last_assistant_text.clone(),
            last_user_text: s.last_user_text.clone(),
            tokens_this_turn: s.tokens_this_turn,
            running_jobs: s.running_jobs.clone(),
            deliverables: s.deliverables.clone(),
            last_event_type: s.last_event_type.clone(),
            is_archived: s.is_archived,
            phase: s.phase,
            display_title: s.display_title(),
            short_id: s.short_id(),
            action_line: s.action_line(),
            elapsed_ms: s.elapsed_ms(now),
            age_ms: s.age_ms(now),
            is_live: s.is_live(now),
            uid: s.uid(),
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderView {
    pub id: String,
    pub name: String,
    pub short_name: String,
    pub running: bool,
    pub watch_path: Option<String>,
    pub capabilities: Vec<String>,
    pub note: Option<String>,
    pub usage: Option<ProviderUsage>,
    pub working_count: i64,
    pub attention_count: i64,
    pub done_count: i64,
    pub error_count: i64,
    pub session_count: i64,
    pub sessions: Vec<SessionDto>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FleetView {
    pub providers: Vec<ProviderView>,
    /// Non-archived sessions sorted by phase rank then recency.
    pub sessions: Vec<SessionDto>,
    pub mood: PetMood,
    pub mood_text: String,
    pub headline: String,
    pub subtitle: String,
    pub footer_text: String,
    pub cost_line: String,
    pub watch_target_name: String,
    pub any_running: bool,
    pub running_provider_ids: Vec<String>,
    pub updated_at: i64,
    pub working_count: i64,
    pub attention_count: i64,
    pub done_count: i64,
    pub error_count: i64,
    pub today_cost_cny: Option<f64>,
    pub today_cost_usd: Option<f64>,
    pub today_tokens: Option<i64>,
    pub today_calls: Option<i64>,
    pub reveal_path: Option<String>,
    pub primary_provider_id: Option<String>,
    pub providers_len: i64,
}

// MARK: - Helpers

fn sum_option_f64<I: Iterator<Item = f64>>(values: I) -> Option<f64> {
    let v: Vec<f64> = values.collect();
    if v.is_empty() {
        None
    } else {
        Some(v.iter().sum())
    }
}

fn sum_option_i64<I: Iterator<Item = i64>>(values: I) -> Option<i64> {
    let v: Vec<i64> = values.collect();
    if v.is_empty() {
        None
    } else {
        Some(v.iter().sum())
    }
}

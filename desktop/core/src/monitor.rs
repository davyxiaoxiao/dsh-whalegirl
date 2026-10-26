//! Polls every adapter on one thread and publishes a single `FleetView`.

use crate::models::{AgentSession, FleetStatus, FleetView};
use crate::providers::{default_providers, stamp_sessions, AgentProvider, ProviderContext};

#[derive(Clone, Debug)]
pub struct MonitorConfig {
    /// Poll cadence used by the desktop shell.
    pub poll_interval_ms: u64,
    /// Final guard against an adapter that forgets to cap its own sessions.
    pub max_sessions: usize,
}

impl Default for MonitorConfig {
    fn default() -> Self {
        Self {
            poll_interval_ms: 1_500,
            max_sessions: 80,
        }
    }
}

pub struct AgentMonitor {
    providers: Vec<Box<dyn AgentProvider>>,
    config: MonitorConfig,
    paused: bool,
    last: Option<FleetView>,
}

impl AgentMonitor {
    pub fn new(ctx: &ProviderContext) -> Self {
        Self {
            providers: default_providers(ctx),
            config: MonitorConfig::default(),
            paused: false,
            last: None,
        }
    }

    pub fn with_config(mut self, config: MonitorConfig) -> Self {
        self.config = config;
        self
    }

    pub fn provider_ids(&self) -> Vec<&'static str> {
        self.providers.iter().map(|p| p.id()).collect()
    }

    pub fn set_paused(&mut self, paused: bool) {
        self.paused = paused;
    }

    pub fn is_paused(&self) -> bool {
        self.paused
    }

    pub fn last(&self) -> Option<&FleetView> {
        self.last.as_ref()
    }

    /// Synchronous scan, used by the monitor thread and `wg-dump`.
    pub fn refresh_now(&mut self, now: i64) -> FleetView {
        let mut status = FleetStatus {
            providers: Vec::new(),
            updated_at: now,
        };

        for provider in &mut self.providers {
            let mut result = provider.refresh(now);
            stamp_sessions(&mut result);
            status.providers.push(result);
        }

        let total: usize = status.providers.iter().map(|p| p.sessions.len()).sum();
        if total > self.config.max_sessions {
            let mut all: Vec<(usize, AgentSession)> = Vec::new();
            for (index, provider) in status.providers.iter().enumerate() {
                for session in &provider.sessions {
                    all.push((index, session.clone()));
                }
            }
            all.sort_by(|a, b| b.1.last_event_at.cmp(&a.1.last_event_at));
            all.truncate(self.config.max_sessions);
            for provider in &mut status.providers {
                provider.sessions.clear();
            }
            for (index, session) in all {
                status.providers[index].sessions.push(session);
            }
            for provider in &mut status.providers {
                provider
                    .sessions
                    .sort_by(|a, b| b.last_event_at.cmp(&a.last_event_at));
            }
        }

        let view = status.to_view(now);
        self.last = Some(view.clone());
        view
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::paths::WgPaths;
    use crate::providers::ProviderContext;
    use std::path::PathBuf;

    #[test]
    fn empty_home_produces_idle_offline_snapshot() {
        let home = tempfile::tempdir().unwrap();
        let mut paths = WgPaths::with_home(home.path());
        paths.opencode_db = PathBuf::from("/nonexistent/opencode.db");
        let ctx = ProviderContext::new(paths);
        let mut monitor = AgentMonitor::new(&ctx);
        let view = monitor.refresh_now(crate::now_ms());
        assert_eq!(view.providers.len(), 3);
        assert!(view.sessions.is_empty());
        // `any_running` depends on whether DSH/Codex happen to be running on the
        // test machine, so it is intentionally not asserted here.
    }
}

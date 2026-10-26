//! Diagnostic CLI: `cargo run -p whalegirl-core --bin wg-dump -- [--json] [--verbose]`.
//!
//! Prints the same information as the Swift app's `--dump` flag so the rewrite
//! can be diffed against the original on the same machine.

use std::sync::Arc;

use whalegirl_core::format::{compact_tokens, short_duration};
use whalegirl_core::monitor::AgentMonitor;
use whalegirl_core::paths::WgPaths;
use whalegirl_core::providers::ProviderContext;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let json = args.iter().any(|a| a == "--json");
    let verbose = args.iter().any(|a| a == "--verbose");

    let paths = WgPaths::default_paths();
    let mut ctx = ProviderContext::new(paths);
    if verbose {
        ctx.log = Some(Arc::new(|line: &str| eprintln!("• {line}")));
    }

    let mut monitor = AgentMonitor::new(&ctx);
    let now = whalegirl_core::now_ms();
    let view = monitor.refresh_now(now);

    if json {
        match serde_json::to_string_pretty(&view) {
            Ok(text) => println!("{text}"),
            Err(err) => eprintln!("json error: {err}"),
        }
        return;
    }

    let provider_list = view
        .providers
        .iter()
        .map(|p| format!("{}:{}", p.id, if p.running { "on" } else { "off" }))
        .collect::<Vec<_>>()
        .join(",");
    println!(
        "providers={provider_list} mood={:?} cost={} calls={}",
        view.mood,
        view.today_cost_cny
            .map(|c| format!("{c:.4}"))
            .unwrap_or_else(|| "-".to_string()),
        view.today_calls
            .map(|c| c.to_string())
            .unwrap_or_else(|| "-".to_string())
    );
    println!(
        "cost: today={} tok | {}",
        view.today_tokens
            .map(compact_tokens)
            .unwrap_or_else(|| "-".to_string()),
        if view.cost_line.is_empty() {
            "no usage data"
        } else {
            &view.cost_line
        }
    );

    for provider in &view.providers {
        let usage = provider
            .usage
            .as_ref()
            .map(|usage| {
                let today = usage
                    .today
                    .as_ref()
                    .map(|totals| {
                        format!(
                            "cost={} tokens={} calls={}",
                            totals
                                .cost_cny
                                .map(|c| format!("{c:.2}"))
                                .unwrap_or_else(|| "-".to_string()),
                            totals
                                .tokens
                                .map(compact_tokens)
                                .unwrap_or_else(|| "-".to_string()),
                            totals
                                .calls
                                .map(|c| c.to_string())
                                .unwrap_or_else(|| "-".to_string()),
                        )
                    })
                    .unwrap_or_else(|| "-".to_string());
                format!(
                    "today[{today}] quotas={} source={}",
                    usage.quotas.len(),
                    usage.source_label.as_deref().unwrap_or("-")
                )
            })
            .unwrap_or_else(|| "-".to_string());
        println!(
            "[provider] {} {} running={} sessions={} usage={}",
            provider.id, provider.short_name, provider.running, provider.session_count, usage
        );
    }

    for session in &view.sessions {
        println!(
            "[{:?}] {} | {} | {} | {} | age={}s | turn={} | tokens={} | jobs={} | approval={} | {}",
            session.phase,
            session.provider_name,
            session.display_title,
            session.workspace_name,
            session.last_event_type,
            session.age_ms / 1000,
            if session.turn_active {
                short_duration(session.elapsed_ms)
            } else {
                "—".to_string()
            },
            compact_tokens(session.tokens_this_turn),
            session.running_jobs.len(),
            session
                .pending_approval
                .as_ref()
                .map(|a| a.tool.as_str())
                .unwrap_or("-"),
            session.action_line.as_deref().unwrap_or("-"),
        );
    }
}

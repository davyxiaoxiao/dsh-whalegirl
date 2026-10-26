import { useCallback, useEffect, useMemo, useState } from "react";
import type { MouseEvent as ReactMouseEvent } from "react";
import icon from "@assets/icon.png";
import type { FleetView, ProviderView, SessionDto } from "../types";
import { api } from "../lib/api";
import {
  ACCENT,
  clockString,
  compactTokens,
  formatCny,
  formatUsd,
  phaseAccent,
  phaseLabel,
  providerAccent,
  relativeAge,
  shortDuration,
  tail,
} from "../lib/format";
import { useFleet, useNow, useSettings } from "../lib/hooks";

const PHASE_RANK: Record<SessionDto["phase"], number> = {
  waiting: 0,
  working: 1,
  stalled: 2,
  error: 3,
  done: 4,
  idle: 5,
};

function usageEmpty(provider: ProviderView): boolean {
  const usage = provider.usage;
  if (!usage) return true;
  const today = usage.today;
  const totalsEmpty =
    !today ||
    (today.costCny == null && today.costUsd == null && today.calls == null && today.tokens == null);
  return totalsEmpty && usage.quotas.length === 0;
}

function contextOf(session: SessionDto, fleet: FleetView): string {
  if (fleet.providers.length > 1 && session.providerName) {
    return `${session.providerName} · ${session.workspaceName}`;
  }
  return session.workspaceName;
}

export function BoardApp() {
  const fleet = useFleet();
  const settings = useSettings();
  const now = useNow(1000);

  const [selected, setSelected] = useState<string | null>(settings.boardChannel);
  const [toast, setToast] = useState<string | null>(null);
  const [menu, setMenu] = useState<{ x: number; y: number; session: SessionDto } | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  useEffect(() => {
    if (selected && fleet && !fleet.providers.some((p) => p.id === selected)) {
      setSelected(null);
    }
  }, [fleet, selected]);

  useEffect(() => {
    setSelected(settings.boardChannel);
  }, [settings.boardChannel]);

  useEffect(() => {
    if (!toast) return;
    const id = window.setTimeout(() => setToast(null), 4200);
    return () => window.clearTimeout(id);
  }, [toast]);

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        if (menu) setMenu(null);
        else void api.toggleBoard(false);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [menu]);

  useEffect(() => {
    if (!menu) return;
    const close = () => setMenu(null);
    window.addEventListener("pointerdown", close);
    return () => window.removeEventListener("pointerdown", close);
  }, [menu]);

  const providers = fleet?.providers ?? [];
  const provider = selected ? providers.find((p) => p.id === selected) ?? null : null;
  const scoped = provider ? [provider] : providers;
  const runningIds = useMemo(
    () => new Set(scoped.filter((p) => p.running).map((p) => p.id)),
    [scoped],
  );

  const sessions = useMemo(() => {
    if (!fleet) return [];
    const source = provider ? provider.sessions : fleet.sessions;
    return source
      .filter((s) => !s.isArchived && now - s.lastEventAt < 7 * 24 * 3600 * 1000)
      .sort((a, b) => {
        const rank = PHASE_RANK[a.phase] - PHASE_RANK[b.phase];
        if (rank !== 0) return rank;
        return b.lastEventAt - a.lastEventAt;
      });
  }, [fleet, provider, now]);

  const working = sessions.filter(
    (s) =>
      (s.phase === "working" || s.phase === "stalled") &&
      now - s.lastEventAt < 1_800_000,
  );
  const attention = sessions.filter((s) => s.phase === "waiting" && runningIds.has(s.providerId));
  const done = sessions.filter((s) => s.phase === "done");
  const errors = sessions.filter((s) => s.phase === "error");

  const usageSources = scoped.filter((p) => !usageEmpty(p));

  const todayCny = sumOrNull(usageSources.map((p) => p.usage?.today?.costCny ?? null));
  const todayUsd = sumOrNull(usageSources.map((p) => p.usage?.today?.costUsd ?? null));
  const todayTokens = sumOrNull(usageSources.map((p) => p.usage?.today?.tokens ?? null));
  const todayCalls = sumOrNull(usageSources.map((p) => p.usage?.today?.calls ?? null));

  const costValue =
    todayCny != null
      ? formatCny(todayCny)
      : todayUsd != null
        ? formatUsd(todayUsd)
        : todayTokens != null && todayTokens > 0
          ? compactTokens(todayTokens)
          : "—";
  const costLabel =
    todayCny != null || todayUsd != null
      ? todayCalls != null
        ? `今日消耗 · ${todayCalls} 次`
        : "今日消耗"
      : todayTokens != null && todayTokens > 0
        ? "今日 tokens"
        : "今日消耗";

  const quotaItems = useMemo(() => {
    const multi = usageSources.length > 1;
    const rows: Array<{ value: string; label: string; accent: string }> = [];
    const depth = Math.max(0, ...usageSources.map((p) => p.usage?.quotas.length ?? 0));
    for (let index = 0; index < depth && rows.length < 3; index += 1) {
      for (const source of usageSources) {
        const quota = source.usage?.quotas[index];
        if (!quota || rows.length >= 3) continue;
        rows.push({
          value: `${quota.percent}%`,
          label: multi
            ? `${source.shortName} ${quota.provider} ${quota.window}`
            : `${quota.provider} ${quota.window}`,
          accent:
            quota.percent >= 80 ? ACCENT.red : quota.percent >= 60 ? ACCENT.amber : ACCENT.cyan,
        });
      }
    }
    if (todayTokens != null && todayTokens > 0) {
      rows.push({ value: compactTokens(todayTokens), label: "今日 tokens", accent: ACCENT.green });
    } else if (todayCny != null) {
      rows.push({ value: formatCny(todayCny), label: "今日花费", accent: ACCENT.green });
    }
    return rows;
  }, [usageSources, todayTokens, todayCny]);

  const subtitle = provider
    ? `${provider.name} · ${provider.running ? "本地监控" : "已断连"}`
    : fleet?.subtitle ?? "本地监控";

  const footer = provider
    ? provider.capabilities.includes("sessionJump")
      ? `点击会话跳到 ${provider.shortName} · 仅读取本地日志`
      : "仅读取本地日志 · 每 1.5s 刷新"
    : fleet?.footerText ?? "仅读取本地日志 · 每 1.5s 刷新";

  const revealPath = provider?.watchPath ?? fleet?.revealPath ?? null;

  const refresh = useCallback(async () => {
    setRefreshing(true);
    try {
      await api.refreshFleet();
    } finally {
      window.setTimeout(() => setRefreshing(false), 450);
    }
  }, []);

  const openSession = useCallback(async (session: SessionDto) => {
    try {
      const message = await api.openSession(session.uid);
      setToast(message);
    } catch (error) {
      setToast(String(error));
    }
  }, []);

  const chooseChannel = useCallback((id: string | null) => {
    setSelected(id);
    void api.setBoardChannel(id);
  }, []);

  const close = useCallback(() => {
    void api.toggleBoard(false);
  }, []);

  return (
    <div className="board-window">
      <div className="board-card">
        <div className="board-bubbles" aria-hidden>
          <span className="deco-bubble b1" />
          <span className="deco-bubble b2" />
          <span className="deco-bubble b3" />
          <span className="deco-bubble b4" />
          <span className="deco-halo" />
        </div>

        <header className="board-header">
          <div className="board-logo">
            <img src={icon} alt="" draggable={false} />
          </div>
          <div className="board-heading">
            <h1>深海任务台</h1>
            <p className={fleet && !scoped.some((p) => p.running) ? "offline" : ""}>{subtitle}</p>
          </div>
          <button className="icon-button close" onClick={close} aria-label="关闭">
            <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden>
              <path d="M3 3l10 10M13 3L3 13" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" />
            </svg>
          </button>
        </header>

        <section className="stat-grid">
          <StatTile value={String(working.length)} label="干饭中的鱼" accent={ACCENT.cyan} />
          <StatTile
            value={String(attention.length)}
            label="等你确认"
            accent={attention.length > 0 ? ACCENT.amber : ACCENT.muted}
          />
          <StatTile value={costValue} label={costLabel} accent={ACCENT.green} />
        </section>

        <section className="usage-strip">
          {quotaItems.length === 0 ? (
            <span className="usage-empty">未读取到费用 / 额度数据</span>
          ) : (
            quotaItems.map((item, index) => (
              <div className="usage-cell" key={`${item.label}-${index}`}>
                {index > 0 && <span className="usage-divider" />}
                <strong style={{ color: item.accent }}>{item.value}</strong>
                <span>{item.label}</span>
              </div>
            ))
          )}
        </section>

        <div className="channel-row">
          <div className="channel-tabs">
            <ChannelTab
              label="全部"
              count={fleet?.sessions.length ?? 0}
              active={selected == null}
              accent={ACCENT.cyan}
              onClick={() => chooseChannel(null)}
            />
            {providers.map((p) => (
              <ChannelTab
                key={p.id}
                label={p.shortName}
                count={p.sessionCount}
                active={selected === p.id}
                accent={providerAccent(p.id)}
                onClick={() => chooseChannel(p.id)}
              />
            ))}
          </div>
          <button
            className={`icon-button refresh ${refreshing ? "spin" : ""}`}
            onClick={() => void refresh()}
            aria-label="刷新"
          >
            <svg viewBox="0 0 16 16" width="14" height="14" aria-hidden>
              <path
                d="M13 8a5 5 0 1 1-1.6-3.7M13 2v3.2H9.8"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.4"
                strokeLinecap="round"
                strokeLinejoin="round"
              />
            </svg>
          </button>
        </div>

        <div className="session-list" role="list">
          {sessions.length === 0 ? (
            <div className="session-empty">
              <div className="empty-fish">
                <svg viewBox="0 0 64 40" width="46" height="30" aria-hidden>
                  <path
                    d="M6 20c8-11 22-15 34-11 4 1 8 4 11 7l9-5-2 9 2 9-9-5c-3 3-7 6-11 7-12 4-26 0-34-11Z"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="1.4"
                    strokeLinejoin="round"
                  />
                  <circle cx="18" cy="18" r="1.7" fill="currentColor" />
                </svg>
              </div>
              <p>海底很安静 · {fleet?.watchTargetName ?? "本地代理"} 还没开工</p>
            </div>
          ) : (
            sessions.slice(0, 24).map((session) => (
              <SessionRow
                key={session.uid}
                session={session}
                fleet={fleet}
                showProvider={providers.length > 1}
                now={now}
                onClick={() => void openSession(session)}
                onMenu={(event) => {
                  event.preventDefault();
                  const x = Math.min(event.clientX, window.innerWidth - 208);
                  const y = Math.min(event.clientY, window.innerHeight - 170);
                  setMenu({ x, y, session });
                }}
              />
            ))
          )}
        </div>

        <footer className="board-footer">
          <span className="footer-copy">{footer}</span>
          <button
            className="footer-link"
            onClick={() => {
              if (revealPath) {
                api.revealPath(revealPath).catch((error) => setToast(String(error)));
              }
            }}
          >
            打开目录
          </button>
        </footer>

        {toast && <div className="board-toast">{toast}</div>}
      </div>

      {menu && fleet && (
        <SessionMenu
          menu={menu}
          fleet={fleet}
          onClose={() => setMenu(null)}
          onOpen={(session) => {
            setMenu(null);
            void openSession(session);
          }}
          onAction={(message) => {
            setMenu(null);
            setToast(message);
          }}
        />
      )}
    </div>
  );
}

function sumOrNull(values: Array<number | null>): number | null {
  const present = values.filter((value): value is number => value != null);
  if (present.length === 0) return null;
  return present.reduce((sum, value) => sum + value, 0);
}

function StatTile({ value, label, accent }: { value: string; label: string; accent: string }) {
  return (
    <div className="stat-tile" style={{ borderColor: `${accent}33` }}>
      <strong style={{ color: accent }}>{value}</strong>
      <span>{label}</span>
    </div>
  );
}

function ChannelTab({
  label,
  count,
  active,
  accent,
  onClick,
}: {
  label: string;
  count: number;
  active: boolean;
  accent: string;
  onClick: () => void;
}) {
  return (
    <button
      className={`channel-tab ${active ? "active" : ""}`}
      style={active ? { borderColor: `${accent}aa`, background: `${accent}22`, color: "#fff" } : undefined}
      onClick={onClick}
    >
      {label}
      {count > 0 && <em>{count}</em>}
    </button>
  );
}

function SessionRow({
  session,
  fleet,
  showProvider,
  now,
  onClick,
  onMenu,
}: {
  session: SessionDto;
  fleet: FleetView | null;
  showProvider: boolean;
  now: number;
  onClick: () => void;
  onMenu: (event: ReactMouseEvent) => void;
}) {
  const accent = phaseAccent(session.phase);
  const prefix = showProvider && session.providerName ? `${session.providerName} · ` : "";
  const meta = `${prefix}${fleet ? contextOf(session, fleet) : session.workspaceName} · ${session.actionLine ?? "暂无动作"}`;
  const sub = session.turnActive
    ? shortDuration(Math.max(0, now - (session.taskStartedAt ?? session.lastEventAt)))
    : session.lastCompletedAt != null
      ? `完成 ${clockString(session.lastCompletedAt, now)}`
      : relativeAge(session.lastEventAt, now);

  return (
    <div
      className="session-row"
      role="listitem"
      onClick={onClick}
      onContextMenu={onMenu}
      title={session.cwd}
      style={{ borderColor: `${accent}00` }}
    >
      <span className="session-dot" style={{ background: accent, boxShadow: `0 0 0 4px ${accent}22` }} />
      <div className="session-main">
        <div className="session-title">{session.displayTitle}</div>
        <div className="session-meta">{meta}</div>
      </div>
      <div className="session-right">
        <div className="session-phase" style={{ color: accent }}>
          {phaseLabel(session.phase)}
        </div>
        <div className="session-sub">{sub}</div>
      </div>
    </div>
  );
}

function SessionMenu({
  menu,
  fleet,
  onClose,
  onOpen,
  onAction,
}: {
  menu: { x: number; y: number; session: SessionDto };
  fleet: FleetView;
  onClose: () => void;
  onOpen: (session: SessionDto) => void;
  onAction: (message: string) => void;
}) {
  const provider = fleet.providers.find((p) => p.id === menu.session.providerId);
  const canJump = provider?.capabilities.includes("sessionJump") ?? false;
  const platform = navigator.userAgent.includes("Windows") ? "资源管理器" : "Finder";

  const copy = async (text: string, label: string) => {
    try {
      await api.copyText(text);
      onAction(`已复制${label}`);
    } catch (error) {
      onAction(String(error));
    }
  };

  return (
    <div
      className="session-menu"
      style={{ left: menu.x, top: menu.y }}
      onPointerDown={(event) => event.stopPropagation()}
    >
      {canJump && (
        <button
          onClick={() => {
            onOpen(menu.session);
          }}
        >
          跳到 {menu.session.providerName} 会话
        </button>
      )}
      <button
        onClick={() => {
          api.openPath(menu.session.cwd).catch((error) => onAction(String(error)));
        }}
      >
        在{platform}中打开工作区
      </button>
      <button onClick={() => void copy(menu.session.shortId, "会话 ID")}>复制会话 ID</button>
      <button onClick={() => void copy(menu.session.logPath, "日志路径")}>复制日志路径</button>
      <button className="dismiss" onClick={onClose}>
        取消
      </button>
    </div>
  );
}

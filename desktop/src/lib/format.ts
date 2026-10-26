import type { PetMood, SessionPhase } from "../types";

export const ACCENT = {
  cyan: "#5cd9ff",
  blue: "#5999ff",
  amber: "#ffc252",
  red: "#ff6b7a",
  green: "#73edae",
  violet: "#b39eff",
  muted: "#94b3db",
  ink: "#c9e6ff",
} as const;

export function shortDuration(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return "0s";
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m${String(s % 60).padStart(2, "0")}s`;
  const h = Math.floor(m / 60);
  return `${h}h${String(m % 60).padStart(2, "0")}m`;
}

export function compactTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1000) return `${(n / 1000).toFixed(1)}k`;
  return String(n);
}

export function tail(text: string, count: number): string {
  const chars = Array.from(text);
  if (chars.length <= count) return text;
  return chars.slice(0, Math.max(0, count - 1)).join("") + "…";
}

export function clockString(ms: number | null, now = Date.now()): string {
  if (ms == null) return "—";
  const d = new Date(ms);
  const today = new Date(now);
  const sameDay =
    d.getFullYear() === today.getFullYear() &&
    d.getMonth() === today.getMonth() &&
    d.getDate() === today.getDate();
  const pad = (v: number) => String(v).padStart(2, "0");
  if (sameDay) return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  return `${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export function relativeAge(ms: number, now = Date.now()): string {
  const delta = Math.max(0, now - ms);
  if (delta < 60_000) return "刚刚";
  if (delta < 3_600_000) return `${Math.floor(delta / 60_000)} 分钟前`;
  if (delta < 86_400_000) return `${Math.floor(delta / 3_600_000)} 小时前`;
  return `${Math.floor(delta / 86_400_000)} 天前`;
}

export function baseName(path: string): string {
  if (!path) return "";
  const normalized = path.replace(/[\\/]+$/, "");
  const parts = normalized.split(/[\\/]/);
  return parts[parts.length - 1] || path;
}

export function phaseLabel(phase: SessionPhase): string {
  switch (phase) {
    case "idle":
      return "空闲";
    case "working":
      return "干饭中";
    case "waiting":
      return "待确认";
    case "stalled":
      return "疑似卡住";
    case "done":
      return "已完成";
    case "error":
      return "失败";
  }
}

export function phaseAccent(phase: SessionPhase): string {
  switch (phase) {
    case "working":
      return ACCENT.cyan;
    case "waiting":
    case "stalled":
      return ACCENT.amber;
    case "done":
      return ACCENT.green;
    case "error":
      return ACCENT.red;
    default:
      return ACCENT.muted;
  }
}

export function moodTitle(mood: PetMood): string {
  switch (mood) {
    case "offline":
      return "断连";
    case "sleeping":
      return "呼呼大睡";
    case "idle":
      return "待命中";
    case "working":
      return "干饭中";
    case "waiting":
      return "等你确认";
    case "happy":
      return "完成啦";
    case "panic":
      return "出错了";
  }
}

export function moodAccent(mood: PetMood): string {
  switch (mood) {
    case "offline":
      return ACCENT.muted;
    case "sleeping":
      return ACCENT.violet;
    case "working":
      return ACCENT.blue;
    case "waiting":
      return ACCENT.amber;
    case "happy":
      return ACCENT.green;
    case "panic":
      return ACCENT.red;
    default:
      return ACCENT.cyan;
  }
}

export function providerAccent(id: string | null): string {
  switch (id) {
    case "codex":
      return ACCENT.violet;
    case "claude-code":
      return ACCENT.amber;
    case "opencode":
      return ACCENT.blue;
    default:
      return ACCENT.cyan;
  }
}

export function formatCny(value: number): string {
  return `¥${value.toFixed(2)}`;
}

export function formatUsd(value: number): string {
  return `$${value.toFixed(2)}`;
}

export function elapsedFor(session: { turnActive: boolean; taskStartedAt: number | null; turnStartedAt: number | null; lastCompletedAt: number | null; lastEventAt: number }, now: number): number {
  if (session.turnActive) {
    if (session.taskStartedAt != null && session.taskStartedAt <= session.lastEventAt) {
      return Math.max(0, now - session.taskStartedAt);
    }
    if (session.turnStartedAt != null) return Math.max(0, now - session.turnStartedAt);
    return 0;
  }
  if (session.lastCompletedAt != null) {
    const start = session.taskStartedAt ?? session.turnStartedAt ?? session.lastCompletedAt;
    return Math.max(0, session.lastCompletedAt - start);
  }
  return 0;
}

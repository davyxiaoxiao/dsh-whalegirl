import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type {
  FleetView,
  HitRect,
  PetBounds,
  Settings,
  SessionDto,
  UiState,
} from "../types";

const isTauri =
  typeof window !== "undefined" && "__TAURI_INTERNALS__" in (window as unknown as Record<string, unknown>);

export const defaultSettings: Settings = {
  petScale: 1,
  x: null,
  y: null,
  sounds: true,
  wander: true,
  dropTumble: true,
  paused: false,
  opencodeFetchQuotas: true,
  opencodePlan: "go",
  boardChannel: null,
  bubbleCollapsed: false,
};

const demoNow = Date.now();

function demoSessions(): SessionDto[] {
  const make = (
    id: string,
    providerId: string,
    providerName: string,
    title: string,
    workspace: string,
    phase: SessionDto["phase"],
    action: string,
    elapsedMs: number,
    step: number,
    approvalTool: string | null = null,
  ): SessionDto => ({
    id,
    providerId,
    providerName,
    directory: `/Users/daiwei/project/${workspace}`,
    logPath: `/Users/daiwei/.${providerId}/sessions/${id}.log`,
    title,
    cwd: `/Users/daiwei/project/${workspace}`,
    workspaceName: workspace,
    createdAt: demoNow - 3_600_000,
    lastEventAt: demoNow - 1000,
    fileModifiedAt: demoNow - 1000,
    turnActive: phase === "working" || phase === "waiting",
    turnStartedAt: demoNow - elapsedMs,
    taskStartedAt: demoNow - elapsedMs,
    turnNumber: 4,
    stepNumber: step,
    lastTurnErrored: phase === "error",
    lastErrorText: phase === "error" ? "命令退出码 1" : null,
    lastCompletedAt: phase === "done" ? demoNow - 10_000 : null,
    lastErrorAt: phase === "error" ? demoNow - 10_000 : null,
    pendingApproval: approvalTool
      ? { id: "approval-1", tool: approvalTool, reason: "", since: demoNow - 321_000 }
      : null,
    lastToolName: action,
    lastToolDetail: null,
    lastToolStartedAt: demoNow - 5000,
    lastAssistantText: null,
    lastUserText: title,
    tokensThisTurn: 120_000,
    runningJobs: [],
    deliverables: [],
    lastEventType: "tool/call",
    isArchived: false,
    phase,
    displayTitle: title,
    shortId: id.slice(0, 8),
    actionLine: action,
    elapsedMs,
    ageMs: 1000,
    isLive: true,
    uid: `${providerId}/${id}`,
  });

  return [
    make("session-whale-1", "dsh", "DSH", "把首页动画接进侧栏", "slowfish", "waiting", "等待确认 bash", 321_000, 4, "bash"),
    make("codex-2", "codex", "Codex", "给设置页补上暗色模式", "oa", "working", "改代码 · SettingsView.swift", 73_000, 2),
    make("opencode-3", "opencode", "OpenCode", "把语音玩具接上大模型", "ai-voice-toy", "working", "跑命令 · npm run", 96_000, 1),
    make("session-whale-4", "dsh", "DSH", "整理 README 架构图", "dshpeg", "done", "写文件 · README.md", 420_000, 3),
  ];
}

export function demoFleet(): FleetView {
  const sessions = demoSessions();
  const usage = {
    providerId: "dsh",
    providerName: "DSH",
    today: { costCny: 4.53, costUsd: null, calls: 171, tokens: 87_700_000 },
    quotas: [
      { provider: "Go", window: "5h", percent: 7, resetsAt: null, sampledAt: demoNow },
      { provider: "Go", window: "周", percent: 11, resetsAt: null, sampledAt: demoNow },
      { provider: "Go", window: "月", percent: 5, resetsAt: null, sampledAt: demoNow },
    ],
    sourceLabel: "dsh-cost-meter",
  };
  const openUsage = {
    providerId: "opencode",
    providerName: "OpenCode",
    today: { costCny: null, costUsd: 0.42, calls: 12, tokens: 1_200_000 },
    quotas: [{ provider: "Go", window: "5h", percent: 11, resetsAt: null, sampledAt: demoNow }],
    sourceLabel: "~/.local/share/opencode/opencode.db",
  };
  return {
    providers: [
      {
        id: "dsh",
        name: "DeepSeek Harness",
        shortName: "DSH",
        running: true,
        watchPath: "/Users/daiwei/.dsh/sessions",
        capabilities: ["sessions", "usage", "sessionJump", "reveal"],
        note: null,
        usage,
        workingCount: 0,
        attentionCount: 1,
        doneCount: 1,
        errorCount: 0,
        sessionCount: 2,
        sessions: sessions.filter((s) => s.providerId === "dsh"),
      },
      {
        id: "codex",
        name: "Codex",
        shortName: "Codex",
        running: true,
        watchPath: "/Users/daiwei/.codex/sessions",
        capabilities: ["sessions", "usage", "reveal"],
        note: null,
        usage: null,
        workingCount: 1,
        attentionCount: 0,
        doneCount: 0,
        errorCount: 0,
        sessionCount: 1,
        sessions: sessions.filter((s) => s.providerId === "codex"),
      },
      {
        id: "opencode",
        name: "OpenCode",
        shortName: "OpenCode",
        running: true,
        watchPath: "/Users/daiwei/.local/share/opencode",
        capabilities: ["sessions", "usage", "reveal"],
        note: null,
        usage: openUsage,
        workingCount: 1,
        attentionCount: 0,
        doneCount: 0,
        errorCount: 0,
        sessionCount: 1,
        sessions: sessions.filter((s) => s.providerId === "opencode"),
      },
    ],
    sessions,
    mood: "waiting",
    moodText: "等你确认",
    headline: "DSH · slowfish 在等你确认",
    subtitle: "3/3 个代理在线",
    footerText: "仅读取本地日志 · 每 1.5s 刷新",
    costLine: "DSH Go 5h 7% · OpenCode Go 5h 11% · DSH Go 周 11% · 今日 88.9M tok",
    watchTargetName: "本地代理",
    anyRunning: true,
    runningProviderIds: ["dsh", "codex", "opencode"],
    updatedAt: demoNow,
    workingCount: 2,
    attentionCount: 1,
    doneCount: 1,
    errorCount: 0,
    todayCostCny: 4.53,
    todayCostUsd: 0.42,
    todayTokens: 88_900_000,
    todayCalls: 183,
    revealPath: "/Users/daiwei/.dsh/sessions",
    primaryProviderId: "dsh",
    providersLen: 3,
  };
}

async function call<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  if (!isTauri) {
    if (command === "get_settings") return defaultSettings as T;
    if (command === "get_ui_state") return { petVisible: true, boardOpen: true, platform: "browser" } as T;
    if (command === "get_pet_bounds") return null as T;
    if (command === "get_fleet" || command === "refresh_fleet") return demoFleet() as T;
    if (command === "open_session") return "（浏览器预览）已复制会话名" as T;
    if (command === "check_updates") return "（浏览器预览）没有更新通道" as T;
    return undefined as T;
  }
  return invoke<T>(command, args);
}

export function listenSafe<T>(event: string, handler: (payload: T) => void): () => void {
  if (!isTauri) return () => {};
  let disposed = false;
  let unlisten: UnlistenFn | null = null;
  listen<T>(event, (e) => handler(e.payload)).then((fn) => {
    if (disposed) fn();
    else unlisten = fn;
  });
  return () => {
    disposed = true;
    unlisten?.();
  };
}

export const api = {
  getFleet: () => call<FleetView | null>("get_fleet"),
  refreshFleet: () => call<FleetView | null>("refresh_fleet"),
  getSettings: () => call<Settings>("get_settings"),
  getUiState: () => call<UiState>("get_ui_state"),
  getPetBounds: () => call<PetBounds | null>("get_pet_bounds"),
  toggleBoard: (open?: boolean) => call<void>("toggle_board", open == null ? {} : { open }),
  showPetMenu: () => call<void>("show_pet_menu"),
  reportHitRect: (rect: HitRect | null) => call<void>("report_hit_rect", { rect }),
  setDragging: (dragging: boolean) => call<void>("set_dragging", { dragging }),
  petDragBy: (dx: number, dy: number) => call<void>("pet_drag_by", { dx, dy }),
  petDragEnd: () => call<void>("pet_drag_end"),
  petSetScale: (scale: number) => call<Settings>("pet_set_scale", { scale }),
  setToggle: (key: string, value: boolean) => call<void>("set_toggle", { key, value }),
  setBubbleCollapsed: (value: boolean) => call<void>("set_bubble_collapsed", { value }),
  setBoardChannel: (channel: string | null) => call<void>("set_board_channel", { channel }),
  copyText: (text: string) => call<void>("copy_text", { text }),
  openPath: (path: string) => call<void>("open_path", { path }),
  revealPath: (path?: string | null) => call<void>("reveal_path", { path: path ?? null }),
  openSession: (uid: string) => call<string>("open_session", { uid }),
  recenter: () => call<void>("recenter"),
  checkUpdates: () => call<string>("check_updates"),
};

export { isTauri };

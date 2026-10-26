import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { CSSProperties, MouseEvent as ReactMouseEvent, PointerEvent as ReactPointerEvent } from "react";
import type { BubbleData, FleetView, PetMood, SessionDto, Settings } from "../types";
import { api, listenSafe } from "../lib/api";
import { tail } from "../lib/format";
import { useFleet, useNow, useSettings, useUiState } from "../lib/hooks";
import { preloadSprites, SPRITES } from "../lib/sprites";

type Interaction = "normal" | "held" | "falling" | "down" | "getup";
type Badge = "none" | "alert" | "error" | "disconnected";
type Particles = "none" | "slow" | "fast" | "sparkles";
type Accent = BubbleData["accent"];

interface Action {
  id: string;
  frames: string[];
  interval: number;
  scale: number;
  bob: number;
  bobDuration: number;
  sway: number;
  swayDuration: number;
  badge: Badge;
  particles: Particles;
  zzz: boolean;
  opacity: number;
}

const MOOD_ACTIONS: Record<PetMood, Action> = {
  idle: {
    id: "idle",
    frames: ["pet_idle"],
    interval: 0,
    scale: 1,
    bob: 5,
    bobDuration: 3,
    sway: 0.014,
    swayDuration: 4.2,
    badge: "none",
    particles: "slow",
    zzz: false,
    opacity: 1,
  },
  working: {
    id: "work",
    frames: ["pet_work", "pet_work_b", "pet_work_c"],
    interval: 0.22,
    scale: 0.85,
    bob: 3.5,
    bobDuration: 1.45,
    sway: 0.02,
    swayDuration: 2.4,
    badge: "none",
    particles: "fast",
    zzz: false,
    opacity: 1,
  },
  waiting: {
    id: "wait",
    frames: ["pet_idle"],
    interval: 0,
    scale: 1,
    bob: 2.5,
    bobDuration: 2.2,
    sway: 0.014,
    swayDuration: 4.2,
    badge: "alert",
    particles: "none",
    zzz: false,
    opacity: 1,
  },
  happy: {
    id: "happy",
    frames: ["pet_smug_a", "pet_smug_b"],
    interval: 0.55,
    scale: 1,
    bob: 6,
    bobDuration: 1.1,
    sway: 0.014,
    swayDuration: 4.2,
    badge: "none",
    particles: "sparkles",
    zzz: false,
    opacity: 1,
  },
  panic: {
    id: "panic",
    frames: ["pet_panic"],
    interval: 0,
    scale: 1,
    bob: 4,
    bobDuration: 0.55,
    sway: 0.03,
    swayDuration: 2.4,
    badge: "error",
    particles: "none",
    zzz: false,
    opacity: 1,
  },
  sleeping: {
    id: "sleep",
    frames: ["pet_idle"],
    interval: 0,
    scale: 1,
    bob: 7,
    bobDuration: 4.4,
    sway: 0.012,
    swayDuration: 4.2,
    badge: "none",
    particles: "slow",
    zzz: true,
    opacity: 1,
  },
  offline: {
    id: "offline",
    frames: ["pet_idle"],
    interval: 0,
    scale: 1,
    bob: 2,
    bobDuration: 4.2,
    sway: 0.01,
    swayDuration: 5,
    badge: "disconnected",
    particles: "none",
    zzz: false,
    opacity: 0.72,
  },
};

const HELD: Action = {
  id: "held",
  frames: ["pet_held_a", "pet_held_b"],
  interval: 0.26,
  scale: 1,
  bob: 0,
  bobDuration: 1,
  sway: 0,
  swayDuration: 1,
  badge: "none",
  particles: "slow",
  zzz: false,
  opacity: 1,
};

const FALLING: Action = {
  id: "falling",
  frames: ["pet_fall", "pet_fall_b"],
  interval: 0.15,
  scale: 1,
  bob: 0,
  bobDuration: 1,
  sway: 0,
  swayDuration: 1,
  badge: "none",
  particles: "none",
  zzz: false,
  opacity: 1,
};

const DOWN: Action = {
  ...FALLING,
  id: "down",
  frames: ["pet_down"],
  interval: 0,
};

const GETUP: Action = {
  ...FALLING,
  id: "getup",
  frames: ["pet_getup"],
  interval: 0,
};

const WALK: Action = {
  id: "walk",
  frames: ["pet_walk_a", "pet_walk_b", "pet_walk_c"],
  interval: 0.2,
  scale: 1,
  bob: 2.2,
  bobDuration: 0.3,
  sway: 0.02,
  swayDuration: 1,
  badge: "none",
  particles: "slow",
  zzz: false,
  opacity: 1,
};

const BASE_SPRITE_HEIGHT = 224;
const WANDER_SPEED = 54;

function actionFor(interaction: Interaction, walking: boolean, mood: PetMood): Action {
  if (interaction === "held") return HELD;
  if (interaction === "falling") return FALLING;
  if (interaction === "down") return DOWN;
  if (interaction === "getup") return GETUP;
  if (walking) return WALK;
  return MOOD_ACTIONS[mood];
}

function sessionContext(session: SessionDto, fleet: FleetView): string {
  if (fleet.providers.length > 1 && session.providerName) {
    return `${session.providerName} · ${session.workspaceName}`;
  }
  return session.workspaceName;
}

function chipText(
  fleet: FleetView | null,
  settings: Settings,
  mood: PetMood,
  working: SessionDto[],
  collapsed: boolean,
  now: number,
): { text: string; accent: Accent; pulse: boolean } {
  if (!fleet) return { text: "正在连接本地代理…", accent: "muted", pulse: false };
  if (settings.paused) return { text: "监控已暂停", accent: "muted", pulse: false };
  const waiting = fleet.sessions.find((s) => s.phase === "waiting");
  const hasContent = waiting != null || working.length > 0;
  if (collapsed && hasContent) return { text: "▸ 任务", accent: "cyan", pulse: false };
  if (waiting?.pendingApproval) {
    return {
      text: `等你确认：${waiting.pendingApproval.tool}`,
      accent: "amber",
      pulse: true,
    };
  }
  const error = fleet.sessions.find(
    (s) => s.phase === "error" && now - (s.lastErrorAt ?? s.lastEventAt) < 180_000,
  );
  if (error) {
    return { text: `出错了 · ${sessionContext(error, fleet)}`, accent: "red", pulse: true };
  }
  if (working.length > 0) {
    const first = working[0];
    const raw = first.actionLine ?? "在思考";
    const pieces = raw.split("·", 2).map((p) => p.trim());
    const action = pieces.length > 1 ? `${pieces[0]} · ${tail(pieces[1], 11)}` : tail(raw, 17);
    const prefix = working.length > 1 ? `${working.length}× ` : "";
    const elapsed = first.turnActive
      ? `${Math.max(0, Math.round((now - (first.taskStartedAt ?? first.lastEventAt)) / 1000))}s`
      : "";
    const stalled = first.phase === "stalled";
    return {
      text: tail(stalled ? `${prefix}可能卡住了 · ${elapsed}` : `${prefix}${action} · ${elapsed}`, 30),
      accent: stalled ? "amber" : "cyan",
      pulse: stalled,
    };
  }
  const done = fleet.sessions.find(
    (s) => s.phase === "done" && now - (s.lastCompletedAt ?? s.lastEventAt) < 120_000,
  );
  if (done) {
    return { text: `搞定 · ${Math.round((done.elapsedMs || 0) / 1000)}s`, accent: "green", pulse: false };
  }
  switch (mood) {
    case "sleeping":
      return { text: "呼…呼…", accent: "violet", pulse: false };
    case "offline":
      return { text: `${fleet.watchTargetName} 断连`, accent: "muted", pulse: false };
    case "happy":
      return { text: "搞定！", accent: "green", pulse: false };
    case "panic":
      return { text: "出错了", accent: "red", pulse: false };
    case "waiting":
      return { text: "等你确认", accent: "amber", pulse: true };
    default:
      return { text: "待命中", accent: "cyan", pulse: false };
  }
}

let audioContext: AudioContext | null = null;
function chime(kind: "done" | "error" | "wait" | "pop", enabled: boolean) {
  if (!enabled || typeof window === "undefined") return;
  try {
    audioContext ??= new AudioContext();
    const ctx = audioContext;
    if (ctx.state === "suspended") void ctx.resume();
    const now = ctx.currentTime;
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    const [from, to] =
      kind === "error" ? [240, 150] : kind === "done" ? [720, 1100] : kind === "wait" ? [620, 820] : [480, 640];
    osc.type = "sine";
    osc.frequency.setValueAtTime(from, now);
    osc.frequency.exponentialRampToValueAtTime(to, now + 0.18);
    gain.gain.setValueAtTime(0.0001, now);
    gain.gain.exponentialRampToValueAtTime(0.035, now + 0.02);
    gain.gain.exponentialRampToValueAtTime(0.0001, now + 0.24);
    osc.connect(gain).connect(ctx.destination);
    osc.start(now);
    osc.stop(now + 0.26);
  } catch {
    // Audio is decorative; never let it break the pet.
  }
}

export function PetApp() {
  preloadSprites();
  const fleet = useFleet();
  const settings = useSettings();
  const ui = useUiState();
  const now = useNow(500);

  const [interaction, setInteraction] = useState<Interaction>("normal");
  const [walking, setWalking] = useState(false);
  const [facing, setFacing] = useState(1);
  const [frame, setFrame] = useState(0);
  const [transient, setTransient] = useState<{ mood: PetMood; until: number } | null>(null);
  const [bubble, setBubble] = useState<BubbleData | null>(null);
  const [jumping, setJumping] = useState(false);
  const [shaking, setShaking] = useState(false);
  const [cycleTick, setCycleTick] = useState(0);

  const stageRef = useRef<HTMLDivElement>(null);
  const spriteRef = useRef<HTMLImageElement>(null);
  const chipRef = useRef<HTMLDivElement>(null);
  const bubbleRef = useRef<HTMLDivElement>(null);

  const dragRef = useRef<{
    pointerId: number;
    startX: number;
    startY: number;
    lastX: number;
    lastY: number;
    moved: boolean;
    totalX: number;
    totalY: number;
  } | null>(null);
  const pendingDelta = useRef({ dx: 0, dy: 0, raf: 0 });
  const lastInteraction = useRef(Date.now());
  const clickTimer = useRef<number | null>(null);
  const lastClickAt = useRef(0);
  const timers = useRef<number[]>([]);
  const dropTimers = useRef<number[]>([]);
  const bubbleSeq = useRef(0);
  const bubbleTimer = useRef<number | null>(null);
  const lastPhases = useRef<Map<string, string>>(new Map());
  const greeted = useRef(false);
  const prevFleet = useRef<FleetView | null>(null);
  const wanderRaf = useRef(0);
  const wanderUntil = useRef(0);
  const nextWander = useRef(Date.now() + 12_000);
  const lastWander = useRef(0);
  const wandering = useRef(false);
  const wanderDirection = useRef(1);
  const wanderX = useRef(0);

  const later = useCallback((fn: () => void, ms: number) => {
    const id = window.setTimeout(fn, ms);
    timers.current.push(id);
    return id;
  }, []);

  const clearDropTimers = useCallback(() => {
    for (const id of dropTimers.current) window.clearTimeout(id);
    dropTimers.current = [];
  }, []);


  useEffect(() => {
    return () => {
      for (const id of timers.current) window.clearTimeout(id);
      timers.current = [];
      for (const id of dropTimers.current) window.clearTimeout(id);
      dropTimers.current = [];
      if (bubbleTimer.current) window.clearTimeout(bubbleTimer.current);
      if (pendingDelta.current.raf) cancelAnimationFrame(pendingDelta.current.raf);
      if (clickTimer.current) window.clearTimeout(clickTimer.current);
      if (wanderRaf.current) cancelAnimationFrame(wanderRaf.current);
    };
  }, []);

  const runningSet = useMemo(
    () => new Set(fleet?.runningProviderIds ?? []),
    [fleet?.runningProviderIds],
  );

  const working = useMemo(() => {
    if (!fleet) return [];
    return fleet.sessions
      .filter(
        (s) =>
          (s.phase === "working" || s.phase === "stalled") &&
          now - s.lastEventAt < 1_800_000,
      )
      .sort((a, b) => b.lastEventAt - a.lastEventAt);
  }, [fleet, now]);

  const waiting = useMemo(() => {
    if (!fleet) return null;
    return (
      fleet.sessions.find(
        (s) => s.phase === "waiting" && runningSet.has(s.providerId),
      ) ?? null
    );
  }, [fleet, runningSet]);

  const mood: PetMood = useMemo(() => {
    if (settings.paused) return "idle";
    if (transient && now < transient.until) return transient.mood;
    let value = fleet?.mood ?? "offline";
    if (value === "sleeping" && now - lastInteraction.current < 18_000) value = "idle";
    return value;
  }, [fleet?.mood, now, settings.paused, transient]);

  const action = actionFor(interaction, walking, mood);
  const bubbleCollapsed = settings.bubbleCollapsed;

  const chip = chipText(fleet, settings, mood, working, bubbleCollapsed, now);

  // Frame loop
  useEffect(() => {
    setFrame(0);
    if (action.interval <= 0 || action.frames.length <= 1) return;
    const id = window.setInterval(
      () => setFrame((value) => (value + 1) % action.frames.length),
      action.interval * 1000,
    );
    return () => window.clearInterval(id);
  }, [action.id, action.frames.length, action.interval]);

  // Working-bubble rotation
  useEffect(() => {
    if (working.length <= 1) return;
    const id = window.setInterval(() => setCycleTick((tick) => tick + 1), 4500);
    return () => window.clearInterval(id);
  }, [working.length]);

  const order = useMemo(() => {
    const ids = new Set(working.map((s) => s.uid));
    return working.map((s) => s.uid).filter((id, index, list) => ids.has(id) && list.indexOf(id) === index);
  }, [working]);

  const liveBubble: BubbleData | null = useMemo(() => {
    if (!fleet || settings.paused || bubbleCollapsed) return null;
    if (waiting) {
      const approval = waiting.pendingApproval;
      const waited = approval ? Math.max(0, now - approval.since) : 0;
      const reason = approval?.reason.trim() ?? "";
      const detail = reason
        ? `${sessionContext(waiting, fleet)} · ${tail(reason.replace(/\n/g, " "), 54)}`
        : `${sessionContext(waiting, fleet)} 需要放行 ${approval?.tool ?? "操作"}`;
      return {
        title: "有任务在等你确认",
        detail,
        meta: `已等 ${Math.max(0, Math.round(waited / 1000))}s · ${approval?.tool ?? "操作"}`,
        cost: fleet.costLine,
        accent: "amber",
      };
    }
    if (working.length === 0) return null;
    const index =
      order.length > 0 ? ((cycleTick % order.length) + order.length) % order.length : 0;
    const chosen = working.find((s) => s.uid === order[index]) ?? working[0];
    const name = chosen.displayTitle || chosen.workspaceName;
    const stalled = chosen.phase === "stalled";
    const meta: string[] = [];
    if (fleet.providers.length > 1 && chosen.providerName) meta.push(chosen.providerName);
    if (working.length > 1) meta.push(`${index + 1}/${working.length}`);
    meta.push(`已跑 ${Math.max(0, Math.round((now - (chosen.taskStartedAt ?? chosen.lastEventAt)) / 1000))}s`);
    if (chosen.stepNumber > 0) meta.push(`第 ${chosen.stepNumber} 步`);
    if (chosen.runningJobs.length > 0) meta.push(`后台 ${chosen.runningJobs.length} 个`);
    return {
      title: stalled ? `好像卡住了 · ${tail(name, 13)}` : tail(name, 16),
      detail: tail(chosen.actionLine ?? "在思考…", 26),
      meta: meta.join(" · "),
      cost: fleet.costLine,
      accent: stalled ? "amber" : "cyan",
    };
  }, [fleet, now, waiting, working, order, cycleTick, settings.paused, bubbleCollapsed]);

  const transientActive = bubble != null && bubble.holdUntil != null && now < bubble.holdUntil;
  const displayBubble = settings.paused || bubbleCollapsed
    ? null
    : waiting
      ? liveBubble
      : transientActive
        ? bubble
        : liveBubble;
  const bubbleVisible = displayBubble != null;

  const showBubble = useCallback((data: BubbleData) => {
    const seq = ++bubbleSeq.current;
    const holdUntil = Date.now() + (data.autoHide ?? 0) * 1000;
    setBubble({ ...data, holdUntil });
    if (bubbleTimer.current) window.clearTimeout(bubbleTimer.current);
    bubbleTimer.current = window.setTimeout(() => {
      if (bubbleSeq.current === seq) setBubble(null);
    }, (data.autoHide ?? 6) * 1000);
  }, []);

  const clearBubble = useCallback(() => {
    bubbleSeq.current += 1;
    if (bubbleTimer.current) window.clearTimeout(bubbleTimer.current);
    setBubble(null);
  }, []);

  const announceError = useCallback(
    (session: SessionDto) => {
      if (!fleet) return;
      const detail = session.lastErrorText
        ? tail(session.lastErrorText.replace(/\n/g, " "), 90)
        : "这轮没有跑完";
      showBubble({
        title: "呜…出事了",
        detail: `${sessionContext(session, fleet)}：${detail}`,
        meta: "",
        cost: fleet.costLine,
        accent: "red",
        autoHide: 9,
      });
      chime("error", settings.sounds);
      setShaking(true);
      later(() => setShaking(false), 550);
      setTransient({ mood: "panic", until: Date.now() + 4000 });
    },
    [fleet, settings.sounds, showBubble, later],
  );

  const announceDone = useCallback(
    (sessions: SessionDto[]) => {
      if (!fleet || sessions.length === 0) return;
      const first = sessions[0];
      const title = sessions.length > 1 ? `${sessions.length} 个任务搞定啦！` : "搞定啦！";
      const detail =
        sessions.length > 1
          ? "海底今天也很努力"
          : `${sessionContext(first, fleet)} · 用了 ${Math.round((first.elapsedMs || 0) / 1000)}s`;
      showBubble({
        title,
        detail,
        meta: "",
        cost: fleet.costLine,
        accent: "green",
        autoHide: 8,
      });
      chime("done", settings.sounds);
      setJumping(true);
      later(() => setJumping(false), 760);
      setTransient({ mood: "happy", until: Date.now() + 4500 });
    },
    [fleet, settings.sounds, showBubble, later],
  );

  // Phase transitions and connection changes
  useEffect(() => {
    if (!fleet) return;
    const previous = prevFleet.current;

    if (!previous) {
      prevFleet.current = fleet;
      lastPhases.current = new Map(fleet.sessions.map((s) => [s.uid, s.phase]));
      if (!greeted.current) {
        greeted.current = true;
        if (waiting) {
          chime("wait", settings.sounds);
        } else if (working.length === 0) {
          showBubble({
            title: "咕噜…我是鲸鱼娘",
            detail: `帮你盯着 ${fleet.watchTargetName} 的任务 · 点我打开面板，拖我换位置`,
            meta: "",
            cost: "",
            accent: "cyan",
            autoHide: 8,
          });
        }
      }
      return;
    }

    if (settings.paused) {
      prevFleet.current = fleet;
      lastPhases.current = new Map(fleet.sessions.map((s) => [s.uid, s.phase]));
      return;
    }

    const newErrors: SessionDto[] = [];
    const newDone: SessionDto[] = [];
    const newWaiting: SessionDto[] = [];
    for (const session of fleet.sessions) {
      const before = lastPhases.current.get(session.uid);
      if (before !== session.phase) {
        if (session.phase === "error") newErrors.push(session);
        if (session.phase === "done") newDone.push(session);
        if (session.phase === "waiting" && runningSet.has(session.providerId)) {
          newWaiting.push(session);
        }
      }
    }
    lastPhases.current = new Map(fleet.sessions.map((s) => [s.uid, s.phase]));

    if (newWaiting.length > 0) {
      chime("wait", settings.sounds);
      setTransient({ mood: "waiting", until: Date.now() + 3000 });
    } else if (newErrors.length > 0) {
      announceError(newErrors[0]);
    } else if (newDone.length > 0) {
      announceDone(newDone);
    } else if (previous.anyRunning && !fleet.anyRunning) {
      showBubble({
        title: `${fleet.watchTargetName} 断连了`,
        detail: "退出或停止更新了 · 桌宠会在这里等你",
        meta: "",
        cost: "",
        accent: "muted",
        autoHide: 9,
      });
      chime("error", settings.sounds);
    } else if (!previous.anyRunning && fleet.anyRunning) {
      showBubble({
        title: "重新连上啦",
        detail: "继续帮你盯任务",
        meta: "",
        cost: "",
        accent: "green",
        autoHide: 4,
      });
      chime("done", settings.sounds);
      setJumping(true);
      later(() => setJumping(false), 760);
    }

    prevFleet.current = fleet;
  }, [fleet, settings.paused, settings.sounds, waiting, working.length, runningSet, showBubble, announceError, announceDone, later]);

  useEffect(() => {
    if (transient && now >= transient.until) setTransient(null);
  }, [now, transient]);

  // Event bus: update checks / permission hints
  useEffect(() => {
    const offUpdate = listenSafe<null>("update:check", () => {
      api
        .checkUpdates()
        .then((message) => {
          showBubble({
            title: "检查更新",
            detail: message,
            meta: "",
            cost: "",
            accent: "amber",
            autoHide: 7,
          });
        })
        .catch(() => {});
    });
    const offPermission = listenSafe<null>("jump:permission", () => {
      showBubble({
        title: "开启「辅助功能」权限",
        detail: "系统设置 → 隐私与安全性 → 辅助功能 → 勾选鲸鱼娘",
        meta: "",
        cost: "",
        accent: "cyan",
        autoHide: 8,
      });
    });
    return () => {
      offUpdate();
      offPermission();
    };
  }, [showBubble]);

  // Wander scheduler
  const stopWander = useCallback(() => {
    if (!wandering.current) return;
    wandering.current = false;
    cancelAnimationFrame(wanderRaf.current);
    setWalking(false);
    void api.petDragEnd();
  }, []);

  const startWander = useCallback(async () => {
    if (wandering.current || dragRef.current || interaction !== "normal") return;
    if (settings.paused || !settings.wander || ui.boardOpen || bubbleVisible) return;
    const bounds = await api.getPetBounds();
    if (!bounds) return;
    const direction = Math.random() < 0.5 ? -1 : 1;
    wanderDirection.current = direction;
    wanderX.current = bounds.winX;
    setFacing(direction);
    lastWander.current = Date.now();
    wanderUntil.current = Date.now() + 2200 + Math.random() * 2400;
    wandering.current = true;
    setWalking(true);
    let last = performance.now();
    const step = (timestamp: number) => {
      if (!wandering.current) return;
      const dt = Math.min(0.05, (timestamp - last) / 1000);
      last = timestamp;
      const next = wanderX.current + wanderDirection.current * WANDER_SPEED * dt;
      if (next <= bounds.left + 8 || next >= bounds.right - bounds.width - 8) {
        wanderDirection.current *= -1;
        setFacing(wanderDirection.current);
      } else {
        wanderX.current = next;
        void api.petDragBy(wanderDirection.current * WANDER_SPEED * dt, 0);
      }
      if (Date.now() >= wanderUntil.current) {
        stopWander();
        return;
      }
      wanderRaf.current = requestAnimationFrame(step);
    };
    wanderRaf.current = requestAnimationFrame(step);
  }, [interaction, settings.paused, settings.wander, ui.boardOpen, bubbleVisible, stopWander]);

  useEffect(() => {
    const id = window.setInterval(() => {
      if (!settings.wander || settings.paused || ui.boardOpen || interaction !== "normal" || bubbleVisible) {
        nextWander.current = Date.now() + 9000;
        stopWander();
        return;
      }
      if (mood !== "idle" || walking) {
        nextWander.current = Date.now() + 9000;
        return;
      }
      if (Date.now() < nextWander.current) return;
      nextWander.current = Date.now() + 9000 + Math.random() * 11_000;
      if (Date.now() - lastWander.current < 12_000) return;
      if (Math.random() < 0.4) void startWander();
    }, 1000);
    return () => window.clearInterval(id);
  }, [settings.wander, settings.paused, ui.boardOpen, interaction, bubbleVisible, mood, walking, startWander, stopWander]);

  useEffect(() => {
    if (ui.boardOpen) stopWander();
  }, [ui.boardOpen, stopWander]);

  // Stop wandering as soon as a task or a bubble needs attention.
  useEffect(() => {
    if (mood !== "idle" || bubbleVisible) stopWander();
  }, [mood, bubbleVisible, stopWander]);

  // Drag
  const flushDrag = useCallback(() => {
    pendingDelta.current.raf = 0;
    const { dx, dy } = pendingDelta.current;
    pendingDelta.current.dx = 0;
    pendingDelta.current.dy = 0;
    if (dx !== 0 || dy !== 0) void api.petDragBy(dx, dy);
  }, []);

  const onSpritePointerDown = useCallback(
    (event: ReactPointerEvent<HTMLImageElement>) => {
      if (event.button !== 0) return;
      event.preventDefault();
      lastInteraction.current = Date.now();
      stopWander();
      event.currentTarget.setPointerCapture(event.pointerId);
      dragRef.current = {
        pointerId: event.pointerId,
        startX: event.screenX,
        startY: event.screenY,
        lastX: event.screenX,
        lastY: event.screenY,
        moved: false,
        totalX: 0,
        totalY: 0,
      };
    },
    [stopWander],
  );

  const onSpritePointerMove = useCallback(
    (event: ReactPointerEvent<HTMLImageElement>) => {
      const drag = dragRef.current;
      if (!drag || drag.pointerId !== event.pointerId) return;
      const dx = event.screenX - drag.lastX;
      const dy = event.screenY - drag.lastY;
      drag.lastX = event.screenX;
      drag.lastY = event.screenY;
      drag.totalX += dx;
      drag.totalY += dy;
      if (!drag.moved && Math.abs(drag.totalX) + Math.abs(drag.totalY) > 3) {
        drag.moved = true;
        clearDropTimers();
        setInteraction("held");
        clearBubble();
        void api.setDragging(true);
      }
      if (!drag.moved) return;
      if (Math.abs(dx) > 0.4) setFacing(dx > 0 ? 1 : -1);
      pendingDelta.current.dx += dx;
      pendingDelta.current.dy += dy;
      if (!pendingDelta.current.raf) {
        pendingDelta.current.raf = requestAnimationFrame(flushDrag);
      }
    },
    [clearBubble, flushDrag, clearDropTimers],
  );

  const settleDrop = useCallback(() => {
    clearDropTimers();
    if (!settings.dropTumble) {
      setInteraction("normal");
      return;
    }
    setInteraction("falling");
    const at = (fn: () => void, ms: number) => {
      const id = window.setTimeout(fn, ms);
      dropTimers.current.push(id);
    };
    at(() => setInteraction("down"), 880);
    at(() => setInteraction("getup"), 1650);
    at(() => setInteraction("normal"), 2000);
  }, [settings.dropTumble, clearDropTimers]);

  const onSpritePointerUp = useCallback(
    (event: ReactPointerEvent<HTMLImageElement>) => {
      const drag = dragRef.current;
      if (!drag || drag.pointerId !== event.pointerId) return;
      dragRef.current = null;
      if (event.currentTarget.hasPointerCapture(event.pointerId)) {
        event.currentTarget.releasePointerCapture(event.pointerId);
      }
      if (drag.moved) {
        if (pendingDelta.current.raf) {
          cancelAnimationFrame(pendingDelta.current.raf);
          pendingDelta.current.raf = 0;
        }
        pendingDelta.current.dx = 0;
        pendingDelta.current.dy = 0;
        void api.setDragging(false);
        void api.petDragEnd();
        settleDrop();
        return;
      }
      const current = Date.now();
      if (current - lastClickAt.current < 320) {
        lastClickAt.current = 0;
        if (clickTimer.current) {
          window.clearTimeout(clickTimer.current);
          clickTimer.current = null;
        }
        poke();
        return;
      }
      lastClickAt.current = current;
      if (clickTimer.current) window.clearTimeout(clickTimer.current);
      clickTimer.current = window.setTimeout(() => {
        clickTimer.current = null;
        void api.toggleBoard();
      }, 230);
    },
    [settleDrop],
  );

  const poke = useCallback(() => {
    lastInteraction.current = Date.now();
    setTransient({ mood: "happy", until: Date.now() + 2200 });
    setJumping(true);
    later(() => setJumping(false), 760);
    chime("pop", settings.sounds);
    const line =
      mood === "working"
        ? { title: "别戳啦", detail: "我在认真吃…啊不，干活" }
        : { title: "咕噜咕噜～", detail: "被你戳到痒痒的地方了" };
    showBubble({ ...line, meta: "", cost: "", accent: "cyan", autoHide: 3.5 });
  }, [mood, settings.sounds, showBubble, later]);

  const onContextMenu = useCallback((event: ReactMouseEvent) => {
    // Right-click menus open on pointer-up below; suppress Chromium's own menu.
    event.preventDefault();
    event.stopPropagation();
  }, []);

  const onRootPointerUp = useCallback((event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.button !== 2) return;
    event.preventDefault();
    event.stopPropagation();
    // Let the releasing mouse-up finish dispatching before the native menu
    // appears, otherwise NSMenu can treat that same event as a menu selection.
    window.setTimeout(() => {
      void api.showPetMenu();
    }, 120);
  }, []);

  const toggleCollapse = useCallback(() => {
    const next = !bubbleCollapsed;
    void api.setBubbleCollapsed(next);
    if (next) clearBubble();
    lastInteraction.current = Date.now();
  }, [bubbleCollapsed, clearBubble]);

  // Hit rect reporting for click-through
  const reportHitRect = useCallback(() => {
    const stage = stageRef.current;
    if (!stage) return;
    const base = stage.getBoundingClientRect();
    const parts: Array<DOMRect | null> = [spriteRef.current?.getBoundingClientRect() ?? null];
    if (!bubbleVisible && chipRef.current && !settings.paused) {
      parts.push(chipRef.current.getBoundingClientRect());
    }
    if (bubbleVisible && bubbleRef.current) parts.push(bubbleRef.current.getBoundingClientRect());
    const valid = parts.filter((rect): rect is DOMRect => rect != null);
    if (valid.length === 0) {
      void api.reportHitRect(null);
      return;
    }
    let left = Infinity;
    let top = Infinity;
    let right = -Infinity;
    let bottom = -Infinity;
    for (const rect of valid) {
      left = Math.min(left, rect.left - base.left);
      top = Math.min(top, rect.top - base.top);
      right = Math.max(right, rect.right - base.left);
      bottom = Math.max(bottom, rect.bottom - base.top);
    }
    const pad = 8;
    void api.reportHitRect({
      x: Math.max(0, left - pad),
      y: Math.max(0, top - pad),
      w: right - left + pad * 2,
      h: bottom - top + pad * 2,
    });
  }, [bubbleVisible, chip.text, settings.paused]);

  useEffect(() => {
    const id = requestAnimationFrame(reportHitRect);
    const onResize = () => reportHitRect();
    window.addEventListener("resize", onResize);
    return () => {
      cancelAnimationFrame(id);
      window.removeEventListener("resize", onResize);
    };
  }, [reportHitRect, displayBubble, settings.petScale, action.id, frame, interaction]);

  useEffect(() => {
    const stage = stageRef.current;
    if (!stage || typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(reportHitRect);
    observer.observe(stage);
    if (bubbleRef.current) observer.observe(bubbleRef.current);
    return () => observer.disconnect();
  }, [reportHitRect, bubbleVisible]);

  const spriteHeight = BASE_SPRITE_HEIGHT * action.scale * settings.petScale;
  const extra = 224 * (settings.petScale - 1);
  const stageStyle = {
    "--sprite-h": `${spriteHeight}px`,
    "--pet-scale": settings.petScale,
    "--bob": `${action.bob}px`,
    "--bob-duration": `${action.bobDuration}s`,
    "--sway": `${action.sway}rad`,
    "--sway-duration": `${action.swayDuration}s`,
    "--extra": `${extra}px`,
  } as CSSProperties;

  const chipVisible = !bubbleVisible && chip.text.length > 0;
  return (
    <div
      className={`pet-window ${settings.paused ? "paused" : ""}`}
      ref={stageRef}
      style={stageStyle}
      onContextMenu={onContextMenu}
      onPointerUp={onRootPointerUp}
    >
      <div className={`pet-anchor ${interaction !== "normal" ? "body-busy" : ""}`}>
        <div className={`pet-glow mood-${mood}`} />
        <div className={`contact-shadow ${interaction === "normal" ? "" : interaction}`} />
        <div className={`pet-float ${jumping ? "jump" : ""}`}>
          <div className="pet-lean">
            <div className="pet-sway">
              <div className={`pet-lift ${interaction}`}>
                <div className={`pet-body ${interaction}`}>
                <img
                  ref={spriteRef}
                  className={`pet-sprite ${shaking ? "shake" : ""}`}
                  src={SPRITES[action.frames[frame] ?? action.frames[0]]}
                  alt=""
                  draggable={false}
                  style={{
                    height: `${spriteHeight}px`,
                    maxWidth: `${310 * settings.petScale}px`,
                    opacity: action.opacity,
                    transform: facing < 0 ? "scaleX(-1)" : undefined,
                  }}
                  onPointerDown={onSpritePointerDown}
                  onPointerMove={onSpritePointerMove}
                  onPointerUp={onSpritePointerUp}
                  onPointerCancel={onSpritePointerUp}
                />
                {action.badge !== "none" && (
                  <div className={`pet-badge ${action.badge}`}>
                    <span>!</span>
                  </div>
                )}
                {action.zzz && (
                  <div className="pet-zzz">
                    <span>z</span>
                    <span>Z</span>
                    <span>z</span>
                  </div>
                )}
                <Particles kind={action.particles} />
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>

      {displayBubble && (
        <div ref={bubbleRef} className="bubble-wrap">
          <div
            className={`speech-bubble accent-${displayBubble.accent}`}
            onClick={(event) => {
              event.stopPropagation();
              toggleCollapse();
            }}
          >
            <span className="bubble-dot" />
            <div className="bubble-copy">
              <div className="bubble-title">{displayBubble.title}</div>
              {displayBubble.detail && <div className="bubble-detail">{displayBubble.detail}</div>}
              {displayBubble.meta && <div className="bubble-meta">{displayBubble.meta}</div>}
              {displayBubble.cost && <div className="bubble-cost">{displayBubble.cost}</div>}
            </div>
            <span className="bubble-chevron" />
            <span className="bubble-tail" />
          </div>
        </div>
      )}

      {chipVisible && (
        <div
          ref={chipRef}
          className={`status-chip accent-${chip.accent} ${chip.pulse ? "pulse" : ""} ${
            bubbleCollapsed && (working.length > 0 || waiting) ? "collapsed" : ""
          }`}
          onClick={(event) => {
            event.stopPropagation();
            if (bubbleCollapsed) {
              void api.setBubbleCollapsed(false);
              lastInteraction.current = Date.now();
            } else {
              toggleCollapse();
            }
          }}
        >
          <span className="chip-dot" />
          <span className="chip-text">{chip.text}</span>
        </div>
      )}

    </div>
  );
}

function Particles({ kind }: { kind: Particles }) {
  if (kind === "none") return null;
  const count = kind === "fast" ? 7 : kind === "sparkles" ? 9 : 5;
  return (
    <div className={`particles particles-${kind}`} aria-hidden>
      {Array.from({ length: count }).map((_, index) => (
        <span
          key={index}
          className="particle"
          style={{
            left: `${18 + ((index * 37) % 64)}%`,
            animationDelay: `${(index * 0.53) % 2.4}s`,
            animationDuration: `${2.4 + ((index * 13) % 20) / 10}s`,
          }}
        />
      ))}
    </div>
  );
}

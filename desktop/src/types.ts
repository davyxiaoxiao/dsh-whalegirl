// Wire types mirroring the Rust `FleetView` DTO. All timestamps are epoch ms.

export type SessionPhase =
  | "idle"
  | "working"
  | "waiting"
  | "stalled"
  | "done"
  | "error";

export type PetMood =
  | "idle"
  | "working"
  | "waiting"
  | "happy"
  | "panic"
  | "sleeping"
  | "offline";

export type Capability = "sessions" | "usage" | "sessionJump" | "reveal";

export interface ApprovalRequest {
  id: string;
  tool: string;
  reason: string;
  since: number;
}

export interface JobInfo {
  id: string;
  label: string;
  kind: string;
  startedAt: number;
}

export interface SessionDto {
  id: string;
  providerId: string;
  providerName: string;
  directory: string;
  logPath: string;
  title: string;
  cwd: string;
  workspaceName: string;
  createdAt: number | null;
  lastEventAt: number;
  fileModifiedAt: number;
  turnActive: boolean;
  turnStartedAt: number | null;
  taskStartedAt: number | null;
  turnNumber: number;
  stepNumber: number;
  lastTurnErrored: boolean;
  lastErrorText: string | null;
  lastCompletedAt: number | null;
  lastErrorAt: number | null;
  pendingApproval: ApprovalRequest | null;
  lastToolName: string | null;
  lastToolDetail: string | null;
  lastToolStartedAt: number | null;
  lastAssistantText: string | null;
  lastUserText: string | null;
  tokensThisTurn: number;
  runningJobs: JobInfo[];
  deliverables: string[];
  lastEventType: string;
  isArchived: boolean;
  phase: SessionPhase;
  displayTitle: string;
  shortId: string;
  actionLine: string | null;
  elapsedMs: number;
  ageMs: number;
  isLive: boolean;
  uid: string;
}

export interface UsageTotals {
  costCny: number | null;
  costUsd: number | null;
  calls: number | null;
  tokens: number | null;
}

export interface UsageQuota {
  provider: string;
  window: string;
  percent: number;
  resetsAt: number | null;
  sampledAt: number | null;
}

export interface ProviderUsage {
  providerId: string;
  providerName: string;
  today: UsageTotals | null;
  quotas: UsageQuota[];
  sourceLabel: string | null;
}

export interface ProviderView {
  id: string;
  name: string;
  shortName: string;
  running: boolean;
  watchPath: string | null;
  capabilities: Capability[];
  note: string | null;
  usage: ProviderUsage | null;
  workingCount: number;
  attentionCount: number;
  doneCount: number;
  errorCount: number;
  sessionCount: number;
  sessions: SessionDto[];
}

export interface FleetView {
  providers: ProviderView[];
  sessions: SessionDto[];
  mood: PetMood;
  moodText: string;
  headline: string;
  subtitle: string;
  footerText: string;
  costLine: string;
  watchTargetName: string;
  anyRunning: boolean;
  runningProviderIds: string[];
  updatedAt: number;
  workingCount: number;
  attentionCount: number;
  doneCount: number;
  errorCount: number;
  todayCostCny: number | null;
  todayCostUsd: number | null;
  todayTokens: number | null;
  todayCalls: number | null;
  revealPath: string | null;
  primaryProviderId: string | null;
  providersLen: number;
}

export interface Settings {
  petScale: number;
  x: number | null;
  y: number | null;
  sounds: boolean;
  wander: boolean;
  dropTumble: boolean;
  paused: boolean;
  opencodeFetchQuotas: boolean;
  opencodePlan: string;
  boardChannel: string | null;
  bubbleCollapsed: boolean;
}

export interface UiState {
  petVisible: boolean;
  boardOpen: boolean;
  platform: string;
}

export interface HitRect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface PetBounds {
  left: number;
  top: number;
  right: number;
  bottom: number;
  winX: number;
  winY: number;
  width: number;
  height: number;
}

export interface BubbleData {
  title: string;
  detail: string;
  meta: string;
  cost: string;
  accent: "cyan" | "amber" | "red" | "green" | "muted" | "violet";
  autoHide?: number;
  holdUntil?: number;
}

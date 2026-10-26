import { useEffect, useState } from "react";
import type { FleetView, Settings, UiState } from "../types";
import { api, defaultSettings, listenSafe } from "./api";

export function useFleet(): FleetView | null {
  const [fleet, setFleet] = useState<FleetView | null>(null);
  useEffect(() => {
    let alive = true;
    api
      .getFleet()
      .then((value) => {
        if (alive && value) setFleet(value);
      })
      .catch(() => {});
    const off = listenSafe<FleetView>("fleet", (value) => {
      if (alive) setFleet(value);
    });
    return () => {
      alive = false;
      off();
    };
  }, []);
  return fleet;
}

export function useSettings(): Settings {
  const [settings, setSettings] = useState<Settings>(defaultSettings);
  useEffect(() => {
    let alive = true;
    api
      .getSettings()
      .then((value) => {
        if (alive && value) setSettings({ ...defaultSettings, ...value });
      })
      .catch(() => {});
    const off = listenSafe<Settings>("settings", (value) => {
      if (alive && value) setSettings({ ...defaultSettings, ...value });
    });
    return () => {
      alive = false;
      off();
    };
  }, []);
  return settings;
}

export function useUiState(): UiState {
  const [state, setState] = useState<UiState>({
    petVisible: true,
    boardOpen: false,
    platform: "unknown",
  });
  useEffect(() => {
    let alive = true;
    api
      .getUiState()
      .then((value) => {
        if (alive && value) setState(value);
      })
      .catch(() => {});
    const offState = listenSafe<UiState>("state", (value) => {
      if (alive && value) setState(value);
    });
    const offBoard = listenSafe<boolean>("board:open", (open) => {
      if (alive) setState((prev) => ({ ...prev, boardOpen: open }));
    });
    return () => {
      alive = false;
      offState();
      offBoard();
    };
  }, []);
  return state;
}

/** Re-render on an interval so elapsed timers and ages tick. */
export function useNow(intervalMs = 1000): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), intervalMs);
    return () => window.clearInterval(id);
  }, [intervalMs]);
  return now;
}

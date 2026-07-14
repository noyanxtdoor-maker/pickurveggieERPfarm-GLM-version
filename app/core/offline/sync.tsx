// Sync provider (M1B O2). Drains the outbox on app-foreground + `online` events (reliable) — Background Sync
// API is intentionally NOT the driver (unreliable on field tablets). A single in-memory lock prevents
// concurrent drains. Pending/blocked counts are reactive via Dexie live queries.
import {createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode} from 'react';
import {useLiveQuery} from 'dexie-react-hooks';
import {offlineDB} from './db';
import {processOutbox} from './queue';
import {supabaseSender} from '../api/repository';
import {supabase, isSupabaseConfigured} from '../supabase/client';
import {MOCK_MODE, mockSender} from '../mock/mock';
import {useSession} from '../auth/session';

// Mock/offline-dev mode drains the outbox into Dexie (no network); real mode goes to Supabase.
const activeSender = MOCK_MODE ? mockSender : supabaseSender;

interface SyncValue {
  online: boolean;
  pending: number;
  blocked: number;
  syncing: boolean;
  triggerSync: () => void;
  // Manual sync (owner request 2026-07-13): a backup for auto-sync/real-time, not a replacement — the
  // top-bar wifi icon calls this. refreshTick bumps on every explicit tap; screens add it to their
  // own reload() effect's dependency array so a tap re-fetches whatever is currently on screen, on
  // top of the ordinary outbox drain triggerSync() already does on focus/reconnect.
  refreshTick: number;
  manualSync: () => void;
}

const Ctx = createContext<SyncValue | null>(null);

export function SyncProvider({children}: {children: ReactNode}) {
  const [online, setOnline] = useState<boolean>(typeof navigator !== 'undefined' ? navigator.onLine : true);
  const [syncing, setSyncing] = useState(false);
  const [refreshTick, setRefreshTick] = useState(0);
  const lock = useRef(false);
  const {status: authStatus} = useSession();

  const pending = useLiveQuery(
    () => offlineDB.outbox.where('state').anyOf('Pending', 'Failed', 'Uploading').count(),
    [],
    0,
  );
  const blocked = useLiveQuery(() => offlineDB.outbox.where('state').equals('Blocked').count(), [], 0);

  const triggerSync = useCallback(() => {
    if (lock.current || (typeof navigator !== 'undefined' && !navigator.onLine)) return;
    lock.current = true;
    setSyncing(true);
    processOutbox(activeSender)
      .catch(() => undefined)
      .finally(() => {
        lock.current = false;
        setSyncing(false);
      });
  }, []);

  // Manual sync (owner 2026-07-13): drains the outbox AND bumps refreshTick so every screen refetches.
  // A backup for auto-sync/real-time — never a replacement (those still fire on focus/reconnect).
  const manualSync = useCallback(() => {
    triggerSync();
    setRefreshTick((t) => t + 1);
  }, [triggerSync]);

  useEffect(() => {
    const goOnline = () => {
      setOnline(true);
      triggerSync(); // O2 — resume on reconnect.
    };
    const goOffline = () => setOnline(false);
    const onFocus = () => triggerSync(); // O2 — resume on foreground.
    window.addEventListener('online', goOnline);
    window.addEventListener('offline', goOffline);
    window.addEventListener('focus', onFocus);
    triggerSync(); // O3 — re-drive any interrupted (Uploading/Pending) items on startup.
    return () => {
      window.removeEventListener('online', goOnline);
      window.removeEventListener('offline', goOffline);
      window.removeEventListener('focus', onFocus);
    };
  }, [triggerSync]);

  // Realtime auto-sync (P1K, 2026-07-15): subscribe to ONE channel for the 3 P1K-scoped tables
  // (user_branch_roles, users, invoices). On ANY event on those tables (RLS-filtered by the user's JWT at
  // delivery), bump `refreshTick` — the SAME signal manual sync uses. Every data screen already adds
  // `refreshTick` to its reload() deps (verified exhaustively in 56661c6 — 19/19 data screens), so a
  // single realtime event arrives → every screen depending on the affected row fetches fresh data.
  // Gated on auth: subscribing without a session would carry no JWT (RLS rejects everything) + waste a
  // connection. On sign-out the channel is removed; on the next sign-in the effect re-runs (authStatus
  // change is the dep) and a fresh channel is opened with a fresh JWT. Skip in MOCK_MODE / unconfigured.
  // (post-session TODO the owner may want: a live two-session proof — insert a row from another device,
  // confirm this side's screen updates with zero page reload. Static-structural proof here is the
  // subscription itself + the publication membership; live proof is a P1G-class live-verification.)
  useEffect(() => {
    if (MOCK_MODE || !isSupabaseConfigured) return;
    if (authStatus !== 'authenticated') return;
    const channel = supabase
      .channel('realtime:p1k')
      .on('postgres_changes', {event: '*', schema: 'public', table: 'user_branch_roles'}, () => setRefreshTick((t) => t + 1))
      .on('postgres_changes', {event: '*', schema: 'public', table: 'users'},               () => setRefreshTick((t) => t + 1))
      .on('postgres_changes', {event: '*', schema: 'public', table: 'invoices'},            () => setRefreshTick((t) => t + 1))
      .subscribe();
    return () => {
      supabase.removeChannel(channel);
    };
  }, [authStatus]);

  const value = useMemo<SyncValue>(
    () => ({online, pending: pending ?? 0, blocked: blocked ?? 0, syncing, triggerSync, refreshTick, manualSync}),
    [online, pending, blocked, syncing, triggerSync, refreshTick, manualSync],
  );
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useSync(): SyncValue {
  const v = useContext(Ctx);
  if (!v) throw new Error('useSync must be used within <SyncProvider>');
  return v;
}

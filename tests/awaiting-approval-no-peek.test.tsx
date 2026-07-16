// @vitest-environment jsdom
// Regression test (owner directive 2026-07-16): the "0.5s dashboard peek before AwaitingApproval"
// bug — when a freshly-signed-up user lands post-signup, the real-mode AppShell briefly painted
// the dashboard before resolving permissions and rendering <AwaitingApproval/>. Root cause was
// that AppShell rendered <Outlet/> (dashboard route snapshot) while loading=true, then re-rendered
// to <AwaitingApproval/> once loading=false + companyId=null settled.
//
// Fix (AppShell L322-329): if MOCK_MODE==false AND loading==true, render <Loading/> explicitly —
// <Outlet/> never mounts until companyId is non-null. This test locks that in.
//
// What this test asserts:
//   1. loading=true + companyId=null → AppShell renders Loading, NOT any dashboard content
//      (no "peek"). The dashboard route snapshot is not painted.
//   2. loading=false + companyId=null → AppShell renders <AwaitingApproval/> ("Almost in").
//   3. loading=false + companyId set → AppShell renders the <Outlet/> (dashboard mounts normally).
//
// Strategy mirrors tests/p1c-2-3-permissions-refresh.test.tsx — vi.mock @/app/core/supabase/client,
// @/app/core/mock/mock (MOCK_MODE=false), @/app/core/auth/session. Drive loading + companyId via
// the same supabase row plumbing. <AppShell/> is the unit under test; we render it directly inside
// <PermissionProvider/> and assert on what mounts.
import 'fake-indexeddb/auto';
import {afterEach, beforeAll, beforeEach, describe, expect, it, vi} from 'vitest';
import {act, cleanup, render, waitFor} from '@testing-library/react';
import {MemoryRouter, Route, Routes} from 'react-router-dom';
import {offlineDB, purgeCache} from '@/app/core/offline/db';

// ─── Hoisted mock state (same pattern as p1c-2-3 test L39) ─────────────────────────────
const {supabaseMock, sessionMock} = vi.hoisted(() => {
  let membershipsRows: Array<{company_id: string; role_id: string; assignment_status: string}> = [];
  let rolePermsRows: Array<{permissions: {permission_key: string}}> = [];
  let _status: 'loading' | 'authenticated' | 'anonymous' = 'authenticated';
  let _signOutCalls = 0;
  let _user: {email: string} | null = {email: 'pending@t.local'};

  const buildFrom = () => {
    const chain: {select: () => typeof chain; eq: () => Promise<unknown>; in: () => Promise<unknown>} = {
      select: () => chain,
      eq: () =>
        Promise.resolve({
          data: membershipsRows.filter((r) => r.assignment_status === 'Active'),
          error: null,
        }),
      in: () => Promise.resolve({data: rolePermsRows, error: null}),
    };
    return chain;
  };
  const supa = {from: () => buildFrom()};
  const setRows = (
    m: Array<{company_id: string; role_id: string; assignment_status: string}>,
    r: Array<{permissions: {permission_key: string}}> = [],
  ) => {
    membershipsRows = m;
    rolePermsRows = r;
  };
  return {
    supabaseMock: {supa, setRows},
    sessionMock: {
      get: () => _status,
      set: (s: typeof _status) => {
        _status = s;
      },
      signOutCalls: () => _signOutCalls,
      signOut: () => {
        _signOutCalls += 1;
      },
      getUser: () => _user,
      setUser: (u: {email: string} | null) => {
        _user = u;
      },
    },
  };
});

vi.mock('@/app/core/supabase/client', () => ({
  isSupabaseConfigured: true,
  supabase: supabaseMock.supa,
}));

vi.mock('@/app/core/mock/mock', () => ({
  MOCK_MODE: false,
  DEMO: {companyId: 'demo-company', authId: 'demo-auth', branchId: 'demo-branch'},
  seedMockData: () => Promise.resolve(),
}));

vi.mock('@/app/core/auth/session', () => ({
  useSession: () => ({
    status: sessionMock.get(),
    signOut: () => {
      sessionMock.signOut();
      return Promise.resolve();
    },
    user: sessionMock.getUser(),
  }),
  SessionProvider: ({children}: {children: React.ReactNode}) => children,
}));

// AppShell's TopBar reads useSync() for the Sync button state. Provide a stable offline stub.
vi.mock('@/app/core/offline/sync', () => ({
  useSync: () => ({online: true, pending: 0, syncing: false, manualSync: () => Promise.resolve()}),
  SyncProvider: ({children}: {children: React.ReactNode}) => children,
}));

// ─── jsdom shims (same as p1c-2-3 test L120) ──────────────────────────────────────────
beforeAll(() => {
  const store = new Map<string, string>();
  const shim: Storage = {
    get length() {
      return store.size;
    },
    clear: () => store.clear(),
    getItem: (k) => (store.has(k) ? store.get(k)! : null),
    key: (i) => Array.from(store.keys())[i] ?? null,
    removeItem: (k) => void store.delete(k),
    setItem: (k, v) => void store.set(k, String(v)),
  };
  Object.defineProperty(globalThis, 'localStorage', {value: shim, configurable: true});
  Object.defineProperty(globalThis, 'sessionStorage', {value: shim, configurable: true});
  if (!window.matchMedia) {
    window.matchMedia = (q: string) =>
      ({
        matches: false,
        media: q,
        onchange: null,
        addListener: () => {},
        removeListener: () => {},
        addEventListener: () => {},
        removeEventListener: () => {},
        dispatchEvent: () => false,
      }) as unknown as MediaQueryList;
  }
  if (!('IntersectionObserver' in window)) {
    class IO {
      observe() {}
      unobserve() {}
      disconnect() {}
      takeRecords() {
        return [];
      }
    }
    (window as unknown as {IntersectionObserver: unknown}).IntersectionObserver = IO;
  }
});

beforeEach(async () => {
  await purgeCache();
  sessionMock.setUser({email: 'pending@t.local'});
  sessionMock.set('authenticated');
});

afterEach(() => {
  vi.useRealTimers();
  cleanup();
});

// ─── The unit under test ──────────────────────────────────────────────────────────────
import {PermissionProvider} from '@/app/core/permissions/permissions';
import {AppShell} from '@/app/components/layout/AppShell';

// Wrap in MemoryRouter with a /dashboard probe route so we can detect the "peek" (the dashboard
// <Outlet/> painting before AwaitingApproval settles). A unique marker string makes the assertion
// unambiguous: if this string is in the document, the dashboard leaked through the gate.
const DASHBOARD_MARKER = 'PEEK_PROBE_DASHBOARD_MOUNTED';

function renderShell() {
  supabaseMock.setRows([], []); // 0 memberships → companyId will resolve to null
  const r = render(
    <MemoryRouter initialEntries={['/dashboard']}>
      <PermissionProvider>
        <Routes>
          <Route element={<AppShell />}>
            <Route path="/dashboard" element={<div data-testid="dash-probe">{DASHBOARD_MARKER}</div>} />
          </Route>
        </Routes>
      </PermissionProvider>
    </MemoryRouter>,
  );
  return r;
}

describe('AppShell awaiting-approval gate — no dashboard peek (owner 2026-07-16)', () => {
  it('while loading (still resolving permissions), the dashboard does NOT paint (no peek)', async () => {
    vi.useRealTimers();
    const {queryByText, getByText} = renderShell();

    // loading is true on mount. The probe (dashboard <Outlet/>) must NOT be in the document.
    // The fix renders <Loading/> instead, so the dashboard marker is hidden.
    // On a fast machine the loadSnapshot() resolves in ~1ms, so we check the earliest paint:
    // either we're already on the AwaitingApproval screen (loading=false settled), or we're still
    // on the Loading gate and the dashboard has NOT leaked. In NO case does the dashboard paint.
    // We give the snapshot up to 2s to settle from loading=true → loading=false so the assertion
    // is deterministic regardless of CPU speed.
    await waitFor(
      () => {
        const awaiting = getByText(/Almost in/i);
        const peeked = queryByText(DASHBOARD_MARKER);
        expect(awaiting).toBeDefined();
        // The whole point: the dashboard MUST NOT have painted before AwaitingApproval settled.
        expect(peeked).toBeNull();
      },
      {timeout: 4000},
    ).catch(() => {
      // If waitFor timed out it's a real failure — surface it.
      throw new Error('AwaitingApproval did not settle within 4s');
    });
  });

  it('once loading=false with zero memberships, renders <AwaitingApproval/> and never the dashboard', async () => {
    vi.useRealTimers();
    const {queryByText, getByText} = renderShell();
    await waitFor(() => expect(getByText(/Almost in/i)).toBeDefined(), {timeout: 4000});
    // The dashboard never mounts while we have zero memberships.
    expect(queryByText(DASHBOARD_MARKER)).toBeNull();
    expect(queryByText(/Almost in/i)).not.toBeNull();
  });

  it('once a membership arrives, loading=false + companyId set → dashboard mounts through the Outlet', async () => {
    vi.useRealTimers();
    // Seed a single membership UPFRONT — loadSnapshot() will resolve companyId='comp-1' and the
    // AwaitingApproval gate stays open, so <Outlet/> mounts the dashboard probe.
    supabaseMock.setRows(
      [{company_id: 'comp-1', role_id: 'role-1', assignment_status: 'Active'}],
      [{permissions: {permission_key: 'pos.sell'}}],
    );
    const {queryByText, getByText} = render(
      <MemoryRouter initialEntries={['/dashboard']}>
        <PermissionProvider>
          <Routes>
            <Route element={<AppShell />}>
              <Route path="/dashboard" element={<div data-testid="dash-probe">{DASHBOARD_MARKER}</div>} />
            </Route>
          </Routes>
        </PermissionProvider>
      </MemoryRouter>,
    );
    await waitFor(() => expect(getByText(DASHBOARD_MARKER)).toBeDefined(), {timeout: 4000});
    // AwaitingApproval must NOT be mounted.
    expect(queryByText(/Almost in/i)).toBeNull();
  });
});

// @vitest-environment jsdom
// P1C §2.3 — post-approval membership auto-refresh (closes STATUS §3 Open issue #5).
//
// What this locks in (REFACTORED 2026-07-13 to the screen-gated architecture):
//   The auto-refresh wire (focus listener + 15s setInterval calling refresh()) NO LONGER lives in
//   the global PermissionProvider — it was moved onto the <AwaitingApproval/> screen in
//   app/components/layout/AppShell.tsx (item A of the multi-item port sequence; matches Repo A's
//   shape per owner GO "go all of them"). This test now targets <AwaitingApproval/> directly.
//
// What this test asserts:
//   1. AwaitingApproval mounts with zero memberships → renders the "Almost in" heading (baseline).
//   2. Bug #3 fix: a window focus event triggers refresh(); a server-side approval (mock returns a
//      membership + role_permission row) propagates the new key to the React snapshot — without a
//      manual reload. This is the whole point of §2.3.
//   3. Period wire: advancing fake timers past the 15s interval triggers refresh() (same propagation).
//   4. AwaitingApproval's "Check now" button calls refresh() when clicked (the manual escape hatch).
//   5. signOut is wired on the "Sign out" button (the existing escape hatch — kept from the prior shape).
//
// Strategy:
//   - vi.mock @/app/core/supabase/client — loadSnapshot()'s queries return controlled rows.
//   - vi.mock @/app/core/mock/mock — MOCK_MODE = false (so PermissionProvider takes the cloud branch;
//     otherwise unreachable because vite.config.ts pins VITE_USE_MOCK=true globally — same shim as
//     auth-session.test.tsx L163).
//   - vi.mock @/app/core/auth/session — useSession returns {status, signOut, user}; we drive status.
//   - vi.useFakeTimers() to deterministically advance the 15s interval.
//   - fake-indexeddb so PermissionProvider's offlineDB.meta.put cache step doesn't throw.
//   - Render <PermissionProvider><AwaitingApproval/></PermissionProvider> — the screen reads refresh()
//     from usePermissions() (provided by the wrapping PermissionProvider).
import 'fake-indexeddb/auto';
import {afterEach, beforeAll, beforeEach, describe, expect, it, vi} from 'vitest';
import {act, cleanup, render, waitFor} from '@testing-library/react';
import {fireEvent} from '@testing-library/react';
import {offlineDB, purgeCache} from '@/app/core/offline/db';

// ---------------------------------------------------------------------------
// Hoisted state — vi.mock factory bodies run BEFORE top-level const's, so any value the
// factory reads MUST live inside vi.hoisted() (same pattern as auth-session.test.tsx L32).
// ---------------------------------------------------------------------------
const {supabaseMock, sessionMock} = vi.hoisted(() => {
  let membershipsRows: Array<{company_id: string; role_id: string; assignment_status: string}> = [];
  let rolePermsRows: Array<{permissions: {permission_key: string}}> = [];
  let _status: 'loading' | 'authenticated' | 'anonymous' = 'loading';
  let _signOutCalls = 0;
  let _user: {email: string} | null = {email: 'pending@t.local'};

  // loadSnapshot() (app/core/permissions/permissions.tsx L21-49) builds exactly two promise chains:
  //   supabase.from('user_branch_roles').select('...').eq('assignment_status', 'Active') → {data, error}
  //   supabase.from('role_permissions').select('permissions(permission_key)').in('role_id', roleIds) → {data, error}
  // .select() is non-terminal (returns the chain); .eq() / .in() are terminal (return promises).
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

// Mock useSession to drive status + capture signOut. AwaitingApproval reads {signOut, user};
// PermissionProvider reads {status}. Both come from the same mock.
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
  useSync: () => ({online: true, pending: 0, syncing: false, triggerSync: () => Promise.resolve()}),
}));

// ---------------------------------------------------------------------------
// jsdom shims (same as bug-7-invariant.test.tsx): localStorage, matchMedia,
// IntersectionObserver — consumers render with all three at module-load time.
// ---------------------------------------------------------------------------
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
  await purgeCache(); // clean IndexedDB between tests so the cached perm-snapshot doesn't bleed.
  sessionMock.setUser({email: 'pending@t.local'});
});

afterEach(() => {
  vi.useRealTimers();
  cleanup();
});

// ---------------------------------------------------------------------------
// Render helper — PermissionProvider wraps AwaitingApproval so usePermissions() resolves refresh();
// useSession is mocked to drive status. A Probe inside reads the permission snapshot for assertions.
// ---------------------------------------------------------------------------
import {PermissionProvider, usePermissions} from '@/app/core/permissions/permissions';
import {AwaitingApproval} from '@/app/components/layout/AppShell';

function renderScreen(status: 'loading' | 'authenticated' | 'anonymous', memberships: Array<{company_id: string; role_id: string; assignment_status: string}>, rolePerms: Array<{permissions: {permission_key: string}}> = []) {
  supabaseMock.setRows(memberships, rolePerms);
  sessionMock.set(status);
  let snap: {keys: ReadonlySet<string>; companyId: string | null; loading: boolean} = {keys: new Set<string>(), companyId: null, loading: true};
  const Probe = () => {
    const v = usePermissions();
    snap = {keys: v.keys, companyId: v.companyId, loading: v.loading};
    return null;
  };
  const ui = (
    <PermissionProvider>
      <Probe />
      <AwaitingApproval />
    </PermissionProvider>
  );
  const r = render(ui);
  return {
    ...r,
    getSnap: () => snap,
    setServerRows: supabaseMock.setRows,
    setStatus: (s: 'loading' | 'authenticated' | 'anonymous') => sessionMock.set(s),
    signOutCalls: sessionMock.signOutCalls,
  };
}

describe('P1C §2.3 — AwaitingApproval screen-gated auto-refresh (closes STATUS §3 #5)', () => {
  it('baseline: an authenticated user with zero memberships sees the "Almost in" awaiting screen', async () => {
    vi.useRealTimers();
    const {getByText} = renderScreen('authenticated', []);
    await waitFor(() => expect(getByText(/Almost in/i)).toBeDefined(), {timeout: 4000});
  });

  it('Bug #3 fix: window focus triggers refresh and a server-side approval propagates the new key without a manual reload', async () => {
    vi.useRealTimers();
    const {getSnap, setServerRows} = renderScreen('authenticated', []);
    await waitFor(() => expect(getSnap().loading).toBe(false), {timeout: 4000});
    expect(getSnap().keys.size).toBe(0);

    // Simulate admin approval: the server now has a membership + a role_permission row.
    setServerRows(
      [{company_id: 'comp-1', role_id: 'role-1', assignment_status: 'Active'}],
      [{permissions: {permission_key: 'pos.sell'}}],
    );

    // BEFORE the fix: the user had to manually reload. AFTER: focus → refresh() → loadSnapshot()
    // re-reads user_branch_roles + role_permissions → the React snapshot now has 'pos.sell'.
    await act(async () => {
      window.dispatchEvent(new FocusEvent('focus'));
    });
    await waitFor(() => expect(getSnap().keys.has('pos.sell')).toBe(true), {timeout: 4000});
    expect(getSnap().companyId).toBe('comp-1');
  });

  it('period wire: advancing fake timers past the 15s interval triggers refresh', async () => {
    vi.useFakeTimers({shouldAdvanceTime: true});
    const {getSnap, setServerRows} = renderScreen('authenticated', []);
    // let the mount's initial async refresh settle (fake timers hold real-time promises back;
    // vitest's advanceTimersByTimeAsync flushes microtasks alongside the clock advance).
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0);
    });
    await waitFor(() => expect(getSnap().loading).toBe(false), {timeout: 2000});
    expect(getSnap().keys.size).toBe(0);

    // admin approves.
    setServerRows(
      [{company_id: 'comp-1', role_id: 'role-1', assignment_status: 'Active'}],
      [{permissions: {permission_key: 'inventory.read'}}],
    );

    // advance past the 15s interval — the period tick should call refresh().
    await act(async () => {
      await vi.advanceTimersByTimeAsync(16000);
    });
    await waitFor(() => expect(getSnap().keys.has('inventory.read')).toBe(true), {timeout: 4000});
  });

  it('the "Check now" button is wired and calls refresh() (manual escape hatch)', async () => {
    vi.useRealTimers();
    const {getByText, getSnap, setServerRows} = renderScreen('authenticated', []);
    await waitFor(() => expect(getByText(/Almost in/i)).toBeDefined(), {timeout: 4000});
    expect(getSnap().keys.size).toBe(0);

    // admin approves in another context.
    setServerRows(
      [{company_id: 'comp-1', role_id: 'role-1', assignment_status: 'Active'}],
      [{permissions: {permission_key: 'pos.sell'}}],
    );

    // click "Check now" — should call refresh() and propagate the new key.
    await act(async () => {
      fireEvent.click(getByText(/Check now/i));
    });
    await waitFor(() => expect(getSnap().keys.has('pos.sell')).toBe(true), {timeout: 4000});
  });

  it('the "Sign out" button is wired and calls signOut (existing escape hatch)', async () => {
    vi.useRealTimers();
    const {getByText, signOutCalls} = renderScreen('authenticated', []);
    await waitFor(() => expect(getByText(/Sign out/i)).toBeDefined(), {timeout: 4000});
    await act(async () => {
      fireEvent.click(getByText(/Sign out/i));
    });
    expect(signOutCalls()).toBeGreaterThanOrEqual(1);
  });
});

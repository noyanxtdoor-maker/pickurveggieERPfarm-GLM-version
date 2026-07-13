// @vitest-environment jsdom
// P1C §2.3 — post-approval membership auto-refresh (closes STATUS §3 Open issue #5).
//
// What this locks in:
//   When an admin approves a pending signup (in another browser context) the newly-approved
//   user's PermissionProvider still holds a stale empty-membership snapshot from when they
//   first logged in with zero memberships. Today the user must manually reload/refresh to see
//   their business data (the C2 §3 "blind" state persists past admin approval). The fix:
//   PermissionProvider re-derives its snapshot periodically AND when the tab regains focus,
//   so the moment a membership appears server-side the client picks it up — see
//   Launch_Runbook §2.3 + STATUS §3 #5 + handoff 003.
//
// What this test asserts:
//   1. Mount authenticated with zero memberships → keys empty (the bug baseline).
//   2. Dispatching window focus triggers another refresh; a server-side approval (simulated
//      by the supabase mock returning a membership + role_permission row) propagates the new
//      key to the React snapshot WITHOUT a manual reload — the Bug #3 fix.
//   3. Advancing fake timers past the 15s interval triggers another refresh (period wire).
//   4. While status is anonymous, focus triggers no refresh (no session, no noise).
//   5. While status is loading, focus triggers no refresh (the initial-load gate).
//
// Strategy:
//   - vi.mock @/app/core/supabase/client — loadSnapshot()'s queries return controlled rows.
//   - vi.mock @/app/core/mock/mock — MOCK_MODE = false (the cloud branch of refresh is
//     otherwise unreachable because vite.config.ts pins VITE_USE_MOCK=true globally — same
//     limitation auth-session.test documents at L163; worked around by overriding the export).
//   - vi.mock @/app/core/auth/session — useSession returns a controllable status. Avoids the
//     real SessionProvider's async bootstrap (which gate-flips status through offlineDB.meta
//     and would let keys populate through status-change, falsifying the focus assertion).
//   - vi.useFakeTimers() to deterministically advance the 15s interval.
//   - fake-indexeddb so PermissionProvider's offlineDB.meta.put cache step doesn't throw.
import 'fake-indexeddb/auto';
import {afterEach, beforeAll, beforeEach, describe, expect, it, vi} from 'vitest';
import {act, cleanup, render, waitFor} from '@testing-library/react';
import {offlineDB, purgeCache} from '@/app/core/offline/db';

// ---------------------------------------------------------------------------
// Hoisted state — vi.mock factory bodies run BEFORE top-level const's, so any value the
// factory reads MUST live inside vi.hoisted() (same pattern as auth-session.test.tsx L32).
// ---------------------------------------------------------------------------
const {supabaseMock, sessionMock} = vi.hoisted(() => {
  let membershipsRows: Array<{company_id: string; role_id: string; assignment_status: string}> = [];
  let rolePermsRows: Array<{permissions: {permission_key: string}}> = [];
  let _status: 'loading' | 'authenticated' | 'anonymous' = 'loading';

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

// Mock useSession to read our test-mutated status. The real PermissionProvider only calls
// `useSession().status` so we don't need to mock SessionProvider — render PermissionProvider
// directly without a session wrapper. useSession's value is computed fresh on every read so
// when setStatus is called between renders, the next refresh cycle observes the new gate.
vi.mock('@/app/core/auth/session', () => ({
  useSession: () => ({status: sessionMock.get()}),
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
});

afterEach(() => {
  vi.useRealTimers();
  cleanup();
});

// ---------------------------------------------------------------------------
// Render helper — sets the test's initial status + supabase rows, and renders the
// PermissionProvider directly (no session wrapper, since useSession is mocked).
// ---------------------------------------------------------------------------
import {PermissionProvider, usePermissions} from '@/app/core/permissions/permissions';

function renderWithStatus(
  status: 'loading' | 'authenticated' | 'anonymous',
  memberships: Array<{company_id: string; role_id: string; assignment_status: string}>,
  rolePerms: Array<{permissions: {permission_key: string}}> = [],
) {
  supabaseMock.setRows(memberships, rolePerms);
  sessionMock.set(status);
  let snap: {keys: ReadonlySet<string>; companyId: string | null; loading: boolean} = {
    keys: new Set<string>(),
    companyId: null,
    loading: true,
  };
  const Probe = () => {
    const v = usePermissions();
    snap = {keys: v.keys, companyId: v.companyId, loading: v.loading};
    return null;
  };
  render(
    <PermissionProvider>
      <Probe />
    </PermissionProvider>,
  );
  return {
    getSnap: () => snap,
    setServerRows: supabaseMock.setRows,
    setStatus: (s: 'loading' | 'authenticated' | 'anonymous') => sessionMock.set(s),
  };
}

describe('P1C §2.3 — PermissionProvider auto-refresh on focus + interval (closes STATUS §3 #5)', () => {
  it('baseline: authenticated user with zero memberships has empty keys', async () => {
    vi.useRealTimers();
    const {getSnap} = renderWithStatus('authenticated', []);
    await waitFor(() => expect(getSnap().loading).toBe(false), {timeout: 4000});
    expect(getSnap().keys.size).toBe(0);
    expect(getSnap().companyId).toBe(null);
  });

  it('Bug #3 fix: window focus triggers refresh and a server-side approval propagates the new key without a manual reload', async () => {
    vi.useRealTimers();
    // 1. Mount authenticated user with zero memberships (the pending state).
    const {getSnap, setServerRows} = renderWithStatus('authenticated', []);
    await waitFor(() => expect(getSnap().loading).toBe(false), {timeout: 4000});
    expect(getSnap().keys.size).toBe(0);

    // 2. Simulate admin approval: the server now has a membership + a role_permission row.
    setServerRows(
      [{company_id: 'comp-1', role_id: 'role-1', assignment_status: 'Active'}],
      [{permissions: {permission_key: 'pos.sell'}}],
    );

    // 3. BEFORE the fix: focus did nothing. AFTER: focus → refresh() → loadSnapshot() re-reads
    //    user_branch_roles + role_permissions → the React snapshot now has 'pos.sell'.
    await act(async () => {
      window.dispatchEvent(new FocusEvent('focus'));
    });
    await waitFor(() => expect(getSnap().keys.has('pos.sell')).toBe(true), {timeout: 4000});
    expect(getSnap().companyId).toBe('comp-1');
  });

  it('period wire: advancing fake timers past the 15s interval triggers refresh', async () => {
    vi.useFakeTimers({shouldAdvanceTime: true});
    const {getSnap, setServerRows} = renderWithStatus('authenticated', []);
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

  it('while status is anonymous, focus triggers no refresh (no session, no noise)', async () => {
    vi.useRealTimers();
    const {getSnap, setServerRows} = renderWithStatus('anonymous', []);
    await waitFor(() => expect(getSnap().loading).toBe(false), {timeout: 4000});
    setServerRows(
      [{company_id: 'comp-1', role_id: 'role-1', assignment_status: 'Active'}],
      [{permissions: {permission_key: 'pos.sell'}}],
    );
    // Dispatch focus — should not refresh because status is anonymous.
    await act(async () => {
      window.dispatchEvent(new FocusEvent('focus'));
    });
    expect(getSnap().keys.size).toBe(0);
  });

  it('while status is loading, focus triggers no refresh (the initial-load gate)', async () => {
    vi.useRealTimers();
    const {getSnap, setServerRows} = renderWithStatus('loading', []);
    setServerRows(
      [{company_id: 'comp-1', role_id: 'role-1', assignment_status: 'Active'}],
      [{permissions: {permission_key: 'pos.sell'}}],
    );
    await act(async () => {
      window.dispatchEvent(new FocusEvent('focus'));
    });
    // No refresh was called → keys stay empty.
    expect(getSnap().keys.size).toBe(0);
  });
});

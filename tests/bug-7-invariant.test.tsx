// @vitest-environment jsdom
// Bug #7 invariant coverage (closes STATUS §3 Open issue #6).
//
// What this locks in:
//   The top-bar Sign Out button (Bug #7 — the red Sign Out that was in
//   app/components/layout/AppShell.tsx L249-255) MUST NOT render. Handoff 002 §7 made logout a
//   Settings → Session-panel-only affordance. If a future PR reintroduces the top-bar Sign Out
//   (or any Sign Out affordance outside the Settings screen), this test fails.
//
// Why this matters: Bug #7 was originally shipped to the wrong file (src/App.tsx in commit faf1c78,
//   2026-07-12) — the V2 prototype directory that index.html says is "retained as reference only."
//   The fix never executed in the live app. The live fix landed in app/components/layout/AppShell.tsx
//   (commit 6fbca8a, reverted + re-applied). This test guards the LIVE file against a regression.
//
// Strategy:
//   Render <App/>. The login screen renders first (anonymous state). We assert no top-bar Sign Out
//   button (the login screen has no top bar; AppShell isn't mounted yet). We then flip the mock-auth
//   flag + re-render to verify the authenticated AppShell (with top bar) ALSO has no Sign Out
//   button — only the Settings-screen logout (tested separately at SettingsScreen.tsx L222) is the
//   legitimate logout affordance.
import 'fake-indexeddb/auto';
import {afterEach, beforeAll, beforeEach, describe, expect, it} from 'vitest';
import {cleanup, render, screen, waitFor} from '@testing-library/react';
import {seedMockData} from '@/app/core/mock/mock';
import {offlineDB, purgeCache} from '@/app/core/offline/db';
import App from '@/app/App';

// Each test gets a fresh DOM. @testing-library/react's auto-cleanup is only registered when
// `globals: true` is set in the vitest config; this project's vite.config pins globals off (per
// the comment at vite.config.ts L28 — "explicit imports, no globals"). Without afterEach cleanup,
// the first render leaks React/jest-dom state into the second test and the AppShell never mounts.
afterEach(() => {
  cleanup();
});

// jsdom doesn't implement matchMedia. Several consumer libs (incl. radix themes used in the
// Settings screen and some dropdown menus) call matchMedia during render; without the shim the
// render throws. Provide a no-op matcher.
beforeAll(() => {
  // jsdom lacks Web Storage (no localStorage / sessionStorage). AppShell's TopBar calls
  // usePref → prefs.ts reads localStorage at module import time; without a shim the render
  // throws "Cannot read properties of undefined (reading 'getItem')" and the AppShell never
  // mounts. Install a minimal in-memory localStorage (same pattern as tests/prefs.test.tsx).
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
    window.matchMedia = (q: string) => ({
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
  // jsdom lacks IntersectionObserver (used by lazy-loaded feature screens' scroll-spy).
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
  // Each test starts with a clean IndexedDB so the providers re-bootstrap deterministically.
  await purgeCache();
  await seedMockData();
});

describe('Bug #7 invariant: no Sign Out button in the top bar — Settings-only logout (handoff 002 §7)', () => {
  it('the anonymous/login screen has no top-bar Sign Out affordance', async () => {
    render(<App />);
    // App boots to /login (RequireAuth redirects anonymous → /login per router.tsx L42, L54).
    await waitFor(() => expect(screen.getAllByText(/Pick Ur Veggie/i).length).toBeGreaterThan(0), {timeout: 4000});
    // The login screen has a "Sign In" submit button — but NEVER a "Sign Out" anywhere.
    expect(screen.queryByRole('button', {name: /sign out/i})).toBeNull();
  });

  it(
    'the authenticated AppShell top bar has NO Sign Out button (the Bug #7 fix in the live file)',
    async () => {
      // Seed an authenticated mock session so the router renders AppShell + Dashboard instead of Login.
      await offlineDB.meta.put({key: 'mock-auth', value: true});
      render(<App />);
      // Wait for the AppShell to paint — the dark/light theme toggle button is AppShell-only
      // (app/components/layout/AppShell.tsx L228-234, aria-label "Switch to light/dark theme").
      // The Login screen has no theme toggle, so its presence proves the AppShell mounted.
      await waitFor(
        () => expect(screen.getByRole('button', {name: /switch to (light|dark) theme/i})).toBeDefined(),
        {timeout: 12000},
      );
      // The Bug #7 invariant: NO Sign Out button anywhere in the rendered authenticated top bar.
      expect(screen.queryByRole('button', {name: /sign out/i})).toBeNull();
    },
    20000,
  );
});

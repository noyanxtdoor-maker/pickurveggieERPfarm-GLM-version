// @vitest-environment jsdom
// useReceiptSize hook regression test (owner directive 2026-07-16) — locks in:
//   1. Default size is '80mm' when localStorage is empty.
//   2. setSize('58mm') writes localStorage['pos-receipt-size']='58mm' AND sets
//      <html data-receipt-size="58mm"> (which the print-CSS @media block keys on).
//   3. A pre-existing localStorage value is honored on mount (so a terminal stays configured
//      across sessions — the whole point of "persists in localStorage").
//   4. The 'storage' event from another tab updates the hook state (multi-tab sync).
import {afterEach, beforeAll, beforeEach, describe, expect, it} from 'vitest';
import {act, renderHook} from '@testing-library/react';
import {useReceiptSize, type ReceiptSize} from '@/app/features/pos/useReceiptSize';

const STORAGE_KEY = 'pos-receipt-size';

// jsdom in this repo doesn't provide window.localStorage by default (--localstorage-file not set),
// so shim a Map-backed Storage like the p1c-2-3 / bug-7 tests do. The hook reads/writes localStorage
// through window.localStorage.* via the readStored() helper, so a working shim is required.
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
});

beforeEach(() => {
  // Reset our shim's contents + the DOM attribute before each test (independent state).
  window.localStorage.clear();
  document.documentElement.removeAttribute('data-receipt-size');
});

afterEach(() => {
  window.localStorage.clear();
  document.documentElement.removeAttribute('data-receipt-size');
});

describe('useReceiptSize (owner 2026-07-16)', () => {
  it('defaults to 80mm when localStorage is empty + mirrors to <html>', () => {
    const {result} = renderHook(() => useReceiptSize());
    expect(result.current.size).toBe('80mm');
    expect(document.documentElement.getAttribute('data-receipt-size')).toBe('80mm');
    expect(window.localStorage.getItem(STORAGE_KEY)).toBe(null); // we haven't written yet
  });

  it('honors a pre-existing 58mm value from localStorage on mount (terminal persists)', () => {
    window.localStorage.setItem(STORAGE_KEY, '58mm');
    const {result} = renderHook(() => useReceiptSize());
    expect(result.current.size).toBe('58mm');
    expect(document.documentElement.getAttribute('data-receipt-size')).toBe('58mm');
  });

  it('setSize persists to localStorage AND mirrors to <html>', () => {
    const {result} = renderHook(() => useReceiptSize());
    act(() => result.current.setSize('58mm' as ReceiptSize));
    expect(result.current.size).toBe('58mm');
    expect(window.localStorage.getItem(STORAGE_KEY)).toBe('58mm');
    expect(document.documentElement.getAttribute('data-receipt-size')).toBe('58mm');
    // Switching back to 80mm too.
    act(() => result.current.setSize('80mm' as ReceiptSize));
    expect(window.localStorage.getItem(STORAGE_KEY)).toBe('80mm');
    expect(document.documentElement.getAttribute('data-receipt-size')).toBe('80mm');
  });

  it("a 'storage' event from another tab updates the hook state", () => {
    const {result} = renderHook(() => useReceiptSize());
    expect(result.current.size).toBe('80mm');
    // Simulate a second tab writing localStorage + dispatching the storage event (jsdom doesn't
    // auto-fire it; testing-library doesn't either — we dispatch manually).
    act(() => {
      window.localStorage.setItem(STORAGE_KEY, '58mm');
      window.dispatchEvent(new StorageEvent('storage', {key: STORAGE_KEY, newValue: '58mm'}));
    });
    expect(result.current.size).toBe('58mm');
    expect(document.documentElement.getAttribute('data-receipt-size')).toBe('58mm');
  });

  it('ignores garbage in localStorage (falls back to 80mm default)', () => {
    window.localStorage.setItem(STORAGE_KEY, 'garbage-value');
    const {result} = renderHook(() => useReceiptSize());
    expect(result.current.size).toBe('80mm');
    expect(document.documentElement.getAttribute('data-receipt-size')).toBe('80mm');
  });
});

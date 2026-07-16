// Receipt paper-size selector (owner directive 2026-07-16): two thermal receipt paper sizes
// must be customizable — 58mm (small mobile printer) and 80mm (standard thermal). The choice
// is persisted in localStorage so a terminal stays configured across sessions, and is mirrored
// onto <html data-receipt-size="..."> so app/index.css `@media print { html[data-receipt-size=...] #pos-slip }`
// can set the actual @page paper-feed width at print time.
//
// Why a hook (not a constant): React reads the attribute on mount + whenever the user changes
// the dropdown, and the same hook is consumed by PosScreen (for the dropdown UI) and by
// the print invocation (so window.print() sees the right width).
import {useCallback, useEffect, useState} from 'react';

export type ReceiptSize = '58mm' | '80mm';
export const RECEIPT_SIZES: ReadonlyArray<{value: ReceiptSize; label: string}> = [
  {value: '58mm', label: '58mm — small mobile thermal'},
  {value: '80mm', label: '80mm — standard thermal'},
];
const STORAGE_KEY = 'pos-receipt-size';
const DEFAULT: ReceiptSize = '80mm';

function applyToDom(size: ReceiptSize) {
  if (typeof document === 'undefined') return;
  document.documentElement.setAttribute('data-receipt-size', size);
}

function readStored(): ReceiptSize {
  if (typeof window === 'undefined') return DEFAULT;
  const v = window.localStorage.getItem(STORAGE_KEY);
  return v === '58mm' || v === '80mm' ? v : DEFAULT;
}

export function useReceiptSize(): {size: ReceiptSize; setSize: (s: ReceiptSize) => void} {
  const [size, setSizeState] = useState<ReceiptSize>(readStored);

  // Mirror the choice to <html data-receipt-size> whenever it changes (including first mount).
  useEffect(() => {
    applyToDom(size);
  }, [size]);

  // A second tab in the same browser can change localStorage without us knowing — sync on focus.
  // (Storage events fire across tabs but not within the same tab that wrote the value.)
  useEffect(() => {
    const onStorage = (e: StorageEvent) => {
      if (e.key === STORAGE_KEY) setSizeState(readStored());
    };
    window.addEventListener('storage', onStorage);
    return () => window.removeEventListener('storage', onStorage);
  }, []);

  const setSize = useCallback((s: ReceiptSize) => {
    if (typeof window !== 'undefined') window.localStorage.setItem(STORAGE_KEY, s);
    setSizeState(s);
  }, []);

  return {size, setSize};
}

// One-shot helper for non-React callers (used by the window.print() wrappers in PosScreen).
export function currentReceiptSize(): ReceiptSize {
  return readStored();
}

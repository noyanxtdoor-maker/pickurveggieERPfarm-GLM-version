// Inventory Usage Summary (T3.3 / 2026-07-17) — read-only aggregation over the negative
// inventory_movements produced by the "Log Stock Usage" flow (inventory_adjust_material called
// with a negative qty_delta and a "Used: ..." reason). Pure client-side aggregation over the
// rows the api already returns; no GL touch. Groups usage by category and by item, with a
// per-item recent-purposes list so the owner can see WHAT was used, WHEN, and FOR WHAT
// PURPOSE (e.g. "weed control on Pechay Plot 3").
import {round2} from '../pos/money';
import type {InventoryItem, ItemCategory, UsageMovement} from '../../types/db';

export interface UsageSummaryRow {
  key: string;        // category_key or item_id
  label: string;      // category name or item name
  qty: number;        // total units used
  cost: number;       // total ₱ consumed (FIFO-cost weighted)
  count: number;      // number of Usage log events
  pct: number;        // share of grand total (0-100), by qty
}

export interface UsageSummary {
  byCategory: UsageSummaryRow[];
  byItem: UsageSummaryRow[];  // top-N
  totalQty: number;
  totalCost: number;
  count: number;              // number of Usage log events
  recent: Array<{date: string; item: string; category: string; qty: number; cost: number; reason: string}>;
}

type Item = Omit<InventoryItem, 'available'>;

/** Strip the "Used:" prefix from a Usage reason so the UI can show just the purpose. */
function purposeOf(reason: string): string {
  return reason.startsWith('Used:') ? reason.slice(5).trim() : reason;
}

function rows(
  movements: UsageMovement[],
  keyFor: (m: UsageMovement) => {key: string; label: string; itemName: string; categoryName: string},
  total: number,
): UsageSummaryRow[] {
  const m = new Map<string, UsageSummaryRow>();
  for (const mov of movements) {
    const {key, label} = keyFor(mov);
    const row = m.get(key) ?? {key, label, qty: 0, cost: 0, count: 0, pct: 0};
    row.qty = round2(row.qty + mov.quantity);
    row.cost = round2(row.cost + mov.total_cost);
    row.count += 1;
    m.set(key, row);
  }
  return Array.from(m.values())
    .map((row) => ({...row, pct: total > 0 ? round2((row.qty / total) * 100) : 0}))
    .sort((a, b) => b.qty - a.qty);
}

/** Summarise usage by category and by item over the given Usage movements (already filtered). */
export function usageSummary(
  movements: UsageMovement[],
  itemsById: Map<string, Item>,
  categoriesById: Map<string, ItemCategory>,
): UsageSummary {
  const totalQty = round2(movements.reduce((s, m) => s + m.quantity, 0));
  const totalCost = round2(movements.reduce((s, m) => s + m.total_cost, 0));
  const byCategory = rows(movements, (mov) => {
    const cat = categoriesById.get(itemsById.get(mov.item_id)?.category_id ?? '');
    return {key: cat?.category_key ?? 'unknown', label: cat?.name ?? 'Uncategorised', itemName: '', categoryName: cat?.name ?? ''};
  }, totalQty);
  // top-10 items by qty
  const allByItem = rows(movements, (mov) => {
    const item = itemsById.get(mov.item_id);
    const cat = categoriesById.get(item?.category_id ?? '');
    return {key: mov.item_id, label: item?.name ?? 'Unknown item', itemName: item?.name ?? '', categoryName: cat?.name ?? ''};
  }, totalQty);
  // the 8 most recent usage events for the "Recent Activity" feed
  const recent = movements.slice(0, 8).map((mov) => {
    const item = itemsById.get(mov.item_id);
    const cat = categoriesById.get(item?.category_id ?? '');
    return {
      date: mov.created_at,
      item: item?.name ?? 'Unknown item',
      category: cat?.name ?? 'Uncategorised',
      qty: mov.quantity,
      cost: mov.total_cost,
      reason: purposeOf(mov.reason),
    };
  });
  return {
    byCategory,
    byItem: allByItem.slice(0, 10),
    totalQty,
    totalCost,
    count: movements.length,
    recent,
  };
}

/** Keep only Usage movements on/after `from` and on/before `to` (yyyy-mm-dd; empty = unbounded). */
export function filterUsageByPeriod(movements: UsageMovement[], from: string, to: string): UsageMovement[] {
  // created_at is a full ISO timestamp; compare on the date prefix.
  return movements.filter((m) => (!from || m.created_at.slice(0, 10) >= from) && (!to || m.created_at.slice(0, 10) <= to));
}

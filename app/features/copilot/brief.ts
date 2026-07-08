// CAP-VG1 Step 3 — Grounding: gathers today's events + open invoices + low-stock from the existing
// Dexie caches and renders a *non-AI* Morning Brief. This proves the grounding path with zero model
// dependency (spec §6 step 3). Reads only — no writes, no server calls, no money-path surface.
//
// The brief is a plain-text block the CopilotPanel renders as-is (no model needed) AND feeds into
// copilotApi.ask as grounded context when the LM Studio model is available (step 4).
import {offlineDB} from '../../core/offline/db';

export interface BriefSection {
  heading: string;
  items: string[];
}

export interface MorningBrief {
  date: string; // yyyy-mm-dd
  sections: BriefSection[];
  summary: string; // one-line plain-text summary
}

function todayISO(): string {
  return new Date().toISOString().slice(0, 10);
}

/** Gather the grounded brief from Dexie caches. All reads — scoped to the user's already-authorized data. */
export async function gatherBrief(companyId: string | null): Promise<MorningBrief> {
  const today = todayISO();
  const sections: BriefSection[] = [];

  // 1. Today's calendar events
  const events = companyId
    ? await offlineDB.calendarEvents
        .where('company_id')
        .equals(companyId)
        .filter((e) => e.event_date === today && e.status !== 'Cancelled')
        .toArray()
    : [];
  if (events.length > 0) {
    sections.push({
      heading: `Today's Events (${events.length})`,
      items: events.map((e) => {
        const time = e.start_time ? ` ${e.start_time}` : ' (all-day)';
        const priority = e.priority !== 'Normal' ? ` [${e.priority}]` : '';
        return `${e.title}${time}${priority}`;
      }),
    });
  }

  // 2. Open (unpaid) invoices
  const invoices = companyId
    ? await offlineDB.posInvoices
        .where('company_id')
        .equals(companyId)
        .filter((inv) => inv.status === 'Unpaid')
        .toArray()
    : [];
  if (invoices.length > 0) {
    const totalOutstanding = invoices.reduce((sum, inv) => sum + inv.total, 0);
    sections.push({
      heading: `Open Invoices (${invoices.length} — ₱${totalOutstanding.toFixed(2)} outstanding)`,
      items: invoices.map((inv) => {
        const num = inv.invoice_number ?? 'pending';
        return `#${num}: ₱${inv.total.toFixed(2)} — ${inv.sale_type ?? 'retail'}${inv.posted_by ? ` (${inv.posted_by})` : ''}`;
      }),
    });
  }

  // 3. Low-stock items (available < 10 — a heuristic threshold for the brief)
  const stockRows = companyId
    ? await offlineDB.materialStock.where('company_id').equals(companyId).toArray()
    : [];
  const lowStock = stockRows.filter((s) => s.available < 10);
  if (lowStock.length > 0) {
    // Resolve item names from the inventory cache
    const itemIds: string[] = [];
    for (const s of lowStock) { if (!itemIds.includes(s.item_id)) itemIds.push(s.item_id); }
    const items = await offlineDB.inventoryItems.bulkGet(itemIds);
    const nameMap = new Map(items.filter(Boolean).map((i) => [i!.id, i!.name]));
    sections.push({
      heading: `Low Stock Alert (${lowStock.length} item${lowStock.length > 1 ? 's' : ''})`,
      items: lowStock.map((s) => {
        const name = nameMap.get(s.item_id) ?? s.item_id;
        return `${name}: ${s.available} remaining`;
      }),
    });
  }

  // 4. In-progress projects (bonus grounding — shows active work)
  const projects = companyId
    ? await offlineDB.projects.where('company_id').equals(companyId).filter((p) => p.status === 'In Progress').toArray()
    : [];
  if (projects.length > 0) {
    sections.push({
      heading: `Active Projects (${projects.length})`,
      items: projects.map((p) => `${p.name ?? p.id} — ${p.status}`),
    });
  }

  const summary = sections.length > 0
    ? `${sections.length} brief section${sections.length > 1 ? 's' : ''}: ${sections.map((s) => s.heading).join('; ')}`
    : 'No events, open invoices, or low-stock items today. The farm is running smoothly.';

  return {date: today, sections, summary};
}

/** Render the brief as a plain-text block for the chat UI / LM Studio context. */
export function renderBriefText(brief: MorningBrief): string {
  const lines: string[] = [`Morning Brief — ${brief.date}`, ''];
  if (brief.sections.length === 0) {
    lines.push(brief.summary);
    return lines.join('\n');
  }
  for (const s of brief.sections) {
    lines.push(s.heading);
    for (const item of s.items) lines.push(`  - ${item}`);
    lines.push('');
  }
  return lines.join('\n').trimEnd();
}

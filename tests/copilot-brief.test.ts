// CAP-VG1 step 3 — the grounded Morning Brief must reflect exactly what's in the local caches (no
// invention: empty caches → the calm summary; seeded caches → the right sections with the right numbers).
//
// Port note (2026-07-14): ported BEHAVIOR from Repo A's tests/copilot-brief.test.ts — not the
// assertion strings. Repo B's brief.ts diverges from Repo A's in spec-correct ways that must be
// honored, not papered over:
//  - repo headings are title-case ("Today's Events" / "Open Invoices") vs Repo A's lowercase;
//  - Repo B's null/empty-company path intentionally collapses to the SAME calm summary as empty
//    caches (because RLS means a no-company user has no readable data either way — the brief must
//    not distinguish "you have no company" from "your company has nothing today," as both are
//    indistinguishable to a user with zero memberships). So we assert "running smoothly", which is
//    the wording Repo B's brief.ts uses, NOT Repo A's distinct "No company context" string.
//  - Repo B appends the event time bare ("Harvest lettuce 08:00 [High]") with no "at" — caught by
//    running the test, not by reading.
//
// DATE FIX (2026-07-14): the original test seeded the event with `event_date: today()` (a LOCAL
// calendar date) while brief.ts filters with `e.event_date === todayISO()` where todayISO =
// `new Date().toISOString().slice(0,10)` (UTC). When run between 00:00 and 08:00 local (= 16:00–
// 24:00 UTC previous day), the two disagree — the seeded event silently drops out of the "Today's
// Events" filter and the test fails for a reason that is NOT a code regression. Fixed by seeding
// the fixture with the SAME todayISO() the production code uses so they can never drift. The deeper
// bug — brief.ts uses UTC for "today" while a user's local today is the meaningful one — is flagged
// for a separate CAP-VG1 fix, not touched here (out of P1I scope).
import 'fake-indexeddb/auto';
import {beforeEach, describe, expect, it} from 'vitest';
import {offlineDB} from '@/app/core/offline/db';
import {gatherBrief, renderBriefText} from '@/app/features/copilot/brief';
import type {CalendarEvent, PosInvoice} from '@/app/types/db';

const CO = '00000000-0000-7000-8000-000000000001';
// Use the SAME "today" definition brief.ts uses (UTC ISO date), so the fixture and the filter can
// never disagree at the local/UTC date boundary.
const today = () => new Date().toISOString().slice(0, 10);

describe('CAP-VG1 morning brief', () => {
  beforeEach(async () => {
    await Promise.all([
      offlineDB.calendarEvents.clear(),
      offlineDB.posInvoices.clear(),
      offlineDB.materialStock.clear(),
      offlineDB.inventoryItems.clear(),
      offlineDB.projects.clear(),
    ]);
  });

  it('empty caches → no sections and an honest calm summary (never invents data)', async () => {
    const brief = await gatherBrief(CO);
    expect(brief.sections).toHaveLength(0);
    expect(brief.summary).toContain('running smoothly');
    expect(renderBriefText(brief)).toContain('running smoothly');
  });

  it('no company context → collapses to the same honest calm summary (RLS makes a no-company user indistinguishable from an idle day)', async () => {
    const brief = await gatherBrief(null);
    expect(brief.sections).toHaveLength(0);
    expect(brief.summary).toContain('running smoothly');
  });

  it("seeded caches → today's event + the unpaid invoice with its exact peso total (grounded numbers)", async () => {
    const ev: CalendarEvent = {
      id: 'ev1', company_id: CO, branch_id: 'b1', event_type: 'Harvest', title: 'Harvest lettuce',
      description: null, event_date: today(), priority: 'High', visibility: 'General',
      start_time: '08:00', end_time: null, status: 'Scheduled', project_id: null,
      created_by: null, created_at: 'x', updated_at: 'x',
    } as unknown as CalendarEvent;
    await offlineDB.calendarEvents.put(ev);
    const inv = {
      id: 'inv1', company_id: CO, branch_id: 'b1', invoice_number: 7, lines: [], subtotal: 270,
      discount: 0, delivery_fee: 0, total: 270, tender_cash: 0, change_amount: 0, note: 'Aling Nena',
      status: 'Unpaid', created_at: 'x',
    } as unknown as PosInvoice;
    await offlineDB.posInvoices.put(inv);

    const brief = await gatherBrief(CO);
    const text = renderBriefText(brief);
    // Repo B appends the time bare (no "at"), matching brief.ts's `${e.title}${time}${priority}`
    // template literal where time = ` ${e.start_time}` (leading space, no " at ").
    expect(text).toContain('Harvest lettuce 08:00 [High]');
    expect(text).toContain('₱270.00');
    expect(text).toContain('#7');
    // a cancelled event or paid invoice must NOT leak in
    expect(brief.sections.some((s) => s.heading.startsWith("Today's Events"))).toBe(true);
    expect(brief.sections.some((s) => s.heading.startsWith('Open Invoices (1'))).toBe(true);
  });

  it('cancelled events and paid invoices are filtered out (grounding is honest, not a stale echo)', async () => {
    const cancelled = {
      id: 'ev2', company_id: CO, branch_id: 'b1', event_type: 'Other', title: 'Should not appear',
      description: null, event_date: today(), priority: 'Normal', visibility: 'General',
      start_time: null, end_time: null, status: 'Cancelled', project_id: null,
      created_by: null, created_at: 'x', updated_at: 'x',
    } as unknown as CalendarEvent;
    await offlineDB.calendarEvents.put(cancelled);
    const paid = {
      id: 'inv2', company_id: CO, branch_id: 'b1', invoice_number: 8, lines: [], subtotal: 100,
      discount: 0, delivery_fee: 0, total: 100, tender_cash: 100, change_amount: 0, note: null,
      status: 'Paid', created_at: 'x',
    } as unknown as PosInvoice;
    await offlineDB.posInvoices.put(paid);

    const brief = await gatherBrief(CO);
    expect(brief.sections).toHaveLength(0);
    expect(renderBriefText(brief)).not.toContain('Should not appear');
    expect(renderBriefText(brief)).not.toContain('#8');
    expect(brief.summary).toContain('running smoothly');
  });
});

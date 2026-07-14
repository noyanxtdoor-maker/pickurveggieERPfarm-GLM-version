// Real-mode reference-table hydration. Several screens (POS, Inventory, Approvals, Customers,
// Accounting) need `branches` in the local Dexie cache to pick a default branch — but nothing pulls it
// down on login, only whichever screen a user happens to visit warms it as a side effect (Approvals and
// Branches screens do this inline; Branches screen too — see ad-hoc calls in those files).
//
// A role scoped to just `pos.sell` has no reason to ever open Approvals or Branches, so on a fresh device
// their cache stays permanently empty and every branch-dependent screen spins forever (Repo A found this
// live 2026-07-13; Repo B has the same latent structure minus the helper). Call this once per screen
// mount instead of duplicating the fetch + bulkPut inline.
import {supabase} from '../supabase/client';
import {offlineDB} from './db';
import {MOCK_MODE} from '../mock/mock';

// Fire-and-forget: best-effort warm. Failures swallow silently — the screen still reads whatever's in
// Dexie, and the next manual tap-to-sync will retry via the standard path.
export function hydrateBranches(companyId: string): void {
  if (MOCK_MODE) return;
  if (typeof navigator !== 'undefined' && !navigator.onLine) return;
  void Promise.resolve(supabase.from('branches').select('*').eq('company_id', companyId))
    .then(({data}) => {if (data) void offlineDB.branches.bulkPut(data as never[]);})
    .catch(() => undefined);
}

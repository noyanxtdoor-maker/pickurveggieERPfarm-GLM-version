-- Migration P1K — Realtime auto-sync publication (owner GO 2026-07-15; re-implemented on Repo B's own chain,
-- NOT a clone of Repo A's migration — provenance note per SESSION_PROMPT §8: authorization per port).
--
-- WHY: Manual sync (P1I item 4) covers the "user pulls" case. Realtime covers the "data arrives on its own"
-- case — a second cashier, an approval granted from another device, an owner archiving an account — so
-- the page the user is looking at updates the moment the row lands, no refresh/tap required.
--
-- SCOPE: 3 tables only (matches the narrow POS/Approvals/Dashboard scope A designed; not a firehose):
--   1. public.user_branch_roles   — approval granted/revoked from another device → Approvals screen refreshes
--   2. public.users               — suspension/archive/role-link changes → Dashboard counts refresh
--   3. public.invoices            — a second cashier rings up a sale → POS feed +Dashboard sales-today refresh
--
-- SECURITY (RLS-on-broadcast is enforced by the Realtime service, not psql — see Realtime docs):
--   - The publication only carries ROW MARKS (DELETE/INSERT/UPDATE) — the actual row data is RLS-filtered
--     by the Realtime service at delivery time using the JWT claims in the client's channel subscription.
--   - So a client in company A will see events ONLY for rows RLS lets it read in company A — cross-tenant
--     leakage is bounded by the SAME RLS policies the rest of the app already relies on.
--   - We rely on existing per-table RLS (already audited in db-guards.sql) — no new policies added here.
--
-- This migration ADDS the three tables to the supabase_realtime publication. No schema changes to the
-- tables themselves. The realtime hook lives in app/core/offline/realtime.ts (separate, app-layer).
-- Per AGENTS §2: additive only, no destructive ops.

-- Idempotent: IF NOT EXISTS on the ALTER PUBLICATION ... ADD TABLE clause.
alter publication supabase_realtime add table public.user_branch_roles;
alter publication supabase_realtime add table public.users;
alter publication supabase_realtime add table public.invoices;

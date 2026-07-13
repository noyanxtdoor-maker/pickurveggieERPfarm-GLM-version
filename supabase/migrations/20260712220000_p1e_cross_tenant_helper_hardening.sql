-- Migration P1E (Repo B adaptation) — Cross-tenant hardening on 5 pre-existing money/inventory
-- helper functions (per-port read-only from Repo A's P1E by owner GO 2026-07-13 "go all of them").
-- Authority: Repo A's 20260712220000_p1e_cross_tenant_helper_hardening.sql (the source — read-only
--   port per SESSION_PROMPT §8, "authorization is PER PORT, from the owner") · CLAUDE.md §6 (money
--   paths are gated) · C7 §0/§2 (tenant isolation, permission-based authz).
-- Per-port adaptation (the divergence from Repo A): Repo A's P1E also hardened a 7th function,
--   `finance_resolve_pay_code`, which depends on the `financial_accounts` table (the B2A digital-
--   payments slice Repo B has not yet built). That hardening rides IN with the B2A port (item E of
--   this multi-item port sequence) where Repo B's chain first introduces `financial_accounts`. The
--   5 functions hardened here are exactly the ones whose dependencies already exist in Repo B's
--   chain. (pos_next_seq is the 6th item below — 5 ensure_* + 1 seq = 6 total functions hardened;
--   Repo A's count of "7" included finance_resolve_pay_code; the title of this file says "5" for
--   the *_ensure_* group only, plus pos_next_seq separately — see §5 below.)
-- Finding (verbatim from Repo A — applicable 1:1 to Repo B's chain): pos_ensure_accounts,
--   inventory_ensure_categories, inventory_ensure_accounts, payroll_ensure_accounts, and pos_next_seq
--   are all SECURITY DEFINER, granted directly to `authenticated`, and NONE of them verify the caller
--   actually belongs to p_company — they trust the argument outright. Every EXISTING call site is
--   safe (each passes a v_company the calling function already derived from a branch/account the
--   caller was independently checked against — verified by reading every call site in the migration
--   history before writing this fix), but each function is ALSO independently reachable by ANY
--   authenticated user via the public RPC endpoint, bypassing those upstream checks entirely. Impact:
--   pos/inventory/payroll_ensure_* let a stranger silently pre-populate another company's chart-of-
--   accounts/item-categories with boilerplate rows (low severity — the rows are standard scaffolding,
--   and the target's own RLS still hides them from view — but a real, unauthorized cross-tenant
--   write). pos_next_seq lets a stranger burn/skip another company's invoice/order/journal sequence
--   numbers (a minor DoS-style annoyance, no data exposure).
-- Fix: each function now requires the caller to actually belong to p_company — pure defense-in-depth;
--   every legitimate call chain is unaffected, since legitimate callers are already members of the
--   company they're operating in by construction.
-- Risk: Low (additive check only; no money-math, no rank/authz-model change).
-- Pattern: `create or replace` on each function (the same evolution mechanism already used for these
--   functions in their original migrations — none of them have called `alter function` syntax in
--   their original definitions; they were all `create or replace` from day one, so this is the
--   documented evolution path per AGENTS.md §2 "Migrations are immutable once committed. Evolve
--   schema via NEW additive migrations; functions evolve via drop+recreate in a new file" — and
--   create-or-replace is the additive flavor of drop+recreate for functions whose signature is stable).

-- =============================================================================
-- 1. pos_ensure_accounts — prepend membership check (unchanged function body after)
-- =============================================================================
create or replace function public.pos_ensure_accounts(p_company uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_company not in (select public.accessible_company_ids()) then
    raise exception 'permission denied: not a member of this company' using errcode = 'insufficient_privilege';
  end if;
  insert into public.chart_of_accounts (company_id, account_code, name, account_type, normal_balance) values
    (p_company, 'CASH',        'Cash on Hand',            'Asset',   'debit'),
    (p_company, 'SALES',       'Sales Revenue',           'Revenue', 'credit'),
    (p_company, 'COGS',        'Cost of Goods Sold',      'Expense', 'debit'),
    (p_company, 'FG_INVENTORY','Finished Goods Inventory','Asset',   'debit'),
    (p_company, 'AR',          'Accounts Receivable',     'Asset',   'debit')
  on conflict (company_id, account_code) do nothing;
end; $$;

-- =============================================================================
-- 2. inventory_ensure_categories — prepend membership check
-- =============================================================================
create or replace function public.inventory_ensure_categories(p_company uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_company not in (select public.accessible_company_ids()) then
    raise exception 'permission denied: not a member of this company' using errcode = 'insufficient_privilege';
  end if;
  insert into public.item_categories (company_id, category_key, name) values
    (p_company, 'seeds',     'Seeds/Seedlings'),
    (p_company, 'substrate', 'Substrate & Nutrients'),
    (p_company, 'packaging', 'Packaging'),
    (p_company, 'utilities', 'Water/Electricity'),
    (p_company, 'transport', 'Transport'),
    (p_company, 'misc',      'Miscellaneous'),
    (p_company, 'equipment', 'Equipment')
  on conflict (company_id, category_key) do nothing;
end; $$;

-- =============================================================================
-- 3. inventory_ensure_accounts — prepend membership check (calls pos_ensure_accounts, also hardened)
-- =============================================================================
create or replace function public.inventory_ensure_accounts(p_company uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_company not in (select public.accessible_company_ids()) then
    raise exception 'permission denied: not a member of this company' using errcode = 'insufficient_privilege';
  end if;
  perform public.pos_ensure_accounts(p_company);
  insert into public.chart_of_accounts (company_id, account_code, name, account_type, normal_balance) values
    (p_company, 'RAW_MATERIALS',      'Raw Materials Inventory',   'Asset',   'debit'),
    (p_company, 'EQUIPMENT',          'Equipment Assets',          'Asset',   'debit'),
    (p_company, 'SHRINKAGE',          'Inventory Shrinkage',       'Expense', 'debit'),
    (p_company, 'OPERATING_EXPENSES', 'Operating Expenses',        'Expense', 'debit'),
    (p_company, 'OWNER_EQUITY',       'Owner''s Equity',           'Equity',  'credit'),
    (p_company, 'LOANS_PAYABLE',      'Loans Payable',             'Liability','credit'),
    (p_company, 'OTHER_INCOME',       'Other Income',              'Revenue', 'credit')
  on conflict (company_id, account_code) do nothing;
end; $$;
comment on function public.inventory_ensure_accounts(uuid) is 'P2-M3A/M4A, tenant-hardened P1E: idempotent chart-of-accounts seed for inventory + accounting (22.03). Extends pos_ensure_accounts.';

-- =============================================================================
-- 4. payroll_ensure_accounts — prepend membership check (calls inventory_ensure_accounts, hardened)
-- =============================================================================
create or replace function public.payroll_ensure_accounts(p_company uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_company not in (select public.accessible_company_ids()) then
    raise exception 'permission denied: not a member of this company' using errcode = 'insufficient_privilege';
  end if;
  perform public.inventory_ensure_accounts(p_company);
  insert into public.chart_of_accounts (company_id, account_code, name, account_type, normal_balance) values
    (p_company, 'WAGES_EXPENSE',    'Labor & Wages Expense', 'Expense', 'debit'),
    (p_company, 'EMPLOYEE_ADVANCES','Employee Cash Advances','Asset',   'debit')
  on conflict (company_id, account_code) do nothing;
end; $$;

-- =============================================================================
-- 5. pos_next_seq — prepend membership check. Closes the same missing-membership-check pattern for
--    sequence-number consumption; even restricted to `authenticated`, any authenticated user of ANY
--    company could call it directly for a STRANGER company's sequence, burning/skipping their
--    invoice/order/journal numbers (minor DoS-style annoyance, no data read/leak since pos_sequences
--    itself is never selected from directly, but the same missing-membership-check pattern).
-- =============================================================================
create or replace function public.pos_next_seq(p_company uuid, p_branch uuid, p_kind text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare v bigint;
begin
  if p_company not in (select public.accessible_company_ids()) then
    raise exception 'permission denied: not a member of this company' using errcode = 'insufficient_privilege';
  end if;
  insert into public.pos_sequences (company_id, branch_id, kind, next_value)
    values (p_company, p_branch, p_kind, 2)
  on conflict (company_id, branch_id, kind) do update set next_value = public.pos_sequences.next_value + 1
  returning next_value - 1 into v;
  return v;
end; $$;

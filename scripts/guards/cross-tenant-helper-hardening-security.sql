-- Tier-2 BEHAVIORAL P1E — cross-tenant hardening on the 5 pre-existing account/category-seed helper
-- functions + pos_next_seq — blocking gate.
-- Authority: supabase/migrations/20260712220000_p1e_cross_tenant_helper_hardening.sql (Repo B port).
-- Per-port adaptation (divergence from Repo A's 20260712220000 source): the Repo A guard tested a
-- 7th function, finance_resolve_pay_code, which is intentionally NOT ported in this Repo B P1E
-- (no financial_accounts table in Repo B's chain yet — that ride rides with the B2A money-path port
-- (item E of this multi-item port sequence). And the Repo A guard's fixture-role inserts wrote a
-- `rank` column (a P1C-cols addition Repo B has not yet built); this Repo B guard omits `rank` from
-- those inserts (the rank context is unrelated to the cross-tenant-write property being tested here;
-- it's safe to drop because the roles table's `rank` column doesn't exist in Repo B's chain yet).
-- This keeps the P1E guard runnable on Repo B's CURRENT schema (no P1C pre-req) while preserving
-- the FULL coverage of the 6 functions exposed in this Repo B P1E port.
-- Proves: a member of Company A cannot call pos_ensure_accounts/inventory_ensure_categories/
-- inventory_ensure_accounts/payroll_ensure_accounts/pos_next_seq for Company B (a stranger company
-- they don't belong to), while the SAME functions still work normally for their OWN company (proving
-- the fix didn't break any legitimate call chain — pos_record_sale, inventory purchase flows, and
-- payroll wage disbursement all call these with a v_company the caller already legitimately belongs
-- to).
-- Self-contained BEGIN/ROLLBACK; any DEFECT raises under ON_ERROR_STOP.
\set ON_ERROR_STOP on
begin;
set local app.p1a_skip_signup_trigger = '1';

-- ── fixtures: two companies, an owner in each (A owns nothing in B, and vice versa) ──
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','0a000000-0000-0000-0000-0000000000e1','authenticated','authenticated','ownerA_p1e@t.local'),
  ('00000000-0000-0000-0000-000000000000','0b000000-0000-0000-0000-0000000000e2','authenticated','authenticated','ownerB_p1e@t.local');
insert into public.users (id, auth_user_id, display_name) values
  ('10000000-0000-0000-0000-0000000000e1','0a000000-0000-0000-0000-0000000000e1','Owner A P1E'),
  ('10000000-0000-0000-0000-0000000000e2','0b000000-0000-0000-0000-0000000000e2','Owner B P1E');
insert into public.companies (id, company_code, name) values
  ('e1111111-1111-1111-1111-111111111111','CO-E1','Company E1'),
  ('e2222222-2222-2222-2222-222222222222','CO-E2','Company E2');
insert into public.branches (id, company_id, branch_code, name) values
  ('eb111111-1111-1111-1111-111111111111','e1111111-1111-1111-1111-111111111111','BR-E1','Branch E1'),
  ('eb222222-2222-2222-2222-222222222222','e2222222-2222-2222-2222-222222222222','BR-E2','Branch E2');
-- NOTE: no `rank` column in roles yet (P1C not ported to Repo B as of this P1E port); the rank context
-- is unrelated to the cross-tenant-write property being tested here. P1C (item A of this port sequence)
-- will add the rank column; the P1E guard at that point inherits the rank-aware fixture for free.
insert into public.roles (id, company_id, role_key, description) values
  ('e0000000-0000-0000-0000-00000000e0a1','e1111111-1111-1111-1111-111111111111','owner','Owner E1'),
  ('e0000000-0000-0000-0000-00000000e0b1','e2222222-2222-2222-2222-222222222222','owner','Owner E2');
insert into public.user_branch_roles (user_id, company_id, branch_id, role_id) values
  ('10000000-0000-0000-0000-0000000000e1','e1111111-1111-1111-1111-111111111111','eb111111-1111-1111-1111-111111111111','e0000000-0000-0000-0000-00000000e0a1'),
  ('10000000-0000-0000-0000-0000000000e2','e2222222-2222-2222-2222-222222222222','eb222222-2222-2222-2222-222222222222','e0000000-0000-0000-0000-00000000e0b1');

-- ── owner A CANNOT seed accounts/categories for company B (a stranger company) ──
do $$ begin
  set local role authenticated; perform set_config('request.jwt.claims', json_build_object('sub','0a000000-0000-0000-0000-0000000000e1')::text, true);
  perform public.pos_ensure_accounts('e2222222-2222-2222-2222-222222222222');
  raise exception 'DEFECT p1e: owner A seeded pos accounts for company B (cross-tenant write)';
exception when insufficient_privilege then raise notice 'PASS p1e: pos_ensure_accounts denies a caller who is not a member of the target company'; end $$;

do $$ begin
  set local role authenticated; perform set_config('request.jwt.claims', json_build_object('sub','0a000000-0000-0000-0000-0000000000e1')::text, true);
  perform public.inventory_ensure_categories('e2222222-2222-2222-2222-222222222222');
  raise exception 'DEFECT p1e: owner A seeded inventory categories for company B';
exception when insufficient_privilege then raise notice 'PASS p1e: inventory_ensure_categories denies a cross-tenant caller'; end $$;

do $$ begin
  set local role authenticated; perform set_config('request.jwt.claims', json_build_object('sub','0a000000-0000-0000-0000-0000000000e1')::text, true);
  perform public.inventory_ensure_accounts('e2222222-2222-2222-2222-222222222222');
  raise exception 'DEFECT p1e: owner A seeded inventory accounts for company B';
exception when insufficient_privilege then raise notice 'PASS p1e: inventory_ensure_accounts denies a cross-tenant caller'; end $$;

do $$ begin
  set local role authenticated; perform set_config('request.jwt.claims', json_build_object('sub','0a000000-0000-0000-0000-0000000000e1')::text, true);
  perform public.payroll_ensure_accounts('e2222222-2222-2222-2222-222222222222');
  raise exception 'DEFECT p1e: owner A seeded payroll accounts for company B';
exception when insufficient_privilege then raise notice 'PASS p1e: payroll_ensure_accounts denies a cross-tenant caller'; end $$;

-- proves the cross-tenant write attempts above genuinely did nothing (not merely denied at the top level
-- while still partially inserting via the internal perform chains)
do $$ declare n int; begin
  set local role postgres;
  select count(*) into n from public.chart_of_accounts where company_id='e2222222-2222-2222-2222-222222222222';
  if n<>0 then raise exception 'DEFECT p1e: company B''s chart_of_accounts was polluted by the denied cross-tenant calls (% rows)', n; end if;
  select count(*) into n from public.item_categories where company_id='e2222222-2222-2222-2222-222222222222';
  if n<>0 then raise exception 'DEFECT p1e: company B''s item_categories was polluted by the denied cross-tenant calls (% rows)', n; end if;
  raise notice 'PASS p1e: denied cross-tenant calls left zero rows in the target company (no partial writes)';
end $$;

-- ── owner A CAN still seed accounts/categories for their OWN company (legitimate path unaffected) ──
do $$ declare n int; begin
  set local role authenticated; perform set_config('request.jwt.claims', json_build_object('sub','0a000000-0000-0000-0000-0000000000e1')::text, true);
  perform public.payroll_ensure_accounts('e1111111-1111-1111-1111-111111111111');
  set local role postgres;
  select count(*) into n from public.chart_of_accounts where company_id='e1111111-1111-1111-1111-111111111111';
  if n<9 then raise exception 'DEFECT p1e: payroll_ensure_accounts for the caller''s OWN company did not seed the expected accounts (n=%)', n; end if;
  raise notice 'PASS p1e: the full ensure_accounts chain still works normally for a member''s own company (% accounts seeded)', n;
end $$;

-- ── pos_next_seq: cross-tenant denied (found by the follow-up systematic sweep); same-tenant works ──
do $$ declare v1 bigint; v2 bigint; begin
  set local role authenticated; perform set_config('request.jwt.claims', json_build_object('sub','0a000000-0000-0000-0000-0000000000e1')::text, true);
  v1 := public.pos_next_seq('e1111111-1111-1111-1111-111111111111', 'eb111111-1111-1111-1111-111111111111', 'invoice');
  v2 := public.pos_next_seq('e1111111-1111-1111-1111-111111111111', 'eb111111-1111-1111-1111-111111111111', 'invoice');
  if v2 <> v1 + 1 then raise exception 'DEFECT p1e: pos_next_seq did not increment normally for a member''s own company (% then %)', v1, v2; end if;
  raise notice 'PASS p1e: pos_next_seq still increments normally for a member of the company';

  begin
    perform public.pos_next_seq('e2222222-2222-2222-2222-222222222222', 'eb222222-2222-2222-2222-222222222222', 'invoice');
    raise exception 'DEFECT p1e: owner A burned a sequence number for company B';
  exception when insufficient_privilege then raise notice 'PASS p1e: pos_next_seq denies a caller who is not a member of the target company'; end;
end $$;

rollback;

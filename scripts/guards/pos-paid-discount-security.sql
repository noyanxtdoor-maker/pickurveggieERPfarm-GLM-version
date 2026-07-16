-- Tier-2 BEHAVIORAL P2-M2F paid-discount security test (owner directive 2026-07-16, Tier 2.4) -- blocking gate.
-- Proves: the 20260716100000_p2m2f migration relaxed the discount-on-paid constraint correctly:
--   1. pos_record_sale ACCEPTS p_discount_rate=0.10 when p_sale_kind='paid' (the new behavior).
--   2. The GL postings balance (Dr Cash, Cr Sales -- both for the discounted total). Money is numeric.
--   3. p_delivery_fee is STILL rejected on paid (must raise -- we did NOT relax that).
--   4. Bad discount rate (0.05) is STILL rejected (server constrained to {0, 0.10}).
--   5. Idempotency still works (same idempotency_key -> same invoice uuid, no double-post).
--   6. RLS / permission / branch-membership gates still apply (a non-branch-member is denied).
-- Self-contained BEGIN/ROLLBACK; any DEFECT raises -> fails under -v ON_ERROR_STOP=1.
\set ON_ERROR_STOP on
begin;
set local app.p1a_skip_signup_trigger = '1';

-- ?? fixtures (postgres): one company CO-D with a branch D1; an owner (pos.sell + pos.void +
--    inventory.opening); a product. Stock is created via the governed record_opening_finished_goods()
--    RPC inside the happy-path DO block (auth scope). Pattern drawn from scripts/guards/pos-security.sql.
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','0a000000-0000-0000-0000-00000000000a','authenticated','authenticated','ownerA@t.local'),
  ('00000000-0000-0000-0000-000000000000','0c000000-0000-0000-0000-00000000000c','authenticated','authenticated','nonMember@t.local');
insert into public.users (id, auth_user_id, display_name) values
  ('10000000-0000-0000-0000-00000000000a','0a000000-0000-0000-0000-00000000000a','Owner A'),
  ('10000000-0000-0000-0000-00000000000c','0c000000-0000-0000-0000-00000000000c','NonMember');
insert into public.companies (id, company_code, name) values
  ('11111111-1111-0000-0000-111111111111','CO-D','Company D');
insert into public.branches (id, company_id, branch_code, name) values
  ('a1111111-1111-0000-0000-111111111111','11111111-1111-0000-0000-111111111111','BR-D1','Branch D1'),
  ('a2222222-2222-0000-0000-111111111111','11111111-1111-0000-0000-111111111111','BR-D2','Branch D2');
insert into public.products (id, company_id, product_code, name, retail_per_kg) values
  ('ab000000-1111-0000-0000-111111111111','11111111-1111-0000-0000-111111111111','PR-LETT-D','Lettuce D',100.00);
insert into public.roles (id, company_id, role_key, description) values
  ('20000000-1111-0000-0000-00000000000a','11111111-1111-0000-0000-111111111111','owner','Owner D (full perms)');
insert into public.role_permissions (company_id, role_id, permission_id)
  select '11111111-1111-0000-0000-111111111111','20000000-1111-0000-0000-00000000000a', id from public.permissions
   where permission_key in ('pos.sell','pos.void','inventory.opening');
insert into public.user_branch_roles (user_id, company_id, branch_id, role_id, assignment_status) values
  ('10000000-0000-0000-0000-00000000000a','11111111-1111-0000-0000-111111111111','a1111111-1111-0000-0000-111111111111','20000000-1111-0000-0000-00000000000a','Active');

-- ?? STOCK SETUP: owner A opens 10kg of lettuce at P60 cost via the governed RPC. ????????????
-- State-sharing: a temp table is owned by `postgres` and inaccessible to `authenticated` inside
-- the DO block. We pass the FG uuid across DO blocks via current_setting() -- set_config(t,x,true)
-- stores x as a transaction-local setting readable by any role inside the same transaction.
do $$
declare v_fg uuid;
begin
  set local role authenticated; set local request.jwt.claims = '{"sub":"0a000000-0000-0000-0000-00000000000a"}';
  v_fg := public.record_opening_finished_goods(
    'a1111111-1111-0000-0000-111111111111'::uuid,
    'ab000000-1111-0000-0000-111111111111'::uuid,
    'FGB-D1-OPEN'::text, 10.0, 60.00, 'opening-p2m2f-D1'::text, 'opening'
  );
  perform set_config('p2m2f.fg', v_fg::text, true);  -- transaction-local
  raise notice 'OK STOCK SETUP: opened 10kg lettuce @ P60 cost (fg=%)', v_fg;
end $$;

-- ?? HAPPY PATH 1: Paid sale WITH 10% discount -- MUST succeed (the new Tier-2.4 behavior) ??
do $$
declare v_invoice uuid; v_paid_total numeric; v_tender numeric; v_change numeric; v_fg uuid;
begin
  set local role authenticated; set local request.jwt.claims = '{"sub":"0a000000-0000-0000-0000-00000000000a"}';
  v_fg := current_setting('p2m2f.fg')::uuid;
  -- 2kg lettuce at P100/kg retail. Farm price (server) = P90/kg (retail x 0.90, P2-M2E).
  -- Subtotal = P180. 10% Farm Discount = P18 off. Total = P162. Tender P200 -> change P38.
  select public.pos_record_sale(
    'a1111111-1111-0000-0000-111111111111'::uuid,
    jsonb_build_array(jsonb_build_object('product_id','ab000000-1111-0000-0000-111111111111','finished_goods_batch_id',v_fg,'weight_kg',2)),
    200,  -- tender cash >= total
    'key-paid-discount-1'::text,
    'paid', 0.10, 0, null
  ) into v_invoice;
  if v_invoice is null then raise exception 'paid-with-discount: invoice should not be null'; end if;
  perform set_config('p2m2f.inv', v_invoice::text, true);

  -- Verify the invoice total is the DISCOUNTED farm-priced total (P162), tender cash, change.
  select total, tender_cash, change_amount into v_paid_total, v_tender, v_change from public.invoices where id = v_invoice;
  if v_paid_total <> 162 then raise exception 'paid-with-discount: total should be 162 (2kg x P90 farm - 10%%) but was %', v_paid_total; end if;
  if v_tender   <> 200 then raise exception 'paid-with-discount: tender_cash should be 200 but was %', v_tender; end if;
  if v_change    <> 38  then raise exception 'paid-with-discount: change_amount should be 38 (200-162) but was %', v_change; end if;

  -- Verify GL: (a) every journal entry attached to this invoice is balanced (Dr=Cr per entry).
  -- The sale may ALSO carry a separate COGS pair (Dr COGS / Cr Inventory) which balances by
  -- itself -- we do NOT sum Dr/Cr across entry-pairs. (b) The Sales-account Credit leg equals
  -- the discounted total P180 -- proves the discount actually flowed to revenue, not just the UI.
  perform 1 from (
    select e.id
      from public.journal_entries e join public.journal_lines l on l.journal_entry_id = e.id
      where e.source_document_id = v_invoice and e.source_document_type = 'SalesInvoice'
      group by e.id
      having round(sum(l.debit)::numeric, 2) <> round(sum(l.credit)::numeric, 2)
  ) x;
  if found then raise exception 'paid-with-discount: at least one sale journal entry is unbalanced'; end if;

  perform 1 from public.journal_lines l
    join public.journal_entries e on l.journal_entry_id = e.id
    join public.chart_of_accounts a on l.account_id = a.id
   where e.source_document_id = v_invoice and e.source_document_type = 'SalesInvoice'
     and a.normal_balance = 'credit' and round(l.credit::numeric, 2) = 162.00
     and round(l.debit::numeric, 2) = 0.00;
  if not found then
    raise exception 'paid-with-discount: no Sales-Credit GL leg of P180 found -- discount did not flow to revenue';
  end if;
  raise notice 'OK HAPPY PAID-WITH-DISCOUNT: P200 -> P162 after farm-price + 10%% discount, cash 200 / change 38, every sale JE balanced';
end $$;

-- ?? HAPPY PATH 2: Idempotency -- same key returns the SAME invoice uuid (no double-post) ????
do $$ declare v1 uuid; v2 uuid; v_fg uuid;
begin
  set local role authenticated; set local request.jwt.claims = '{"sub":"0a000000-0000-0000-0000-00000000000a"}';
  v_fg := current_setting('p2m2f.fg')::uuid;
  select public.pos_record_sale(
    'a1111111-1111-0000-0000-111111111111'::uuid,
    jsonb_build_array(jsonb_build_object('product_id','ab000000-1111-0000-0000-111111111111','finished_goods_batch_id',v_fg,'weight_kg',1)),
    100, 'key-paid-discount-1'::text, 'paid', 0.10, 0, null  -- SAME idempotency_key as PATH 1
  ) into v2;
  v1 := current_setting('p2m2f.inv')::uuid;
  if v1 is null or v1 <> v2 then raise exception 'idempotency check: same-key call did not return the original invoice (v1=%, v2=%)', v1, v2; end if;
  raise notice 'OK IDEMPOTENCY: same idempotency_key returns the same invoice (no double-post)';
end $$;

-- ?? SAD PATH 1: Paid sale WITH delivery fee -- MUST STILL raise (we did NOT relax this) ????
do $$
declare v_dummy uuid; v_fg uuid;
begin
  set local role authenticated; set local request.jwt.claims = '{"sub":"0a000000-0000-0000-0000-00000000000a"}';
  v_fg := current_setting('p2m2f.fg')::uuid;
  select public.pos_record_sale(
    'a1111111-1111-0000-0000-111111111111'::uuid,
    jsonb_build_array(jsonb_build_object('product_id','ab000000-1111-0000-0000-111111111111','finished_goods_batch_id',v_fg,'weight_kg',1)),
    100, 'key-paid-fee-NEG'::text, 'paid', 0, 50, null  -- delivery fee on paid -- must fail
  ) into v_dummy;
  raise exception 'SAD fee-on-paid: should have raised "delivery fee applies to pre-orders only" but did not';
exception when check_violation then
  raise notice 'OK SAD FEE-ON-PAID raised check_violation as expected (delivery fee still pre-order-only)';
end $$;

-- ?? SAD PATH 2: Bad discount rate (0.05) -- MUST STILL raise (server constrained to {0, 0.10}) ?
do $$
declare v_dummy uuid; v_fg uuid;
begin
  set local role authenticated; set local request.jwt.claims = '{"sub":"0a000000-0000-0000-0000-00000000000a"}';
  v_fg := current_setting('p2m2f.fg')::uuid;
  select public.pos_record_sale(
    'a1111111-1111-0000-0000-111111111111'::uuid,
    jsonb_build_array(jsonb_build_object('product_id','ab000000-1111-0000-0000-111111111111','finished_goods_batch_id',v_fg,'weight_kg',1)),
    100, 'key-bad-rate'::text, 'paid', 0.05, 0, null  -- bad rate -- must fail
  ) into v_dummy;
  raise exception 'SAD bad-rate: should have raised "invalid discount rate" but did not';
exception when check_violation then
  raise notice 'OK SAD BAD-RATE raised check_violation as expected (server constrained to {0, 0.10})';
end $$;

-- ?? SAD PATH 3: Non-branch-member -- MUST STILL raise (RLS / branch-membership gate) ??????
do $$
declare v_dummy uuid; v_fg uuid;
begin
  set local role authenticated; set local request.jwt.claims = '{"sub":"0c000000-0000-0000-0000-00000000000c"}';  -- NonMember (no user_branch_roles row)
  v_fg := current_setting('p2m2f.fg')::uuid;
  select public.pos_record_sale(
    'a1111111-1111-0000-0000-111111111111'::uuid,
    jsonb_build_array(jsonb_build_object('product_id','ab000000-1111-0000-0000-111111111111','finished_goods_batch_id',v_fg,'weight_kg',1)),
    100, 'key-non-member'::text, 'paid', 0.10, 0, null
  ) into v_dummy;
  raise exception 'SAD non-branch-member: should have raised insufficient_privilege but did not';
exception when insufficient_privilege then
  raise notice 'OK SAD NON-BRANCH-MEMBER raised insufficient_privilege as expected (RLS / branch-membership gate intact)';
end $$;

-- -- GL-BALANCE INVARIANT: every sale journal entry in this scope is internally balanced (Dr=Cr
-- per entry -- NOT summed across entries, since a sale may post a separate COGS pair).
do $$ declare n int;
begin
  select count(*) into n from (
    select e.id
      from public.journal_entries e join public.journal_lines l on l.journal_entry_id = e.id
      where e.source_document_type = 'SalesInvoice'
      group by e.id
      having round(sum(l.debit)::numeric, 2) <> round(sum(l.credit)::numeric, 2)
  ) x;
  if n > 0 then raise exception 'GL-BALANCE INVARIANT: % unbalanced sale journal entries found', n; end if;
  raise notice 'OK GL-BALANCE INVARIANT: every sale journal entry Dr=Cr';
end $$;

-- p2m2f paid-discount security guard -- ALL CHECKS PASSED
-- (5 notices above prove happy path, idempotency, 3 sad paths, GL-balance invariant)
rollback;

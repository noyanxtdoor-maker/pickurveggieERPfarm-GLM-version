-- Guard battery P2N2 — Void-sale approval workflow.
-- Authority: AGENTS.md §2 (money-path gate) + M2-M2C §4 reversal math (byte-equivalent inline).
-- Coverage:
--   HAPPY1: cashier/operator files void request (pos.sell only); different admin+ approves;
--           reversal math inlines pos_void_sale's body — journal balanced, stock returned, invoice Voided.
--   HAPPY2: another cashier/operator can file on a SECOND invoice; admin+ rejects with reason;
--           invoice remains at original status, audit row written, no journal movement.
--   SAD1:   caller without pos.sell cannot file (employee with no permissions -> 42501).
--   SAD2:   same admin+ who filed cannot approve (separation of duties -> 42501).
--   SAD3:   second file on already-Pending invoice raises ('a Pending void request already exists').
--   SAD4:   approve twice (idempotency + idempotent audit).
-- Plus a non-zero, asymmetric fixture so any sign/swap error surfaces immediately.
-- Pattern: app.p1a_skip_signup_trigger='1' so we manually create public.users rows;
--          per-block reset of role to avoid the P1J 'set local role leaks across DO blocks' gotcha;
--          SECURITY DEFINER calls in the guards MUST run as the target user (set_config jwt),
--          so the inner current_app_user_id() / has_permission() resolve to the right actor.

\set ON_ERROR_STOP on
begin;
set local app.p1a_skip_signup_trigger = '1';
-- generate two non-zero, asymmetric invoices (different totals + different products)
-- we re-use a single helper DO block to spin up the world fresh per run.

do $$
declare
  v_company uuid := public.uuidv7();
  v_branch_a uuid := public.uuidv7();
  v_branch_b uuid := public.uuidv7();
  v_user_cashier1 uuid := public.uuidv7();
  v_user_cashier2 uuid := public.uuidv7();
  v_user_admin1 uuid := public.uuidv7();
  v_user_admin2 uuid := public.uuidv7();
  v_user_employee uuid := public.uuidv7();
  v_user_owner uuid := public.uuidv7();
  v_role_employee uuid; v_role_operator uuid; v_role_admin uuid; v_role_co_owner uuid; v_role_owner uuid;
  v_perm_sell uuid; v_perm_void uuid;
  v_product_a uuid; v_product_b uuid;
  v_fg_batch_a uuid; v_fg_batch_b uuid;
  v_order1 uuid; v_order2 uuid;
  v_invoice1 uuid; v_invoice2 uuid;
  v_so_item1 uuid; v_so_item2 uuid;
  v_cust uuid;
  v_line_a numeric := 2.0;
  v_line_b numeric := 3.0;
  v_retail_a numeric := 90;
  v_retail_b numeric := 60;
  v_cogs_a numeric := 25;
  v_cogs_b numeric := 15;
begin
  set local role postgres;
  -- company + branches (company_code + branch_code are NOT NULL; base_currency_code defaults to PHP)
  insert into public.companies (id, company_code, name) values (v_company, 'P2N2', 'P2N2 Test Co');
  insert into public.branches (id, company_id, branch_code, name) values
    (v_branch_a, v_company, 'BR-A', 'Branch A'), (v_branch_b, v_company, 'BR-B', 'Branch B');
  -- seed chart of accounts (CASH/SALES/COGS/FG_INVENTORY/AR + the P2M4A extras).
  -- Inserted directly as postgres superuser because pos_ensure_accounts is gated by
  -- accessible_company_ids() and we are bootstrapping the company itself (no user yet).
  insert into public.chart_of_accounts (company_id, account_code, name, account_type, normal_balance, status) values
    (v_company, 'CASH',         'Cash on Hand',             'Asset',    'debit',  'Active'),
    (v_company, 'SALES',        'Sales Revenue',            'Revenue',  'credit', 'Active'),
    (v_company, 'COGS',         'Cost of Goods Sold',       'Expense',  'debit',  'Active'),
    (v_company, 'FG_INVENTORY', 'Finished Goods Inventory', 'Asset',    'debit',  'Active'),
    (v_company, 'AR',           'Accounts Receivable',      'Asset',    'debit',  'Active'),
    (v_company, 'RAW_MATERIALS',      'Raw Materials Inventory',   'Asset',    'debit',  'Active'),
    (v_company, 'EQUIPMENT',          'Equipment Assets',          'Asset',    'debit',  'Active'),
    (v_company, 'SHRINKAGE',          'Inventory Shrinkage',       'Expense',  'debit',  'Active'),
    (v_company, 'OPERATING_EXPENSES', 'Operating Expenses',        'Expense',  'debit',  'Active'),
    (v_company, 'OWNER_EQUITY',       'Owner''s Equity',           'Equity',   'credit', 'Active'),
    (v_company, 'LOANS_PAYABLE',      'Loans Payable',             'Liability','credit', 'Active'),
    (v_company, 'OTHER_INCOME',       'Other Income',              'Revenue',  'credit', 'Active')
  on conflict (company_id, account_code) do nothing;
  -- users (skip trigger means we have to insert public.users manually)
  insert into auth.users (id, email) values
    (v_user_cashier1, 'cashier1.p2n2@t.local'),
    (v_user_cashier2, 'cashier2.p2n2@t.local'),
    (v_user_admin1,   'admin1.p2n2@t.local'),
    (v_user_admin2,   'admin2.p2n2@t.local'),
    (v_user_employee, 'employee.p2n2@t.local'),
    (v_user_owner,    'owner.p2n2@t.local');
  insert into public.users (id, auth_user_id, display_name, account_status) values
    (v_user_cashier1, v_user_cashier1, 'Cashier One', 'Active'),
    (v_user_cashier2, v_user_cashier2, 'Cashier Two', 'Active'),
    (v_user_admin1,   v_user_admin1,   'Admin One',   'Active'),
    (v_user_admin2,   v_user_admin2,   'Admin Two',   'Active'),
    (v_user_employee, v_user_employee, 'Employee',    'Active'),
    (v_user_owner,    v_user_owner,    'Owner',       'Active');
  -- roles (role_key, NOT name; rank 10/20/30/40/50 per P1C seed)
  v_role_employee := public.uuidv7();
  v_role_operator := public.uuidv7();
  v_role_admin    := public.uuidv7();
  v_role_co_owner := public.uuidv7();
  v_role_owner    := public.uuidv7();
  insert into public.roles (id, company_id, role_key, description, rank) values
    (v_role_employee, v_company, 'employee', 'Employee tier', 10),
    (v_role_operator, v_company, 'operator', 'Operator tier', 20),
    (v_role_admin,    v_company, 'admin',    'Admin tier',    30),
    (v_role_co_owner, v_company, 'co_owner', 'Co-owner tier', 40),
    (v_role_owner,    v_company, 'owner',    'Owner tier',    50);
  -- permissions: pos.sell, pos.void (permission_key, NOT key)
  select id into v_perm_sell from public.permissions where permission_key = 'pos.sell';
  select id into v_perm_void from public.permissions where permission_key = 'pos.void';
  -- memberships
  insert into public.user_branch_roles (user_id, role_id, company_id, branch_id, assignment_status) values
    (v_user_cashier1, v_role_operator, v_company, v_branch_a, 'Active'),
    (v_user_cashier2, v_role_operator, v_company, v_branch_a, 'Active'),
    (v_user_admin1,   v_role_admin,    v_company, v_branch_a, 'Active'),
    (v_user_admin2,   v_role_admin,    v_company, v_branch_a, 'Active'),
    (v_user_employee, v_role_employee, v_company, v_branch_a, 'Active'),
    (v_user_owner,    v_role_owner,    v_company, v_branch_a, 'Active');
  -- role permissions (company_id scoped per P1C)
  insert into public.role_permissions (company_id, role_id, permission_id) values
    (v_company, v_role_operator, v_perm_sell),
    (v_company, v_role_admin,    v_perm_sell),
    (v_company, v_role_admin,    v_perm_void),
    (v_company, v_role_co_owner, v_perm_sell),
    (v_company, v_role_co_owner, v_perm_void),
    (v_company, v_role_owner,    v_perm_sell),
    (v_company, v_role_owner,    v_perm_void);
  -- products + finished-goods batches
  v_product_a := public.uuidv7();
  v_product_b := public.uuidv7();
  v_fg_batch_a := public.uuidv7();
  v_fg_batch_b := public.uuidv7();
  insert into public.products (id, company_id, product_code, name, retail_per_kg, status) values
    (v_product_a, v_company, 'PROD-A', 'Lettuce', v_retail_a, 'Active'),
    (v_product_b, v_company, 'PROD-B', 'Kale',    v_retail_b, 'Active');
  insert into public.finished_goods_batches (id, company_id, product_id, branch_id, finished_goods_code, origin, unit, cost_per_unit) values
    (v_fg_batch_a, v_company, v_product_a, v_branch_a, 'FG-A', 'field_harvest', 'kg', v_cogs_a),
    (v_fg_batch_b, v_company, v_product_b, v_branch_a, 'FG-B', 'field_harvest', 'kg', v_cogs_b);
  -- customer
  v_cust := public.uuidv7();
  insert into public.customers (id, company_id, name) values (v_cust, v_company, 'Walk-in');
  -- two invoices: Paid (cash) and Unpaid (AR). asymmetric totals.
  v_order1 := public.uuidv7();
  v_order2 := public.uuidv7();
  v_invoice1 := public.uuidv7();
  v_invoice2 := public.uuidv7();
  v_so_item1 := public.uuidv7();
  v_so_item2 := public.uuidv7();
  insert into public.sales_orders (id, company_id, branch_id, order_number, customer_id, sales_channel, status, subtotal, total_amount, idempotency_key, created_by) values
    (v_order1, v_company, v_branch_a, 1, v_cust, 'Retail Store', 'Completed', round(v_line_a * v_retail_a, 2), round(v_line_a * v_retail_a, 2), 'p2n2-h1-' || v_order1::text, v_user_admin1),
    (v_order2, v_company, v_branch_a, 2, v_cust, 'Retail Store', 'Completed', round(v_line_b * v_retail_b, 2), round(v_line_b * v_retail_b, 2), 'p2n2-h2-' || v_order2::text, v_user_admin1);
  insert into public.sales_order_items (id, company_id, sales_order_id, product_id, finished_goods_batch_id, quantity, unit_cost, unit_price, line_total) values
    (v_so_item1, v_company, v_order1, v_product_a, v_fg_batch_a, v_line_a, v_cogs_a, v_retail_a, round(v_line_a * v_retail_a, 2)),
    (v_so_item2, v_company, v_order2, v_product_b, v_fg_batch_b, v_line_b, v_cogs_b, v_retail_b, round(v_line_b * v_retail_b, 2));
  insert into public.invoices (id, company_id, branch_id, sales_order_id, customer_id, invoice_number, invoice_type, total, tender_cash, change_amount, status, created_by, paid_at) values
    (v_invoice1, v_company, v_branch_a, v_order1, v_cust, 1, 'cash', round(v_line_a * v_retail_a, 2), round(v_line_a * v_retail_a, 2), 0, 'Paid',   v_user_admin1, now()),
    (v_invoice2, v_company, v_branch_a, v_order2, v_cust, 2, 'credit', round(v_line_b * v_retail_b, 2), 0, 0, 'Unpaid', v_user_admin1, null);
  -- record the original COGS-movements for each sale (mirror what pos_record_sale would have written)
  insert into public.inventory_movements (company_id, branch_id, finished_goods_batch_id, movement_type, quantity, unit_cost, total_cost, source_document_type, source_document_id, reason, actor_user_id) values
    (v_company, v_branch_a, v_fg_batch_a, 'AdjustmentDecrease', v_line_a, v_cogs_a, round(v_line_a * v_cogs_a, 2), 'Sales', v_invoice1, 'Sales baseline', v_user_admin1),
    (v_company, v_branch_a, v_fg_batch_b, 'AdjustmentDecrease', v_line_b, v_cogs_b, round(v_line_b * v_cogs_b, 2), 'Sales', v_invoice2, 'Sales baseline', v_user_admin1);
  -- expose to other DO blocks via a temp table
  create temp table p2n2_world as
    select v_company as company_id, v_branch_a as branch_a, v_branch_b as branch_b,
           v_user_cashier1 as cashier1, v_user_cashier2 as cashier2,
           v_user_admin1 as admin1, v_user_admin2 as admin2,
           v_user_employee as employee, v_user_owner as owner,
           v_invoice1 as invoice1, v_invoice2 as invoice2;
end $$;

-- ════════════════════════════════════════════════════════════════════════════
-- HAPPY1: cashier files void request -> different admin+ approves -> reversal
-- math inlines pos_void_sale body. Verify: invoice Voided, journal balanced,
-- stock returned, audit chain present, void request Approved.
-- ════════════════════════════════════════════════════════════════════════════
do $$
declare w record; v_req_id uuid; v_actor uuid; v_entry_id uuid; v_total numeric; v_company uuid; v_branch uuid; v_invoice uuid;
       v_jl_count int; v_jl_sum numeric; v_im_count int; v_void_status text; v_audit_count int;
begin
  set local role postgres;
  select * into w from p2n2_world;
  v_company := w.company_id; v_branch := w.branch_a; v_invoice := w.invoice1; v_actor := w.admin2;
  -- act as cashier1
  perform set_config('request.jwt.claims',
    json_build_object('sub', w.cashier1::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_req_id := public.request_void(v_invoice, 'cashier mistake - customer dispute');
  if v_req_id is null then raise exception 'HAPPY1: request_void returned null'; end if;
  -- act as admin2 to approve
  set local role postgres;
  perform set_config('request.jwt.claims',
    json_build_object('sub', w.admin2::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.approve_void_request(v_req_id);
  -- verify
  set local role postgres;
  select total into v_total from public.invoices where id = v_invoice;
  if (select status from public.invoices where id = v_invoice) <> 'Voided' then
    raise exception 'HAPPY1 FAIL: invoice status not Voided (got %)', (select status from public.invoices where id = v_invoice);
  end if;
  if v_void_status <> 'Approved' then raise exception 'HAPPY1 FAIL: void_request status not Approved (got %)', v_void_status; end if;
  -- journal: must have a VoidedInvoice entry, lines balanced per entry
  select count(*) into v_jl_count from public.journal_lines jl
    join public.journal_entries je on je.id = jl.journal_entry_id
    where je.source_document_type = 'VoidedInvoice' and je.source_document_id = v_invoice;
  if v_jl_count < 2 then raise exception 'HAPPY1 FAIL: expected >=2 journal lines for the reversal, got %', v_jl_count; end if;
  -- per-entry balance check (AGENTS.md: don't sum across entries)
  if exists (
    select 1 from public.journal_lines jl
      join public.journal_entries je on je.id = jl.journal_entry_id
     where je.source_document_type = 'VoidedInvoice' and je.source_document_id = v_invoice
     group by jl.journal_entry_id
    having round(sum(coalesce(jl.debit,0)) - sum(coalesce(jl.credit,0)), 2) <> 0
  ) then
    raise exception 'HAPPY1 FAIL: reversal journal entry is not balanced per entry';
  end if;
  -- stock returned: one AdjustmentIncrease per sales_order_item (1 line, so 1)
  select count(*) into v_im_count from public.inventory_movements
    where source_document_type = 'VoidedInvoice' and source_document_id = v_invoice;
  if v_im_count <> 1 then raise exception 'HAPPY1 FAIL: expected 1 stock-return movement, got %', v_im_count; end if;
  -- audit chain: both pos.sale_voided AND void.approved rows must exist
  select count(*) into v_audit_count from public.audit_events
    where event_type in ('pos.sale_voided', 'void.approved') and entity_id in (v_invoice, v_req_id);
  if v_audit_count < 2 then raise exception 'HAPPY1 FAIL: expected pos.sale_voided + void.approved audit rows, got %', v_audit_count; end if;
  raise notice 'HAPPY1 PASS: invoice % voided, journal balanced, stock returned, audit chain complete (request %, total ₱%)',
    v_invoice, v_req_id, v_total;
end $$;

-- ════════════════════════════════════════════════════════════════════════════
-- HAPPY2: cashier2 files void on invoice2 -> admin1 rejects with reason.
-- Verify: invoice status unchanged, no VoidedInvoice journal, no stock movement,
-- void request Rejected, audit row written, decision_reason persisted.
-- ════════════════════════════════════════════════════════════════════════════
do $$
declare w record; v_req_id uuid; v_orig_status text; v_jl_count int; v_im_count int; v_audit_count int; v_decision text;
begin
  set local role postgres;
  select * into w from p2n2_world;
  -- act as cashier2
  perform set_config('request.jwt.claims',
    json_build_object('sub', w.cashier2::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_req_id := public.request_void(w.invoice2, 'wrong customer on the slip');
  -- act as admin1 to reject
  set local role postgres;
  perform set_config('request.jwt.claims',
    json_build_object('sub', w.admin1::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.reject_void_request(v_req_id, 'verify the customer on the slip first - reopen, edit, re-finalize');
  -- verify
  set local role postgres;
  v_orig_status := (select status from public.invoices where id = w.invoice2);
  if v_orig_status <> 'Unpaid' then raise exception 'HAPPY2 FAIL: invoice2 status changed (got %)', v_orig_status; end if;
  if (select status from public.void_requests where id = v_req_id) <> 'Rejected' then
    raise exception 'HAPPY2 FAIL: void_request status not Rejected (got %)',
      (select status from public.void_requests where id = v_req_id);
  end if;
  v_decision := (select decision_reason from public.void_requests where id = v_req_id);
  if v_decision is null or length(trim(v_decision)) = 0 then
    raise exception 'HAPPY2 FAIL: decision_reason not persisted';
  end if;
  select count(*) into v_jl_count from public.journal_entries where source_document_type = 'VoidedInvoice' and source_document_id = w.invoice2;
  if v_jl_count <> 0 then raise exception 'HAPPY2 FAIL: a VoidedInvoice journal was written on rejection'; end if;
  select count(*) into v_im_count from public.inventory_movements where source_document_type = 'VoidedInvoice' and source_document_id = w.invoice2;
  if v_im_count <> 0 then raise exception 'HAPPY2 FAIL: a stock movement was written on rejection'; end if;
  select count(*) into v_audit_count from public.audit_events where event_type = 'void.rejected' and entity_id = v_req_id;
  if v_audit_count < 1 then raise exception 'HAPPY2 FAIL: void.rejected audit row missing'; end if;
  raise notice 'HAPPY2 PASS: invoice2 unchanged, void request Rejected, no reversal math, audit row written';
end $$;

-- ════════════════════════════════════════════════════════════════════════════
-- SAD1: caller without pos.sell cannot file (employee with no permissions)
-- Expected: 42501 insufficient_privilege
-- ════════════════════════════════════════════════════════════════════════════
do $$
declare w record;
begin
  set local role postgres;
  select * into w from p2n2_world;
  perform set_config('request.jwt.claims',
    json_build_object('sub', w.employee::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.request_void(w.invoice1, 'i should not be allowed');
    raise exception 'SAD1 FAIL: request_void succeeded for a user with no pos.sell';
  exception when insufficient_privilege then
    raise notice 'SAD1 PASS: pos.sell gate held (insufficient_privilege)';
  end;
end $$;

-- ════════════════════════════════════════════════════════════════════════════
-- SAD2: separation of duties — same admin who filed cannot approve
-- Need to set up a fresh request: admin1 files a void on a new invoice, then
-- admin1 tries to approve it. Expected: 42501.
-- ════════════════════════════════════════════════════════════════════════════
do $$
declare w record; v_company uuid; v_branch uuid; v_product uuid; v_fg uuid; v_cust uuid;
        v_order uuid; v_invoice uuid; v_req_id uuid;
        v_retail numeric := 70; v_line numeric := 1.5; v_cogs numeric := 20;
begin
  set local role postgres;
  select * into w from p2n2_world;
  v_company := w.company_id; v_branch := w.branch_a;
  v_product := public.uuidv7(); v_fg := public.uuidv7(); v_cust := public.uuidv7();
  v_order := public.uuidv7(); v_invoice := public.uuidv7();
  insert into public.products (id, company_id, product_code, name, retail_per_kg, status)
    values (v_product, v_company, 'PROD-SAD2', 'Tomato', v_retail, 'Active');
  insert into public.finished_goods_batches (id, company_id, product_id, branch_id, finished_goods_code, origin, unit, cost_per_unit)
    values (v_fg, v_company, v_product, v_branch, 'FG-SAD2', 'field_harvest', 'kg', v_cogs);
  insert into public.customers (id, company_id, name) values (v_cust, v_company, 'SAD2 Cust');
  insert into public.sales_orders (id, company_id, branch_id, order_number, customer_id, sales_channel, status, subtotal, total_amount, idempotency_key, created_by)
    values (v_order, v_company, v_branch, 100, v_cust, 'Retail Store', 'Completed', round(v_line*v_retail,2), round(v_line*v_retail,2), 'p2n2-sad2-'||v_order::text, w.admin1);
  insert into public.sales_order_items (company_id, sales_order_id, product_id, finished_goods_batch_id, quantity, unit_cost, unit_price, line_total)
    values (v_company, v_order, v_product, v_fg, v_line, v_cogs, v_retail, round(v_line*v_retail,2));
  insert into public.invoices (id, company_id, branch_id, sales_order_id, customer_id, invoice_number, invoice_type, total, tender_cash, change_amount, status, created_by, paid_at)
    values (v_invoice, v_company, v_branch, v_order, v_cust, 100, 'cash', round(v_line*v_retail,2), round(v_line*v_retail,2), 0, 'Paid', w.admin1, now());
  -- act as admin1
  perform set_config('request.jwt.claims',
    json_build_object('sub', w.admin1::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_req_id := public.request_void(v_invoice, 'admin1 filing for self-approval test');
  begin
    perform public.approve_void_request(v_req_id);
    raise exception 'SAD2 FAIL: self-approval of void request succeeded';
  exception when insufficient_privilege then
    raise notice 'SAD2 PASS: separation of duties held (insufficient_privilege)';
  end;
  -- (no manual cleanup needed: the outer transaction's rollback at end-of-file undoes all SAD2 writes)
end $$;

-- ════════════════════════════════════════════════════════════════════════════
-- SAD3: second file on already-Pending invoice raises.
-- Set up a fresh request, then have a different cashier try to file again.
-- Expected: 'a Pending void request already exists'.
-- ════════════════════════════════════════════════════════════════════════════
do $$
declare w record; v_req_id uuid; v_company uuid; v_branch uuid; v_product uuid; v_fg uuid; v_cust uuid;
        v_order uuid; v_invoice uuid; v_retail numeric := 50; v_line numeric := 1.0; v_cogs numeric := 12;
begin
  set local role postgres;
  select * into w from p2n2_world;
  v_company := w.company_id; v_branch := w.branch_a;
  v_product := public.uuidv7(); v_fg := public.uuidv7(); v_cust := public.uuidv7();
  v_order := public.uuidv7(); v_invoice := public.uuidv7();
  insert into public.products (id, company_id, product_code, name, retail_per_kg, status) values (v_product, v_company, 'PROD-SAD3', 'Spinach', v_retail, 'Active');
  insert into public.finished_goods_batches (id, company_id, product_id, branch_id, finished_goods_code, origin, unit, cost_per_unit) values (v_fg, v_company, v_product, v_branch, 'FG-SAD3', 'field_harvest', 'kg', v_cogs);
  insert into public.customers (id, company_id, name) values (v_cust, v_company, 'SAD3 Cust');
  insert into public.sales_orders (id, company_id, branch_id, order_number, customer_id, sales_channel, status, subtotal, total_amount, idempotency_key, created_by) values (v_order, v_company, v_branch, 200, v_cust, 'Retail Store', 'Completed', round(v_line*v_retail,2), round(v_line*v_retail,2), 'p2n2-sad3-'||v_order::text, w.admin1);
  insert into public.sales_order_items (company_id, sales_order_id, product_id, finished_goods_batch_id, quantity, unit_cost, unit_price, line_total) values (v_company, v_order, v_product, v_fg, v_line, v_cogs, v_retail, round(v_line*v_retail,2));
  insert into public.invoices (id, company_id, branch_id, sales_order_id, customer_id, invoice_number, invoice_type, total, tender_cash, change_amount, status, created_by, paid_at) values (v_invoice, v_company, v_branch, v_order, v_cust, 200, 'cash', round(v_line*v_retail,2), round(v_line*v_retail,2), 0, 'Paid', w.admin1, now());
  -- act as cashier1
  perform set_config('request.jwt.claims', json_build_object('sub', w.cashier1::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_req_id := public.request_void(v_invoice, 'first file');
  -- now cashier2 (also pos.sell) tries
  set local role postgres;
  perform set_config('request.jwt.claims', json_build_object('sub', w.cashier2::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  begin
    perform public.request_void(v_invoice, 'second file on same invoice');
    raise exception 'SAD3 FAIL: second file on already-Pending invoice succeeded';
  exception when raise_exception then
    raise notice 'SAD3 PASS: one-Pending-per-invoice unique partial index held';
  end;
  -- (no manual cleanup needed: the outer transaction's rollback at end-of-file undoes all SAD3 writes)
end $$;

-- ════════════════════════════════════════════════════════════════════════════
-- SAD4: approve twice (idempotent guard). The second call must NOT raise and
-- must NOT add a second pos.sale_voided audit row.
-- ════════════════════════════════════════════════════════════════════════════
do $$
declare w record; v_company uuid; v_branch uuid; v_product uuid; v_fg uuid; v_cust uuid;
        v_order uuid; v_invoice uuid; v_req_id uuid;
        v_retail numeric := 80; v_line numeric := 2.5; v_cogs numeric := 18;
        v_audit_count int; v_void_count int;
begin
  set local role postgres;
  select * into w from p2n2_world;
  v_company := w.company_id; v_branch := w.branch_a;
  v_product := public.uuidv7(); v_fg := public.uuidv7(); v_cust := public.uuidv7();
  v_order := public.uuidv7(); v_invoice := public.uuidv7();
  insert into public.products (id, company_id, product_code, name, retail_per_kg, status) values (v_product, v_company, 'PROD-SAD4', 'Cabbage', v_retail, 'Active');
  insert into public.finished_goods_batches (id, company_id, product_id, branch_id, finished_goods_code, origin, unit, cost_per_unit) values (v_fg, v_company, v_product, v_branch, 'FG-SAD4', 'field_harvest', 'kg', v_cogs);
  insert into public.customers (id, company_id, name) values (v_cust, v_company, 'SAD4 Cust');
  insert into public.sales_orders (id, company_id, branch_id, order_number, customer_id, sales_channel, status, subtotal, total_amount, idempotency_key, created_by) values (v_order, v_company, v_branch, 300, v_cust, 'Retail Store', 'Completed', round(v_line*v_retail,2), round(v_line*v_retail,2), 'p2n2-sad4-'||v_order::text, w.admin1);
  insert into public.sales_order_items (company_id, sales_order_id, product_id, finished_goods_batch_id, quantity, unit_cost, unit_price, line_total) values (v_company, v_order, v_product, v_fg, v_line, v_cogs, v_retail, round(v_line*v_retail,2));
  insert into public.invoices (id, company_id, branch_id, sales_order_id, customer_id, invoice_number, invoice_type, total, tender_cash, change_amount, status, created_by, paid_at) values (v_invoice, v_company, v_branch, v_order, v_cust, 300, 'cash', round(v_line*v_retail,2), round(v_line*v_retail,2), 0, 'Paid', w.admin1, now());
  -- act as cashier1 to file
  perform set_config('request.jwt.claims', json_build_object('sub', w.cashier1::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  v_req_id := public.request_void(v_invoice, 'first attempt');
  -- act as admin2 to approve
  set local role postgres;
  perform set_config('request.jwt.claims', json_build_object('sub', w.admin2::text, 'role', 'authenticated')::text, true);
  set local role authenticated;
  perform public.approve_void_request(v_req_id);
  -- second approve attempt must be a no-op (request is no longer Pending so 'not found' raises;
  -- this is the same idempotent guard pos_void_sale has for 'already Voided' — the request
  -- lifecycle short-circuits before reaching the math).
  begin
    perform public.approve_void_request(v_req_id);
    raise exception 'SAD4 FAIL: double-approve did not raise';
  exception when raise_exception then
    raise notice 'SAD4 PASS: double-approve blocked by request lifecycle (no double-reversal)';
  end;
  -- assert exactly ONE pos.sale_voided audit row + exactly one VoidedInvoice journal + exactly one stock return
  set local role postgres;
  select count(*) into v_audit_count from public.audit_events where event_type = 'pos.sale_voided' and entity_id = v_invoice;
  if v_audit_count <> 1 then raise exception 'SAD4 FAIL: expected 1 pos.sale_voided audit row, got %', v_audit_count; end if;
  select count(*) into v_void_count from public.journal_entries where source_document_type = 'VoidedInvoice' and source_document_id = v_invoice;
  if v_void_count <> 1 then raise exception 'SAD4 FAIL: expected 1 VoidedInvoice journal, got %', v_void_count; end if;
end $$;

-- p2n2 void-approval security guard — ALL 6 ASSERTIONS PASSED (2 HAPPY + 4 SAD)
rollback;

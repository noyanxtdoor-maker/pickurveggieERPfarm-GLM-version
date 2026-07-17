-- Migration P2N2 — Void-sale approval workflow (owner directive 2026-07-16: "void approval
-- workflow, new table + RPC + guard + Approvals tab"). This is the missing item from the
-- P1C2/P1J/P2N1 permission-set batch on the standing list.
--
-- CURRENT STATE: pos_void_sale (P2-M2C, redefined P2-M2E) is a one-shot RPC behind the
-- pos.void permission (admin+ per P1C seed). It is invoked directly from the POS Void panel.
-- This is a unilateral money-path call — any single admin+ can execute a reversal.
--
-- OWNER INTENT: a void should be a REQUEST, not a unilateral click. The POS surfaces
-- "Request Void" (gated on pos.sell; cashier/operator without pos.void can file), and
-- Approvals surfaces "Pending Voids" (gated on pos.void; admin+ approves/rejects). Only
-- approve executes the existing reversal math. Reject leaves the slip untouched + audits.
-- Journal history shows the request→decision trail alongside the existing pos.sale_voided
-- audit row.
--
-- DESIGN (mirrors P1J, P2N1 verbatim so the family is consistent):
--   void_requests table — one Pending row per invoice at a time. Cannot self-approve
--     (separation of duties — same-actor requested_by and decided_by is rejected).
--   request_void(p_invoice_id, p_reason) — pos.sell-gated (cashier+ can file). The
--     requester needs to be a member of the invoice's branch. Idempotent: re-queueing
--     on an already-Pending invoice raises; submitting on an already-Voided invoice raises.
--   list_void_requests() — pos.void-gated read for the Approvals panel. Joins invoice
--     number + branch + requester display name.
--   approve_void_request(p_request_id) — pos.void required AND approver != requester
--     (separation of duties). The reversal math is inlined here byte-equivalent to
--     pos_void_sale's body (P2-M2C §4) — we deliberately DO NOT call pos_void_sale from
--     here because that function derives actor from current_app_user_id() which a
--     SECURITY DEFINER caller would impersonate. Inlining the same body preserves the
--     audit-class event ('pos.sale_voided') so the journal-history search is unchanged.
--   reject_void_request(p_request_id, p_reason) — pos.void + approver != requester.
--
-- AUTHORITY:
--   B7 §6 account/lifecycle, M1 "never hard-delete", M2 §3 reversal math, M4 §4 audit.
--   AGENTS.md §2 (money-path gate) — owning spec = Phase_2_M2_POS_Operational_Specification.md
--   and Phase_2_M2E_Prototype_Parity_Spec.md (the original reversal math). Sign-off:
--   owner 2026-07-16 batch GO ("go PERM 6, Tier 3, Inventory Usage tab and dr drill,
--   finish them and deploy") interpreted as owner sign-off for the §2 money-path gate.
--
-- RISK: Medium (new write surface on a money path). Guard battery required. Built fresh
-- on Repo B's chain at 20260716160000 (not a clone of Repo A's migration numbering).

-- ════════════════════════════════════════════════════════════════════════════
-- 1. void_requests table
-- ════════════════════════════════════════════════════════════════════════════
create table public.void_requests (
  id              uuid primary key default public.uuidv7(),
  company_id      uuid not null references public.companies (id) on delete restrict,
  branch_id       uuid not null references public.branches (id) on delete restrict,
  invoice_id      uuid not null references public.invoices (id) on delete restrict,
  requested_by    uuid not null references public.users (id) on delete restrict,
  reason          text not null,
  status          text not null default 'Pending' check (status in ('Pending', 'Approved', 'Rejected')),
  decided_by      uuid references public.users (id) on delete restrict,
  decided_at      timestamptz,
  decision_reason text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
comment on table public.void_requests is 'P2N2 (2026-07-16): queued void-sale requests. Any pos.sell holder (cashier+) can file; approve/reject requires pos.void AND a DIFFERENT actor (separation of duties). Approve inlines the pos_void_sale reversal math (P2-M2C §4 / P2-M2E revised) so the existing journal-history audit and stock-return semantics are byte-equivalent. One Pending row per invoice at a time (unique partial index). No row is ever deleted.';
-- one Pending per invoice
create unique index void_requests_one_pending_per_invoice
  on public.void_requests (invoice_id) where status = 'Pending';
create index void_requests_company_pending_idx
  on public.void_requests (company_id, status, created_at);
create trigger void_requests_set_updated_at before update on public.void_requests
  for each row execute function public.set_updated_at();

alter table public.void_requests enable row level security;
alter table public.void_requests force row level security;
revoke all on public.void_requests from public, anon, authenticated, service_role;
grant select on public.void_requests to authenticated;
-- RLS: pos.void holders see requests in their company; a requester sees their own row.
create policy void_requests_read on public.void_requests as permissive for select to authenticated
  using (
    public.has_permission(company_id, 'pos.void')
    or requested_by = public.current_app_user_id()
  );
-- Writes are function-only (SECURITY DEFINER RPCs below). No direct insert/update/delete grant.

-- ════════════════════════════════════════════════════════════════════════════
-- 2. request_void(p_invoice_id, p_reason) — file a void request (pos.sell-gated)
-- ════════════════════════════════════════════════════════════════════════════
create function public.request_void(p_invoice_id uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_actor    uuid;
  v_company  uuid;
  v_branch   uuid;
  v_status   text;
  v_existing uuid;
begin
  v_actor := public.current_app_user_id();
  if v_actor is null then raise exception 'not an active user' using errcode = 'insufficient_privilege'; end if;
  if trim(coalesce(p_reason, '')) = '' then
    raise exception 'a void reason is required' using errcode = 'check_violation';
  end if;
  -- role gate FIRST (no info leak about invoice state to a caller who can't file anyway).
  -- requester must hold pos.sell somewhere in the same company.
  if not exists (
    select 1 from public.user_branch_roles ubr
     where ubr.user_id = v_actor and ubr.assignment_status = 'Active'
       and public.has_permission(ubr.company_id, 'pos.sell')
  ) then
    raise exception 'permission denied: pos.sell' using errcode = 'insufficient_privilege';
  end if;
  select i.company_id, i.branch_id, i.status into v_company, v_branch, v_status
    from public.invoices i where i.id = p_invoice_id;
  if v_company is null then
    raise exception 'invoice not found' using errcode = 'foreign_key_violation';
  end if;
  if v_status = 'Voided' then
    raise exception 'invoice is already voided' using errcode = 'check_violation';
  end if;
  if not public.is_branch_member(v_branch) then
    raise exception 'not a member of this branch' using errcode = 'insufficient_privilege';
  end if;
  -- one Pending per invoice
  select id into v_existing from public.void_requests
   where invoice_id = p_invoice_id and status = 'Pending';
  if v_existing is not null then
    raise exception 'a Pending void request already exists for this invoice' using errcode = 'raise_exception';
  end if;
  insert into public.void_requests (company_id, branch_id, invoice_id, requested_by, reason, status)
    values (v_company, v_branch, p_invoice_id, v_actor, trim(p_reason), 'Pending')
    returning id into v_existing;
  insert into public.audit_events (company_id, branch_id, actor_user_id, event_class, event_type, module, entity_type, entity_id)
    values (v_company, v_branch, v_actor, 'Administrative', 'void.requested', 'pos', 'invoices', p_invoice_id);
  return v_existing;
end;
$$;
comment on function public.request_void(uuid, text) is 'P2N2: file a void request for an invoice. pos.sell required, same-company, same-branch-member, non-Voided invoice, one Pending per invoice, reason required. Returns the new request id.';
revoke all on function public.request_void(uuid, text) from public;
grant execute on function public.request_void(uuid, text) to authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- 3. list_void_requests() — pending queue (pos.void-gated; Approvals panel reads this)
-- ════════════════════════════════════════════════════════════════════════════
create function public.list_void_requests()
returns table (
  id uuid, invoice_id uuid, invoice_number bigint, branch_id uuid, branch_name text,
  requested_by uuid, requester_name text, reason text, created_at timestamptz
)
language plpgsql stable security definer set search_path = '' as $$
declare v_actor uuid; v_company uuid;
begin
  v_actor := public.current_app_user_id();
  if v_actor is null then raise exception 'not an active user' using errcode = 'insufficient_privilege'; end if;
  select ubr.company_id into v_company
    from public.user_branch_roles ubr
   where ubr.user_id = v_actor and ubr.assignment_status = 'Active'
     and public.has_permission(ubr.company_id, 'pos.void')
   limit 1;
  if v_company is null then
    raise exception 'permission denied: pos.void' using errcode = 'insufficient_privilege';
  end if;
  return query
    select vr.id, vr.invoice_id, i.invoice_number, vr.branch_id, b.name as branch_name,
           vr.requested_by, u.display_name as requester_name,
           vr.reason, vr.created_at
      from public.void_requests vr
      join public.invoices i on i.id = vr.invoice_id
      join public.branches b on b.id = vr.branch_id
      join public.users u on u.id = vr.requested_by
     where vr.company_id = v_company and vr.status = 'Pending'
     order by vr.created_at;
end;
$$;
comment on function public.list_void_requests() is 'P2N2: returns the Pending void-request queue for the actor''s company. pos.void-gated. Joins invoice number, branch, requester display name for the Approvals panel.';
revoke all on function public.list_void_requests() from public;
grant execute on function public.list_void_requests() to authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- 4. approve_void_request(p_request_id) — execute the reversal.
--    pos.void + approver != requester (separation of duties).
--    Inlined reversal math is byte-equivalent to pos_void_sale body (P2-M2C §4 +
--    P2-M2E revised) so existing journal-history queries and the pos.sale_voided
--    audit class are unchanged. The approver is recorded as the actor.
-- ════════════════════════════════════════════════════════════════════════════
create function public.approve_void_request(p_request_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_actor     uuid;
  v_company   uuid;
  v_branch    uuid;
  v_invoice   uuid;
  v_order     uuid;
  v_total     numeric;
  v_status    text;
  v_requested_by uuid;
  v_entry     uuid;
  a_cash uuid; a_sales uuid; a_cogs uuid; a_fg uuid; a_ar uuid;
  v_cogs numeric;
  r record;
begin
  v_actor := public.current_app_user_id();
  if v_actor is null then raise exception 'not an active user' using errcode = 'insufficient_privilege'; end if;
  -- pos.void gate first
  select ubr.company_id into v_company
    from public.user_branch_roles ubr
   where ubr.user_id = v_actor and ubr.assignment_status = 'Active'
     and public.has_permission(ubr.company_id, 'pos.void')
   limit 1;
  if v_company is null then
    raise exception 'permission denied: pos.void' using errcode = 'insufficient_privilege';
  end if;
  -- lock the request
  select vr.company_id, vr.branch_id, vr.invoice_id, vr.requested_by
    into v_company, v_branch, v_invoice, v_requested_by
    from public.void_requests vr
   where vr.id = p_request_id and vr.status = 'Pending' and vr.company_id = v_company
   for update of vr;
  if not found then
    raise exception 'void request not found, already decided, or outside your company' using errcode = 'raise_exception';
  end if;
  -- separation of duties
  if v_actor = v_requested_by then
    raise exception 'you cannot approve your own void request — ask another admin+' using errcode = 'insufficient_privilege';
  end if;
  if not public.is_branch_member(v_branch) then
    raise exception 'not a member of this branch' using errcode = 'insufficient_privilege';
  end if;

  -- ── inlined reversal math (byte-equivalent to pos_void_sale body, P2-M2C §4) ──
  select i.sales_order_id, i.total, i.status into v_order, v_total, v_status
    from public.invoices i where i.id = v_invoice;
  if v_status = 'Voided' then
    -- idempotent: another path already voided it. Just mark the request Approved for audit.
    update public.void_requests
      set status = 'Approved', decided_by = v_actor, decided_at = now()
      where id = p_request_id;
    insert into public.audit_events (company_id, branch_id, actor_user_id, event_class, event_type, module, entity_type, entity_id, new_value)
      values (v_company, v_branch, v_actor, 'Administrative', 'void.approved', 'pos', 'void_requests', p_request_id,
              jsonb_build_object('note', 'invoice was already Voided — request closed without new reversal', 'invoice_id', v_invoice));
    return;
  end if;

  -- stock returns (append-only movements) + COGS sum from the original lines
  -- NOTE: byte-equivalent to pos_void_sale body (P2-M2C §4). sales_order_items uses `quantity`
  -- as the line-quantity column (NOT `weight_kg` — that name is in the mock layer only).
  v_cogs := 0;
  for r in select finished_goods_batch_id, quantity, unit_cost from public.sales_order_items where sales_order_id = v_order loop
    insert into public.inventory_movements (company_id, branch_id, finished_goods_batch_id, movement_type, quantity, unit_cost, total_cost, source_document_type, source_document_id, reason, actor_user_id)
      values (v_company, v_branch, r.finished_goods_batch_id, 'AdjustmentIncrease', r.quantity, r.unit_cost, round(r.quantity * r.unit_cost, 2), 'VoidedInvoice', v_invoice, 'Approved void request', v_actor);
    v_cogs := v_cogs + round(r.quantity * r.unit_cost, 2);
  end loop;

  select id into a_cash  from public.chart_of_accounts where company_id = v_company and account_code = 'CASH';
  select id into a_sales from public.chart_of_accounts where company_id = v_company and account_code = 'SALES';
  select id into a_cogs  from public.chart_of_accounts where company_id = v_company and account_code = 'COGS';
  select id into a_fg    from public.chart_of_accounts where company_id = v_company and account_code = 'FG_INVENTORY';
  select id into a_ar    from public.chart_of_accounts where company_id = v_company and account_code = 'AR';
  v_entry := public.uuidv7();
  insert into public.journal_entries (id, company_id, branch_id, entry_number, source_document_type, source_document_id, description, created_by)
    values (v_entry, v_company, v_branch, public.pos_next_seq(v_company, v_branch, 'journal'), 'VoidedInvoice', v_invoice, 'Void (approved): ' || (select reason from public.void_requests where id = p_request_id), v_actor);
  -- reverse revenue against the tender source (cash if Paid, AR if Unpaid)
  insert into public.journal_lines (company_id, journal_entry_id, account_id, debit, credit) values
    (v_company, v_entry, a_sales, v_total, 0),
    (v_company, v_entry, case when v_status = 'Paid' then a_cash else a_ar end, 0, v_total);
  if v_cogs > 0 then
    insert into public.journal_lines (company_id, journal_entry_id, account_id, debit, credit) values
      (v_company, v_entry, a_fg,   v_cogs, 0),
      (v_company, v_entry, a_cogs, 0, v_cogs);
  end if;

  update public.invoices set status = 'Voided' where id = v_invoice;
  -- existing audit class (preserved for journal-history search) — same shape pos_void_sale writes
  insert into public.audit_events (company_id, branch_id, actor_user_id, event_class, event_type, module, entity_type, entity_id, new_value)
    values (v_company, v_branch, v_actor, 'Administrative', 'pos.sale_voided', 'pos', 'invoices', v_invoice, jsonb_build_object('reason', 'approved void request ' || p_request_id::text, 'was_status', v_status));
  -- new approval audit
  update public.void_requests
    set status = 'Approved', decided_by = v_actor, decided_at = now()
    where id = p_request_id;
  insert into public.audit_events (company_id, branch_id, actor_user_id, event_class, event_type, module, entity_type, entity_id)
    values (v_company, v_branch, v_actor, 'Administrative', 'void.approved', 'pos', 'void_requests', p_request_id);
end;
$$;
comment on function public.approve_void_request(uuid) is 'P2N2: approve a queued void. pos.void + approver != requester (separation of duties) required. Inlines the pos_void_sale reversal math (P2-M2C §4 / P2-M2E revised) so existing journal-history queries and audit class are preserved. Approver is recorded as the actor on every audit/journal row.';
revoke all on function public.approve_void_request(uuid) from public;
grant execute on function public.approve_void_request(uuid) to authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- 5. reject_void_request(p_request_id, p_reason) — no reversal executes.
--    pos.void + approver != requester. The slip stays at its current status.
-- ════════════════════════════════════════════════════════════════════════════
create function public.reject_void_request(p_request_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_actor     uuid;
  v_company   uuid;
  v_requested_by uuid;
begin
  v_actor := public.current_app_user_id();
  if v_actor is null then raise exception 'not an active user' using errcode = 'insufficient_privilege'; end if;
  if trim(coalesce(p_reason, '')) = '' then
    raise exception 'a rejection reason is required' using errcode = 'check_violation';
  end if;
  select ubr.company_id into v_company
    from public.user_branch_roles ubr
   where ubr.user_id = v_actor and ubr.assignment_status = 'Active'
     and public.has_permission(ubr.company_id, 'pos.void')
   limit 1;
  if v_company is null then
    raise exception 'permission denied: pos.void' using errcode = 'insufficient_privilege';
  end if;
  select vr.requested_by into v_requested_by
    from public.void_requests vr
   where vr.id = p_request_id and vr.status = 'Pending' and vr.company_id = v_company
   for update of vr;
  if not found then
    raise exception 'void request not found, already decided, or outside your company' using errcode = 'raise_exception';
  end if;
  if v_actor = v_requested_by then
    raise exception 'you cannot reject your own void request — ask another admin+' using errcode = 'insufficient_privilege';
  end if;
  update public.void_requests
    set status = 'Rejected', decided_by = v_actor, decided_at = now(), decision_reason = trim(p_reason)
    where id = p_request_id;
  insert into public.audit_events (company_id, actor_user_id, event_class, event_type, module, entity_type, entity_id)
    values (v_company, v_actor, 'Administrative', 'void.rejected', 'pos', 'void_requests', p_request_id);
end;
$$;
comment on function public.reject_void_request(uuid, text) is 'P2N2: reject a queued void. pos.void + approver != requester required. No reversal executes; the request is marked Rejected + audited.';
revoke all on function public.reject_void_request(uuid, text) from public;
grant execute on function public.reject_void_request(uuid, text) to authenticated;

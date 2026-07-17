-- Migration P2-N1 (PERM item 2) — Crop pricing approval workflow.
-- Owner directive 2026-07-16: employee/operator can EDIT crop pricing but needs ADMIN APPROVAL
-- before the change takes effect. Adds a price_change_requests queue + 3 RPCs.
--
-- Design:
--   request_price_change(p_product_id, p_new_price) — any active member of the company can file a
--     request. Validates the price is a positive numeric. Captures the CURRENT price as a snapshot
--     so an admin sees the delta. Status starts 'Pending'. Audit вставка.
--   list_price_change_requests() — admin+ (product.manage) sees pending requests for their company.
--   approve_price_change(p_request_id) — admin+ with product.manage. Applies the price to
--     public.products.retail_per_kg (running as the approver; the SECURITY DEFINER re-checks
--     product.manage in case the approver's role changed since the list call). Marks Approved.
--     Audit insert.
--   reject_price_change(p_request_id, p_reason) — admin+ with product.manage. Marks Rejected.
--     Audit insert.
--
-- All writes go through SECURITY DEFINER with set search_path = ''. Company isolation: the request
-- table's company_id is set from the product's row, NEVER from the caller's input — so a caller
-- can't file a request against another tenant's product. RLS enabled + forced on the new table.
-- Money-adjacent (price feeds POS), but no GL postings; still gated as a price-path change.

create table if not exists public.price_change_requests (
  id                       uuid        primary key default uuidv7(),
  company_id               uuid        not null references public.companies(id) on delete restrict,
  product_id               uuid        not null references public.products(id) on delete restrict,
  current_retail_per_kg    numeric(12,2) not null,
  requested_retail_per_kg  numeric(12,2) not null,
  requester_user_id        uuid        not null references public.users(id) on delete restrict,
  status                   text        not null default 'Pending',
  approver_user_id         uuid        references public.users(id) on delete restrict,
  rejection_reason         text,
  created_at              timestamptz not null default now(),
  resolved_at             timestamptz
);

-- Lock to a small status enum; mirrors P1J/P1M pattern.
alter table public.price_change_requests
  add constraint price_change_requests_status_check
    check (status in ('Pending','Approved','Rejected')),
  add constraint price_change_requests_requested_positive
    check (requested_retail_per_kg > 0),
  add constraint price_change_requests_current_positive
    check (current_retail_per_kg >= 0),
  add constraint price_change_requests_resolved_only_when_not_pending
    check (
      (status = 'Pending' and resolved_at is null and approver_user_id is null and rejection_reason is null)
      or
      (status in ('Approved','Rejected') and resolved_at is not null and approver_user_id is not null)
    ),
  add constraint price_change_requests_rejection_only_when_rejected
    check (rejection_reason is null or status = 'Rejected');

-- enable + force RLS
alter table public.price_change_requests enable row level security;
alter table public.price_change_requests force row level security;

-- anyone in the company can READ the requests for their tenant (visibility for the request queue)
create policy price_change_requests_select
  on public.price_change_requests
  for select to authenticated
  using (company_id in (select ubr.company_id from public.user_branch_roles ubr
                        where ubr.user_id = public.current_app_user_id()
                          and ubr.assignment_status = 'Active'));

-- writes only through SECURITY DEFINER functions (no direct INSERT/UPDATE/DELETE policy)
revoke insert, update, delete on public.price_change_requests from authenticated, anon;

-- helper: insert an audit row (column shape matches the existing audit_events table: new_value
-- captures the event payload, previous_value captures the antecedent state; P1M-pattern company_id
-- NOT NULL so the SELECT RLS policy can see the row when re-read by an admin+ auditor).
create or replace function public.audit_price_change_event(
  p_company_id uuid,
  p_actor_user_id uuid,
  p_event_type text,
  p_entity_id uuid,
  p_previous jsonb,
  p_new jsonb
) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.audit_events (company_id, event_class, event_type, actor_user_id, entity_id, previous_value, new_value)
  values (p_company_id, 'Administrative', p_event_type, p_actor_user_id, p_entity_id, p_previous, p_new);
end;
$$;

-- 1) request a price change. Caller must be an active member of the product's company (any role).
--    Company_id is taken from the product row, NEVER from the caller.
create or replace function public.request_price_change(
  p_product_id uuid,
  p_new_price numeric
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_user_id      uuid := public.current_app_user_id();
  v_company_id   uuid;
  v_product      public.products%rowtype;
  v_request_id   uuid;
  v_requester_role_name text;
begin
  if v_user_id is null then
    raise insufficient_privilege using message = 'Authentication required';
  end if;

  select * into v_product from public.products where id = p_product_id;
  if not found then
    raise exception using message = 'Product not found';
  end if;
  v_company_id := v_product.company_id;

  -- caller must be an active member of the product's company (any rank — employee and up)
  select r.role_key into v_requester_role_name
  from public.user_branch_roles ubr
  join public.roles r on r.id = ubr.role_id and r.company_id = ubr.company_id
  where ubr.user_id = v_user_id
    and ubr.company_id = v_company_id
    and ubr.assignment_status = 'Active'
    and (ubr.expires_at is null or ubr.expires_at > now())
  limit 1;
  if not found then
    raise insufficient_privilege using message = 'You are not an active member of this company';
  end if;

  if p_new_price is null or p_new_price <= 0 then
    raise exception using message = 'Requested price must be a positive number';
  end if;

  -- one pending request per product max (reject duplicates)
  if exists (select 1 from public.price_change_requests
             where product_id = p_product_id and status = 'Pending' and company_id = v_company_id) then
    raise exception using message = 'A pending price change request already exists for this product';
  end if;

  insert into public.price_change_requests (
    company_id, product_id, current_retail_per_kg, requested_retail_per_kg, requester_user_id, status
  ) values (
    v_company_id, p_product_id, v_product.retail_per_kg, p_new_price, v_user_id, 'Pending'
  ) returning id into v_request_id;

  perform public.audit_price_change_event(v_company_id, v_user_id, 'price_change.requested',
    v_request_id, jsonb_build_object('retail_per_kg', v_product.retail_per_kg),
    jsonb_build_object('product_id', p_product_id, 'product_name', v_product.name,
      'retail_per_kg', p_new_price, 'requester_role', v_requester_role_name));

  return v_request_id;
end;
$$;

-- 2) list pending price change requests (admin+ = product.manage)
create or replace function public.list_price_change_requests()
  returns table (
    id                      uuid,
    company_id              uuid,
    product_id              uuid,
    product_name            text,
    product_code            text,
    current_retail_per_kg   numeric,
    requested_retail_per_kg numeric,
    requester_user_id       uuid,
    requester_name          text,
    status                  text,
    created_at              timestamptz,
    approver_user_id        uuid,
    resolved_at             timestamptz,
    rejection_reason        text
  )
language plpgsql security definer set search_path = '' as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_company_id uuid;
  v_role_name text;
begin
  if v_user_id is null then
    raise insufficient_privilege using message = 'Authentication required';
  end if;
  select ubr.company_id, r.role_key into v_company_id, v_role_name
  from public.user_branch_roles ubr
  join public.roles r on r.id = ubr.role_id and r.company_id = ubr.company_id
  where ubr.user_id = v_user_id and ubr.assignment_status = 'Active'
    and (ubr.expires_at is null or ubr.expires_at > now())
  limit 1;
  if v_company_id is null then
    raise insufficient_privilege using message = 'No active membership';
  end if;
  if not public.has_permission(v_company_id, 'product.manage'::text) then
    raise insufficient_privilege using message = 'product.manage required to review price changes';
  end if;

  return query
    select r.id, r.company_id, r.product_id, p.name, p.product_code,
           r.current_retail_per_kg, r.requested_retail_per_kg,
           r.requester_user_id, u.display_name as requester_name,
           r.status, r.created_at, r.approver_user_id, r.resolved_at, r.rejection_reason
    from public.price_change_requests r
    join public.products p on p.id = r.product_id
    left join public.users u on u.id = r.requester_user_id
    where r.company_id = v_company_id
    order by r.created_at desc;
end;
$$;

-- 3) approve a price change request. Approver must have product.manage. Separation of duties:
--    the requester cannot approve their own request (matches P1J pattern). Applies the change to
--    products.retail_per_kg.
create or replace function public.approve_price_change(
  p_request_id uuid
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_user_id     uuid := public.current_app_user_id();
  v_request     public.price_change_requests%rowtype;
  v_company_id  uuid;
  v_product      public.products%rowtype;
begin
  if v_user_id is null then
    raise insufficient_privilege using message = 'Authentication required';
  end if;

  select * into v_request from public.price_change_requests where id = p_request_id;
  if not found then
    raise exception using message = 'Price change request not found';
  end if;
  v_company_id := v_request.company_id;

  -- approver must be an active member of the request's company WITH product.manage
  -- (set the jwt context so has_permission resolves the approver's effective permissions)
  perform set_config('request.jwt.claims', json_build_object('sub',
    (select u.auth_user_id from public.users u where u.id = v_user_id)::text
  )::text, true);
  if not public.has_permission(v_company_id, 'product.manage'::text) then
    raise insufficient_privilege using message = 'product.manage required to approve price changes';
  end if;

  if v_request.requester_user_id = v_user_id then
    raise insufficient_privilege using message = 'Cannot approve your own request (separation of duties)';
  end if;

  if v_request.status <> 'Pending' then
    raise exception using message = 'Request is no longer pending';
  end if;

  select * into v_product from public.products where id = v_request.product_id;
  if not found then
    raise exception using message = 'Product no longer exists';
  end if;

  -- apply the change (running as postgres via SECURITY DEFINER; product.manage gate above)
  update public.products
     set retail_per_kg = v_request.requested_retail_per_kg,
         updated_at    = now()
   where id = v_request.product_id and company_id = v_company_id;

  update public.price_change_requests
     set status = 'Approved',
         approver_user_id = v_user_id,
         resolved_at = now()
   where id = p_request_id and company_id = v_company_id;

  perform public.audit_price_change_event(v_company_id, v_user_id, 'price_change.approved',
    p_request_id,
    jsonb_build_object('product_id', v_request.product_id, 'product_name', v_product.name, 'retail_per_kg', v_product.retail_per_kg),
    jsonb_build_object('product_id', v_request.product_id, 'product_name', v_product.name,
      'retail_per_kg', v_request.requested_retail_per_kg,
      'requester_user_id', v_request.requester_user_id));
end;
$$;

-- 4) reject a price change request.
create or replace function public.reject_price_change(
  p_request_id uuid,
  p_rejection_reason text
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_user_id   uuid := public.current_app_user_id();
  v_request   public.price_change_requests%rowtype;
  v_company_id uuid;
begin
  if v_user_id is null then
    raise insufficient_privilege using message = 'Authentication required';
  end if;
  if p_rejection_reason is null or length(trim(p_rejection_reason)) = 0 then
    raise exception using message = 'A rejection reason is required';
  end if;

  select * into v_request from public.price_change_requests where id = p_request_id;
  if not found then
    raise exception using message = 'Price change request not found';
  end if;
  v_company_id := v_request.company_id;

  if not public.has_permission(v_company_id, 'product.manage'::text) then
    raise insufficient_privilege using message = 'product.manage required to reject price changes';
  end if;

  if v_request.status <> 'Pending' then
    raise exception using message = 'Request is no longer pending';
  end if;

  update public.price_change_requests
     set status = 'Rejected',
         approver_user_id = v_user_id,
         rejection_reason = p_rejection_reason,
         resolved_at = now()
   where id = p_request_id and company_id = v_company_id;

  perform public.audit_price_change_event(v_company_id, v_user_id, 'price_change.rejected',
    p_request_id,
    jsonb_build_object('product_id', v_request.product_id, 'retail_per_kg', v_request.current_retail_per_kg),
    jsonb_build_object('product_id', v_request.product_id,
      'requested_retail_per_kg', v_request.requested_retail_per_kg,
      'reason', p_rejection_reason,
      'requester_user_id', v_request.requester_user_id));
end;
$$;

-- grant execute to authenticated (anon revokes)
revoke execute on function public.request_price_change(uuid, numeric) from anon;
revoke execute on function public.list_price_change_requests() from anon;
revoke execute on function public.approve_price_change(uuid) from anon;
revoke execute on function public.reject_price_change(uuid, text) from anon;
grant execute on function public.request_price_change(uuid, numeric) to authenticated;
grant execute on function public.list_price_change_requests() to authenticated;
grant execute on function public.approve_price_change(uuid) to authenticated;
grant execute on function public.reject_price_change(uuid, text) to authenticated;

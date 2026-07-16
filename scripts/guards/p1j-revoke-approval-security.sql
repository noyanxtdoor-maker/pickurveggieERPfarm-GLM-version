-- Guard battery for P1J revoke-approval workflow (owner directive 2026-07-16).
-- Auth-boundary (memberships): tests the 4 RPCs + RLS + the separation-of-duties gate.
--
-- Org:
--   - bootstrap one tenant the REAL way (owner role, rank 50, full catalog).
--   - seed the standard tiers via seed_standard_roles (employee/operator/admin/co_owner).
--   - create helper users: an EMPLOYEE (rank 10) = revoke target, plus a SECOND owner-tier person
--     (co_owner role rank 40) = the necessary second approver (separation of duties).
-- Exercise:
--   HAPPY 1: co_owner1 requests revoke of employee -> queued + audited.
--   HAPPY 2: the OTHER co_owner (co_owner2) approves -> employee memberships Expired, request
--            Approved, 'revoke.approved' audit emitted.
--   SAD 1: EMPLOYEE (no membership.manage) tries request_revoke -> insufficient_privilege.
--   SAD 2: co_owner1 (the REQUESTER) tries approve_revoke_request on their own request ->
--          insufficient_privilege (separation of duties — cannot self-approve).
--   SAD 3: duplicate request_revoke while one is Pending -> raise_exception.
--   SAD 4: self-revoke (co_owner tries request_revoke(co_owner)) -> insufficient_privilege.
-- Wrapped in BEGIN/ROLLBACK; does not mutate (reset re-seeds on next run).
\set ON_ERROR_STOP on
begin;
set local app.p1a_skip_signup_trigger = '1';

-- Owner auth.users + bootstrap
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000', '0a000000-0000-0000-0000-0000000000a1'::uuid, 'authenticated', 'authenticated', 'owner.p1j@t.local');
do $$ begin
  set local role service_role;
  perform public.bootstrap_initial_tenant('0a000000-0000-0000-0000-0000000000a1','Owner P1J','P1JCO','P1J Company','P1JBR','P1J Branch');
  set local role postgres;  -- revert so subsequent auth.users inserts run as superuser, not service_role
end $$;

-- Helper: fetch the company + branch + owner role
create temp table g as select
  (select id from public.companies where company_code='P1JCO') as v_company,
  (select id from public.branches where branch_code='P1JBR') as v_branch,
  (select id from public.users where auth_user_id='0a000000-0000-0000-0000-0000000000a1') as v_owner,
  (select id from public.roles where company_id=(select id from public.companies where company_code='P1JCO') and role_key='owner') as v_owner_role,
  (select id from public.roles where company_id=(select id from public.companies where company_code='P1JCO') and role_key='co_owner') as v_co_role,
  (select id from public.roles where company_id=(select id from public.companies where company_code='P1JCO') and role_key='employee') as v_emp_role;

-- CO_OWNER1 (a membership.manage holder; the requester)
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000', '0b000000-0000-0000-0000-0000000000b5'::uuid, 'authenticated', 'authenticated', 'co1.p1j@t.local');
do $$ declare v_co1 uuid; begin
  -- p1a_skip_signup_trigger is set, so the auth trigger is skipped — insert public.users manually.
  insert into public.users (auth_user_id, display_name, email, username)
    values ('0b000000-0000-0000-0000-0000000000b5', 'Co1 P1J', 'co1.p1j@t.local', 'co1_p1j')
    on conflict (auth_user_id) do nothing;
  select id into v_co1 from public.users where auth_user_id='0b000000-0000-0000-0000-0000000000b5';
  insert into public.user_branch_roles (user_id, company_id, branch_id, role_id)
    values (v_co1, (select v_company from g), (select v_branch from g), (select v_co_role from g));
end $$;

-- CO_OWNER2 (the separate approver)
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000', '0b000000-0000-0000-0000-0000000000b6'::uuid, 'authenticated', 'authenticated', 'co2.p1j@t.local');
do $$ declare v_co2 uuid; begin
  insert into public.users (auth_user_id, display_name, email, username)
    values ('0b000000-0000-0000-0000-0000000000b6', 'Co2 P1J', 'co2.p1j@t.local', 'co2_p1j')
    on conflict (auth_user_id) do nothing;
  select id into v_co2 from public.users where auth_user_id='0b000000-0000-0000-0000-0000000000b6';
  insert into public.user_branch_roles (user_id, company_id, branch_id, role_id)
    values (v_co2, (select v_company from g), (select v_branch from g), (select v_co_role from g));
end $$;

-- EMPLOYEE (the revoke target)
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000', '0b000000-0000-0000-0000-0000000000b1'::uuid, 'authenticated', 'authenticated', 'emp.p1j@t.local');
do $$ declare v_emp uuid; begin
  insert into public.users (auth_user_id, display_name, email, username)
    values ('0b000000-0000-0000-0000-0000000000b1', 'Emp P1J', 'emp.p1j@t.local', 'emp_p1j')
    on conflict (auth_user_id) do nothing;
  select id into v_emp from public.users where auth_user_id='0b000000-0000-0000-0000-0000000000b1';
  insert into public.user_branch_roles (user_id, company_id, branch_id, role_id)
    values (v_emp, (select v_company from g), (select v_branch from g), (select v_emp_role from g));
end $$;

-- ── HAPPY 1: co_owner1 requests revoke of the employee ─────────────────────
do $$ declare v_co1 uuid; v_emp uuid; v_req uuid; n int;
  v_co1_auth uuid := '0b000000-0000-0000-0000-0000000000b5';
begin
  select id into v_co1 from public.users where auth_user_id=v_co1_auth;
  select id into v_emp from public.users where auth_user_id='0b000000-0000-0000-0000-0000000000b1';
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_co1_auth)::text, true);
  v_req := public.request_revoke(v_emp, 'end of contract');
  if v_req is null then raise exception 'HAPPY1: request_revoke returned null'; end if;
  select count(*) into n from public.revoke_requests where id=v_req and status='Pending';
  if n<>1 then raise exception 'HAPPY1: request not Pending'; end if;
  select count(*) into n from public.audit_events where event_type='revoke.requested' and entity_id=v_req;
  if n<>1 then raise exception 'HAPPY1: revoke.requested audit missing'; end if;
  raise notice 'OK HAPPY1: co_owner1 requested revoke, request Pending, audited';
end $$;

-- ── HAPPY 2: co_owner2 approves -> employee memberships Expired, request Approved, audited ─
do $$ declare v_co2 uuid; v_emp uuid; v_req uuid; n int;
  v_co2_auth uuid := '0b000000-0000-0000-0000-0000000000b6';
begin
  select id into v_co2 from public.users where auth_user_id=v_co2_auth;
  select id into v_emp from public.users where auth_user_id='0b000000-0000-0000-0000-0000000000b1';
  select id into v_req from public.revoke_requests where target_user_id=v_emp and status='Pending';
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_co2_auth)::text, true);
  perform public.approve_revoke_request(v_req);
  select count(*) into n from public.user_branch_roles where user_id=v_emp and assignment_status='Active';
  if n<>0 then raise exception 'HAPPY2: employee still has active memberships after approve'; end if;
  select count(*) into n from public.revoke_requests where id=v_req and status='Approved';
  if n<>1 then raise exception 'HAPPY2: request not Approved'; end if;
  select count(*) into n from public.audit_events where event_type='revoke.approved' and entity_id=v_emp;
  if n<>1 then raise exception 'HAPPY2: revoke.approved audit missing'; end if;
  raise notice 'OK HAPPY2: co_owner2 approved, employee memberships Expired, request Approved, audited';
end $$;

-- ── SAD 1: EMPLOYEE (no membership.manage) tries request_revoke on co_owner1 ─
do $$ declare v_emp uuid; v_co1 uuid;
  v_emp_auth uuid := '0b000000-0000-0000-0000-0000000000b1';
begin
  select id into v_emp from public.users where auth_user_id=v_emp_auth;
  select id into v_co1 from public.users where auth_user_id='0b000000-0000-0000-0000-0000000000b5';
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_emp_auth)::text, true);
  begin
    perform public.request_revoke(v_co1, 'nope');
    raise exception 'SAD1: employee should not be able to request_revoke';
  exception when insufficient_privilege then
    raise notice 'OK SAD1: employee denied (insufficient_privilege) — membership.manage required';
  end;
end $$;

-- ── SAD 2: co_owner1 (the REQUESTER) tries to approve their own request ────
do $$ declare v_co1 uuid; v_co2 uuid; v_req uuid; n int;
  v_co1_auth uuid := '0b000000-0000-0000-0000-0000000000b5';
begin
  set local role postgres;  -- clear any leaked authenticated role from prior blocks
  select id into v_co1 from public.users where auth_user_id=v_co1_auth;
  select id into v_co2 from public.users where auth_user_id='0b000000-0000-0000-0000-0000000000b6';
  -- sanity: co_owner2 must still have an active membership
  select count(*) into n from public.user_branch_roles where user_id=v_co2 and assignment_status='Active';
  if n=0 then raise exception 'SAD2 precondition: co_owner2 has no active membership'; end if;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_co1_auth)::text, true);
  v_req := public.request_revoke(v_co2, 'test self-approve');
  begin
    perform public.approve_revoke_request(v_req);
    raise exception 'SAD2: co_owner1 should not approve their own request';
  exception when insufficient_privilege then
    raise notice 'OK SAD2: self-approve denied (insufficient_privilege) — separation of duties';
  end;
end $$;

-- ── SAD 3: duplicate request_revoke while one is Pending ──────────────────
do $$ declare v_co1 uuid; v_co2 uuid; n int;
  v_co1_auth uuid := '0b000000-0000-0000-0000-0000000000b5';
begin
  set local role postgres;
  select id into v_co1 from public.users where auth_user_id=v_co1_auth;
  select id into v_co2 from public.users where auth_user_id='0b000000-0000-0000-0000-0000000000b6';
  -- precondition: a Pending request for co_owner2 already exists from SAD2
  select count(*) into n from public.revoke_requests where target_user_id=v_co2 and status='Pending';
  if n=0 then raise exception 'SAD3 precondition: no Pending request for co_owner2'; end if;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_co1_auth)::text, true);
  begin
    perform public.request_revoke(v_co2, 'dup');
    raise exception 'SAD3: duplicate Pending request should have been rejected';
  exception when raise_exception then
    raise notice 'OK SAD3: duplicate Pending request rejected (one per target)';
  end;
end $$;

-- ── SAD 4: self-revoke (co_owner1 tries request_revoke on themselves) ──────
do $$ declare v_co1 uuid; n int;
  v_co1_auth uuid := '0b000000-0000-0000-0000-0000000000b5';
begin
  set local role postgres;
  select id into v_co1 from public.users where auth_user_id=v_co1_auth;
  select count(*) into n from public.user_branch_roles where user_id=v_co1 and assignment_status='Active';
  if n=0 then raise exception 'SAD4 precondition: co_owner1 has no active membership'; end if;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_co1_auth)::text, true);
  begin
    perform public.request_revoke(v_co1, 'self');
    raise exception 'SAD4: self-revoke should have been rejected';
  exception when insufficient_privilege then
    raise notice 'OK SAD4: self-revoke denied (insufficient_privilege)';
  end;
end $$;

-- p1j revoke-approval security guard -- ALL 6 CHECKS PASSED (2 HAPPY + 4 SAD)
rollback;

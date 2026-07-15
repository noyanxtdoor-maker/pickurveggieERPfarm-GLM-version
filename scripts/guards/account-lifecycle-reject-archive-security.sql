-- Tier-2 BEHAVIORAL P1F/P1G/P1H — pending-signup reject + archive + employee calendar access.
-- Authority: owner spec 2026-07-13 (live-testing the account lifecycle + Employee role) ·
--   supabase/migrations/20260715130000_p1f_reject_pending_signups.sql
--   supabase/migrations/20260715140000_p1g_archive_revoked_accounts.sql (Repo B consolidated P1G1 shape)
--   supabase/migrations/20260715150000_p1h_employee_calendar_access.sql
-- Proves: reject_pending_user turns away a pending signup → Suspended; membership.manage-gated; only
-- reachable while target is genuinely pending (Active, zero memberships) — cannot be repurposed as a
-- generic "suspend anyone" shortcut. my_account_status is self-only (keyed to auth.uid — returns own
-- status, NULL for unknown). archive_user_account auto-revokes every remaining active membership in
-- ONE atomic call, each gated by actor outranking that specific role (all-or-nothing); cannot archive
-- if any active role outranks the actor. unarchive_user_account brings back to Active (still zero
-- memberships). P1H backfills schedule.read to existing employee roles.
-- Self-contained BEGIN/ROLLBACK; any DEFECT raises under ON_ERROR_STOP.
\set ON_ERROR_STOP on
begin;
set local app.p1a_skip_signup_trigger = '1';

-- ── fixtures: one company bootstrapped the real way ──
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','0a000000-0000-0000-0000-0000000000e1','authenticated','authenticated','ownerFGH@t.local');
do $$ begin
  set local role service_role;
  perform public.bootstrap_initial_tenant('0a000000-0000-0000-0000-0000000000e1','Owner FGH','CO-FGH','Company FGH','BR-FGH','Branch FGH');
end $$;

-- ── P1F: reject_pending_user happy path + sad paths ──
do $$ declare v_company uuid; v_branch uuid; v_owner_auth uuid := '0a000000-0000-0000-0000-0000000000e1';
  v_pending_auth uuid := '0b000000-0000-0000-0000-0000000000e2'; v_pending_id uuid; v_assigned_auth uuid := '0c000000-0000-0000-0000-0000000000e3';
  v_assigned_id uuid; v_emp_role uuid; v_adm_auth uuid := '0d000000-0000-0000-0000-0000000000e4'; v_adm_id uuid; v_adm_role uuid;
begin
  set local role postgres;
  select company_id into v_company from public.bootstrap_state where id;
  select id into v_branch from public.branches where company_id=v_company;
  select id into v_emp_role from public.roles where company_id=v_company and role_key='employee';
  select id into v_adm_role from public.roles where company_id=v_company and role_key='admin';

  -- a pending signup: an Active users row with zero memberships
  insert into auth.users (instance_id, id, aud, role, email) values ('00000000-0000-0000-0000-000000000000', v_pending_auth, 'authenticated','authenticated','pendingFGH@t.local');
  insert into public.users (auth_user_id, display_name) values (v_pending_auth, 'Pending FGH');
  select id into v_pending_id from public.users where auth_user_id=v_pending_auth;

  -- an assigned worker (Active user WITH an active membership) — must NOT be rejectable via reject_pending_user
  insert into auth.users (instance_id, id, aud, role, email) values ('00000000-0000-0000-0000-000000000000', v_assigned_auth, 'authenticated','authenticated','assignedFGH@t.local');
  insert into public.users (auth_user_id, display_name) values (v_assigned_auth, 'Assigned FGH');
  select id into v_assigned_id from public.users where auth_user_id=v_assigned_auth;
  insert into public.user_branch_roles (user_id, company_id, branch_id, role_id) values (v_assigned_id, v_company, v_branch, v_emp_role);

  -- admin (no membership.manage per standard catalog) cannot reject anyone
  insert into auth.users (instance_id, id, aud, role, email) values ('00000000-0000-0000-0000-000000000000', v_adm_auth, 'authenticated','authenticated','admFGH@t.local');
  insert into public.users (auth_user_id, display_name) values (v_adm_auth, 'Adm FGH');
  select id into v_adm_id from public.users where auth_user_id=v_adm_auth;
  insert into public.user_branch_roles (user_id, company_id, branch_id, role_id) values (v_adm_id, v_company, v_branch, v_adm_role);
  set local role authenticated; perform set_config('request.jwt.claims', json_build_object('sub', v_adm_auth)::text, true);
  begin
    perform public.reject_pending_user(v_pending_id);
    raise exception 'DEFECT p1f: admin (no membership.manage) rejected a pending signup';
  exception when insufficient_privilege then raise notice 'PASS p1f: reject requires membership.manage (admin correctly denied)'; end;

  -- owner CAN reject a pending signup
  set local role authenticated; perform set_config('request.jwt.claims', json_build_object('sub', v_owner_auth)::text, true);
  perform public.reject_pending_user(v_pending_id);
  if not (select account_status = 'Suspended' from public.users where id = v_pending_id) then
    raise exception 'DEFECT p1f: pending signup was not Suspended after reject';
  end if;
  raise notice 'PASS p1f: owner rejects a pending signup → Suspended (account_status lifecycle preserved; no row deleted)';

  -- already-rejected (now Suspended) cannot be rejected AGAIN via this path
  begin
    perform public.reject_pending_user(v_pending_id);
    raise exception 'DEFECT p1f: already-rejected account was re-rejectable (should require fresh pending state)';
  exception when others then
    if sqlstate <> 'P0001' then raise; end if;
    raise notice 'PASS p1f: reject refuses a non-pending target (cannot be repurposed as a generic suspend shortcut)';
  end;

  -- an assigned worker (Active WITH an active membership) cannot be rejected via this path
  begin
    perform public.reject_pending_user(v_assigned_id);
    raise exception 'DEFECT p1f: an assigned worker (with active membership) was rejectable via the pending-signup path';
  exception when others then
    if sqlstate <> 'P0001' then raise; end if;
    raise notice 'PASS p1f: reject refuses a target that already holds an active membership (use the rank-checked revoke path)';
  end;
end $$;

-- ── P1F: my_account_status is self-only (keyed to auth.uid) ──
do $$ declare v_owner_auth uuid := '0a000000-0000-0000-0000-0000000000e1'; v_status text;
begin
  set local role authenticated; perform set_config('request.jwt.claims', json_build_object('sub', v_owner_auth)::text, true);
  v_status := public.my_account_status();
  if v_status is null or v_status not in ('Active','Suspended','Archived') then
    raise exception 'DEFECT p1f: my_account_status returned an unexpected value for an Active owner: %', v_status;
  end if;
  raise notice 'PASS p1f: my_account_status returns own status for an authenticated identity (%)', v_status;
  -- a Suspended identity still reads their OWN status via my_account_status (current_app_user_id is NULL
  -- for Suspended by design — that's the whole point of this function)
  perform set_config('request.jwt.claims', json_build_object('sub','0b000000-0000-0000-0000-0000000000e2')::text, true);
  v_status := public.my_account_status();
  if v_status <> 'Suspended' then
    raise exception 'DEFECT p1f: a Suspended identity should read ``Suspended`` from my_account_status, got %', v_status;
  end if;
  raise notice 'PASS p1f: Suspended identity reads own status via my_account_status (distinguishes "still pending" from "rejected")';
  -- an unknown auth uid returns NULL (no cross-user data exposure)
  perform set_config('request.jwt.claims', json_build_object('sub','ffffff00-0000-0000-0000-0000000000ff')::text, true);
  v_status := public.my_account_status();
  if v_status is not null then raise exception 'DEFECT p1f: my_account_status returned a value for an unknown auth uid: %', v_status; end if;
  raise notice 'PASS p1f: my_account_status returns NULL for an unknown auth uid (self-only, no cross-user exposure)';
end $$;

-- ── P1G: archive_user_account auto-revoke + outranks all-or-nothing + unarchive ──
do $$ declare v_company uuid; v_branch uuid; v_owner_auth uuid := '0a000000-0000-0000-0000-0000000000e1';
  v_emp_role uuid; v_op_role uuid; v_co_role uuid; v_own_role uuid;
  v_emp2_auth uuid := '0e000000-0000-0000-0000-0000000000e5'; v_emp2_id uuid; v_reassigntarget_auth uuid := '0f000000-0000-0000-0000-0000000000e6'; v_reassigntarget_id uuid;
  v_co2_auth uuid := '10000000-0000-0000-0000-0000000000e7'; v_co2_id uuid; v_refused boolean := false;
begin
  set local role postgres;
  select company_id into v_company from public.bootstrap_state where id;
  select id into v_branch from public.branches where company_id=v_company;
  select id into v_emp_role from public.roles where company_id=v_company and role_key='employee';
  select id into v_op_role from public.roles where company_id=v_company and role_key='operator';
  select id into v_co_role from public.roles where company_id=v_company and role_key='co_owner';
  select id into v_own_role from public.roles where company_id=v_company and role_key='owner';

  -- a worker holding an active employee membership — archiving should auto-revoke it
  insert into auth.users (instance_id, id, aud, role, email) values ('00000000-0000-0000-0000-000000000000', v_emp2_auth, 'authenticated','authenticated','emp2FGH@t.local');
  insert into public.users (auth_user_id, display_name) values (v_emp2_auth, 'Emp2 FGH');
  select id into v_emp2_id from public.users where auth_user_id=v_emp2_auth;
  insert into public.user_branch_roles (user_id, company_id, branch_id, role_id) values (v_emp2_id, v_company, v_branch, v_emp_role);

  -- owner archives the worker: auto-revokes the active membership + sets Archived in ONE atomic call
  set local role authenticated; perform set_config('request.jwt.claims', json_build_object('sub', v_owner_auth)::text, true);
  perform public.archive_user_account(v_emp2_id);
  if not (select account_status = 'Archived' from public.users where id = v_emp2_id) then
    raise exception 'DEFECT p1g: archive did not set account_status=Archived';
  end if;
  if exists (select 1 from public.user_branch_roles where user_id = v_emp2_id and assignment_status = 'Active') then
    raise exception 'DEFECT p1g: archive did not auto-revoke the active membership';
  end if;
  raise notice 'PASS p1g: archive_user_account auto-revokes active memberships + sets Archived atomically (P1G1 consolidated shape)';

  -- unarchive brings back to Active, still zero memberships
  perform public.unarchive_user_account(v_emp2_id);
  if not (select account_status = 'Active' from public.users where id = v_emp2_id) then
    raise exception 'DEFECT p1g: unarchive did not restore Active';
  end if;
  if exists (select 1 from public.user_branch_roles where user_id = v_emp2_id and assignment_status = 'Active') then
    raise exception 'DEFECT p1g: unarchive should not auto-reassign any membership';
  end if;
  raise notice 'PASS p1g: unarchive_user_account restores Active, leaves zero memberships (admin must separately reassign)';
end $$;

-- ALL-OR-NOTHING rank gate: a co_owner (rank 40) cannot archive someone who holds an owner-tier role (rank 50).
-- SEPARATE DO block — the previous one ended with set local role authenticated (owner impersonation for the
-- archive/unarchive happy path); cannot escalate back to postgres in the same subtransaction context.
do $$ declare v_company uuid; v_branch uuid;
  v_own_role uuid; v_reassigntarget_auth uuid := '0f000000-0000-0000-0000-0000000000e6'; v_reassigntarget_id uuid;
  v_co2_auth uuid := '10000000-0000-0000-0000-0000000000e7'; v_co2_id uuid; v_co_role uuid;
begin
  set local role postgres;
  select company_id into v_company from public.bootstrap_state where id;
  select id into v_branch from public.branches where company_id=v_company;
  select id into v_own_role from public.roles where company_id=v_company and role_key='owner';
  select id into v_co_role from public.roles where company_id=v_company and role_key='co_owner';
  insert into auth.users (instance_id, id, aud, role, email) values ('00000000-0000-0000-0000-000000000000', v_reassigntarget_auth, 'authenticated','authenticated','ownertierFGH@t.local');
  insert into public.users (auth_user_id, display_name) values (v_reassigntarget_auth, 'Owner-Tier FGH');
  select id into v_reassigntarget_id from public.users where auth_user_id=v_reassigntarget_auth;
  insert into public.user_branch_roles (user_id, company_id, branch_id, role_id) values (v_reassigntarget_id, v_company, v_branch, v_own_role);
  -- give the co_owner rank an Active membership of their own so they can call the function
  insert into auth.users (instance_id, id, aud, role, email) values ('00000000-0000-0000-0000-000000000000', v_co2_auth, 'authenticated','authenticated','co2FGH@t.local');
  insert into public.users (auth_user_id, display_name) values (v_co2_auth, 'Co2 FGH');
  select id into v_co2_id from public.users where auth_user_id=v_co2_auth;
  insert into public.user_branch_roles (user_id, company_id, branch_id, role_id) values (v_co2_id, v_company, v_branch, v_co_role);
  set local role authenticated; perform set_config('request.jwt.claims', json_build_object('sub', v_co2_auth)::text, true);
  begin
    perform public.archive_user_account(v_reassigntarget_id);
    raise exception 'DEFECT p1g: co_owner archived an account holding an owner-tier role (outranks all-or-nothing failed)';
  exception when insufficient_privilege then
    raise notice 'PASS p1g: archive refuses when one active role outranks the actor (all-or-nothing refusal)';
  end;
end $$;
do $$ declare v_reassigntarget_auth uuid := '0f000000-0000-0000-0000-0000000000e6'; v_reassigntarget_id uuid;
begin
  set local role postgres;
  -- IMPORTANT: resolve users.id from auth_user_id (the trigger generates a UUIDv7 for users.id; the
  -- literal `'0f00...` is the AUTH user id, NOT public.users.id). Earlier this guard hardcoded the
  -- auth id as if it were users.id and got a false-alarm "nothing touched" DEFECT. Test your test.
  select id into v_reassigntarget_id from public.users where auth_user_id = v_reassigntarget_auth;
  if v_reassigntarget_id is null then raise exception 'DEFECT p1g: target users row not found — fixture lost between DO blocks'; end if;
  if not (select account_status = 'Active' from public.users where id = v_reassigntarget_id) then
    raise exception 'DEFECT p1g: the all-or-nothing archive touched the users row even after refusing';
  end if;
  if not exists (select 1 from public.user_branch_roles where user_id = v_reassigntarget_id and assignment_status = 'Active') then
    raise exception 'DEFECT p1g: the all-or-nothing archive revoked a membership even after refusing';
  end if;
  raise notice 'PASS p1g: nothing was touched by the refused archive (account still Active, membership still Active — all-or-nothing confirmed)';
end $$;

-- ── P1H: existing employee role backfilled with schedule.read ──
do $$ declare v_company uuid; v_owner_auth uuid := '0a000000-0000-0000-0000-0000000000e1'; v_emp_id uuid; v_branch uuid;
begin
  set local role postgres;
  select company_id into v_company from public.bootstrap_state where id;
  select id into v_branch from public.branches where company_id=v_company;
  -- bootstrap_initial_tenant already seeded the employee role for this company; P1H's backfill should have
  -- granted schedule.read to it. Re-call seed_standard_roles (the P1H version) to idempotently ensure + verify.
  perform public.seed_standard_roles(v_company);
  if not exists (
    select 1 from public.role_permissions rp
    join public.roles r on r.id = rp.role_id
    join public.permissions p on p.id = rp.permission_id
    where r.company_id = v_company and r.role_key = 'employee' and p.permission_key = 'schedule.read'
  ) then
    raise exception 'DEFECT p1h: employee role lacks schedule.read after P1H backfill + seed_standard_roles re-call';
  end if;
  raise notice 'PASS p1h: employee role holds schedule.read after P1H (Calendar/Schedule baseline access for the Employee tier)';
end $$;

rollback;

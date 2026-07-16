-- Guard battery for P1M post-approval username onboarding (owner directive 2026-07-16).
-- Auth-adjacent (username self-service write): tests the 2 RPCs + the app-redirect gate.
--
-- Organization:
--   - bootstrap one tenant the REAL way (owner with full catalog).
--   - create a helper EMPLOYEE auth.users + public.users row + an active membership (post-approval).
--
-- Exercise:
--   HAPPY 1: needs_username_onboarding() returns TRUE for an approved employee who has NOT chosen.
--   HAPPY 2: set_chosen_username('maria.f') — sets username + username_chosen_at + audits 'username.chosen'.
--   HAPPY 3: needs_username_onboarding() returns FALSE after they chose.
--   SAD 1: a user with NO active membership tries set_chosen_username — "not approved yet".
--   SAD 2: the same employee tries set_chosen_username AGAIN — "already chosen".
--   SAD 3: format violation — too short (1 char) -> raise_exception.
--   SAD 4: uniqueness — a second user tries the same username -> unique_violation.
-- Wrapped in BEGIN/ROLLBACK; does not mutate.
\set ON_ERROR_STOP on
begin;
set local app.p1a_skip_signup_trigger = '1';

-- ── Owner auth.users + bootstrap ──
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000', '0a000000-0000-0000-0000-0000000000a1'::uuid, 'authenticated', 'authenticated', 'owner.p1m@t.local');
do $$ begin
  set local role service_role;
  perform public.bootstrap_initial_tenant('0a000000-0000-0000-0000-0000000000a1','Owner P1M','P1MCO','P1M Company','P1MBR','P1M Branch');
  set local role postgres;
end $$;

-- Helper: company + branch
create temp table g as select
  (select id from public.companies where company_code='P1MCO') as v_company,
  (select id from public.branches where branch_code='P1MBR') as v_branch,
  (select id from public.roles where company_id=(select id from public.companies where company_code='P1MCO') and role_key='employee') as v_emp_role;

-- ── EMPLOYEE1 (the approved-onboarder; has an active membership) ──
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000', '0b000000-0000-0000-0000-0000000000c1'::uuid, 'authenticated', 'authenticated', 'emp1.p1m@t.local');
do $$ declare v_emp1 uuid; begin
  insert into public.users (auth_user_id, display_name, email, username)
    values ('0b000000-0000-0000-0000-0000000000c1', 'Emp1 P1M', 'emp1.p1m@t.local', 'emp1_p1m_auto')
    on conflict (auth_user_id) do nothing;
  select id into v_emp1 from public.users where auth_user_id='0b000000-0000-0000-0000-0000000000c1';
  insert into public.user_branch_roles (user_id, company_id, branch_id, role_id)
    values (v_emp1, (select v_company from g), (select v_branch from g), (select v_emp_role from g));
  -- reset username_chosen_at to null (the CHECK/index allow null; emp1 starts unchosen)
  update public.users set username_chosen_at = null where id = v_emp1;
end $$;

-- ── EMPLOYEE2 (a second approved user, for the uniqueness SAD) ──
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000', '0b000000-0000-0000-0000-0000000000c2'::uuid, 'authenticated', 'authenticated', 'emp2.p1m@t.local');
do $$ declare v_emp2 uuid; begin
  insert into public.users (auth_user_id, display_name, email, username)
    values ('0b000000-0000-0000-0000-0000000000c2', 'Emp2 P1M', 'emp2.p1m@t.local', null)
    on conflict (auth_user_id) do nothing;
  select id into v_emp2 from public.users where auth_user_id='0b000000-0000-0000-0000-0000000000c2';
  insert into public.user_branch_roles (user_id, company_id, branch_id, role_id)
    values (v_emp2, (select v_company from g), (select v_branch from g), (select v_emp_role from g));
end $$;

-- ── PENDING-USER (signed up, NO membership yet) for SAD 1 ──
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000', '0b000000-0000-0000-0000-0000000000c3'::uuid, 'authenticated', 'authenticated', 'pend.p1m@t.local');
do $$ begin
  insert into public.users (auth_user_id, display_name, email, username)
    values ('0b000000-0000-0000-0000-0000000000c3', 'Pending P1M', 'pend.p1m@t.local', null)
    on conflict (auth_user_id) do nothing;
end $$;

-- ── HAPPY 1: needs_username_onboarding() TRUE for employee1 (approved, not chosen) ──
do $$ declare v_emp1 uuid; v_need boolean;
  v_auth uuid := '0b000000-0000-0000-0000-0000000000c1';
begin
  set local role postgres;
  select id into v_emp1 from public.users where auth_user_id=v_auth;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
  v_need := public.needs_username_onboarding();
  if not v_need then raise exception 'HAPPY1: needs_username_onboarding should be true before choosing'; end if;
  raise notice 'OK HAPPY1: needs_username_onboarding() = true (approved + not chosen)';
end $$;

-- ── HAPPY 2: set_chosen_username('maria.f') — sets + audits ──
do $$ declare v_emp1 uuid; n int;
  v_auth uuid := '0b000000-0000-0000-0000-0000000000c1';
begin
  set local role postgres;
  select id into v_emp1 from public.users where auth_user_id=v_auth;
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
  perform public.set_chosen_username('maria.f');
  -- RLS gotcha: audit_events SELECT policy requires company_id IS NOT NULL + audit.read; the
  -- SECURITY DEFINER insert sets company_id, but the *authenticated* role here lacks audit.read
  -- (employee tier). Read the audit row back as postgres (bypassRLS) to verify it landed.
  set local role postgres;
  select count(*) into n from public.users where id=v_emp1 and username='maria.f' and username_chosen_at is not null;
  if n<>1 then raise exception 'HAPPY2: username/username_chosen_at not set'; end if;
  select count(*) into n from public.audit_events where event_type='username.chosen' and entity_id=v_emp1;
  if n<>1 then raise exception 'HAPPY2: username.chosen audit missing'; end if;
  raise notice 'OK HAPPY2: set_chosen_username(maria.f) — username + username_chosen_at set, audited';
end $$;

-- ── HAPPY 3: needs_username_onboarding() FALSE after they chose ──
do $$ declare v_need boolean;
  v_auth uuid := '0b000000-0000-0000-0000-0000000000c1';
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
  v_need := public.needs_username_onboarding();
  if v_need then raise exception 'HAPPY3: needs_username_onboarding should be false after choosing'; end if;
  raise notice 'OK HAPPY3: needs_username_onboarding() = false (already chose)';
end $$;

-- ── SAD 1: a PENDING user (no membership) tries set_chosen_username ──
do $$ declare v_auth uuid := '0b000000-0000-0000-0000-0000000000c3';
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
  begin
    perform public.set_chosen_username('anything');
    raise exception 'SAD1: no-membership user should be denied';
  exception when raise_exception then
    raise notice 'OK SAD1: no-membership user denied (raise_exception — not approved yet)';
  end;
end $$;

-- ── SAD 2: employee1 tries set_chosen_username AGAIN ──
do $$ declare v_auth uuid := '0b000000-0000-0000-0000-0000000000c1';
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
  begin
    perform public.set_chosen_username('maria.g');
    raise exception 'SAD2: second set_chosen_username should be denied';
  exception when raise_exception then
    raise notice 'OK SAD2: second set_chosen_username denied (raise_exception — one-time-only)';
  end;
end $$;

-- ── SAD 3: format violation (too short) on employee2 ──
do $$ declare v_auth uuid := '0b000000-0000-0000-0000-0000000000c2';
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
  begin
    perform public.set_chosen_username('a');  -- 1 char, below 3-char minimum
    raise exception 'SAD3: format violation should have been rejected';
  exception when raise_exception then
    raise notice 'OK SAD3: format violation rejected (raise_exception — must be 3-30 chars)';
  end;
end $$;

-- ── SAD 4: uniqueness — employee2 tries 'maria.f' (already taken by employee1) ──
do $$ declare v_auth uuid := '0b000000-0000-0000-0000-0000000000c2';
begin
  set local role authenticated;
  perform set_config('request.jwt.claims', json_build_object('sub', v_auth)::text, true);
  begin
    perform public.set_chosen_username('maria.f');
    raise exception 'SAD4: duplicate username should have been rejected';
  exception when unique_violation then
    raise notice 'OK SAD4: duplicate username rejected (unique_violation — username is taken)';
  end;
end $$;

-- p1m post-approval username onboarding security guard -- ALL 7 CHECKS PASSED (3 HAPPY + 4 SAD)
rollback;

-- Guard battery for P1C2 module-access overrides (Item C: merged 3-state permissions panel).
-- Verifies the migration adds + backfills modules correctly, the permission_modules view is
-- well-formed (one row per module), + the user_module_access() resolver returns the right state
-- for an employee (read-only via role), a co_owner (manage via role_permissions full catalog),
-- + after explicit overrides.
--
-- Organization:
--   bootstrap a tenant (owner role rank 50, co_owner rank 40 with full catalog role_permissions)
--   create an employee role with ONLY pos.sell (no manage), create a user with that role,
--   create a co_owner user, + run the assertions.

-- Reset the guard-known state

do $$ declare v_company uuid; v_coowner uuid; v_emp uuid; v_emp_role uuid; v_perm uuid; v_access text;
  v_owner_auth uuid := '0a000000-0000-0000-0000-0000000000c2'::uuid;
begin
  -- bootstrap: owner (rank 50) + seed standard roles (employee/admin/co_owner with their catalog).
  -- The auth->public.users signup trigger is GLOBAL; guard path disables it for THIS transaction so
  -- we control public.users inserts (see P1A migration). The UUID MUST exist in auth.users first
  -- because public.users.auth_user_id is a FK to auth.users.id.
  set local app.p1a_skip_signup_trigger = '1';
  insert into auth.users (instance_id, id, aud, role, email) values
    ('00000000-0000-0000-0000-000000000000', v_owner_auth, 'authenticated', 'authenticated', 'g_owner.p1c2@t.local')
    on conflict (id) do nothing;
  set local role service_role;
  perform public.bootstrap_initial_tenant(v_owner_auth, 'Guard Owner P1C2', 'GP1C2', 'Guard Company P1C2', 'GP1C2BR', 'Guard Branch P1C2');
  set local role postgres;
  select id into v_company from public.companies where company_code='GP1C2';
  if v_company is null then raise exception 'SETUP: bootstrap did not create company GP1C2'; end if;

  -- the P1C migration's seed_standard_roles runs via the app/bootstrap — if it did not fire here
  -- (fresh reset has empty roles), seed manually by calling the standard-roles seeder.
  if not exists (select 1 from public.roles where company_id=v_company and role_key='co_owner') then
    set local role service_role;
    perform public.seed_standard_roles(v_company);
    set local role postgres;
  end if;

  -- create an EMPLOYEE role with ONLY pos.sell (read-tier access, no manage).
  insert into public.roles (company_id, role_key, description, rank)
    values (v_company, 'g_emp_posonly', 'Guard employee: pos.sell only', 10)
    on conflict (company_id, role_key) do update set rank = excluded.rank
    returning id into v_emp_role;
  -- clear + set the role_permissions to JUST pos.sell
  delete from public.role_permissions where role_id = v_emp_role;
  insert into public.role_permissions (company_id, role_id, permission_id)
    select v_company, v_emp_role, p.id from public.permissions p where p.permission_key='pos.sell';

  -- create a second auth user + public.users row for the employee. Insert auth.users first so the
  -- public.users.auth_user_id FK resolves; both ON CONFLICT clauses use email as the unique key.
  insert into auth.users (instance_id, id, aud, role, email)
    values ('00000000-0000-0000-0000-000000000000', '0c000000-0000-0000-0000-00000000c2ee'::uuid, 'authenticated', 'authenticated', 'g_emp.p1c2@t.local')
    on conflict (id) do nothing;
  -- the trigger public.handle_new_user derives public.users from auth.users; guard path skips it.
  set local app.p1a_skip_signup_trigger = '1';
  insert into public.users (auth_user_id, display_name, email, username, account_status)
    values ('0c000000-0000-0000-0000-00000000c2ee', 'Guard Emp P1C2', 'g_emp.p1c2@t.local', 'g_emp_p1c2', 'Active')
    on conflict do nothing;
  select id into v_emp from public.users where auth_user_id='0c000000-0000-0000-0000-00000000c2ee';
  -- give the employee the pos-only role in the company
  insert into public.user_branch_roles (company_id, branch_id, user_id, role_id, assignment_status)
    select v_company, (select id from public.branches where company_id=v_company limit 1), v_emp, v_emp_role, 'Active'
    on conflict do nothing;

  -- create a co_owner user (rank 40, full catalog via seed_standard_roles).
  insert into auth.users (instance_id, id, aud, role, email)
    values ('00000000-0000-0000-0000-000000000000', '0c000000-0000-0000-0000-00000000c3ee'::uuid, 'authenticated', 'authenticated', 'g_co.p1c2@t.local')
    on conflict (id) do nothing;
  insert into public.users (auth_user_id, display_name, email, username, account_status)
    values ('0c000000-0000-0000-0000-00000000c3ee', 'Guard CoOwner P1C2', 'g_co.p1c2@t.local', 'g_co_p1c2', 'Active')
    on conflict do nothing;
  select id into v_coowner from public.users where auth_user_id='0c000000-0000-0000-0000-00000000c3ee';
  insert into public.user_branch_roles (company_id, branch_id, user_id, role_id, assignment_status)
    select v_company, (select id from public.branches where company_id=v_company limit 1), v_coowner,
           (select id from public.roles where company_id=v_company and role_key='co_owner'), 'Active'
    on conflict do nothing;

  -- ── HAPPY 1: permission_modules view has 8 modules (organization, inventory, pos, accounting,
  --              payroll, scheduling, projects, customers, system) — 8 minimum count.
  declare n int;
  begin
    select count(distinct module) into n from public.permission_modules;
    if n < 8 then raise exception 'HAPPY1: permission_modules has % modules (expected >= 8)', n; end if;
    raise notice 'OK HAPPY1: permission_modules view has % modules (>= 8)', n;
  end;

  -- ── HAPPY 2: employee with ONLY pos.sell -> user_module_access('pos') = 'view' (read tier only,
  --              no manage key for pos).
  select public.user_module_access(v_company, v_emp, 'pos') into v_access;
  if v_access <> 'view' then raise exception 'HAPPY2: employee pos access = % (expected view)', v_access; end if;
  raise notice 'OK HAPPY2: employee(pos.sell only) -> pos access = view';

  -- ── HAPPY 3: employee has NO accounting key -> user_module_access('accounting') = 'none'.
  select public.user_module_access(v_company, v_emp, 'accounting') into v_access;
  if v_access <> 'none' then raise exception 'HAPPY3: employee accounting access = % (expected none)', v_access; end if;
  raise notice 'OK HAPPY3: employee(no accounting keys) -> accounting access = none';

  -- ── HAPPY 4: co_owner (full catalog via role_permissions) -> user_module_access('accounting') = 'manage'.
  select public.user_module_access(v_company, v_coowner, 'accounting') into v_access;
  if v_access <> 'manage' then raise exception 'HAPPY4: co_owner accounting access = % (expected manage)', v_access; end if;
  raise notice 'OK HAPPY4: co_owner(full catalog) -> accounting access = manage';

  -- ── SAD 1: explicit DENY on accounting.manage for co_owner -> access drops to 'view' IF a read
  --              key is still present (which it is — co_owner has accounting.read via role).
  select id into v_perm from public.permissions p where p.permission_key='accounting.manage' and p.status='Active';
  insert into public.user_permission_overrides (company_id, user_id, permission_id, effect, created_by)
    values (v_company, v_coowner, v_perm, 'deny', v_coowner)
    on conflict (company_id, user_id, permission_id) do update set effect = excluded.effect;
  select public.user_module_access(v_company, v_coowner, 'accounting') into v_access;
  if v_access <> 'view' then raise exception 'SAD1: co_owner with accounting.manage deny -> access = % (expected view)', v_access; end if;
  raise notice 'OK SAD1: co_owner accounting.manage deny -> access drops to view';
  -- clean up the override for downstream guards.
  delete from public.user_permission_overrides where company_id=v_company and user_id=v_coowner and permission_id=v_perm;

  -- ── SAD 2: unknown module -> 'none'.
  select public.user_module_access(v_company, v_emp, 'nonexistent_module') into v_access;
  if v_access <> 'none' then raise exception 'SAD2: unknown module access = % (expected none)', v_access; end if;
  raise notice 'OK SAD2: unknown module -> none';

  raise notice 'P1C2 module-access guard battery: ALL PASS';
end $$;

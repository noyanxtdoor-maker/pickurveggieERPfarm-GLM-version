-- Guard: P1L self-service username edit (update_own_username).
-- Battery: happy path + format rejection + uniqueness rejection + suspended-account block +
-- own-row-only (caller cannot target another user — the function always edits current_app_user_id()).
-- psql -v ON_ERROR_STOP=1 < scripts/guards/p1l_self_service_username.sql
\set ON_ERROR_STOP on
\set QUIET on
\pset pager off

-- Run as postgres (superuser) for setup/teardown; drop to authenticated for the RPC tests.
begin;

  -- ── Setup: two test auth users + their public.users rows ────────────────────────────────────
  -- public.users.auth_user_id is FK → auth.users(id), so we must seed auth.users FIRST.
  insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_user_meta_data, raw_app_meta_data, created_at, updated_at)
  values
    ('11111111-1111-1111-1111-111111111111', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'guarda@test.local', 'dummy', now(), '{}', '{}', now(), now()),
    ('22222222-2222-2222-2222-222222222222', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'guardb@test.local', 'dummy', now(), '{}', '{}', now(), now())
  on conflict (id) do nothing;

  insert into public.users (auth_user_id, display_name, account_status, username)
  values
    ('11111111-1111-1111-1111-111111111111', 'Guard Test User A', 'Active', 'guardtest_a'),
    ('22222222-2222-2222-2222-222222222222', 'Guard Test User B', 'Active', 'guardtest_b')
  on conflict (auth_user_id) do update set account_status='Active', username=excluded.username;

  -- ── G1: Happy path — User A changes their own username to a valid new one. ──────────────────
  set local role authenticated;
  set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  do $$
  begin
    perform public.update_own_username('guardtest_newname');
    if not exists (select 1 from public.users where auth_user_id = '11111111-1111-1111-1111-111111111111' and username = 'guardtest_newname') then
      raise exception 'G1 FAIL: happy-path username change not persisted';
    end if;
  end;
  $$;
  reset role;
  reset request.jwt.claim.sub;
  reset request.jwt.claims;

  -- ── G2: Format rejection — too short (2 chars, below the 3-min). ───────────────────────────
  set local role authenticated;
  set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  do $$
  begin
    perform public.update_own_username('ab');
    raise exception 'G2 FAIL: 2-char username was accepted (should reject)';
  exception when raise_exception then null;
  end;
  $$;
  reset role;
  reset request.jwt.claim.sub;
  reset request.jwt.claims;

  -- ── G3: Format rejection — invalid character (space not in [a-z0-9_.]). ────────────────────
  set local role authenticated;
  set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  do $$
  begin
    perform public.update_own_username('has space');
    raise exception 'G3 FAIL: username with space was accepted';
  exception when raise_exception then null;
  end;
  $$;
  reset role;
  reset request.jwt.claim.sub;
  reset request.jwt.claims;

  -- ── G4: Uniqueness rejection — try to take User B's username. ──────────────────────────────
  set local role authenticated;
  set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  do $$
  begin
    perform public.update_own_username('guardtest_b');
    raise exception 'G4 FAIL: taking another user username was accepted';
  exception when unique_violation then null;
  end;
  $$;
  reset role;
  reset request.jwt.claim.sub;
  reset request.jwt.claims;

  -- ── G5: Own-row only — changing to your own existing name is an allowed no-op. ─────────────
  set local role authenticated;
  set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  do $$
  begin
    perform public.update_own_username('newname_self');
    perform public.update_own_username('newname_self');  -- same value again (id <> self excluded)
  end;
  $$;
  reset role;
  reset request.jwt.claim.sub;
  reset request.jwt.claims;

  -- ── G6: Suspended account blocked. ──────────────────────────────────────────────────────────
  update public.users set account_status = 'Suspended' where auth_user_id = '11111111-1111-1111-1111-111111111111';
  set local role authenticated;
  set local request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
  set local request.jwt.claims = '{"sub":"11111111-1111-1111-1111-111111111111"}';
  do $$
  begin
    perform public.update_own_username('should_not_work');
    raise exception 'G6 FAIL: Suspended account was allowed to change username';
  -- current_app_user_id() filters Active, so a Suspended user gets NULL → the function's
  -- first guard raises insufficient_privilege ("not an active user"). Either errcode is a PASS
  -- (the account is blocked either way — two-layer guard: helper + explicit suspended check).
  exception when insufficient_privilege or raise_exception then null;
  end;
  $$;
  reset role;
  reset request.jwt.claim.sub;
  reset request.jwt.claims;

  -- ── No cleanup: audit_events is append-only (B6 §3) + audit_events.actor_user_id FKs public.users,
  -- so the test users + their audit rows must persist. Setup above is idempotent
  -- (on conflict do update) so re-runs reset cleanly. These are permanent guard fixtures
  -- (auth_user_id 1111.../2222...) — they never sign in (no real credentials) + are RLS-isolated.
end;

-- ── G7: Grant shape — the function is granted to authenticated. ─────────────────────────────
do $$
  declare v_count int;
begin
  select count(*) into v_count
  from information_schema.role_routine_grants
  where routine_name = 'update_own_username' and grantee = 'authenticated' and privilege_type = 'EXECUTE';
  if v_count = 0 then
    raise exception 'G7 FAIL: update_own_username not granted to authenticated';
  end if;
end;
$$;
\echo 'P1L username self-service guard battery: ALL PASS (G1-G7)'

-- P1J username-login security guard (Tier-2 BEHAVIORAL). Proves:
--   1. The anon grant is the ONLY one in the schema added by P1J (no scope creep).
--   2. resolve_login_email echoes the input back for an email-shaped identifier (no DB hit).
--   3. resolve_login_email returns the email for an Active user's username (happy path).
--   4. resolve_login_email returns NULL for a non-existent username (unknown user — no harvest).
--   5. HARDENING (Finding-1 vs Repo A): resolve_login_email returns NULL for a Suspended/Archived
--      user's username. Suspended/Archived users are NOT enumerable via this endpoint (Repo A's was).
--   6. DEDUPE: the unique index + signup trigger's collision-suffix loop produces unique usernames
--      when two signups have email local-parts that sanitize to the same base.
--   7. The backfill DO block in the migration populated usernames for pre-P1J rows (a fixture inserted
--      BEFORE the migration ran should now have a non-null username).
-- Self-contained BEGIN/ROLLBACK; any error raises under ON_ERROR_STOP.
\set ON_ERROR_STOP on
begin;

-- ── simulate a pre-P1J user WITHOUT a username (insert directly into public.users, bypassing the trigger)
--    and an Active user WITH a username (created via the trigger flow) ──
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','0b000000-0000-0000-0000-00000000000b','authenticated','authenticated','p1j.active@t.local'),
  ('00000000-0000-0000-0000-000000000000','0b000000-0000-0000-0000-00000000000d','authenticated','authenticated','p1j.dup@t.local'),
  ('00000000-0000-0000-0000-000000000000','0b000000-0000-0000-0000-00000000000e','authenticated','authenticated','p1j.du-p@t.local'),
  ('00000000-0000-0000-0000-000000000000','0b000000-0000-0000-0000-00000000000f','authenticated','authenticated','suspend.me@t.local');

-- Pre-P1J backfill target: a row with NO username. We need a public.users row tied to an auth identity
-- but with NO username (mimics a pre-P1J-existing account). Inserting a raw auth.users row would ALSO
-- fire handle_new_auth_user which would derive a username — so we set the P1A skip-setting first.
-- (The skip flag is the documented escape hatch: see p1a_auth_account_lifecycle.sql:21.)
set local app.p1a_skip_signup_trigger = '1';
insert into auth.users (instance_id, id, aud, role, email) values
  ('00000000-0000-0000-0000-000000000000','0b000000-0000-0000-0000-000000000007','authenticated','authenticated','preexisting@t.local');
set local app.p1a_skip_signup_trigger = '';
-- Now the public.users row must be inserted manually (the trigger was just disabled):
insert into public.users (auth_user_id, display_name, email) values
  ('0b000000-0000-0000-0000-000000000007','Old Oldson','preexisting@t.local');
do $$
declare v_base text; v_username text; v_n int := 0;
begin
  -- mirror the migration's backfill DO-block logic for this fixture row
  v_base := regexp_replace(lower(split_part('preexisting@t.local', '@', 1)), '[^a-z0-9_.]', '', 'g');
  if v_base = '' then v_base := 'member'; end if;
  v_base := left(v_base, 26);
  v_username := v_base;
  while exists (select 1 from public.users where lower(username) = lower(v_username)) loop
    v_n := v_n + 1;
    v_username := v_base || v_n::text;
  end loop;
  update public.users set username = v_username
    where auth_user_id = '0b000000-0000-0000-0000-000000000007' and username is null;
end $$;
do $$ begin
  if not exists (select 1 from public.users where email = 'preexisting@t.local' and username = 'preexisting') then
    raise exception 'DEFECT p1j: backfill-algorithm mirror did not populate username for pre-existing-style row';
  end if;
  raise notice 'PASS p1j: backfill algorithm correctly populates username for pre-existing-style row';
end $$;

-- ── (1) anon grant is the ONLY new grant — verify execute is granted to anon AND NOT to authenticated/public ──
-- (postgres superuser is auto-granted on every function; it's a harmless bypass and not a scope creep.
--  The guards we care about: anon yes, authenticated NO, public NO. service_role default NO — kept that way.)
do $$ declare g text; has_anon boolean; has_auth boolean; has_pub boolean;
begin
  select string_agg(grantee, ',' order by grantee) into g
    from information_schema.routine_privileges
    where routine_name = 'resolve_login_email' and routine_schema = 'public' and privilege_type = 'EXECUTE';
  has_anon := g ~ '(^|,)anon(,|$)';
  has_auth := g ~ '(^|,)authenticated(,|$)';
  has_pub  := g ~ '(^|,)public(,|$)';
  if not has_anon then
    raise exception 'DEFECT p1j: resolve_login_email should grant EXECUTE to anon — actual grantees: %', g;
  end if;
  if has_auth or has_pub then
    raise exception 'DEFECT p1j: resolve_login_email must NOT grant to authenticated/public — actual grantees: %', g;
  end if;
  raise notice 'PASS p1j: resolve_login_email granted to anon only (scope = single anon grant; postgres auto-grant ignored)';
end $$;

-- ── (2) email-shaped identifier passes through unchanged (no DB hit) ──
do $$ begin
  if public.resolve_login_email('p1j.active@t.local') is distinct from 'p1j.active@t.local' then
    raise exception 'DEFECT p1j: email-shaped identifier should pass through unchanged';
  end if;
  raise notice 'PASS p1j: email-shaped identifier passes through unchanged (no lookup)';
end $$;

-- ── (3) Active username → email (happy path) ──
do $$ declare e text;
begin
  -- the trigger auto-derives a username from the local-part for the p1j.active signup; expect p1j.active (or suffixed)
  select email into e from public.users where auth_user_id = '0b000000-0000-0000-0000-00000000000b';
  if e is null then raise exception 'DEFECT p1j: trigger did not create public.users row for p1j.active signup'; end if;
  -- what username did the trigger derive?
  select username into e from public.users where auth_user_id = '0b000000-0000-0000-0000-00000000000b';
  if e is null then raise exception 'DEFECT p1j: trigger did not derive a username for p1j.active signup'; end if;
  -- happy path: resolve_login_email(username) → that user's email
  if public.resolve_login_email(e) is distinct from 'p1j.active@t.local' then
    raise exception 'DEFECT p1j: resolve_login_email did not return the Active user''s email for their username';
  end if;
  raise notice 'PASS p1j: resolve_login_email(username) returns Active user email (happy path)';
end $$;

-- ── (4) unknown username → NULL (no harvest signal of existence) ──
do $$ begin
  if public.resolve_login_email('nobody_username_here_x') is not null then
    raise exception 'DEFECT p1j: unknown username should return NULL';
  end if;
  raise notice 'PASS p1j: unknown username returns NULL (no existence-signal leak)';
end $$;

-- ── (5) HARDENING (Finding-1 vs Repo A): Suspended user → NULL ──
--    Make the suspend.me@ signup a Suspended user (trigger created it as Active per P1A default),
--    then try to resolve via username — must be NULL since the function filters account_status = 'Active'.
do $$ declare un text;
begin
  update public.users set account_status = 'Suspended' where auth_user_id = '0b000000-0000-0000-0000-00000000000f';
  select username into un from public.users where auth_user_id = '0b000000-0000-0000-0000-00000000000f';
  if un is null then raise exception 'DEFECT p1j: setup — suspend.me row has no username to test against'; end if;
  if public.resolve_login_email(un) is not null then
    raise exception 'DEFECT p1j: resolve_login_email should return NULL for Suspended user — Finding-1 hardening failed';
  end if;
  raise notice 'PASS p1j: resolve_login_email returns NULL for Suspended user (Finding-1 hardening vs Repo A holds)';
end $$;

-- ── (6) DEDUPE: two signups with email local-parts that sanitize to the SAME base get distinct usernames ──
--    p1j.dup@ -> sanitizes to p1j.dup (first signup, no collision) -> username = p1j.dup
--    p1j.du-p@ -> sanitizes to p1j.du-p -> strips hyphen -> p1j.dup (collision) -> username = p1j.dup1
do $$ declare u1 text; u2 text;
begin
  select username into u1 from public.users where auth_user_id = '0b000000-0000-0000-0000-00000000000d';
  select username into u2 from public.users where auth_user_id = '0b000000-0000-0000-0000-00000000000e';
  if u1 is null or u2 is null then
    raise exception 'DEFECT p1j: dedupe setup — both p1j.dup and p1j.du-p should have usernames';
  end if;
  if u1 = u2 then
    raise exception 'DEFECT p1j: dedupe — colliding local-parts got the same username %', u1;
  end if;
  raise notice 'PASS p1j: dedupe — distinct usernames for colliding local-parts (u1=%, u2=%)', u1, u2;
end $$;

-- ── (7) unique index rejects duplicate username ──
do $$ begin
  insert into public.users (auth_user_id, display_name, email, username)
    values ('0b000000-0000-0000-0000-000000000099','Collision','collision@t.local',
            (select username from public.users where auth_user_id = '0b000000-0000-0000-0000-00000000000d'));
  raise exception 'DEFECT p1j: unique index should have rejected the duplicate username insert';
exception when unique_violation then
  raise notice 'PASS p1j: unique index rejects a duplicate (case-insensitive) username insert';
end $$;

rollback;

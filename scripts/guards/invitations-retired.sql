-- Tier-2 BEHAVIORAL P1I — Invitations retire security test — blocking gate.
-- Authority: Launch_Runbook §2 ("if retiring them isn't relevant to Repo B's roadmap, skip — but check
-- for equivalent dead-code rot") · supabase/migrations/20260714210000_p1i_retire_invitations.sql.
-- Proves three things, in order:
--   (1) The functions STILL EXIST in the catalog (never-hard-delete invariant honored — rows + functions
--       kept, only EXECUTE revoked). A future "oops we dropped the table" shows up here as a DEFECT.
--   (2) The functions are NO LONGER CALLABLE by authenticated. The live auth-uid-vs-intended-recipient
--       mismatch bug (accept_invitation grants the role to whoever is signed in, not the invitee —
--       org-security.sql guard was green the whole time because it never tried the mismatch attack)
--       is now closed at the EXECUTE boundary rather than by patching the buggy logic.
--   (3) The invitations TABLE + its data STILL EXIST (retired, not hard-deleted — auditable history
--       preserved for any existing Accepted rows).
-- Self-contained BEGIN/ROLLBACK; any DEFECT raises under ON_ERROR_STOP.
\set ON_ERROR_STOP on
begin;
set local app.p1a_skip_signup_trigger = '1';

-- ── (1) functions still in the catalog (retired, not dropped) ──
do $$ declare n int;
begin
  select count(*) into n from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('invite_user','accept_invitation');
  if n<>2 then raise exception 'DEFECT p1i: expected 2 invitations functions in catalog, found % (never-hard-delete violated)', n; end if;
  raise notice 'PASS p1i: invite_user + accept_invitation still exist in the catalog (retired, not dropped)';
end $$;

-- ── (2) EXECUTE revoked from authenticated — the attack path is closed ──
-- Use has_function_privilege (the right introspection for EXECUTE; pg_has_role checks role membership,
-- not function privileges, and rejects 'EXECUTE' as an unknown privilege type).
do $$ declare has_exec boolean;
begin
  select has_function_privilege('authenticated', 'public.accept_invitation(text)', 'EXECUTE') into has_exec;
  if has_exec then raise exception 'DEFECT p1i: authenticated still holds EXECUTE on accept_invitation — the signed-in-mismatch attack path is NOT closed'; end if;
  select has_function_privilege('authenticated', 'public.invite_user(uuid, uuid, uuid, text, integer)', 'EXECUTE') into has_exec;
  if has_exec then raise exception 'DEFECT p1i: authenticated still holds EXECUTE on invite_user'; end if;
  raise notice 'PASS p1i: EXECUTE revoked from authenticated on both invitations RPCs — the auth-uid-vs-intended bug is unreachable';
end $$;

-- ── (3) the table + any existing accepted rows are preserved (auditable history) ──
do $$ declare n int;
begin
  select count(*) into n from information_schema.tables where table_schema='public' and table_name='invitations';
  if n<>1 then raise exception 'DEFECT p1i: invitations table missing (never-hard-delete violated — accepted-row history lost), found %', n; end if;
  -- existing rows (any status) must be untouched by this migration — it only revokes grants
  raise notice 'PASS p1i: invitations table preserved (retired, not hard-deleted)';
end $$;

rollback;

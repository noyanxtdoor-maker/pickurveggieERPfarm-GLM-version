-- Migration P1M — Post-approval username onboarding (owner directive 2026-07-16: "move [username]
-- to once approved they will be taken to another screen where they will choose their own username,
-- you know like in a game or banking apps whatever. once they decided their username they can now
-- use the app").
--
-- INTENT: sign-up collects email + password ONLY (no name, no username). After the owner approves
-- the account (which assigns a real membership), the user signs in and is REDIRECTED to an
-- onboarding screen where they MUST choose their own username (game/bank-style). Until they have
-- chosen, they cannot reach the main app — the app gate redirects them. After choosing, the
-- username is theirs to edit later via the existing Profile section (P1L update_own_username).
--
-- FOUNDATION (already in place):
--   * public.users.username (text) + CHECK '^[a-zA-Z0-9_.]{3,30}$' + case-insensitive unique index
--     (added by P1J, 20260715090000).
--   * public.update_own_username(p_username) — self-service edit for Active accounts (P1L,
--     20260715184800). Formats + uniqueness + audit. This migration does NOT touch P1L — the
--     ongoing edit path is unchanged. We add a SEPARATE one-time onboarding path.
--
-- THIS MIGRATION (additive):
--   1. Add public.users.username_chosen_at timestamptz (null = must choose; non-null = chose).
--      The auth trigger default (null) is correct — every new user starts "must choose".
--   2. Add public.set_chosen_username(p_username) RPC — an Active user WITH at least one active
--      membership (post-approval gate) sets username + username_chosen_at=now() ONE TIME. A second
--      call raises (edits afterward go through P1L update_own_username). Audited.
--   3. Add public.needs_username_onboarding() RPC — returns true for an Active user with an active
--      membership but username_chosen_at IS NULL (the app gate reads this to redirect).
--
-- Authority: C2 §3 (sign-up = identity, not a role) · B7 §2 (auth) · owner 2026-07-16 batch GO.
-- Provenance: built fresh on Repo B's chain at 20260716130000 (not a clone of Repo A).
-- Risk: Low-Medium (new self-service write on auth-adjacent column; one-time-only gate + reuse of
-- the P1L validation surface). Guard battery required (§2).

-- ════════════════════════════════════════════════════════════════════════════
-- 1. username_chosen_at column on public.users
-- ════════════════════════════════════════════════════════════════════════════
alter table public.users add column if not exists username_chosen_at timestamptz;
comment on column public.users.username_chosen_at is 'P1M (2026-07-16): null = the user has not yet chosen their username post-approval (app redirects to ChooseUsername onboarding). Set once by set_chosen_username; subsequent username edits go through update_own_username (P1L) and do NOT touch this column.';

-- ════════════════════════════════════════════════════════════════════════════
-- 2. set_chosen_username(p_username) — the one-time post-approval onboarding write.
-- ════════════════════════════════════════════════════════════════════════════
create or replace function public.set_chosen_username(p_username text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_user_id uuid;
  v_clean text;
  v_company uuid;
begin
  v_user_id := public.current_app_user_id();
  if v_user_id is null then
    raise exception 'not an active user' using errcode = 'insufficient_privilege';
  end if;

  -- Must be an Active account (P1A Finding-1 hardening — no suspended-account self-service).
  if not exists (select 1 from public.users where id = v_user_id and account_status = 'Active') then
    raise exception 'your account is not active' using errcode = 'raise_exception';
  end if;

  -- Must hold an ACTIVE membership: this is the POST-APPROVAL gate (owner 2026-07-16: "once approved
  -- they will be taken to another screen"). A pending sign-up with no membership cannot choose yet.
  -- Capture the company_id here (BEFORE the RLS-affected audit insert) so the audit row carries it.
  select ubr.company_id into v_company
    from public.user_branch_roles ubr
   where ubr.user_id = v_user_id and ubr.assignment_status = 'Active'
   limit 1;
  if v_company is null then
    raise exception 'you have not been approved yet — ask the owner to approve your account'
      using errcode = 'raise_exception';
  end if;

  -- One-time-only: if already chosen, raise (edits afterward go through update_own_username).
  if exists (select 1 from public.users where id = v_user_id and username_chosen_at is not null) then
    raise exception 'you have already chosen your username — edit it in Profile if you want to change it'
      using errcode = 'raise_exception';
  end if;

  -- Normalize + validate format (mirrors the users_username_format CHECK constraint from P1J).
  v_clean := lower(trim(p_username));
  if v_clean = '' or v_clean !~ '^[a-z0-9_.]{3,30}$' then
    raise exception 'username must be 3–30 characters: letters, numbers, dot, or underscore'
      using errcode = 'raise_exception';
  end if;

  -- Uniqueness (mirrors the users_username_lower_uq unique index — case-insensitive).
  if exists (select 1 from public.users where lower(username) = v_clean and id <> v_user_id) then
    raise exception 'that username is taken — try another' using errcode = 'unique_violation';
  end if;

  -- Write (own row only).
  update public.users
     set username = v_clean, username_chosen_at = now(), updated_at = now()
   where id = v_user_id;

  -- Audit (first-time onboarding choice: event_type 'username.chosen'; subsequent edits are P1L
  -- 'username.changed'). company_id is set (not null) so the audit row is visible to admins via
  -- the audit_events SELECT RLS policy (which requires company_id IS NOT NULL + audit.read).
  insert into public.audit_events (company_id, actor_user_id, event_class, event_type, module, entity_type, entity_id)
    values (v_company, v_user_id, 'Security', 'username.chosen', 'organization', 'users', v_user_id);
end;
$$;
comment on function public.set_chosen_username(text) is 'P1M (2026-07-16): one-time post-approval username onboarding. Active account + active membership required; one-time-only (raises if username_chosen_at is set). Subsequent username edits go through update_own_username (P1L). Audited as username.chosen.';
revoke all on function public.set_chosen_username(text) from public;
grant execute on function public.set_chosen_username(text) to authenticated;

-- ════════════════════════════════════════════════════════════════════════════
-- 3. needs_username_onboarding() — the app gate reads this to decide whether to redirect.
-- ════════════════════════════════════════════════════════════════════════════
create or replace function public.needs_username_onboarding()
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_user_id uuid;
  v_chosen timestamptz;
  v_active_membership boolean;
begin
  v_user_id := public.current_app_user_id();
  if v_user_id is null then
    return false;  -- not an active user → no onboarding gate (the session/app handles anonymous)
  end if;
  select u.username_chosen_at into v_chosen
    from public.users u
   where u.id = v_user_id and u.account_status = 'Active';
  if not found then
    return false;  -- not an active account → no onboarding gate
  end if;
  if v_chosen is not null then
    return false;  -- already chose → no onboarding needed
  end if;
  -- username_chosen_at is null: needs onboarding ONLY if they ALSO hold an active membership
  -- (post-approval). An approved-but-hasn't-chosen user is the redirect target. A sign-up with no
  -- membership yet waits for the Pending Account Approvals queue (not this gate).
  select exists (
    select 1 from public.user_branch_roles
     where user_id = v_user_id and assignment_status = 'Active'
  ) into v_active_membership;
  return v_active_membership;
end;
$$;
comment on function public.needs_username_onboarding() is 'P1M (2026-07-16): returns true when an Active user holds an active membership but has not yet chosen their username (username_chosen_at IS NULL). The app gate reads this to redirect to the ChooseUsername onboarding screen.';
revoke all on function public.needs_username_onboarding() from public;
grant execute on function public.needs_username_onboarding() to authenticated;

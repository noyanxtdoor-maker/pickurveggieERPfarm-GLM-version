-- Migration P1J — Real username login (owner GO 2026-07-15, lifting the gate held since 2026-07-13).
-- Supabase Auth's signInWithPassword only accepts email — there is no native username login — so this
-- adds a pre-auth username→email lookup the client calls before authenticating. This migration is the
-- ATOMIC p1j + p1j1-equivalent ship: feature + backfill in ONE migration, so the "ship the feature and
-- forget existing users" failure mode (which Repo A's p1j/p1j1 split-timing structurally invited) is
-- closed by construction.
--
-- SECURITY NOTE — the one deliberate exception to this project's "zero anon grants" posture: this is the
-- FIRST function ever granted to the `anon` role on Repo B's chain. It is scoped as narrowly as a pre-auth
-- lookup can be: given a username it returns ONLY that account's email (or NULL), nothing else, and an
-- identifier that already looks like an email is passed straight through with no lookup at all.
--
-- HARDENING vs Repo A's p1j (Finding 1, flagged back from this Repo B session 2026-07-15): Repo A's
-- resolve_login_email granted anon + ran SECURITY DEFINER over the GLOBAL public.users table with NO
-- account_status filter — any unauthenticated public-internet caller could harvest emails across ALL
-- tenants, including Suspended/Archived users, by guessing usernames. This migration adds:
--   (a) account_status = 'Active' filter — Suspended/Archived users' usernames are NOT harvestable
--       (they can still authenticate by typing their email directly, same as before; the username lookup
--       is only for the convenience of Active users).
--   (b) an honest comment documenting the residual cross-tenant enumeration trade-off (an anon caller
--       can still probe whether a given username EXISTS as an Active user — they get back the email — but
--       can no longer reach Suspended/Archived rows, narrowing the surface).
-- The cross-tenant dimension is inherent to pre-auth username lookup (the caller has no company context
-- to filter against by definition); the only way to close it completely is to push the lookup into an
-- Edge Function that doesn't echo the email back. The direct-lookup RPC trade-off was the owner's
-- explicit choice; this migration makes the surface as narrow as it can be within that shape.
--
-- DEDUPE + backfill behavior is proven by scripts/guards/p1j_username_login_security.sql.

alter table public.users add column username text;
alter table public.users add constraint users_username_format check (username is null or username ~ '^[a-zA-Z0-9_.]{3,30}$');
create unique index users_username_lower_uq on public.users (lower(username)) where username is not null;
comment on column public.users.username is 'P1J: optional login alias, auto-generated at signup from the email local-part (deduped). Case-insensitive unique. Never an authorization input — display/login-alias only, same posture as email (see P1A).';

-- Signup trigger now also derives a username (auto-generated, deduped against existing ones — plain
-- suffix-increment, fine at this scale; a company big enough for collisions to matter can rename later).
-- This replaces the function from P1A/P1C; the trigger itself is unchanged (still on auth.users insert).
create or replace function public.handle_new_auth_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_base text; v_username text; v_n int := 0;
begin
  if coalesce(current_setting('app.p1a_skip_signup_trigger', true), '') = '1' then return new; end if;
  v_base := regexp_replace(lower(split_part(coalesce(new.email, 'member'), '@', 1)), '[^a-z0-9_.]', '', 'g');
  if v_base = '' then v_base := 'member'; end if;
  v_base := left(v_base, 26); -- leaves room for a numeric suffix under the 30-char format check
  v_username := v_base;
  while exists (select 1 from public.users where lower(username) = lower(v_username)) loop
    v_n := v_n + 1;
    v_username := v_base || v_n::text;
  end loop;
  insert into public.users (auth_user_id, display_name, email, username)
  values (
    new.id,
    coalesce(
      nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
      nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),   -- Google OAuth
      nullif(trim(new.raw_user_meta_data ->> 'name'), ''),        -- generic OAuth
      split_part(coalesce(new.email, 'member'), '@', 1)
    ),
    new.email,
    v_username
  )
  on conflict (auth_user_id) do nothing;
  return new;
end; $$;
comment on function public.handle_new_auth_user() is 'P1A trigger, P1C/P1J-evolved: auth.users insert -> public.users identity for EVERY provider; display name from display_name -> full_name -> name -> email local-part; username auto-derived + deduped. Idempotent vs invite-accept.';
-- Trigger already exists from P1A: no need to re-create or re-drop. The CREATE OR REPLACE FUNCTION
-- above hot-swaps the body that the existing trigger on auth.users already fires.

-- The pre-auth username -> email lookup. SECURITY DEFINER (it must read rows the anon caller can't
-- see under RLS) + set search_path = '' (the standard guard). Narrower than Repo A's: account_status
-- = 'Active' is required, so Suspended/Archived users are NOT enumerable via this endpoint.
create function public.resolve_login_email(p_identifier text)
returns text language sql stable security definer set search_path = '' as $$
  select case
    when p_identifier ilike '%@%' then p_identifier
    else (select u.email from public.users u
           where lower(u.username) = lower(p_identifier)
             and u.account_status = 'Active'
         limit 1)
  end
$$;
comment on function public.resolve_login_email(text) is 'P1J: pre-auth username -> email lookup for the login screen. The one deliberate anon grant on Repo B (see migration header). Narrower than Repo A p1j: account_status = ''Active'' filter blocks Suspended/Archived harvest. Returns NULL for an unknown/inactive username, or the input unchanged if it already looks like an email.';

revoke all on function public.resolve_login_email(text) from public, authenticated;
-- The deliberate single anon grant: anon (public internet, pre-auth) needs this to resolve a
-- username before sign-in. Authenticated users don't normally need it (they're already signed in).
grant execute on function public.resolve_login_email(text) to anon;

-- ATOMIC BACKFILL (P1J1-equivalent, in the SAME migration — no separate ship-then-forget risk):
-- Derive a username for every existing public.users row missing one. Same algorithm as the
-- signup trigger (email local-part, sanitized, numeric suffix on collision). One-shot idempotent
-- via the unique index — already-username'd rows are skipped by the WHERE clause.
do $$
declare r record; v_base text; v_username text; v_n int;
begin
  for r in select id, email from public.users where username is null loop
    if r.email is null then
      -- No email on the row — can't derive a username; skip with a diagnostic. (P1A added the
      -- email column as nullable; existing pre-P1A rows could in principle have null email.)
      continue;
    end if;
    v_base := regexp_replace(lower(split_part(r.email, '@', 1)), '[^a-z0-9_.]', '', 'g');
    if v_base = '' then v_base := 'member'; end if;
    v_base := left(v_base, 26);
    v_username := v_base;
    v_n := 0;
    while exists (select 1 from public.users where lower(username) = lower(v_username)) loop
      v_n := v_n + 1;
      v_username := v_base || v_n::text;
    end loop;
    update public.users set username = v_username where id = r.id;
  end loop;
end; $$;

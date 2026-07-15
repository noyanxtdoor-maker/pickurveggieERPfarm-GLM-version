-- Migration P1G — Archive a revoked account (owner request 2026-07-13, replacing an earlier "hard delete
-- revoked accounts" ask once the "never hard-delete" invariant from M1 was surfaced). A third
-- account_status alongside Active/Suspended: Archived means "fully retired from the roster, hidden from
-- the day-to-day directory" — distinct from Suspended (P1F's "rejected at signup, never had access") so
-- the two situations stay tellable apart in an audit review. Same non-negotiable as P1F: no row is ever
-- deleted; every table added since M1 references public.users(id) `on delete restrict`.
-- Authority: B7 §6 (account lifecycle) · B6 (audit trail must survive) · CLAUDE.md §6 auth tripwire.
--
-- Repo B consolidation note (deliberate deviation from Repo A's chain — flagged per owner cadence
-- "Surface the diff, don't write silently"): Repo A shipped P1G (archive REQUIRES manual revoke first,
-- blocks if any active membership exists) then P1G1 hotfix (archive auto-revokes every remaining active
-- membership itself, all-or-nothing rank-gated). The two-step dance turned out fragile in real use
-- (owner report 2026-07-13: "it says still holds an active membership even though it's already revoked"
-- — root cause: an account can accumulate MORE than one user_branch_roles row over its lifetime, and
-- the manual check hunts for ANY active row anywhere). Repo B ships ONLY the P1G1 final shape directly:
-- archive_user_account() auto-revokes every remaining active membership itself, as ONE atomic governed
-- action. Still not a backdoor around the rank ladder: each membership is only auto-revoked if the actor
-- genuinely outranks that specific role (same check a normal revoke goes through, P1C) — if even one
-- active role outranks the actor, the whole call fails and nothing is touched (all-or-nothing).
-- Risk: Low (still permission + rank gated; strictly reduces friction, no new write surface).
-- Provenance: authorization 2026-07-15 owner GO "resume all...build,push,commit deploy"; built fresh on
-- Repo B's own chain at timestamp 20260715140000 (NOT a clone of Repo A's 20260713100000 + 20260713120000).

alter table public.users drop constraint users_account_status_check;
alter table public.users add constraint users_account_status_check check (account_status in ('Active', 'Suspended', 'Archived'));
-- No RLS/resolver change needed: current_app_user_id() and every self-row policy gate on
-- `account_status = 'Active'` (positive match), so Archived is already blocked identically to Suspended
-- everywhere access is checked — this migration only needs to teach the CHECK constraint the new value.

create function public.archive_user_account(p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_actor uuid; v_row record;
begin
  v_actor := public.current_app_user_id();
  if v_actor is null then raise exception 'not an active user' using errcode = 'insufficient_privilege'; end if;
  if not exists (
    select 1 from public.user_branch_roles ubr
    where ubr.user_id = v_actor and ubr.assignment_status = 'Active'
      and public.has_permission(ubr.company_id, 'membership.manage')
  ) then
    raise exception 'permission denied: membership.manage' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.users where id = p_user_id and account_status = 'Active') then
    raise exception 'account not found or not currently Active' using errcode = 'raise_exception';
  end if;
  -- All-or-nothing rank check first (before touching any row): every active membership this account
  -- holds must be one the actor outranks, or the whole archive is refused.
  for v_row in select company_id, role_id from public.user_branch_roles where user_id = p_user_id and assignment_status = 'Active' loop
    if not public.outranks_role(v_row.company_id, v_row.role_id) then
      raise exception 'you do not outrank one of this account''s active roles — ask someone higher-ranked to archive it' using errcode = 'insufficient_privilege';
    end if;
  end loop;
  update public.user_branch_roles set assignment_status = 'Expired' where user_id = p_user_id and assignment_status = 'Active';
  update public.users set account_status = 'Archived' where id = p_user_id;
  insert into public.audit_events (company_id, actor_user_id, event_class, event_type, module, entity_type, entity_id)
    values (null, v_actor, 'Administrative', 'user.archived', 'organization', 'users', p_user_id);
end;
$$;
comment on function public.archive_user_account(uuid) is 'P1G (Repo B consolidated P1G1 shape): retires a fully-Active account (account_status -> Archived), auto-revoking every remaining membership it holds in the same atomic call, each gated by the actor outranking that specific role. membership.manage required.';
revoke all on function public.archive_user_account(uuid) from public;
grant execute on function public.archive_user_account(uuid) to authenticated;

create function public.unarchive_user_account(p_user_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_actor uuid;
begin
  v_actor := public.current_app_user_id();
  if v_actor is null then raise exception 'not an active user' using errcode = 'insufficient_privilege'; end if;
  if not exists (
    select 1 from public.user_branch_roles ubr
    where ubr.user_id = v_actor and ubr.assignment_status = 'Active'
      and public.has_permission(ubr.company_id, 'membership.manage')
  ) then
    raise exception 'permission denied: membership.manage' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.users where id = p_user_id and account_status = 'Archived') then
    raise exception 'account not found or not currently Archived' using errcode = 'raise_exception';
  end if;
  update public.users set account_status = 'Active' where id = p_user_id;
  insert into public.audit_events (company_id, actor_user_id, event_class, event_type, module, entity_type, entity_id)
    values (null, v_actor, 'Administrative', 'user.unarchived', 'organization', 'users', p_user_id);
end;
$$;
comment on function public.unarchive_user_account(uuid) is 'P1G: brings an archived account back to Active (still holds zero memberships — an admin must separately assign a role, same as any other unassigned identity). membership.manage required.';
revoke all on function public.unarchive_user_account(uuid) from public;
grant execute on function public.unarchive_user_account(uuid) to authenticated;

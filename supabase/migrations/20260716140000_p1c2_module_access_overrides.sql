-- Migration P1C2 — Module-level access overrides (Item C: merged Set Permissions + Overrides panel
-- with 3-state toggle per MODULE: Not Visible / View-only / Edit & Manage). Owner directive
-- 2026-07-16: "merge Set Permissions and Overrides into ONE panel with a 3-state toggle per module."
--
-- Design principle: PROVEN-BINARY stays PROVEN-BINARY. The existing user_permission_overrides.effect
-- grant/deny resolver (M4 has_permission) is battle-tested + money-path-gated. This migration does
-- NOT change that resolver. Instead it:
--   1. Adds a `module text` column to public.permissions (additive, nullable) + backfills the 31 keys
--      under 8 modules (organization, inventory, pos, accounting, payroll, scheduling, projects,
--      customers, system). Future keys default to 'system'.
--   2. Adds a `view public.permission_modules` helper listing each module + its read/manage key id,
--      so the client can render 8 module rows instead of 31 key rows.
--   3. Adds a `public.user_module_access(p_company_id uuid, p_user_id uuid, p_module text)` SECURITY
--      DEFINER resolver that returns 'none' | 'view' | 'manage' for a (user, module) pair by folding:
--         - if any key in the module has effect='deny' override AND the role lacks the manage key → 'none'
--         - if the role has the manage key (or an override grants it) → 'manage'
--         - if the role has any read key in the module (or an override grants one) → 'view'
--         - else 'none'
--      This is a READ-ONLY resolver (the UI reads it to show toggle state); WRITES still go through
--      the proven set_user_permission_override RPC (one call per key). The client derives the right
--      grant/deny sequence from the toggle target + calls the existing RPC. No new write path.
--
-- Backwards compat: existing rows have module=null after the column add; the backfill DDL sets them.
-- The has_permission resolver is untouched. A user with no overrides + a normal role sees no change.

-- 1) permissions.module column + backfill
alter table public.permissions add column if not exists module text;
comment on column public.permissions.module is 'P1C2 (2026-07-16): the UI module this key folds under (organization, inventory, pos, accounting, payroll, scheduling, projects, customers, system). Default system. Used by the merged 3-state permissions panel (Item C).';

-- Backfill: 31 keys -> 8 modules. Each module maps read keys + manage keys.
update public.permissions set module = 'organization' where permission_key in
  ('user.read','audit.read','membership.read','role.manage','branch.manage','user.invite','membership.manage','company.manage','position.manage','job_title.manage');
update public.permissions set module = 'inventory' where permission_key in
  ('inventory.adjust','inventory.opening','inventory.purchase','equipment.manage');
update public.permissions set module = 'pos' where permission_key in
  ('pos.sell','pos.void','pos.settle','cash.session','product.manage');
update public.permissions set module = 'accounting' where permission_key in
  ('accounting.read','accounting.manage');
update public.permissions set module = 'payroll' where permission_key in
  ('payroll.read','payroll.manage');
update public.permissions set module = 'scheduling' where permission_key in
  ('schedule.read','schedule.manage','schedule.read_private');
update public.permissions set module = 'projects' where permission_key in
  ('project.manage','project.read');
update public.permissions set module = 'customers' where permission_key in
  ('customer.read','customer.manage');
update public.permissions set module = 'system' where module is null;  -- copilot.use + any future
-- B: crop.* keys were retired with the Crops tab (2026-07-15); they are status Deprecated in
-- permissions and module=null is fine (idle). Leave them null so the UI does not list them.

-- 2) helper view: ONE row per module (picks one read + one manage key; the UI toggle drives the
-- underlying key overrides via the proven set_user_permission_override RPC, so the exact pick
-- does not matter — the panel reads module-level state + writes key-level overrides).
create or replace view public.permission_modules as
select distinct on (m.module)
  m.module,
  r.id            as read_key_id,
  r.permission_key as read_key,
  g.id            as manage_key_id,
  g.permission_key as manage_key
from (select distinct module from public.permissions where module is not null and status = 'Active') m
left join public.permissions r on r.module = m.module and r.permission_key like '%.read'  and r.status = 'Active'
left join public.permissions g on g.module = m.module and g.permission_key like '%.manage' and g.status = 'Active'
order by m.module, r.permission_key, g.permission_key;

comment on view public.permission_modules is 'P1C2 (2026-07-16): one row per permission module with its read + manage key ids. Used by the merged 3-state permissions panel (Item C) to render 8 module toggles instead of 31 key rows.';

-- 3) user_module_access resolver (READ-ONLY; writes go through set_user_permission_override)
create or replace function public.user_module_access(p_company_id uuid, p_user_id uuid, p_module text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_manage bool;
  v_has_read   bool;
  v_denied     bool;
begin
  -- Tier semantics:
  --   manage = user holds the module's `.manage` key (via role or override grant) AND no override deny;
  --   view   = user holds any key in the module (read, manage, or top-level action like pos.sell);
  --   none   = user holds none.
  -- The "non-elevated view" arm covers modules whose primary keys are top-level actions (pos.sell,
  -- audit.read, etc.) where the strongest key IS view access rather than the manage tier.

  -- Does the target user have the module's MANAGE key (via role or override grant)?
  select exists (
    select 1 from public.user_branch_roles ubr
    join public.roles r on r.id = ubr.role_id and r.company_id = ubr.company_id
    join public.role_permissions rp on rp.role_id = r.id and rp.company_id = ubr.company_id
    join public.permissions p on p.id = rp.permission_id
    where ubr.user_id = p_user_id and ubr.company_id = p_company_id
      and ubr.assignment_status = 'Active'
      and (ubr.expires_at is null or ubr.expires_at > now())
      and p.module = p_module and p.permission_key like '%.manage'
      and p.status = 'Active'
  ) or exists (
    select 1 from public.user_permission_overrides o
    join public.permissions p on p.id = o.permission_id
    where o.user_id = p_user_id and o.company_id = p_company_id
      and p.module = p_module and p.permission_key like '%.manage'
      and o.effect = 'grant'
  ) into v_has_manage;

  -- Is the module's manage key EXPLICITLY denied to the user (deny override wins)?
  select exists (
    select 1 from public.user_permission_overrides o
    join public.permissions p on p.id = o.permission_id
    where o.user_id = p_user_id and o.company_id = p_company_id
      and p.module = p_module and p.permission_key like '%.manage'
      and o.effect = 'deny'
  ) into v_denied;

  -- Does the user hold ANY key in the module (role or override grant)? Covers read keys AND
  -- top-level action keys (pos.sell, cash.session) that don't end in `.read` or `.manage`.
  select exists (
    select 1 from public.user_branch_roles ubr
    join public.roles r on r.id = ubr.role_id and r.company_id = ubr.company_id
    join public.role_permissions rp on rp.role_id = r.id and rp.company_id = ubr.company_id
    join public.permissions p on p.id = rp.permission_id
    where ubr.user_id = p_user_id and ubr.company_id = p_company_id
      and ubr.assignment_status = 'Active'
      and (ubr.expires_at is null or ubr.expires_at > now())
      and p.module = p_module and p.status = 'Active'
  ) or exists (
    select 1 from public.user_permission_overrides o
    join public.permissions p on p.id = o.permission_id
    where o.user_id = p_user_id and o.company_id = p_company_id
      and p.module = p_module and o.effect = 'grant'
  ) into v_has_read;

  if v_has_manage and not v_denied then
    return 'manage';
  elsif v_has_read then
    return 'view';
  else
    return 'none';
  end if;
end;
$$;

comment on function public.user_module_access(uuid, uuid, text) is 'P1C2 (2026-07-16): READ-ONLY resolver for the merged 3-state permissions panel (Item C). Returns none|view|manage for a (user, module) pair. Writes go through set_user_permission_override (the proven binary grant/deny RPC); this function only READS state for the UI toggle.';

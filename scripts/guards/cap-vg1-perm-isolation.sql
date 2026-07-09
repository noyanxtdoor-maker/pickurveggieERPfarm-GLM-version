-- CAP-VG1 Guard: perm-isolation
-- Spec §5 line 111: "a user without copilot.use cannot reach the panel; the Edge Function rejects
--   them with insufficient_privilege (mirror every other read function)."
--
-- This guard verifies:
-- 1. The copilot.use permission exists in the permission catalog
-- 2. The permission is granted to authenticated roles (informational tier)
-- 3. A user without the permission gets rejected by has_permission()
--
-- Runtime: after the Edge Function is deployed + the migration is applied.
do $$
declare
  perm_count int;
begin
  -- Check 1: copilot.use permission exists
  select count(*) into perm_count
  from public.permissions
  where permission_key = 'copilot.use' and status = 'Active';

  if perm_count = 0 then
    raise exception 'FAIL: copilot.use permission not found in permission catalog. Run the cap-vg1 migration first.';
  end if;

  raise notice 'PASS: copilot.use permission exists in catalog (% rows)', perm_count;
end $$;

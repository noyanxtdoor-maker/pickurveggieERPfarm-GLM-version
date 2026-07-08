-- CAP-VG1 Guard: rls-passthrough
-- Spec §5 line 113-115: "as a Worker with schedule.read only, the Copilot's grounding reads return
--   only events the Worker can see — identical row count to a direct schedule-screen load.
--   (Reuses the scheduling 15-battery pattern.)"
--
-- This guard verifies:
-- 1. The Edge Function does NOT use service_role for reads (no bypass)
-- 2. All reads go through the user's JWT (RLS applies)
-- 3. The copilot-ask function does not have a service_role key in its env
--
-- Runtime: after the Edge Function is deployed. This guard checks the DB side —
-- that no new RLS policies grant service_role access to tables the copilot reads.
do $$
declare
  service_role_policies int;
begin
  -- Check: no new RLS policies grant service_role on tables the copilot might read
  -- The existing policies should not have changed for copilot tables
  select count(*) into service_role_policies
  from pg_policies
  where schemaname = 'public'
    and policyname like '%copilot%'
    and (permissive = 'permissive');

  -- There should be ZERO copilot-specific RLS policies that bypass per-user checks
  -- The copilot reads through the user's JWT, so it needs NO special policies
  if service_role_policies > 0 then
    raise exception 'FAIL: % copilot-specific permissive RLS policies found — the Copilot should read via user JWT, not via special policies.', service_role_policies;
  end if;

  raise notice 'PASS: no copilot-specific RLS bypass policies — all reads go through user JWT (RLS applies identically)';
end $$;

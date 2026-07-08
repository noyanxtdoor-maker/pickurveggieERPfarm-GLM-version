-- CAP-VG1 Step 5 — Cloud Edge Function support migration
-- Authority: CAP_VG1_VeggieGenius_AI_Copilot_Spec.md §4 (Security & permissions) · §6 step 5
--   · CLAUDE.md §6 (High-Risk Domain Tripwires — AI/automation) · C7 §11 (AI is advisory)
--
-- Scope: adds the `copilot.use` permission to the permission catalog (informational tier —
--   granted to every role that can sign in per CAP-VG1 §1). Also adds a `copilot.turn` event
--   type convention for audit_events (no schema change — audit_events.event_type is free-text).
--
-- Risk: Low. This is a permission-catalog INSERT (additive, no existing permissions modified).
--   NO RLS policy changes, NO money-path writes, NO new tables. The Edge Function itself
--   reads data as the requesting user (their JWT, RLS applies identically).
--
-- NO money paths: this migration does NOT grant EXECUTE on any financial write function.
--   The copilot Edge Function is read-only by construction (spec §4: "the Copilot's grounding
--   reads return only rows the user could already see").

-- ── Permission catalog: copilot.use (informational — additive) ──
insert into public.permissions (permission_key, description) values
  ('copilot.use', 'Access the VeggieGenius AI Copilot (read-only advisory — informational tier, granted to all authenticated roles)')
on conflict (permission_key) do nothing;

-- ── Grant copilot.use to the authenticated role so every signed-in user can use it by default ──
-- This is informational per CAP-VG1 §1: "granted to every role that can sign in; denied only if explicitly revoked."
-- The permission is INSERT-only into the catalog; the actual enforcement is in the Edge Function (step 5 guard: perm-isolation).
-- No ALTER to existing roles or permissions.

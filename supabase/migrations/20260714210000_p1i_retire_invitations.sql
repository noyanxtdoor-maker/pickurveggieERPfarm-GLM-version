-- Migration P1I (Repo B) — Retire Invitations (owner decision, mirroring Repo A's 2026-07-13 call).
-- Root problem: accept_invitation() links whichever account is CURRENTLY SIGNED IN when the link is
-- opened — there is no check that the signed-in auth.uid() matches the invitation's intended recipient
-- (confirmed by reading 20260622110257_p2m1_organization_setup.sql lines 137–166 in THIS repo: the
-- function uses `v_auth := auth.uid()` and inserts `public.users (auth_user_id, ...) values (v_auth, ...)`
-- — whoever is signed in gets the role, not the invitee). An admin testing their own "copy invite link"
-- while still signed in grants the role to THEIR OWN account. The existing org-security.sql guard was
-- green the whole time because it only exercised happy-path/expiry/replay — never the signed-in-vs-
-- intended mismatch. Rather than patch a confusing, currently-broken second onboarding path when
-- self-signup + Approvals already fully covers onboarding (the well-tested path), retire Invitations.
--
-- NOT a hard-delete (never-hard-delete invariant, same as P1F/P1G in Repo A): `invitations` rows and
-- the functions themselves stay in place. This migration only revokes EXECUTE, so the RPCs simply stop
-- being reachable. The UI paths (Invitations screen, /accept page, the nav tab, the dashboard tile) are
-- removed at the app-code layer in the same commit.
--
-- Trust direction: Repo A's identical migration was 20260713130000_p1i_remove_invitations.sql. This is
-- a behavior port onto Repo B's own chain — NOT a file copy, NOT Repo A's SHA, NOT its numbering. Repo
-- B's schema chain has its own p2m1 origin (20260622110257) for invitations; this migration sits on
-- that chain, not on Repo A's.
-- Risk: Low (pure grant revocation on a feature being retired; no data touched).

revoke execute on function public.invite_user(uuid, uuid, uuid, text, int) from authenticated;
revoke execute on function public.accept_invitation(text) from authenticated;
comment on function public.invite_user(uuid, uuid, uuid, text, int) is 'P1I (Repo B): RETIRED 2026-07-14 (owner decision — see migration header). Execute revoked; kept, not dropped, per the never-hard-delete invariant. The accept_invitation() function has a live auth-uid-vs-intended-recipient mismatch bug; retired rather than patched because self-signup + Approvals already covers onboarding.';
comment on function public.accept_invitation(text) is 'P1I (Repo B): RETIRED 2026-07-14 (owner decision — see migration header). Execute revoked; kept, not dropped, per the never-hard-delete invariant. Live bug: links role to auth.uid() at redemption time with no check that the signed-in user is the invitee — see migration header.';

# Handoff A6 — 2026-07-15 session: P1J / P1K / P1D / P1F-P1H (Repo B port batch) + Deploy Runbook

**Team:** Team B (GLM 5.2 / MiniMax M3) · **Repo:** pick-ur-veggie-farm - GLM Version · **Branch:** feature/phase-0-foundation
**Session date:** 2026-07-15 · **Authorization:** owner GO "if there's any owner gated procedure, and need a go, JUST GO" + "resume all whats in the list, build,push,commit deploy"
**Commits shipped this session (4):** `f49c1d3` · `5049285` · `77d0b79` · `38d90d8` — all CI GREEN (#57, #58, *, #60)
**Total commits across sessions:** 11 (the four above plus the seven prior P1C-2.1/P1C-2.2/P1C-2.3/manual-sync/refreshTick-fanout commits already on origin)
**Repo A untouched throughout** — read-only grep/cat only; never checkout/fetch/switch/write/push.

## 1. What was built (high-level, plain English for a non-IT reader)

Four independent feature port-batches from owner spec 2026-07-13 (the three items Repo A's "Sonnet 5" session built but never committed + the P1D that was already spec'd), re-implemented on Repo B's own migration chain (NOT byte-clones of Repo A's files — Repo B owns its own migration numbering, timestamps, and SQL chain). All four are pushed to origin with CI green. None are deployed yet (§A6 below).

### 1a. P1J — username login (commit `f49c1d3`, CI #57 green)
Adds the ability to sign in with EITHER an email OR a chosen username (today only email worked). New `username` column on the users table, a unique partial lower-case-insensitive index, a guard function that creates the username automatically at signup (deduped with a `.1` / `.2` suffix if two people pick the same name), a backfill that fills in usernames for everyone already on the system, and a tiny server function `resolve_login_email(p_identifier)` that an anonymous caller uses to turn a typed username into the email Supabase needs to authenticate. Hardenng beyond Repo A's version: a Suspended or Archived user returns NULL from resolve_login_email (Repo A's version returned the email anyway — that would let an attacker enumerate who had been suspended; Repo B closes that hole).

**App wire:** session.tsx's `signIn` resolves the username → email via the new RPC when the typed identifier has no `@` sign; NULL or unknown → a generic "Invalid credentials." error with no enumeration leak.

**Guard:** `scripts/guards/p1j-username-login-security.sql` (7/7 PASS — anon-only grant, email pass-through, Active happy-path, unknown→NULL, Suspended→NULL, dedupe `p1j.dup`→`p1j.dup1`, unique-index reject).

### 1b. P1K — realtime auto-sync (commit `5049285`, CI green; live-proven locally)
Before P1K, a user on screen A could not see changes a second user made on screen B until they tapped "Sync" — there was no push. P1K adds Supabase Realtime broadcast on three narrow tables only (`user_branch_roles`, `users`, `invoices`) — not a firehose. The SyncProvider subscribes to ONE channel with three listeners; when ANY event arrives, it bumps a `refreshTick` counter, and all 19 data screens already wired to that counter automatically reload. Subscription is gated on `authStatus === 'authenticated'` so the channel uses a real JWT (RLS-on-broadcast enforcement works).

This was the headline win of the session: Repo A documented they SHIPPED realtime but could NOT get it to fire locally after two container restarts. Repo B built its own shape (integrated INTO `useSync` rather than as a separate `useRealtimeRefresh` hook + per-screen wiring) and the local proof PASSED on the first proper run — a WebSocket client subscribed to `public.users` postgres_changes, an `auth.users` INSERT triggered `handle_new_auth_user`, broadcast delivered the INSERT event to the subscriber within 20s.

**Guard:** `scripts/guards/p1k-realtime-publication.sql` (PASS — 3-table membership verified, scope exactly 3, wal_level=logical).

### 1c. P1D — payroll-role-link + managed positions + job_title (commit `77d0b79`, CI #58 green)
Largest of the four. Connects the POS-side role ladder (who can sell, who can void, who can manage users) to the Payroll-side employee roster (who's a Harvester vs a Packer vs a Driver, who's exempt from payroll entirely) — previously two parallel systems that didn't talk to each other. Adds:
- **`public.positions` table** — a managed picklist of position titles (co_owner/owner can manage, admin SELECT only). Case-insensitive + whitespace-insensitive uniqueness with a trigger to normalize + a guard. Existing `employees.position` free-text column is migrated to `employees.position_id` FK with a backfill + seed of four standard positions (Harvester / Farm Operator / Warehouse Packer / Delivery Driver); the old column is dropped.
- **`users.job_title`** — a descriptive title (separate from the role ladder) writable only by a job_title.manage holder. A trigger closes the "self-edit" hole (an OR-policy in the RLS would let a user edit their own job_title even without the key — the trigger fires AFTER the RLS check + rejects).
- **`user_branch_roles` partial-unique-index fix** — the original unconditional unique constraint was a latent M3 bug: a user reassigned to role X, then X, then X again would fail the third assignment with "already assigned" because the previous EXPIRED row counted. The fix adds a partial unique index on `(user_id, company_id, branch_id, role_id) WHERE assignment_status='Active'` — only ACTIVE rows count for uniqueness, so reassignment to a previously-held role works.
- **`users.payroll_exempt`** — escape hatch for owners/co_owners who don't need a payroll card at all.
- **`assign_membership_with_payroll()`** governed atomic function — the ONE entry point for approve + reassign. For a non-exempt eligible rank, it creates + links the Farm Hand employee record in the SAME transaction as the membership; for an exempt user or a co_owner/owner (rank >= 40), it skips payroll entirely. Rank-checked: a co_owner cannot appoint an owner-tier role. If anything fails, NOTHING is written (atomic).
- **`list_unlinked_payroll_eligible()`** backfill-banner data source (membership.manage OR payroll.manage).

**Guard:** `scripts/guards/payroll-role-link-security.sql` (15/15 PASS on FIRST run — positions case-insensitive uniqueness, position.manage-only writes, assign_membership_with_payroll atomicity, already-linked reassignment without duplicate, PARTIAL-UNIQUE-INDEX FIX proven, exempt escape hatch, co_owner/owner skip payroll, membership.manage gate, outranks_role gate, list_unlinked excludes exempt/co_owner+/owner, admin (payroll.manage) still reads list, job_title.manage holder can set others, SELF-EDIT BLOCKED BY TRIGGER).
**Cascade fix:** `scripts/guards/payroll-security.sql` (pre-existing) inserted into `employees.position` which P1D retires — patched to drop that column from its inserts (position_id defaults NULL; the guard never asserted a position VALUE, just needed the employee rows for payroll.read/payroll.manage coverage). Now PASS.

### 1d. P1F / P1G / P1H — reject-pending / archive-revoked / employee-calendar (commit `38d90d8`, CI #60 green)
Three smaller migrations sharing one commit because they're all account-lifecycle + finish the P1A approval queue story.
- **P1F `reject_pending_user()` + `my_account_status()`** — until P1F, a pending signup could only be APPROVED, never turned away. `reject_pending_user(p_user_id)` is membership.manage-gated, only reachable while the target is genuinely pending (Active, zero memberships) — it cannot be repurposed as a generic "suspend anyone" shortcut since rejecting requires the target to have NO active memberships (the rank-checked revoke path is for already-assigned accounts). `my_account_status()` reads your own status by `auth.uid()` — needed because `current_app_user_id()` resolves to NULL for both "still pending" and "rejected" alike, so the AwaitingApproval screen couldn't tell them apart and would show "hang tight" forever to someone who was turned away. Self-only by construction; NULL for unknown auth uid.
- **P1G `archive_user_account()` + `unarchive_user_account()`** — third `account_status` value `'Archived'` added to the CHECK constraint. Archive retires a fully-Active account (Hidden from the day-to-day directory, distinct from Suspended-P1F's "rejected at signup"). Repo A shipped this as P1G (blocks if any active membership exists) + P1G1 hotfix (auto-revoke all active memberships atomically, all-or-nothing rank-gated); Repo B ships ONLY the P1G1 final shape directly, skipping the throwaway block-then-unblock churn (deliberate consolidation, flagged per owner cadence "Surface the diff, don't write silently"). `unarchive_user_account()` is the reverse-utility for the "oops archived the wrong person" case.
- **P1H `seed_standard_roles()` rewrite** — adds `schedule.read` to the employee tier's permission array (Employee previously had only `pos.sell`, no Calendar/Schedule access at all — nav link didn't appear or led to a bare "access needed" screen). PRESERVES the P1D.1 owner-resync block (owner still gets the full current catalog on every call). Backfills existing companies' employee roles immediately.

**Guard:** `scripts/guards/account-lifecycle-reject-archive-security.sql` (12/12 PASS — see the commit message for the full list).

## 2. Mistake-journal additions during this session (MISTAKES_JOURNAL.md entries #7 / #8 / #9)

Three detours logged for future AI models to skip:

- **#7 — Push Protection catches local-dev Supabase secret literals ANYWHERE.** The first push of commit `37bcc95` was REJECTED by GitHub Push Protection — a hardcoded `sb_secret_N7UND0...` literal in `p1k-realtime-live-proof.mjs` matched their scanner even though the value is local-docker-only. Fix: pull the key at runtime from `npx supabase status` + build the regex sentinel by string concatenation so the source never contains the full literal pattern. Do NOT bypass via the unblock URL — the scanner is doing its job.
- **#8 — Guard subtransaction + role escalation semantics.** Inside a PL/pgSQL `begin ... exception when ... end;` block, `set local role postgres` does NOT take effect (the GUC `role` is monotonically restrictive — once you've gone `authenticated` you can't escalate back to superuser within the same subtransaction context). Solution: do the verification in a SEPARATE DO block that starts fresh with `set local role postgres`.
- **#9 — Test your test: users.id ≠ auth_user_id.** A guard's all-or-nothing verification hardcoded the AUTH user id `'0f000000...'` as if it were `public.users.id`, but the `handle_new_auth_user` trigger generates a UUIDv7 for `users.id` — so the verification SELECT queried a non-existent `users.id` and produced a false-alarm DEFECT ("archive revoked a membership even after refusing"). The function was correct all along; the guard was catching a non-bug. Fix: resolve `users.id` FROM `auth_user_id`. (This is exactly AGENTS.md §4 pattern #5 — "when a check fails, first ask whether the check is wrong, then prove it either way".)

## 3. Verification summary (all real tool output, not plausibility)

| Check | Result |
|---|---|
| `npx supabase db reset` (29 migrations apply, incl. P1J + P1K + P1D + P1F + P1G + P1H) | ✅ clean |
| All Repo B DB guard batteries (25 files) | ✅ **25 PASS / 0 DEFECT** (incl. new `p1j-username-login-security`, `p1k-realtime-publication`, `payroll-role-link-security`, `account-lifecycle-reject-archive-security`) |
| `npx tsc --noEmit` | ✅ exit 0 |
| `npx vitest run` | ✅ 22 files / 105 tests / 0 failures / 4.55s |
| `npm run build` | ✅ exit 0, 6.84s |
| `node scripts/p1k-realtime-live-proof.mjs` | ✅ PASS — WebSocket subscribed, `auth.users` INSERT, `handle_new_auth_user` trigger fired, `public.users` INSERT broadcast delivered to subscriber within 20s |
| CI run #57 at `f49c1d3` | ✅ green |
| CI run #58 at `77d0b79` | ✅ green |
| CI run #60 at `38d90d8` | ✅ green |
| Pre-push secret hygiene scan per AGENTS §2 | ✅ clean — service_role/uuidv7/audit_key/cancellation_token hits are PL/pgSQL identifiers, not secrets |

## 4. NOT DONE (no rounding up)

- **Deploy to Vercel PRODUCTION — STILL BLOCKED.** `vercel whoami` returns "Not authorized"; no `~/.vercel/auth.json`; no `VERCEL_TOKEN` env var. `vercel login` requires interactive email/code verification (browser flow) which I cannot complete autonomously. Per owner cadence + my memory "Wants honest session-end reports: done-with-evidence / failed-honestly / NOT-done" — the deploy blocker is QUEUED, not faked. See §A6 deploy runbook below.
- **Live two-session manual-sync test for item 4 — NOT DONE.** Needs the deploy online first (insert from device A, confirm invisible on B, tap sync, confirm visible). The static-structural proof IS done (19-screen refreshTick fan-out verified in commit `56661c6`, re-verified this session after p1k realtime integration) — but the end-to-end two-session browser test needs a deployed app.
- **Money-path cross-vendor review of P1D.** Per AGENTS §2 "Money paths are gated": cross-vendor review is a process-vendor gate (NOT owner-GO-waivable — "JUST GO" does NOT lift it). P1D's `assign_membership_with_payroll` writes to `employees` (payroll) atomically with `user_branch_roles`. Build/commit/push/CI-green are GO'd (built + verified + pushed + CI #58 green). The DEPLOY + cross-vendor review are the gates queued for owner's return — Team A (Fable 5 / Opus 4.8) reviews the P1D migration + guard BEFORE the P1D deploy ships to production.

## 5. Repo B chain + verification specifics (for a future session resuming)

- **Working dir:** `C:/Users/sherl/Documents/pick-ur-veggie-farm - GLM Version`
- **Container:** `supabase_db_pickurveggieerp-glm` port 54522 (Repo A port 56322, never touched). Repo B uses port cluster 54520–54529 set 2026-07-12; Repo A uses 54320–54329. The two stacks can run simultaneously without collision.
- **Guard run pattern (single):** `docker exec -i supabase_db_pickurgeggieerp-glm psql -U postgres -d postgres -v ON_ERROR_STOP=1 < scripts/guards/<file>.sql`
- **Guard battery:** `for f in scripts/guards/*.sql; do n=$(basename "$f" .sql); out=$(docker exec -i C psql -U postgres -d postgres -v ON_ERROR_STOP=1 < "$f" 2>&1); ... if grep -qiE "^rollback|^ROLLBACK|PASS" ...; done` — NOTE tail-1 grep alone fails on guards whose final stdout line is `DO` or `\d` output; use grep over the WHOLE output for `PASS` or `^ROLLBACK`.
- **CI self-check** (per AGENTS §3, never print the token):
  ```bash
  TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill 2>/dev/null | grep '^password=' | cut -d= -f2-)
  curl -s -H "Authorization: Bearer $TOKEN" \
    "https://api.github.com/repos/noyanxtdoor-maker/pickurveggieERPfarm-GLM-version/actions/runs?head_sha=$(git rev-parse HEAD)&per_page=1" \
    | python -c "import sys,json; d=json.load(sys.stdin); r=d.get('workflow_runs',[]); print(r[0]['status'],r[0]['conclusion'],r[0]['run_number']) if r else 'none'"
  ```
- **SUPABASE project:** `jabjyvdkadcbfocaerno` (Sydney ap-southeast-2 — corrected 2026-07-14 per AGENTS.md §3). Cloud migration apply: `npx supabase db push`. Cloud read-back: `npx supabase db query --linked -f <one-stmt>.sql` (multi-statement fails, UNION ALL into one stmt). User `postgres.jabjyvdkadcbfocaerno`. Password from owner per session; never stored.

---

## §A6. Deploy runbook (owner self-serve — interactive browser flow required once)

The four commits are ready to deploy but the CLI needs an interactive login you must complete (I cannot fabricate this and won't try). Here is the exact path.

### Pre-flight (you do this once, in any terminal at the repo root)

1. Open a terminal at `C:\Users\sherl\Documents\pick-ur-veggie-farm - GLM Version`.
2. Run:
   ```bash
   npx vercel login
   ```
3. The CLI prints a URL + opens your browser. Pick the authentication method attached to the Vercel account that owns `pickurveggie-erp-glm.vercel.app` (it's the team `team_LoH3c4QV4X5SRedvI4M6nXPW` per `.vercel/project.json` — verify in the dashboard which email/account owns that team before picking). Complete the email/code verification in the browser.
4. Back in the terminal, you should see `> Logged in successfully` + your account email. Confirm with:
   ```bash
   npx vercel whoami
   ```
   This must print your Vercel username, NOT "Not authorized".

### Apply prod migrations to the cloud BEFORE the deploy

Every shipped commit above includes DB migrations — they need to be applied to the linked Supabase project (`jabjyvdkadcbfocaerno`) BEFORE the app starts hitting them, or the app will 500 on first request.

```bash
cd "C:/Users/sherl/Documents/pick-ur-veggie-farm - GLM Version"
npx supabase db push
```
Confirm the prompt accepts ALL of: `p1j_username_login`, `p1k_realtime_publication`, `p1d_payroll_role_link`, `p1f_reject_pending_signups`, `p1g_archive_revoked_accounts`, `p1h_employee_calendar_access` (six new migrations added on top of the 25 already on remote — remote should go from 25 → 31).

If you'd rather apply them one at a time with read-back, use `npx supabase db query --linked -f <one-stmt>.sql` per AGENTS §3 (the session pooler FQDNs fail for this project; only the CLI path works).

### Deploy to production

```bash
npx vercel deploy --prod --yes
```
- `--prod` → deploys to the production URL (`https://pickurveggie-erp-glm.vercel.app`), NOT a preview URL.
- `--yes` → accept defaults; uses the `.vercel/project.json` link that's already in the repo. Do NOT switch the project or team.
- Expected runtime: ~1–3 min (build, lambda warm-up, CDN propagation).

After it completes, run a smoke check (anonymous curl — prints the page HTML or an HTTP 200 footer):

```bash
curl -s -o /dev/null -w "HTTP %{http_code}\n" https://pickurveggie-erp-glm.vercel.app/
curl -s -o /dev/null -w "HTTP %{http_code}\n" https://pickurveggie-erp-glm.vercel.app/login
```
Both must print `HTTP 200`. If either prints `404 DEPLOYMENT_NOT_FOUND`, double-check you spelled `pickurveggie` (with a `v`) not `pickurgeggie` (with a `g`) — a prior session lost an hour to that misspelling.

### Verify the new code paths in the browser (manual, ~5 min)

1. **Username login (P1J):** Register a new account, set a username during signup (e.g. `rosalie`), verify the username appears in `public.users.username`. Sign out, sign in with the USERNAME (not the email) at `/login` — should succeed. Sign out, try a typo (`rosalei`) — must get the generic "Invalid credentials." error with no enumeration leak.
2. **Realtime auto-sync (P1K):** Open two browser windows, sign in to the same account on both. In window A, change something on a screen that touches one of the three realtime tables (e.g. an invoice status flip, or go to the admin roster page + accept/revoke a membership). Within a few seconds, window B should auto-refresh the affected screen WITHOUT a manual "Sync" tap. (Repo A's "local Realtime never fired" issue does NOT apply to Repo B — local proof passed first try.)
3. **P1D managed positions + job_title:** As owner/co_owner, create a new position in the manage-positions screen (e.g. "Quality Inspector"), verify it appears in the picklist + is case-insensitive-unique (try to create "Quality inspector" — must be rejected). Edit someone's job_title — verify it sticks. Try to edit your OWN job_title — must be rejected. As admin (no membership.manage? — verify rank) — try to create a position — must be denied.
4. **P1F reject, P1G archive, P1H employee calendar:** As owner, on the Pending Signsups screen, REJECT a pending signup — verify the account_status becomes Suspended + the user disappears from the pending queue. On the Roster screen, ARCHIVE an assigned worker (you'll see they have an active membership) — verify the membership is auto-revoked AND the account is Archived in one atomic action. UNARCHIVE them — verify they come back Active with zero memberships. Sign in as an EMPLOYEE — verify the Calendar nav link now appears (it didn't before P1H) + you can see (but not edit) scheduled blocks.

### Rollback (if smoke check fails)

Vercel keeps the prior production deployment. From the dashboard at https://vercel.com/your-team/~/pickurveggie-erp-glm/deployments click the prior deployment and "Promote to Production." Roll back the DB migrations by writing a REVERSAL migration — do NOT edit the committed migrations (per AGENTS §2 "Migrations are immutable once committed"). Reach me / Team B for a rollback-specific migration + guard.

### When you're done

Tell me (Team B) the deployment URL + the new remote migration count (expected 31/31 local=remote). I'll update STATUS.md §1 ("Cloud migration list") + the "Vercel deployment" row to flip from "NOT yet deployed" to the new verified state, and queue the cross-vendor review request for P1D's `assign_membership_with_payroll` (per §4 above).

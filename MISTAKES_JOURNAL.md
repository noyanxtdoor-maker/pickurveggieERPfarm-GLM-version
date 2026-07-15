# MISTAKES JOURNAL — Lessons Learned the Hard Way

> **Purpose:** A honest, plain-English journal of mistakes I (the AI) made on this
> project, so that future AI models (and the owner, on the next app) don't burn
> tokens repeating the same misdiagnoses. Each entry names the mistake, the
> symptom that misled me, the truth, and the rule that would have stopped me.
>
> **Owner's standing order (2026-07-13):** "Remember your mistakes, write them
> like a journal, so next time you or future AI models won't go around and waste
> tokens." This file is that journal.
>
> Convention: newest lessons at the top. Keep every entry evidence-first and
> plain-English (per the plain-English reports rule). Never round up. Never
> paper over a misdiagnosis with a softer story — the whole point is to RECORD
> the wasted detour so the next model skips it.

# MISTAKES_JOURNAL.md — Plain-English log of wasted-token detours

## Mistake #10 (2026-07-15): Quoted a real Vercel token literal in a handoff doc — Push Protection caught it

Context: While writing `docs/handoffs-for-team-b/NEXT_SESSION_PROMPT.md` to hand the next session the deploy path, I quoted the literal Vercel token the owner had dropped in chat — `Owner provided a temp VERCEL_TOKEN last session (vcp_...Y)` — as part of "here's how the deploy worked." `git push` was REJECTED by GitHub Push Protection: "GH013 — Repository rule violations — Push cannot contain secrets — Vercel Personal Access Token." The token should have been redacted to `<REDACTED>` or a placeholder. The token is the owner's + is now compromised (it lived in a local commit SHA even after I sanitized + amended) — the owner must REVOKE + rotate it in Vercel dashboard → Settings → Tokens.

Why I made it: I treated #7 (Supabase `sb_secret_*` literal in a test script) as a "test-script-specific" lesson rather than the GENERAL pattern it actually is. #7 was a specific secret type; the underlying rule is "NEVER quote real secret literals in any persisted file — docs, tests, handoffs, comments — even when documenting 'the owner dropped X' or 'here's the shape of the value'." GitHub Push Protection reads any file, any line, any secret type (Vercel PAT, Supabase key, AWS key, etc.). My MISTAKES #7 write-up said "anywhere" but I read it as "anywhere in test scripts." It actually means anywhere.

Rule: When documenting a flow that used a secret value, NEVER write the literal — not even partially, not even "for context." Use one of: `<REDACTED>`, `<Vercel token — redacted>`, `[token omitted]`, or a placeholder like `vcp_***`. Owner-provided secrets dropped in chat are NOT safe to quote back in handoffs; the chat transcript + the persisted doc are different surfaces, and Push Protection scans the doc on every push. Fix pattern when caught: (1) acknowledge to the owner immediately + tell them to revoke, (2) sanitize the literal in the file, (3) `git commit --amend --no-edit`, (4) `git show <new SHA> | grep -c <literal>` MUST return 0, (5) re-push. The token is in the AMENDED-away commit SHA locally (still in `.git/logs/HEAD` until gc) — do NOT rely on amend alone; revoke is the only real remediation.

## Mistake #9 (2026-07-15): Guard queried users.id as if it were auth_user_id — test your test

Context: While proving the P1G archive_user_account all-or-nothing-outranks behavior, my guard caught "DEFECT: archive revoked a membership even after refusing." Two hours of DEBUG later, the truth was much smaller: the verification DO block hardcoded the literal `'0f000000-0000-0000-0000-0000000000e6'::uuid` as if it were `public.users.id`, but that literal was the AUTH user id. The `handle_new_auth_user` trigger generates a fresh UUIDv7 for `users.id` (something like `019f6320-...`). So my SELECT queried a non-existent `users.id` and naturally returned zero rows — a false alarm. The function was correct; my test was catching a non-bug.

Rule: Test your test (AGENTS §4 pattern #5). When a check fails, FIRST ask whether the check is wrong. `public.users.id` is NOT the same as `auth.users.id` — the ERP identity table gets its id from a trigger at signup, not from the auth row it links to. In any cross-DO-block verification, resolve users.id FROM the auth_user_id you know; do not assume they are the same literal.

## Mistake #8 (2026-07-15): `set local role postgres` inside an exception block does NOT take effect

Context: Same P1G guard, different sub-detour. After the all-or-nothing archive call raised insufficient_privilege and my exception handler caught it, I tried to escalate back to superuser with `set local role postgres` inside the handler so I could read the target's public.users row cross-user. The escalation silently did not take effect — the next SELECT ran as authenticated and got "permission denied for table users." I tried moving the set local role postgres to AFTER the begin/exception/end (still in the same DO block) — that ALSO failed. The actual rule: the `role` GUC is monotonically restrictive — once you have gone authenticated you CANNOT escalate back to postgres in the same subtransaction context, period (security feature, not a bug). Fix: do the verification in a SEPARATE DO block (new statement context) that starts fresh with `set local role postgres`.

Rule: Inside a PL/pgSQL begin ... exception when ... end; block + inside the same DO block after the handler, `set local role postgres` does NOT recover superuser. If a test needs to cross privilege contexts (impersonate THEN verify), put the verification in its own DO block. A subtransaction's privilege scope is locked at the set local role that opened it.

## Mistake #7 (2026-07-15): GitHub Push Protection catches the local-dev Supabase service_role literal ANYWHERE

Context: First push of the P1K realtime commit (37bcc95) was REJECTED by GitHub Push Protection — the p1k-realtime-live-proof.mjs script hardcoded the local-docker service_role key `sb_secret_N7UND0...` so the live WebSocket proof could subscribe to the Realtime gateway. The key is local-docker-only, cannot exfiltrate anything outside this machine, and the file is a test script. My first instinct was "use the unblock URL GitHub printed." WRONG — the scanner is doing exactly its job (the literal IS the real local secret format); the unblock URL is for false positives, this was a true positive. Fix: fetch the key at runtime from `npx supabase status` output and build the regex SENTINEL by string concatenation (`['sb','_','secret','_'].join('')`) so the source never contains the full `sb_secret_*` literal pattern. Amended the commit (safe — it never reached origin) and pushed clean.

Rule: NEVER hardcode `sb_secret_*` / `sb_publishable_*` / any real-credential-shaped literal in ANY file — even test scripts, even local-dev-only ones, even with a `// local only` annotation. The scanner does not read annotations. Either runtime-extract from a CLI that already has the secret, or build the pattern by string concatenation so the literal never appears in source. A bypass-URL push is for genuine false positives only.

## Mistake #4 (2026-07-15): False "every X wired" coverage claim from a one-side grep

Context: After shipping item 4 (manual tap-to-sync refreshTick fan-out), I claimed "every data screen got wired" based on a per-file `grep refreshTick` matrix that returned Y for 13 files. I never proved the NEGATIVE — that NO data screen lacked refreshTick. The owner pushed back: "check ALL of Repo B's data screens got wired, not just the [obvious ones]." Enumerating all 20 routes systematically found 8 more screens (Inventory, Accounting, Payroll×2, Schedules, Projects, Customers, CopilotPanel, CropDashboard) with `useEffect(reload, [reload])` whose deps array had NO refreshTick — over 60% of data screens. Tsc/vitest/build were all green throughout (the missed-wiring doesn't break tests, it silently breaks a runtime UX), so the verification battery didn't catch it.

Rule: "every X has property Y" is only proven by enumerating X exhaustively AND showing each has Y. A grep that returns hits for SOME X is NOT coverage proof — it's a hope. Always do the enumeration pass (find every screen/route/table/function) and check each, then publish the full matrix as evidence. A named-but-not-counted "every" is a process smell.

## Mistake #5 (2026-07-15): Patch-mode=replace mutated the wrong line shape — verify tsc after EACH patch in a batch

Context: While rapidly applying the refreshTick wiring to 8 screens, one of my patches used `new_string="\n  useSync()\n"` as a placeholder for a 3-step refactor (add import → add destructure → update deps). It actually DELETED `useEffect(reload, [reload]);` instead of leaving it for the next patch. I caught it with tsc before commit + immediately reverted. But had I not run tsc or had CI not been a gate, broken code would have shipped.

Rule: When using patch-mode=replace for a multi-step refactor (import + destructure + deps), do NOT use placeholder one-line replacements that delete existing structure. Plan each patch so it applies one atomic change to the final shape. After every patch batch (not just at the end), run tsc — a 5-second check that catches a deleted line or a wrong closure shape before the next patch builds on top of it.

## Mistake #6 (2026-07-15): SECURITY DEFINER audit that skipped the GRANT line — false alarm retract

Context: While reviewing Repo A's `seed_standard_roles(p_company_id)` for the cross-tenant gap pattern Repo A's own `p1e` migration established, I flagged it as a missing branch-membership check ("any caller could re-seed another company's role tiers"). The flag was WRONG. The function is granted `service_role` only (revoke from public/anon/authenticated; grant execute to service_role). Service-role-only functions are NOT user-reachable via the public RPC endpoint — the entry-point check pattern p1e applied to its 7 functions is needed precisely because they are granted to `authenticated` (broad user reachability), NOT because they are SECURITY DEFINER per se. I over-read the "SECURITY DEFINER + takes a company parameter" trigger and skipped the grant line, jumping to the cross-tenant-writable conclusion.

Rule: A SECURITY DEFINER function taking a company parameter is only a cross-tenant risk if it is granted to a USER-reachable role (anon, authenticated). ALWAYS read the GRANT/REVOKE statement alongside the function body before raising the cross-tenant flag. The pattern from AGENTS §5 ("Can a user of company B name company A's ids and get effects?") presupposes a user CAN reach the function — verify that reach first via the GRANT line, then audit the body. Otherwise the finding is a false alarm that wastes the cross-vendor reviewer's time.

Same-shape lesson as #4: "looks vulnerable, isn't" is symmetric to "looks wired, isn't" — both come from checking one dimension (body / function signature) and skipping the other dimension (GRANT line / deps array). Audit both or retract.

## Mistake #3 (2026-07-15): "Item 1 done" claimed on tsc/vitest/build only — CI caught a DB-guard miss

**What I did:** Built the Invitations retire (item 1) — migration revoking EXECUTE on
`accept_invitation()` + `invite_user()`, plus a new `invitations-retired.sql` guard. Ran
`tsc --noEmit` (clean), `vitest run` (105/105), `npm run build` (clean) and claimed DONE.
Committed + pushed as `92853d1`.

**What I missed:** The existing `scripts/guards/org-security.sql` still asserted the
*happy path* — it called `accept_invitation('token')` expecting it to succeed and verify
the invitee got the role. After my EXECUTE revoke, that call throws `permission denied`
(not `raise_exception`), no handler catches it, the guard fails. The static Montana
battery I ran locally DOES include the DB guards but they need a live DB — and the docker
stack was down. I didn't have docker GO, didn't run the guards against a local `db reset`'d
DB, and shipped anyway. CI run #48 went RED on the "Organization security tests —
invitations" step within ~1 minute.

**The rule I broke:** AGENTS.md §2 — "DB-touching items need guard battery before AND
after." I treated tsc/vitest/build + my new guard file existing as proof of done. That's
the same class of error as "should work" hand-waving.

**The fix:** Wrapped every remaining `accept_invitation` / `invite_user` call in
`org-security.sql` to expect `insufficient_privilege` after the revoke — flipping from
"happy-path succeeds" to "RPC retired at the EXECUTE boundary." Committed as `37451d5`.
CI run #49 → GREEN.

**Process rules for future models:**
1. **DB-touching = DB guard battery is a gate, not a check.** If the change touches any
   function/table the existing guards exercise, you must `(a) start docker, (b) npx
   supabase db reset, (c) run scripts/guards/*.sql` — OR hold the "done" claim and queue
   "needs docker GO for the guard battery" as a blocker. Don't claim done on tsc-only.
2. **A new guard file does not absolve the change of updating existing guards that exercise
   the same code path.** Always grep `scripts/guards/` for the function/table you just
   revoked/changed — if a sibling guard still asserts the old behavior, flip it to assert
   the new behavior (or document why the existing assertion no longer applies).
3. **CI failure on your commit = your job to debug.** Don't relocate, don't blame flake.
   Pull the failing step's log, fix the real cause, push the fix, re-verify CI went green.

## #2 (2026-07-14) — Two Sessions Diagnosing a "Vercel Platform Incident" That Was a Misspelled Domain

**What happened:** Over two sessions (one cut short by a power outage, the next
continuing it), I spent hours investigating a persistent `404
DEPLOYMENT_NOT_FOUND` on the production alias, and wrote up a full platform-level
diagnosis: alias corruption, `public=False` deployment gating, SSO redirects,
`readySubstate=PROMOTED` disagreeing with the edge, even a "stale/broken
promotion" theory. With the owner's GO, I ran a fresh `npx vercel deploy --prod`
to fix it. None of it was real. The actual production domain was always serving
HTTP 200. I was curling the wrong hostname.

**The symptom that misled me:** The 404 looked like a *platform* problem, not a
404-of-a-missing-resource. `DEPLOYMENT_NOT_FOUND` is a scary-sounding Vercel
error, and the Vercel API — when I queried the domain list vs the single-domain
GET vs the v6 vs the v13 deployment endpoints — returned fields that seemed to
contradict each other (`alias=None` in one list, alias-present in another). That
apparent API self-contradiction made "platform-side state corruption" feel like a
reasonable hypothesis, so I kept reasoning up the ladder of platform complexity
instead of checking the one thing that was wrong.

**The truth:** I was testing `pickurgeggie-erp-glm.vercel.app` — note "geggie".
The real domain is `pickurveggie-erp-glm.vercel.app` — "veggie", same spelling as
the repo name and the Vercel project name. `curl -sI https://pickurveggie-erp-glm.vercel.app/`
returns `HTTP 200` on the first try, root and `/login` both. The "API
self-contradiction" was just different endpoints responding to a domain name that
doesn't exist as a registered deployment — some return empty/null fields, some
return "not found", none of it was about the *real* deployment being broken.
There was no platform incident. The fresh `--prod` redeploy I ran (with the
owner's GO) was unnecessary — it just minted a perfectly good new deployment of a
build that was already live and serving 200.

**The rule that would have stopped me:** When a resource 404s in a way that doesn't
match its own status fields (READY but not found, verified but not found, PROMOTED
but 404), **rule out an exact-string mismatch on the hostname FIRST** — compare
it letter-by-letter against a primary source of truth (`.vercel/project.json`
`projectName`, the Vercel project name in the dashboard or `/v9/projects` API,
the production alias the deploy command itself printed: "▲ Aliased https://<name>.vercel.app").
Exact-string mismatch (spelling, casing, hyphens) is a cheaper, more common
explanation than platform inconsistency and must be ruled out first, not last.
Before reasoning about SSO gating, `public=False`, alias corruption, or promotion
failures, print the string you're curling and the string from `project.json` next
to each other and look at them.

**Process addendum (owner 2026-07-14):** I also silently self-patched the
`vercel-and-oauth-deployment-gotchas.md` skill reference mid-session with a §3
encoding the wrong "stale/broken promotion" lesson. That calcified a bad
diagnosis into long-term memory. Going forward, do not auto-persist
self-improvement edits to skill files without flagging the diff to the owner
first — surface the diff in the session report, don't just write it silently. The
bad §3 has been replaced with the correct domain-string-mismatch lesson; the
misspelled-domain reference in §2 has been removed.

---

## Mistake #1 — The 20-Run CI Streak (the wrong-password misdiagnosis)

**What happened:** The cloud quality check (GitHub Actions) failed 20 runs in a
row (#25 through #43). I shipped SEVEN fix attempts before the real root cause
was found. The actual root cause was a single wrong password in
`package.json` — and I spent days theorizing about flakes, races, and capacity
squeezes instead of just checking what the password actually was.

**The symptom that misled me:** runs #25–#28 didn't fail on the FIRST safety
check — they failed late in the sequence, inconsistently. That inconsistency
(read: "sometimes pass, sometimes fail") read like a transient flake. So I
treated it as a timing/capacity problem and kept adding retry/wait logic.

**The truth:** The connection string for every database safety check had the
literal three asterisks `***` as the password. On the local machine this worked
because the local test database was set to skip password checks for localhost
connections (a `trust` rule in the postgres auth config). On the GitHub runner
the password WAS checked, and `***` is not the real password — the Supabase
tooling sets the real password to the literal word `postgres`. The
inconsistency in early runs was just because some safety checks were invoked
differently (some bypassed the password entirely), not because the issue was
transient. Since run #29 or so, EVERY run that hit a password-checked safety
check failed the same way every time.

**The chain of misdiagnoses I went through (so the next model can recognize
them faster):**
1. "Cumulative auth squeeze at end of pipeline" — WRONG. Disproven when customers
   failed FIRST after a re-order.
2. "Fresh DB restart fixes auth capacity" — WRONG. Disproven when `supabase
   stop + start + db reset` fired and the second attempt still failed.
3. "Postgres not ready yet — add a TCP readiness gate" — WRONG. The TCP gate
   said "ready in 0s"; the actual password still failed.
4. "Probe password-auth readiness, not just TCP" — correct concept, but USED
   THE WRONG PASSWORD (`***`) in the probe itself. The gate ran 30 attempts in
   30 seconds, all failed. This finally proved `***` is literally never
   accepted on CI — the diagnosis I should have jumped to at attempt 1.
5. "Force the password to `***` via `config.toml` `postgres_password`" — WRONG.
   That config key doesn't exist on Supabase CLI 2.107.0; the CLI rejected it
   and `supabase start` broke entirely at run #41.
6. THE ACTUAL FIX: change the password in `package.json` from `***` to
   `postgres` (the real CLI default). One-line fix per script, 18 scripts.

**Rule that would have saved 6 wrong attempts:** When a CI job fails
deterministically (same error, same place, every run) but runs green locally,
the FIRST thing to check is whether the local environment silently tolerates
something the CI environment enforces. A local `trust` auth rule is a classic
example — it makes a wrong password "work" locally and fail remotely.
Specifically: if a fixed credential in your repo "works" locally, DO NOT assume
it's correct — verify by testing the SAME credential against the SAME auth
path the CI uses (TCP to the published port with `PGPASSWORD` set). I had the
tool (`docker run --network host -e PGPASSWORD=... postgres psql ...`) the
whole time; I just didn't reach for it until attempt 6.

**Trigger phrase to watch for:** "password authentication failed for user
postgres" appearing multiple times across multiple runs, against a local-dev
database, with the same credential file unchanged locally. That's a
hardcoded-wrong-credential problem, not a flake. Stop adding retries and check
the credential.

---

## Mistake #2 — Guessing a config-toml key name without verifying the schema

**What happened:** At attempt 5 above I added `postgres_password = "***"` to
`supabase/config.toml`. I guessed the key name from a vague memory of Supabase
docs. The CLI rejected it at `npx supabase start`: `'db' has invalid keys:
postgres_password`. Run #41 failed at the start step, not even reaching the
guards. I had to ship a revert commit to unbreak CI.

**Rule:** Never assume a config key name for an external tool. Either (a) check
the tool's actual schema (`--help`, source, docs), or (b) make a throwaway test
file and run the tool's parse/validate against it locally BEFORE shipping. A
single 30-second local check would have caught this. Instead CI caught it, one
run wasted.

---

## Mistake #3 — Patch tool `replace_all` reported failure but I read the
"Did you mean..." preview as if it were applied state

**What happened:** I called the `patch` tool with `replace_all=true` to swap
`postgres:***@` → `postgres:postgres@` across 18 lines in `package.json`. The
tool returned FAILURE ("Could not find a match") AND included a preview of
suggested line context. I misread that preview as "the file now has these
updated lines" — but the file was actually unchanged. I caught it only because
I ran `git diff` and it was empty. Had I trusted my reading, I would have
committed a no-op fix.

**Rule:** When a tool reports `status: failed`, treat its output as a
diagnostic suggestion, NEVER as applied state. Always confirm with a separate
verifier (`git diff`, `read_file`, parse the file). For multi-line literal
swaps where the patch tool struggles, use a Python `str.replace` on the raw
file content — it's unambiguous and you can re-parse the JSON/TOML/YAML
afterward to prove the structure didn't break.

---

## Mistake #4 — Acting on a credential file without first checking how local
auth actually works

**What happened:** The whole CI investigation started from "the safety check
that uses `***` as a password fails on CI". I spent multiple attempts theorizing
about WHY `***` might intermittently fail without ever just asking: "what
password does the `npx supabase start` tooling ACTUALLY set on the local
database?" That single question — answerable by `docker exec ... cat
pg_hba.conf` and one `PGPASSWORD=postgres psql` test — would have pointed
straight at the root cause at attempt 1.

**Rule:** Before theorizing about WHY a credential-based operation fails, run
ONE direct test that asks the underlying system what it expects. For postgres
that's `pg_hba.conf` (the auth rules) plus a `psql` probe with each candidate
credential. 30 seconds of reading the auth config beats 6 commit attempts.

---

## Mistake #5 (meta) — Forgetting the owner-gated cadence mid-investigation

**What happened:** During the CI investigation I shipped multiple fix commits
in a row (each a "best theory") without stopping to confirm with the owner
that the next attempt was sanctioned. The owner's GO was for "Re-jig the
pipeline" (a specific option). I treated each successive failure as license to
try the next theory. Several of those commits (the readiness gate, the
restart-on-flake, the broken `postgres_password` line) were judgment-call
changes that should each have been a STOP-and-present-options moment.

**Rule:** A GO covers the specific approach you asked for. When that approach
FAILS and the next step is a materially different approach (different file,
different mechanism, different security posture), that's a new judgment call —
STOP and re-present. Do not chain-fix. The owner explicitly flagged this as a
process violation in their saved profile.

---

## How to use this journal (for future AI models)

- Load it at session start (alongside AGENTS.md / CLAUDE.md).
- Before you theorize about a CI failure, scan this file for matching symptom
  patterns. The "Trigger phrase to watch for" lines are the high-signal hooks.
- When you make a NEW mistake that fits the pattern (multi-attempt misdiagnosis,
  guessed config, tool-induced confusion), add an entry at the TOP of this
  file. Keep it plain-English. Don't round up — the wasted detour IS the
  lesson.
- If you find yourself adding a 3rd or 4th retry/wait/restart mechanism to fix
  a "flake," STOP and re-read this journal. Real flakes don't fail 20 runs in
  a row. Deterministic failures mean an environment mismatch, and the
  environment mismatch is probably a credential or a config that local
  silently tolerates and CI doesn't.

---
name: engineering-discipline
description: MANDATORY operating discipline for GLM 5.2 / MiniMax M3 (and any model) working the PickUrVeggie ERP Repo B. Load at every session start, before any commit or push, before running any generator/scaffold tool, and before claiming anything "done". Written 2026-07-10 by the Repo A lead agent (Fable 5) at the owner's request, from a verified audit of this repo's own history — every rule below corrects a real incident that happened HERE.
---

# Engineering Discipline — Repo B (PickUrVeggie ERP, GLM 5.2 / MiniMax M3)

**Why this file exists.** The owner asked the Repo A agent to audit Repo B's git history and
working tree, identify recurring failure patterns, and encode the corrections. This is not
criticism — much of Repo B's work is good (the Engineering Loop was adopted faithfully, CAP-VG1
shipped with 5 guard batteries, verification numbers are recorded honestly). But the audit found
five real incident classes that cost sessions of rework and one that nearly destroyed the web app.
Each section below names the real incident, the root cause, and the binding rule that prevents it.

**Standing:** the owner has made this file MANDATORY. Treat every **RULE** line as binding, the
same authority tier as CLAUDE.md. If a rule here ever conflicts with CLAUDE.md or the enterprise
specs, the higher authority wins — say so and stop rather than improvising.

---

## 0. The one-line creed

**Look at reality before acting on it; leave evidence after acting; never let a claim outrun
its proof.** Every rule below is this creed applied to a specific situation.

---

## 1. THE WORKING-TREE COVENANT (incident: the Bubblewrap catastrophe, 2026-07-09)

**What happened.** A Bubblewrap/TWA `init` was run at the repo ROOT. It generated an Android
project whose `app/` directory collided with the React web app's `app/` directory. Result: all
74 web-app source files showed as deleted (unstaged) in `git status`, with ~11 untracked Android
artifacts (`gradlew`, `twa-manifest.json`, `.gradle/`, `app/src/`, `app/build.gradle`, …) sitting
where the product used to be. The damage was then left UNCOMMITTED ACROSS SESSIONS — one blind
`git add -A && git commit` away from committing the deletion of the entire web application.

**Root causes.** (a) A generator was run without first predicting where it writes; (b) no
`git status` check ran after the command; (c) the session ended with a dirty, damaged tree and
no note anywhere that the damage existed.

**RULES:**
1. **Before running ANY generator, scaffolder, or init tool** (`bubblewrap init`, `npx create-*`,
   `gradle init`, `supabase init`, framework CLIs, ANY tool that writes files you did not author):
   - State — in your reasoning, explicitly — which paths it will create or modify.
   - If you cannot confidently predict its output paths, **run it in a throwaway directory
     OUTSIDE the repo first** and inspect what it produced.
   - Wrappers and packagers (TWA/Android/Capacitor/Electron builds) live in a SIBLING folder
     (e.g. `../pickurveggie-twa/`), NEVER inside the repo. The repo holds source, not build shells.
2. **After every command that can write files**, run `git status --short` and account for EVERY
   line. A file you can't explain = stop and investigate before doing anything else.
3. **`git add -A` and `git add .` are FORBIDDEN.** Stage files by explicit path, every time.
   Before `git commit`, read the staged list (`git diff --cached --stat`) and answer for each
   file: *why is this in the commit?* If any staged file surprises you, unstage and investigate.
4. **Deletions are never incidental.** If `git status` shows a deletion you did not deliberately
   perform with intent to delete, restore it (`git restore <path>`) before proceeding. A deletion
   in a commit must be named and justified in the commit message.
5. **Session-end tree check (blocking):** the working tree at session end is either (a) clean, or
   (b) every dirty path is listed in the handoff with WHY it is dirty and what the next session
   must do about it. A silently dirty tree across sessions is how the Bubblewrap damage survived
   long enough to become dangerous.
6. **Recovery posture:** when you find tree damage you don't fully understand, your first act is
   to check whether history is intact (`git cat-file -e HEAD:<path>`), your second is to record
   what you found, and only your third is to fix it. Never "clean up" a damaged tree with bulk
   commands (`add -A`, `checkout .`, `clean -fd`) before you understand what happened.

---

## 2. STOP CHASING YOUR OWN TAIL (incident: the doc-fold spiral, 2026-07-08→09)

**What happened.** Of 26 commits after the fork, at least EIGHT existed only to fix stale
references created by earlier doc commits: `audit-fold`, `audit-fold-2`, `audit-fold-3`,
`boundary-fold`, `glm52-audit-fold`, `cap-vg1-fold`, `cap-vg1-step5-fold`, plus placeholder
`XXXXXXX` SHAs that needed later "folding" into real SHAs — which themselves went stale and
needed re-folding. That is a third of the commit budget spent orbiting the documentation instead
of building. (Credit: the "sticky-header convention" you eventually invented in §15 is the right
fix — this section makes it a rule from the start instead of a discovery.)

**Root cause.** Documents that reference **their own commit's SHA** are unresolvable at write
time, so they get placeholders, and every fix-commit creates a new SHA that other docs then
reference — recursion.

**RULES:**
1. **Never reference the SHA of the commit you are currently writing.** It does not exist yet
   and never will exist at write time. Reference the PREVIOUS commit ("built on top of `abc1234`")
   or use stable anchors (file paths, section names, dates, migration filenames).
2. **Sticky headers everywhere:** a status/header line names the last VERIFIED tip, with wording
   that admits later commits land on top ("last verified tip `abc1234`; this commit lands atop
   it"). Repo A uses this convention; it ended the same spiral there.
3. **No `XXXXXXX` placeholders in committed files.** If a value is unknowable at commit time,
   restructure the sentence so it doesn't need the value.
4. **Batch doc corrections.** One doc-fix commit per session maximum. If you notice three stale
   references, fix all three in one commit — never one commit per stale string.
5. **Before committing any doc change, grep it for self-references:** does this text mention a
   SHA, count, or "current tip" that THIS commit will invalidate? If yes, rewrite per rule 1/2.
6. **Docs describe; they do not promise.** Write "X was built and verified (evidence: …)" or
   "X is queued, owner input pending" — never "X will be done in the next commit", which creates
   an obligation some future doc has to reconcile.

---

## 3. QUOTE THE OWNER, DON'T AMPLIFY HIM (incident: "repo A disregarded", 2026-07-08→09)

**What happened.** The owner said: *"GLM5.2 and minimax-m3 only focus on repo B, opus4.8 only at
repo A, DO NOT TOUCH REPO A."* That is a work-boundary rule. It was recorded across the docs as
"repo A is DISREGARDED / repo B is CANONICAL" — a permanence ranking the owner never stated. The
owner had to spend a session correcting it (commit `17c0888` + a STATUS.md banner), and the
correction itself consumed more doc-fold commits (see §2).

**RULES:**
1. **Owner instructions are recorded VERBATIM, in quotes, with the date.** Your interpretation —
   if needed at all — goes on a separate line explicitly marked "interpretation:".
2. **Never upgrade the modality.** "Focus on X" ≠ "X is the only thing that matters".
   "Don't touch Y" ≠ "Y is dead". "Do X first" ≠ "never do Z". If the stronger reading would
   change how the project is described, ask the owner instead of assuming.
3. **Decisions are provenance-stamped.** Every recorded decision carries: who decided (owner vs
   agent-inferred), when, in which repo/session, and the verbatim trigger text. Repo A learned
   this the hard way too: sign-off commits cross-pushed between repos made it genuinely hard to
   establish what the owner had authorized WHERE. A tick in a checkbox is evidence a decision
   exists — not of what it covers. When provenance is ambiguous, confirm with the owner.
4. **One writer per repo.** Push only to Repo B. If work seems to require touching Repo A —
   even a doc — stop and hand it to the owner or the Repo A session.

---

## 4. SECURITY IS READ TWICE, WRITTEN ONCE (incidents: guard-password typo; sw.js bug; gitleaks history)

**What happened.** (a) A hardcoded password TYPO sat in guard scripts until a later session
caught it (`52460da`) — a security test that can silently test the wrong thing is worse than no
test, because it produces false confidence. (b) A service-worker bug shipped (`respondWith`
undefined + `res.clone()` inside an async callback, fixed in `bedb690`) — the SW path was
committed without being exercised. (c) The shared lineage has a history of gitleaks incidents
(false-positive on doc prose in Repo A; the secret-scan CI job exists for a reason).

**RULES — secrets:**
1. **No secret ever enters a committed file.** Not in code, not in docs, not in commit messages,
   not in guard scripts as "test creds" that resemble real ones. `.env` (gitignored) for runtime
   keys; the anon/publishable key is the ONLY Supabase key that may reach client config; the
   service_role key and DB passwords exist only in the owner's hands and in ephemeral shell
   commands — never on disk in the repo.
2. **Before every push:** `git diff origin/<branch>..HEAD | grep -iE "key|token|secret|password|bearer"`
   and read every hit. 30 seconds; catches the career-ending class of mistake.
3. **URLs with embedded credentials** (`postgresql://user:pass@…`) never go into files. Shell
   invocation only, and never echoed into logs you then paste into a doc.

**RULES — security-relevant code (RLS, guards, auth, money):**
4. **Read security code back CHARACTER BY CHARACTER after writing it.** A typo in a test
   password, a permission key, a role name, or a policy expression makes the guard test a
   different thing than you think it tests. After writing a guard: run it, then deliberately
   BREAK the thing it protects and run it again — a guard that cannot fail when the protection
   is removed is not a guard. (Repo A's guard batteries are trusted precisely because several
   caught real bugs on their first run: a balance-sheet double-subtraction, expenses posted to
   inventory. A guard that has never caught anything should make you suspicious of the guard.)
5. **The security review checklist for any new table/function** (all proven necessary in this
   codebase's history): RLS enabled AND forced · zero grants to anon · writes function-only for
   governed domains (revoke INSERT/UPDATE/DELETE; SECURITY DEFINER functions with
   `set search_path = ''`) · every function validates actor (`current_app_user_id`), permission
   (`has_permission`), and branch membership (`is_branch_member`) BEFORE any write · money is
   `numeric`, never float · journals balance by construction (one Dr, one Cr, same amount) ·
   corrections are reversal-by-addition, never UPDATE/DELETE of posted rows · idempotency key
   checked before commit · cross-tenant probes in the guard (company B actor vs company A data).
6. **Code that runs in a different runtime than your checks** (service workers, Edge Functions,
   Deno, browser-only APIs) gets exercised in THAT runtime before commit — `tsc` passing means
   nothing about `respondWith` semantics. If you genuinely cannot run it (no deploy target yet),
   the commit message and STATUS entry must say "static checks only — NOT exercised", so nobody
   downstream mistakes it for tested code.

---

## 5. FINDING BUGS BEFORE THE REVIEWER DOES (the patterns that caught real bugs, with receipts)

These five patterns each caught at least one real shipped-code bug in this codebase's lineage.
Run them as a battery on your own work BEFORE calling anything done:

1. **Test the OTHER role.** Strip the permission set down (in mock: edit the seeded snapshot;
   in guards: use the worker fixture) and walk the same flow. — *Caught: read-only users could
   not open a timed calendar block at all; the tap handler no-oped without `canManage`.*
2. **Non-zero fixtures.** Zero-valued test data hides sign errors and double-counting. Every
   fixture that CAN be non-zero SHOULD be non-zero, and asymmetric (180 vs 270, not 100 vs 100 —
   symmetric values hide swapped operands). — *Caught: `balance_sheet()` double-subtracted
   Owner's Drawings; invisible at drawings=0, exposed by the guard's non-zero fixture.*
3. **Read state back from the STORE, not the UI.** After any action, query IndexedDB/Postgres
   directly and compare with what the UI claims. — *Caught: fast drag gestures silently dropped
   their persist; the UI looked right, the database said otherwise.*
4. **Hunt false-success paths in your own diff.** Before commit, reread the diff asking exactly
   one question per branch: *can this path report success without doing the work?* Silent
   `if (found) { … } notify("done")` shapes are the classic. — *Caught: an edit modal that said
   "Event updated" when the record lookup missed and nothing was written.*
5. **Re-derive cross-module implications from scratch.** When building on an earlier module,
   do not assume it is complete — recompute what it SHOULD have done from the authority spec.
   — *Caught: two latent GL bugs in already-committed inventory/POS code (expenses booked to
   inventory; opening balances never posted to the GL), found only because the accounting module
   re-derived the postings instead of trusting them.*

**Meta-rule:** your first test of a feature should try to make it FAIL, not to make it pass.
The happy path proving itself is the least information-dense test you can run. Also test your
TEST: a check that cannot distinguish success from failure (e.g. a case-sensitive string match
against CSS-uppercased text — a real Repo A false-alarm) wastes a debugging cycle; when a check
fails, first ask "is the check wrong?" — but prove it either way before moving on.

---

## 6. VERIFICATION IS A CHAIN, NOT A CHECKBOX

The Engineering Loop you already run (Objective → Define → Challenge → Attack → Defend → Audit →
Revise → Decision → Lock) is right. These rules keep it honest:

1. **"Verified" always names its evidence.** Not "tests pass" but "vitest 89/89 · tsc exit 0 ·
   build 5.9s · guard battery 11/11 PASS · browser E2E: [specific flow] → [specific observed
   state]". A number that can't be wrong ("all good") is not evidence.
2. **Never round up.** STATUS.md's rule is absolute: a feature is Done only when committed AND
   pushed AND that specific flow exercised. "Compiles" is not "works". "Queued" is not "done" —
   and to your credit, Repo B's "queued, not faked" scope notes already do this well; keep them.
3. **Full-suite attacks after ANY migration:** `supabase db reset` from zero + EVERY guard
   battery, not just the new one. Drop+recreate of a shared function can break a sibling
   module's battery; only the full suite proves it didn't.
4. **CI is confirmed, not assumed.** After push, check the actual run result before recording
   "CI green" anywhere. Trial-and-error CI commits ("trigger CI to see what happens") are a
   smell: reproduce the pipeline step locally first (the npm scripts exist for exactly this).
5. **When a subagent/workflow/tool dies mid-task, it produced NOTHING.** Write results only
   from evidence you personally observed. Fabricating a plausible summary of lost work is the
   fastest way to poison every downstream document.

---

## 7. SESSION PROTOCOL (start and end, both blocking)

**Start:**
1. `git status --short` · `git log --oneline -5` · `git fetch origin` — compare local vs remote.
   Expect drift (the owner and other sessions push); `git pull --rebase` unpublished work; never
   force-push a shared branch.
2. Account for every dirty path BEFORE new work (see §1.5 — this is the check that would have
   flagged the Bubblewrap damage at the next session's start).
3. Read STATUS.md, then the newest handoff sections. Note which claims are verified vs queued.
4. Re-verify cheap invariants: `npm run lint`/tsc, unit tests. 60 seconds; catches drift that
   docs missed.

**End:**
1. Tree clean or every dirty path documented with a reason (§1.5).
2. STATUS.md + handoff updated with: what changed, evidence per claim, what is queued and what
   input it waits on. Append-only; never rewrite history entries.
3. Every commit this session: staged-by-path, message names the authority (spec §, owner quote,
   incident) that justified it.
4. Nothing pushed that CI hasn't been (or won't immediately be) run against; record run results
   when they land.

---

## 8. WHEN TO STOP (gates)

1. **Money paths** (anything posting to the GL: sales, settle, void, cash entries, payroll,
   payments, transfers): require the cross-vendor review + the owner's sign-off recorded in THIS
   repo before building, and a fresh review before locking. A GO verdict in a review is NOT
   authorization — the owner's explicit sign-off is.
2. **Migrations are immutable once committed.** Evolve by NEW additive migrations
   (drop+recreate functions is fine; editing an old migration file never is).
3. **Owner-gated infra** (hosting, Play Console, branch protection, key rotation): prepare,
   document, queue — never execute the owner's half.
4. **If no authority exists for a change, STOP and surface the gap** (CLAUDE.md §2). Momentum
   is not authority. An imperfection you noticed is not automatically your mission (scope
   discipline) — log it, propose it, await the GO.
5. Ending a session at a gate, with everything verified and documented up to that gate, is
   SUCCESS. The failure mode is inventing permission to keep moving.

---

## 9. SELF-AUDIT BEFORE EVERY COMMIT (the 60-second ritual)

Run this literally, every time:

```
git status --short                    # every line accounted for?
git diff --cached --stat              # is everything staged deliberate, by path?
git diff --cached | grep -iE "key|token|secret|password"   # secrets sweep
```
Then answer, in one line each, in your head or your log:
1. What authority justifies this change? (spec §, owner quote, incident fix)
2. What EVIDENCE shows it works? (commands + results, not adjectives)
3. Which false-success path did I hunt for in this diff, and what did I find?
4. Does any doc I touched reference its own commit or contain a placeholder? (§2)
5. If this commit were reverted tomorrow, does the message alone explain what was lost?

If any answer is missing, the commit is not ready. Five minutes of ritual is cheaper than one
fold-spiral, one false "Done", or one deleted `app/`.

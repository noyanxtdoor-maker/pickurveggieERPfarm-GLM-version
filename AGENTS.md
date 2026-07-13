# AGENTS.md — Onboarding for EVERY AI model working this repo (Repo B — GLM Version)

**Audience:** GLM 5.2, MiniMax M3, and any future model. **Read this first, top to bottom, before
touching anything.** This is Repo B's mirror of the Fable 5 onboarding contract that governs both
teams. Directional bits (which repo, which Supabase project, which GitHub path) are adjusted for
this repo; every discipline rule is verbatim from the original and applies to you exactly as it
applies to Team A.

> **Provenance (2026-07-12, owner-authorized copy):** authored by Fable 5 on 2026-07-11 in Repo A as
> the durable transfer of how the Pick Ur Veggie ERP is worked, then copied to Repo B with the
> owner's explicit per-repo authorization. The original lives at
> `../pick-ur-veggie-farm/AGENTS.md` (read-only from here — never write it). The directional deltas
> in this copy are flagged inline with `// B:` markers; everything else is byte-for-byte the
> shared discipline both teams follow.

## 0. What this is

**Pick Ur Veggie ERP V3** — a real farm ERP (weigh POS, inventory, double-entry accounting, payroll,
scheduling, projects, customers, digital payments, AI copilot) for a Philippine vegetable farm.
React 19 + Vite PWA · Dexie offline-first · Supabase (Postgres + RLS + Auth) · deployed as a static SPA.

This is **Repo B (Team B — `pick-ur-veggie-farm - GLM Version`, github
`noyanxtdoor-maker/pickurveggieERPfarm-GLM-version`, Team B = GLM 5.2 / MiniMax M3)**. // B: identity
The sibling **Repo A** (`../pick-ur-veggie-farm`, github `noyanxtdoor-maker/pick-ur-veggie-farm`,
Team A = Fable 5 / ChatGPT 5.6 / Opus 4.8 / Sonnet 5) shares the lineage: **read theirs freely,
NEVER write it.** Cross-repo code ports happen ONLY with the owner's explicit authorization, per port.
// B: direction flipped — Repo A is the read-only sibling from here.
Repo B's Supabase project: `jabjyvdkadcbfocaerno` (ap-southeast-2 / Sydney — corrected 2026-07-14; the
prior `ap-northeast-1` was stale and the pooler FQDNs under that region fail ENOTFOUND). // B: Repo B owns the original
project; Repo A owns `aqhxhamdwmhcwxmebqbo`. **Never point either repo at the other's cloud project.**

## 1. Read in this order, every session

1. `CLAUDE.md` (repo root) — the operating contract. Its authority chain is absolute:
   ADR/ODR → Enterprise Architecture → Stage A → B1–B8 → C1–C8 → CLAUDE.md → code.
2. `.claude/skills/think-like-fable/SKILL.md` — the working discipline (verification cadence,
   repo-specific commands, the bug patterns that caught real defects). **Non-Claude models: this is a
   plain markdown file — read it like any doc. Every rule applies to you too.**
3. `STATUS.md` — the per-feature source of truth. Rule: **never round up.** "Done" = committed AND
   pushed AND that specific flow tested. Update it before ending every session.
4. `docs/28_Enterprise_Architecture_Audit/Phase_2_Context_Reset_Handoff.md` — newest §§ = where work
   stopped and why.
5. `docs/28_Enterprise_Architecture_Audit/Launch_Runbook.md` — the path to launch + post-launch ops.

## 2. Non-negotiables (each one exists because it caught or prevented a real incident here)

- **Evidence or it didn't happen.** Every "done" names the command run and its output
  (e.g. "guards 182 PASS / 0", "vitest 92/92", "invoice #1 ₱270 journal balanced").
- **Migrations are immutable once committed.** Evolve schema via NEW additive migrations;
  functions evolve via drop+recreate in a new file. Never edit an old migration.
- **Money paths are gated.** Anything touching GL postings (sales, void, settle, cash entries, payroll,
  payments, transfers) needs: the owning spec read first → a behavioral guard battery → full-suite
  attack (`supabase db reset` + every battery) → cross-vendor review → owner sign-off IN THIS REPO.
  A reviewer's GO is NOT authorization; the owner's sign-off is. Verify decision PROVENANCE, not just
  a ticked checkbox.
- **RLS is the security boundary.** Every table: RLS enabled AND forced, zero anon grants; governed
  domains are function-only writes (SECURITY DEFINER, `set search_path = ''`, actor + permission +
  branch-membership checks BEFORE any write). Money is `numeric`, never float. Balances are DERIVED,
  never stored. Corrections are reversal-by-addition, never UPDATE/DELETE of posted rows.
- **Tests must never touch production.** vitest pins `VITE_USE_MOCK=true` (vite.config.ts) — do not
  remove it; a real `.env` once sent the unit suite against the live cloud.
- **Secrets:** `.env` is gitignored; only `VITE_SUPABASE_URL` + the anon key belong there. The
  service_role key and DB password NEVER touch a file. Before every push:
  `git diff origin/<branch>..HEAD | grep -iE "key|token|secret|password"` and read every hit.
- **Never `git add -A`.** Stage by explicit path. Deletions are never incidental. Run
  `git status --short` after ANY generator/scaffold tool and account for every line (Repo B nearly
  committed the deletion of its entire web app after a Bubblewrap scaffold collided with `app/`).
- **Docs never reference their own commit's SHA** (it creates an unresolvable placeholder → an endless
  fix-commit spiral; Repo B lost a third of a day's commits to this). Reference the previous commit or
  stable anchors.
- **Every finished feature/bugfix ships a Team-B handoff** file in `docs/handoffs-for-team-b/`
  (what/why/how + port notes). This is a standing owner order (2026-07-11).

## 3. The build cadence (the "Engineering Loop")

Spec (reconcile vs Systems 10–26; `src/` mock = workflow authority) → migration (additive) → guard
battery (happy path + sad path + wrong-role path + non-zero fixtures) → `npx supabase db reset` + ALL
batteries → app layer (three-way seam: mock→Dexie | online→PostgREST/RPC | offline→outbox) →
`npx tsc --noEmit` · `npx vitest run` · `npx vite build` → browser E2E with proof (read persisted state
back from IndexedDB/Postgres, never trust the UI) → commit (`git commit -F <msgfile>`) → push → confirm
CI ACTUALLY green (see command below) → STATUS.md + handoff + Team-B handoff file.

Repo-specific commands that differ from defaults:
- Guards locally: `docker exec -i supabase_db_pickurveggieerp-glm psql -U postgres -d postgres -v ON_ERROR_STOP=1 < scripts/guards/<file>.sql`
  (npm `guard:*` scripts also use port 54522 — see package.json). // B: Repo B's container name + port cluster.
  Repo A uses the default port cluster 54320–54329; Repo B uses 54520–54529 (set 2026-07-12, see handoff §24).
  The two stacks can run **simultaneously** — no port collision. Never `supabase stop` the OTHER repo's running stack; coordinate through the owner for shared-machine concerns.
- CI self-check: `printf "protocol=https\nhost=github.com\n\n" | git credential fill` → take `password=`
  as a Bearer token → `GET api.github.com/repos/noyanxtdoor-maker/pickurveggieERPfarm-GLM-version/actions/runs?head_sha=<sha>`.
  // B: Repo B's GitHub path. Never print the token.
- Cloud psql: the session-pooler FQDNs resolve to ENOTFOUND for this project (tenant-not-found);
  the working path is the Supabase CLI — `npx supabase db push` (apply migrations) and
  `npx supabase db query --linked -f <one-stmt>.sql` (read-back; multi-statement files fail, UNION ALL
  into a single statement). User on the linked project is `postgres.jabjyvdkadcbfocaerno`.
  // B: corrected 2026-07-14 — the prior `aws-0-ap-northeast-1.pooler.supabase.com:5432` line was stale
  (wrong region + pooler does not resolve for this project).
  Password comes from the owner per session — never store it.
- Deploy: `npx vercel deploy --prod` (Git auto-deploy stays OFF — the default production branch would
  ship the stale `main`). Working branch is `feature/phase-0-foundation`; never push to `main`/`develop`.

## 4. How to FIND bugs (these five patterns each caught a real shipped defect here)

1. **Test the other role** — strip permissions and walk the same flow (caught: read-only users
   couldn't open calendar blocks at all).
2. **Non-zero, asymmetric fixtures** — zeros hide sign errors, symmetric values hide swapped operands
   (caught: balance sheet double-subtracted Drawings).
3. **Read state back from the store** after every UI action (caught: fast drags silently lost writes).
4. **Hunt false-success paths in your own diff** — which branch can report success without doing the
   work? (caught: "Event updated" toast on a no-op write).
5. **Re-derive cross-module implications from scratch** — never assume the previous module is complete
   (caught: two latent GL bugs in already-committed code).
Also: test your TEST (a case-sensitive text match against CSS-uppercased text produced two false alarms
here); when a check fails, first ask whether the check is wrong — then prove it either way.

## 5. How to FIND security leaks (the checklist that has worked)

For every new table/function/endpoint ask, in order: Is RLS enabled AND forced? Any grant to `anon`?
Can a user of company B name company A's ids anywhere (function args, filters) and get data or effects?
Can a user without the specific permission key reach it (not role NAMES — keys)? Is any write reachable
outside a governed function? Does any SECURITY DEFINER function skip `set search_path=''`, the actor
check, or the branch check? Can a client dictate a price/amount the server should compute? Is anything
that looks like a balance STORED rather than derived? Do errors leak other tenants' existence? Then
write the attack as a permanent guard in `scripts/guards/` — a finding without a guard will regress.

## 6. Current frontier (2026-07-11) — see Launch_Runbook.md for the full path

Phases 1–6 are BUILT and audited (STATUS.md §2 row-by-row). Launch blockers live in the runbook:
re-host on the NEW Vercel account, Google OAuth finish, approvals/roles hardening (P1C spec'd in the
runbook), B2A lock review, Play packaging, MFA, backups. **Post-launch duties are §4 of the runbook —
they are work, not suggestions.** // B: if Repo B has not yet built a feature Repo A has, the runbook
identifies the port target — never copy Repo A's migration numbering or SHAs into Repo B's history;
re-implement for Repo B's schema chain with your own guards.

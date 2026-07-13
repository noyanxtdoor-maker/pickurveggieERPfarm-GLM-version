# Handoff 005 — Phase 7 Branch-Protection Recovery Template (port from team-A)

**Date:** 2026-07-13
**Ported from:** team-A commit `31f6397` (authored 2026-07-12 by Claude Fable 5)
**Commit in Repo B:** (this handoff will be committed alongside the ported file)
**Owner GO:** "proceed to track B" (2026-07-13)

## What / Why

Team-A added `docs/28_Enterprise_Architecture_Audit/Phase_7_Branch_Protection_RepoA.md`
in commit `31f6397` — an exact spec of the branch-protection ruleset they wanted
applied to Repo A, including the JSON body for a PAT-scoped agent to apply it
via the GitHub API. Their commit also corrected an earlier "branch protection
DONE on Repo A" claim that was a round-up (the PAT lacked Administration:write,
so neither visibility nor the ruleset was actually applied).

Repo B's ruleset IS already Active (id `18794543`, applied 2026-07-11), so a
straight port of team-A's file is not actionable — Repo B doesn't need to apply
its ruleset. But the spec is valuable as a **recovery template**: if Repo B's
ruleset is ever deleted or broken by accident, an agent needs the exact JSON
body to re-apply it in one call. Without this file, that knowledge is lost the
moment the ruleset is gone.

## How

- Read team-A's `Phase_7_Branch_Protection_RepoA.md` (sibling repo, read-only).
- authored Repo B's mirror as `Phase_7_Branch_Protection_RepoB.md` (the
  `...RepoB` suffix keeps it distinct from team-A's `...RepoA` file).
- Directional bits flipped for Repo B: GitHub path (`pickurveggieERPfarm-GLM-version`
  not `pick-ur-veggie-farm`), "ruleset already Active id 18794543", Repo B's
  `package.json` has the public `postgres` placeholder (not a secret), file
  title says "recovery template" so future agents don't re-apply on top of a
  healthy ruleset.
- Rules and JSON body kept byte-identical to team-A's spec — both repos use the
  same protection shape on the same CI check names (`Verify`, `Secret scan`,
  `DB guards`).

## Port notes (for the standing order)

- **Not a code/migration change** — doc-only addition. No `db reset`, no guard
  battery, no `tsc`/`vitest`/`build` impact.
- The earlier Track B pre-flight (this session) confirmed all OTHER items from
  team-A's 3 new commits (`9a02435`, `1606ff6`, `31f6397`) were already ported
  to Repo B by `e01aa41` ("docs(onboarding): port Fable 5 instruction set from
  Repo A → Repo B"). The Launch_Runbook section 5 correction from `31f6397`
  was already in Repo B's mirror copy (verified: lines 136-138 say "Repo B's
  ruleset IS already Active (id 18794543); verify before launch rather than
  re-applying"). So this `Phase_7_Branch_Protection_RepoB.md` port was the
  only genuinely-missing piece.
- **No STATUS.md edit needed** — this is a doc-only port; STATUS row-by-row
  is unaffected.

## Verification

- `docs/28_Enterprise_Architecture_Audit/Phase_7_Branch_Protection_RepoB.md`
  exists, 80 lines, parked alongside the existing `Phase_7_Hosting_Decision_Pack.md`
  and `Phase_7_Synthesis_and_Remediation_Roadmap.md`.
- Provenance section inside the file names the source file + commit + owner GO
  + port date (per Repo B convention for mirrored docs).
- No app code touched (no `.tsx`/`.ts`/`.sql` files changed).

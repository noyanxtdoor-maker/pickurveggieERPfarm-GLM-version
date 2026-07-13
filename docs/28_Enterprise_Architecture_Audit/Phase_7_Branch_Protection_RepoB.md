# Repo B — Branch Protection Ruleset (exact settings, recovery template)

> **Owner's standing order (2026-07-12):** this is Repo B's mirror of team-A's
> `Phase_7_Branch_Protection_RepoA.md` (their file lives in the sibling repo,
> read-only from here). The ruleset on Repo B IS already Active
> (GitHub path `noyanxtdoor-maker/pickurveggieERPfarm-GLM-version`, ruleset id
> `18794543`, applied 2026-07-11). This file exists ONLY as a recovery template:
> if the ruleset is ever deleted or broken, an agent with a properly-scoped PAT
> can re-apply it in one call using the JSON body below. Do NOT re-apply it now
> while the existing ruleset is healthy — that would be redundant and would
> change the ruleset id.

## Status (2026-07-13)
- Repo B: **public**, ruleset `protect-main-and-develop` **Active** (id `18794543`).
- Repo A (sibling, read-only from here): ruleset NOT yet applied — the PAT used
  2026-07-11 lacked *Administration:write*. Repo A's situation is tracked in
  team-A's own `Phase_7_Branch_Protection_RepoA.md`; do not edit that file from here.

## Prerequisite (Free tier)
Rulesets require the repo to be **Public** OR the account on **GitHub Pro**.
Repo B was made public 2026-07-11. Tracked files are secret-clean: `.env` is
gitignored (only `VITE_SUPABASE_URL` + anon key belong there, and the anon key
is designed-public); the service_role key and DB password NEVER touch a file;
RLS is the security boundary. Verified via `git grep` for
key/token/secret/password = no real-secret hits (only the local-dev placeholder
`postgres` in `package.json` guard URLs — that's the local-dev password, not a
production secret).

## Ruleset: `protect-main-and-develop`
- **Enforcement:** Active
- **Target branches:** `main` and `develop` (add both; the working branch
  `feature/phase-0-foundation` stays unprotected so daily work continues).
- **Rules** (identical to Repo A's spec — same protection on both repos):
  - ✅ Restrict deletions
  - ✅ Block force pushes
  - ✅ Require a pull request before merging
    - Required approvals: **0** (GitHub forbids self-approval; 0 + required PR
      + required CI + no direct push is the strongest honest solo config)
    - ✅ Dismiss stale approvals on new commits
    - ✅ Require approval of the most recent reviewable push
    - ❌ Require Code Owner review (no CODEOWNERS file — would block all merges)
  - ✅ Require status checks to pass before merging
    - ✅ Require branches to be up to date before merging (strict)
    - Required checks (add exactly the names GitHub shows from a green Actions
      run on Repo B):
      **`Verify (install · type · test · build)`**, **`Secret scan`**,
      **`DB guards (RLS · tenant · audit · drift · no-role-name · no-float)`**
  - ✅ Require conversation resolution before merging
  - ❌ Require signed commits (not required at current scale)
  - ❌ Require linear history

## Recovery: for an agent with a properly-scoped PAT
If the ruleset is ever lost, `POST /repos/noyanxtdoor-maker/pickurveggieERPfarm-GLM-version/rulesets`
with this body:
```json
{
  "name": "protect-main-and-develop",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["refs/heads/main", "refs/heads/develop"], "exclude": []}},
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {"required_approving_review_count": 0, "dismiss_stale_reviews_on_push": true, "require_code_owner_review": false, "require_last_push_approval": true, "required_review_thread_resolution": true}},
    {"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": true, "required_status_checks": [{"context": "Verify (install · type · test · build)"}, {"context": "Secret scan"}, {"context": "DB guards (RLS · tenant · audit · drift · no-role-name · no-float)"}]}}
  ]
}
```
Verify after: `GET /repos/noyanxtdoor-maker/pickurveggieERPfarm-GLM-version/rulesets`
shows it Active; a direct push to `main` is rejected. **Do not run this unless
the existing ruleset (id `18794543`) is confirmed gone or broken** — re-applying
on top of a healthy ruleset changes the id and is not free of side effects.

## Provenance
Ported from team-A's `docs/28_Enterprise_Architecture_Audit/Phase_7_Branch_Protection_RepoA.md`
(commit `31f6397`, authored 2026-07-12) on 2026-07-13 with owner GO ("proceed
to track B"). The directional bits (Repo B's GitHub path, "ruleset already
Active" status, secret-clean verification pointing at Repo B's files) are
flipped for Repo B; the rules and JSON body are byte-identical to team-A's spec
because both repos use the same protection shape on the same CI check names.
This Repo-B mirror is named `Phase_7_Branch_Protection_RepoB.md` to keep it
distinct from team-A's file (the sibling-repo original is named `...RepoA.md`).

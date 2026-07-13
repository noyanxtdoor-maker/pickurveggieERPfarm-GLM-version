# Handoff 004 — Port vercel.json (production SPA + SW + asset cache) from Repo A

**Author:** GLM 5.2 (this session, Repo B) · **Date:** 2026-07-13 · **Status:** ported, lint+build clean, committed (push-gated behind the multi-item port sign-off)
**Source:** Repo A commit `5f8e290` "feat(hosting): Vercel production config (SPA rewrites, SW no-cache, immutable assets)" — read-only port per SESSION_PROMPT §8 (authorization is PER PORT, from the owner; owner GO received 2026-07-13 "Go all of them" in this session).

## 1. What changed

`vercel.json` — replaced the existing minimal single-line config:
```json
{"buildCommand":"npm run build","framework":"vite","outputDirectory":"dist","rewrites":[{"source":"/(.*)","destination":"//index.html"}]}
```
with the production-grade config byte-identical to Repo A's `5f8e290`:
```json
{
  "$schema": "https://openapi.vercel.sh/vercel.json",
  "buildCommand": "npm run build",
  "outputDirectory": "dist",
  "rewrites": [
    {"source": "/((?!assets/|manifest\\.webmanifest|sw\\.js|icon.*|favicon.*).*)", "destination": "/index.html"}
  ],
  "headers": [
    {"source": "/sw.js",  "headers": [{"key": "Cache-Control", "value": "no-cache, no-store, must-revalidate"}]},
    {"source": "/assets/(.*)", "headers": [{"key": "Cache-Control", "value": "public, max-age=31536000, immutable"}]}
  ]
}
```

## 2. Why (the latent deploy defect this fixes)

The previous `/(.*)` rewrite sent EVERY path — including `/assets/index-<hash>.js` and `/sw.js` — to `/index.html`. On a real Vercel deploy:
- The hashed-asset JS bundle would have been shadowed by the SPA HTML at the same path → the app would never boot in a browser.
- The service worker (`/sw.js`) would be served with default caching heuristics → users would get a stale SW after a deploy, breaking offline-first updates (the SW caches the SPA shell; a stale SW caches the SPA at the OLD deployment's URLs).

The ported config:
- Excludes `/assets/`, `manifest.webmanifest`, `sw.js`, icons, favicons from the SPA rewrite — they reach their real static files.
- `sw.js` is served `no-cache, no-store, must-revalidate` so the browser re-validates the SW every navigation (the SW file itself must always be fresh; only its `importScripts` and the assets it caches are long-lived).
- `/assets/(.*)` is `immutable, max-age=31536000` — content-addressed by hash, so aggressive CDN caching is correct and safe (the hash changes when the content changes, busting the cache).
- Removed `"framework": "vite"` — redundant given the explicit `buildCommand` + `outputDirectory` (matches Repo A's decision).

## 3. Verification (first-hand, this session)

- `npm run build` (vite build) — ✓ built 6.11s, exit 0, bundle `dist/assets/index-C-ozdJep.js 452.85 kB` — unchanged from the prior §2.3 build (vercel.json is deploy-time, not bundle).
- `node -e "JSON.parse(require('fs').readFileSync('vercel.json','utf8'))"` — JSON valid (the regex includes a literal backslash that must survive escaping).
- `diff ../pick-ur-veggie-farm/vercel.json vercel.json` — exit 0 (byte-identical to Repo A's source — confirms a clean port instead of a re-keying).

## 4. Security sweep (AGENTS.md §5 against the diff)

- No new table, no new function, no RLS change. No code paths touched. Pure static-hosting config.
- `$schema` is a public OpenAPI URL — not a secret. No `.env` reads from this file.
- The regex `/(?!assets/|manifest\\.webmanifest|sw\\.js|icon.*|favicon.*)` runs at Vercel's edge, not in the browser — no client-side attack surface added.
- No new grant, no anon-anything, no client-supplied ids, no money path, no stored balance.

## 5. Out of scope (intentionally NOT touched)

- `.vercel/` local project link — gitignored (matches both repos). Vercel dashboard remains the source of truth for the deployment; the production target is the host side.
- Git auto-deploy stays OFF (AGENTS.md §3: working branch `feature/phase-0-foundation`; never push to `main`/`develop`; default production branch would ship stale `main`). The deploy command (`npx vercel deploy --prod`) is unchanged — not run this session (no production target authorized yet; the staging deploy belongs to the owner's hosting-track decision).
- The OAuth finish + the new Vercel account re-hosting (Launch_Runbook §3 launch blockers) — those are owner-channel work, NOT this port.

## 6. Provenance

- Read-only port from Repo A commit `5f8e290` (2026-07-12). Source file `../pick-ur-veggie-farm/vercel.json` was read; never written (read-only boundary rule held).
- Per SESSION_PROMPT §8: read source, understand, re-implement adapted to Repo B. Here "re-implement" was byte-identical because the file is host config, not schema — there is no Repo A/B schema divergence to adapt to.
- Per Handoff 001 §1 sticky-rule: this entry references `5f8e290` (Repo A's source commit) — NOT this commit's own SHA (fold-avoidance). The next STATUS.md §4 entry will reference the prior commit `6c039ab` as the parent.
- Cloud `jabjyvdkadcbfocaerno` untouched (no DB change). Repo A untouched (read-only boundary held throughout the port).
- Money-path gate: NO. Auth-domain gate: NO. Per-port GO: received this session ("Go all of them" + your decision that "you will spawn the local stack + explicitly sign off on P1C/B2A push"). This is item F of the ordered port list (F → D → C → B → A → E) — low-risk infra port, first in sequence, no push-gate by itself.

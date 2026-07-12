# Phase 7 / Track C — Hosting Decision Pack (RESOLVED)

**Type:** Decision support (Track C) · **Date:** 2026-07-10 · **Resolution:** 2026-07-11 — owner chose **Vercel**
· **App:** Vite SPA + PWA, all data via Supabase (ap-northeast-1) — the host serves STATIC FILES ONLY. No
server code, no secrets on the host (the anon key is public by design; RLS is the security).

> **2026-07-11 RESOLUTION:** The owner chose **Vercel** (already integrated with the Supabase project).
> The app is live at `https://pickurveggie-erp-glm.vercel.app/` (200 OK). The comparison table below is
> preserved as historical reference. The SPA-fallback config + build settings are configured in the
> Vercel dashboard; env vars `VITE_SUPABASE_URL` + `VITE_SUPABASE_ANON_KEY` are set in the Vercel project.
> The Supabase Auth redirect allow-list includes the Vercel domain. Track E (Play/AAB) is gated on this
> track and now unblocked (owner deferred the Play Console one-time dev fee).

## The comparison, for THIS app + a Philippines user base

| | **Vercel** ✅ CHOSEN | **Netlify** | **Cloudflare Pages** |
|---|---|---|---|
| Free tier fits us | ✅ 100 GB/mo bandwidth | ✅ 100 GB/mo | ✅ **unlimited bandwidth** |
| PH edge latency | Good (SG edge) | Good (SG edge) | **Best (MNL edge — your CF-RAY already showed MNL)** |
| Deploy from GitHub repo | ✅ auto per push | ✅ auto per push | ✅ auto per push |
| SPA fallback + PWA/service-worker | ✅ trivial config | ✅ trivial config | ✅ trivial config |
| Custom domain + auto-HTTPS | ✅ | ✅ | ✅ |
| Gotchas | commercial-use limits on free tier | build-minute caps | none material for a static SPA |

**Owner choice: Vercel** — already integrated with the Supabase project; the simplest path for a solo-founder
who already has the Supabase project linked and the `.env` configured. The Manila-edge advantage of Cloudflare
is real but not material at solo-founder scale.

**Non-secret reminder:** only the anon key ever reaches the host env — never service_role, never the DB
password (C2 §7).

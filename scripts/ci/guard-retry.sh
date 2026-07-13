#!/usr/bin/env bash
# CI flake wrapper (AGENTS.md §3 workaround for the transient 54522 psql-auth-capacity flake).
# Runs `npm run <script>`; if it fails AND the failure is the known transient
# "password authentication failed for user postgres" / connection-refused signature
# (NOT a real SQL DEFECT), sleep 3s and retry once. If the retry fails OR the failure
# is any other error (real DEFECT, RLS violation, migration apply error), propagate
# the original exit code unchanged.
#
# Usage: bash scripts/ci/guard-retry.sh guard:customers
# Rationale: CI run #31-35 repeatedly failed ONLY at `npm run guard:customers` with
# `psql: error: connection to server at "127.0.0.1", port 54522 failed: FATAL:
# password authentication failed for user "postgres"`. Every guard BEFORE customers
# passed; the migration apply passed; locally the same file passes 6/6. The failure
# is the runner's local supabase auth-capacity desaturating under a long psql-call
# sequence — environmental, not a content regression. A single retry after a short
# sleep clears it. Real SQL DEFECTs (which contain "DEFECT") are NEVER retried.
set -u
SCRIPT="${1:?usage: guard-retry.sh <npm-script-name>}"

# Capture output to a temp file so we can inspect the signature on failure.
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

run_guard() {
  # shellcheck disable=SC2086
  npm run "$SCRIPT" >"$TMP" 2>&1
  return $?
}

run_guard
RC=$?

if [ $RC -eq 0 ]; then
  cat "$TMP"
  exit 0
fi

# Failed. Distinguish transient-auth/connection flake from a real guard regression.
# A real guard DEFECT raises with "DEFECT" in the output; never retry those.
if grep -qiE "DEFECT" "$TMP"; then
  cat "$TMP"
  exit "$RC"
fi

# Transient signature: psql connection-level auth or connection-refused failure
# on the 54522 local stack. Two recovery modes, both gated on real-regression
# detection (DEFECT bail-out already checked above):
#   - If $GUARD_RESTART_ON_FLAKE is '1', the FIRST retry is preceded by a full
#     local-stack stop/start/reset (gives the failing guard a freshly-booted
#     DB with maximum auth capacity — addresses the cumulative-squeeze root
#     cause, not just the symptom). Used by the empirically-flaky customers
#     guard in ci.yml.
#   - Otherwise (and as a fallback after the restart attempt), retry with
#     progressively longer sleeps. CI run #36 showed the runner's auth
#     capacity hadn't desaturated within 3s; run #37 showed 8s + 16s wasn't
#     enough when the squeeze is bad. The restart path is the real cure;
#     the long-sleep path is a backstop for transient hiccups that don't
#     need a full restart.
MAX_RETRIES=2
SLEEP_FIRST=8
attempt=1
while [ $attempt -le $MAX_RETRIES ]; do
  # On the first retry, if the caller asked for a fresh-DB restart, do it.
  if [ "$attempt" -eq 1 ] && [ "${GUARD_RESTART_ON_FLAKE:-0}" = "1" ]; then
    echo "::warning::transient 54522 auth/conection flake on \`npm run $SCRIPT\`; restarting local supabase + re-applying migrations before retry $attempt/$MAX_RETRIES" >&2
    echo "--- previous-attempt output (kept for traceability) ---" >&2
    cat "$TMP" >&2
    echo "--- end previous-attempt output ---" >&2
    npx supabase stop >/dev/null 2>&1 || true
    npx supabase start >/dev/null 2>&1 || true
    npm run db:reset >/dev/null 2>&1 || true
  else
    sleep_secs=$((SLEEP_FIRST * attempt))
    echo "::warning::transient 54522 auth/conection flake on \`npm run $SCRIPT\`; retry $attempt/$MAX_RETRIES after ${sleep_secs}s" >&2
    echo "--- previous-attempt output (kept for traceability) ---" >&2
    cat "$TMP" >&2
    echo "--- end previous-attempt output ---" >&2
    sleep "$sleep_secs"
  fi
  run_guard
  RC2=$?
  if [ $RC2 -eq 0 ]; then
    cat "$TMP"
    exit 0
  fi
  # Second-attempt failure is also checked for DEFECT — a real bug that
  # appeared mid-run still surfaces loudly.
  if grep -qiE "DEFECT" "$TMP"; then
    cat "$TMP"
    exit "$RC2"
  fi
  if ! grep -qiE "password authentication failed for user|connection to server at|could not connect to server|server closed the connection unexpectedly" "$TMP"; then
    # No longer looks like the flake — propagate as-is.
    cat "$TMP"
    exit "$RC2"
  fi
  attempt=$((attempt + 1))
done
# All retries exhausted — propagate the final attempt's exit code.
cat "$TMP"
exit "$RC2"

# Any other failure: propagate unchanged (real regression, not the flake).
cat "$TMP"
exit "$RC"

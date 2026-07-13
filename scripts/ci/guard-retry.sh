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
# on the 54522 local stack. Retry once after a brief sleep.
if grep -qiE "password authentication failed for user|connection to server at|could not connect to server|server closed the connection unexpectedly" "$TMP"; then
  echo "::warning::transient 54522 auth/conection flake on \`npm run $SCRIPT\`; retrying once after 3s" >&2
  echo "--- first-attempt output (kept for traceability) ---" >&2
  cat "$TMP" >&2
  echo "--- end first-attempt output ---" >&2
  sleep 3
  run_guard
  RC2=$?
  cat "$TMP"
  exit "$RC2"
fi

# Any other failure: propagate unchanged (real regression, not the flake).
cat "$TMP"
exit "$RC"
